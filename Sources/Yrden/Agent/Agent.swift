/// Agent - Orchestration layer for LLM tool use and structured output.
///
/// An Agent:
/// 1. Sends prompts to an LLM
/// 2. Processes tool calls from the LLM response
/// 3. Feeds tool results back to the LLM
/// 4. Continues until the LLM provides a final answer
/// 5. Validates and returns typed output
///
/// ## Basic Usage
/// ```swift
/// // Define tools
/// struct SearchTool: AgentTool {
///     @Schema struct Args: SchemaType { let query: String }
///     var name: String { "search" }
///     var description: String { "Search the knowledge base" }
///
///     func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
///         return .success("Results for: \(arguments.query)")
///     }
/// }
///
/// // Create agent
/// let agent = Agent<Void, Report>(
///     model: claude,
///     systemPrompt: "You are a research assistant.",
///     tools: [AnyAgentTool(SearchTool())]
/// )
///
/// // Run
/// let result = try await agent.run("Find information about Swift", deps: ())
/// print(result.output)
/// ```

import Foundation

// MARK: - Agent

/// An agent that orchestrates LLM tool use and produces typed output.
public actor Agent<Deps: Sendable, Output: SchemaType> {
    /// The model to use for completions.
    public let model: any Model

    /// System prompt prepended to all conversations.
    public let systemPrompt: String

    /// Available tools.
    public let tools: [AnyAgentTool<Deps>]

    /// Output validators run after LLM produces output.
    public let outputValidators: [OutputValidator<Deps, Output>]

    /// Maximum iterations before failing.
    public let maxIterations: Int

    /// Usage limits for the run.
    public let usageLimits: UsageLimits

    /// Strategy for handling multiple tool calls.
    public let endStrategy: EndStrategy

    /// Name for the output tool (when using tool-based structured output).
    public let outputToolName: String

    /// Description for the output tool.
    public let outputToolDescription: String

    public init(
        model: any Model,
        systemPrompt: String = "",
        tools: [AnyAgentTool<Deps>] = [],
        outputValidators: [OutputValidator<Deps, Output>] = [],
        maxIterations: Int = 10,
        usageLimits: UsageLimits = .none,
        endStrategy: EndStrategy = .early,
        outputToolName: String = "final_result",
        outputToolDescription: String = "Provide the final result"
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.outputValidators = outputValidators
        self.maxIterations = maxIterations
        self.usageLimits = usageLimits
        self.endStrategy = endStrategy
        self.outputToolName = outputToolName
        self.outputToolDescription = outputToolDescription
    }

    // MARK: - Run

    /// Run the agent with the given prompt and return typed output.
    ///
    /// - Parameters:
    ///   - prompt: User prompt to start the conversation
    ///   - deps: Dependencies to pass to tools
    ///   - messageHistory: Optional previous messages to continue from
    /// - Returns: Final result with typed output and metadata
    /// - Throws: `AgentError` for agent-level failures, `LLMError` for provider failures
    public func run(
        _ prompt: String,
        deps: Deps,
        messageHistory: [Message] = []
    ) async throws -> AgentResult<Output> {
        let runID = UUID().uuidString
        var state = RunState(
            runID: runID,
            deps: deps,
            messages: messageHistory,
            usage: Usage(inputTokens: 0, outputTokens: 0)
        )

        // Add user message
        state.messages.append(.user(prompt))

        // Main agent loop
        while state.requestCount < maxIterations {
            // Check for cancellation
            try Task.checkCancellation()

            // Check usage limits
            try checkUsageLimits(state: state)

            // Build request
            let request = buildRequest(state: state)

            // Send to model
            let response = try await model.complete(request)
            state.requestCount += 1
            state.usage = accumulateUsage(current: state.usage, new: response.usage)

            // Add assistant message
            state.messages.append(.fromResponse(response))

            // Check for refusal
            if let refusal = response.refusal {
                throw AgentError.unexpectedModelBehavior("Model refused: \(refusal)")
            }

            // Handle response based on stop reason
            switch response.stopReason {
            case .endTurn, .stopSequence:
                // Try to extract output from text
                if let output = try await extractTextOutput(
                    response: response,
                    context: buildContext(state: state)
                ) {
                    return AgentResult(
                        output: output,
                        usage: state.usage,
                        messages: state.messages,
                        outputToolName: nil,
                        runID: runID,
                        requestCount: state.requestCount,
                        toolCallCount: state.toolCallCount
                    )
                }

                // If we have tool calls, process them
                if !response.toolCalls.isEmpty {
                    let result = try await processToolCalls(
                        response: response,
                        state: &state
                    )
                    if let output = result {
                        return output
                    }
                    // Continue loop with tool results
                    continue
                }

                // No output and no tools - unexpected
                throw AgentError.unexpectedModelBehavior("Model ended without output or tool calls")

            case .toolUse:
                // Process tool calls
                let result = try await processToolCalls(
                    response: response,
                    state: &state
                )
                if let output = result {
                    return output
                }
                // Continue loop with tool results

            case .maxTokens:
                throw AgentError.unexpectedModelBehavior("Response truncated due to max tokens")

            case .contentFiltered:
                throw AgentError.unexpectedModelBehavior("Response was content filtered")
            }
        }

        throw AgentError.maxIterationsReached(maxIterations)
    }

    // MARK: - Private State

    private struct RunState {
        let runID: String
        let deps: Deps
        var messages: [Message]
        var usage: Usage
        var requestCount: Int = 0
        var toolCallCount: Int = 0
        var pendingApprovals: [DeferredToolCall] = []
    }

    // MARK: - Request Building

    private func buildRequest(state: RunState) -> CompletionRequest {
        var messages = state.messages

        // Add system prompt if present
        if !systemPrompt.isEmpty {
            messages.insert(.system(systemPrompt), at: 0)
        }

        // Build tool definitions
        var toolDefs = tools.map { $0.definition }

        // Add output tool for structured output
        // For String output, the model responds with text directly (no tool needed)
        if Output.self != String.self {
            let outputToolDef = ToolDefinition(
                name: outputToolName,
                description: outputToolDescription,
                inputSchema: Output.jsonSchema
            )
            toolDefs.append(outputToolDef)
        }

        return CompletionRequest(
            messages: messages,
            tools: toolDefs.isEmpty ? nil : toolDefs
        )
    }

    private func buildContext(state: RunState) -> AgentContext<Deps> {
        AgentContext(
            deps: state.deps,
            model: model,
            usage: state.usage,
            retries: 0,
            toolCallID: nil,
            toolName: nil,
            runStep: state.requestCount,
            runID: state.runID,
            messages: state.messages
        )
    }

    // MARK: - Tool Processing

    private func processToolCalls(
        response: CompletionResponse,
        state: inout RunState
    ) async throws -> AgentResult<Output>? {
        var toolResults: [(ToolCall, ToolOutput)] = []
        var outputResult: Output?
        var outputToolUsed: String?
        var deferredCalls: [DeferredToolCall] = []

        for call in response.toolCalls {
            state.toolCallCount += 1

            // Check if this is the output tool
            if call.name == outputToolName {
                // Parse as output type
                if let output = try await parseAndValidateOutput(
                    json: call.arguments,
                    context: buildContext(state: state).forToolCall(id: call.id, name: call.name)
                ) {
                    outputResult = output
                    outputToolUsed = call.name

                    // Add success result for the output tool
                    toolResults.append((call, .text("Output accepted")))

                    // If early end strategy, skip remaining tools
                    if endStrategy == .early {
                        break
                    }
                }
                continue
            }

            // Find the tool
            guard let tool = tools.first(where: { $0.name == call.name }) else {
                toolResults.append((call, .error("Tool not found: \(call.name)")))
                continue
            }

            // Execute tool with retries
            let result = try await executeToolWithRetries(
                tool: tool,
                call: call,
                state: state
            )

            switch result {
            case .success(let value):
                toolResults.append((call, .text(value)))

            case .retry(let message):
                // Max retries exceeded
                toolResults.append((call, .error("Tool failed after retries: \(message)")))

            case .failure(let error):
                toolResults.append((call, .error(error.localizedDescription)))

            case .deferred(let deferral):
                deferredCalls.append(deferral)
                toolResults.append((call, .error("Tool deferred: \(deferral.reason)")))
            }
        }

        // Check for deferred tools
        if !deferredCalls.isEmpty {
            state.pendingApprovals.append(contentsOf: deferredCalls)
            throw AgentError.hasDeferredTools(state.pendingApprovals)
        }

        // Add tool results to messages
        if !toolResults.isEmpty {
            state.messages.append(.fromToolResults(toolResults))
        }

        // Return output if found
        if let output = outputResult {
            return AgentResult(
                output: output,
                usage: state.usage,
                messages: state.messages,
                outputToolName: outputToolUsed,
                runID: state.runID,
                requestCount: state.requestCount,
                toolCallCount: state.toolCallCount
            )
        }

        return nil
    }

    private func executeToolWithRetries(
        tool: AnyAgentTool<Deps>,
        call: ToolCall,
        state: RunState
    ) async throws -> AnyToolResult {
        var retries = 0
        var lastResult: AnyToolResult?

        while retries <= tool.maxRetries {
            let context = buildContext(state: state)
                .forToolCall(id: call.id, name: call.name, retries: retries)

            do {
                let result = try await tool.call(
                    context: context,
                    argumentsJSON: call.arguments
                )
                lastResult = result

                // If not a retry, return immediately
                if !result.needsRetry {
                    return result
                }

                retries += 1
            } catch {
                return .failure(error)
            }
        }

        // Return last result (will be a retry that exceeded max)
        return lastResult ?? .failure(ToolExecutionError.maxRetriesExceeded(
            toolName: tool.name,
            attempts: retries
        ))
    }

    // MARK: - Output Extraction

    private func extractTextOutput(
        response: CompletionResponse,
        context: AgentContext<Deps>
    ) async throws -> Output? {
        // Only try text extraction for string output type
        guard Output.self == String.self else {
            return nil
        }

        guard let content = response.content, !content.isEmpty else {
            return nil
        }

        // Validate through validators
        var output = content as! Output
        for validator in outputValidators {
            output = try await validator.validate(context: context, output: output)
        }

        return output
    }

    private func parseAndValidateOutput(
        json: String,
        context: AgentContext<Deps>
    ) async throws -> Output? {
        guard let data = json.data(using: .utf8) else {
            return nil
        }

        do {
            var output = try JSONDecoder().decode(Output.self, from: data)

            // Run through validators
            for validator in outputValidators {
                output = try await validator.validate(context: context, output: output)
            }

            return output
        } catch {
            // Validation retry - add error to messages and let model retry
            if error is ValidationRetry {
                throw error
            }
            return nil
        }
    }

    // MARK: - Usage Limits

    private func checkUsageLimits(state: RunState) throws {
        if let maxInput = usageLimits.maxInputTokens,
           state.usage.inputTokens > maxInput {
            throw AgentError.usageLimitExceeded(.inputTokens(
                used: state.usage.inputTokens,
                limit: maxInput
            ))
        }

        if let maxOutput = usageLimits.maxOutputTokens,
           state.usage.outputTokens > maxOutput {
            throw AgentError.usageLimitExceeded(.outputTokens(
                used: state.usage.outputTokens,
                limit: maxOutput
            ))
        }

        if let maxTotal = usageLimits.maxTotalTokens,
           state.usage.totalTokens > maxTotal {
            throw AgentError.usageLimitExceeded(.totalTokens(
                used: state.usage.totalTokens,
                limit: maxTotal
            ))
        }

        if let maxRequests = usageLimits.maxRequests,
           state.requestCount >= maxRequests {
            throw AgentError.usageLimitExceeded(.requests(
                used: state.requestCount,
                limit: maxRequests
            ))
        }

        if let maxToolCalls = usageLimits.maxToolCalls,
           state.toolCallCount >= maxToolCalls {
            throw AgentError.usageLimitExceeded(.toolCalls(
                used: state.toolCallCount,
                limit: maxToolCalls
            ))
        }
    }

    private func accumulateUsage(current: Usage, new: Usage) -> Usage {
        Usage(
            inputTokens: current.inputTokens + new.inputTokens,
            outputTokens: current.outputTokens + new.outputTokens,
            cachedTokens: (current.cachedTokens ?? 0) + (new.cachedTokens ?? 0),
            reasoningTokens: (current.reasoningTokens ?? 0) + (new.reasoningTokens ?? 0)
        )
    }
}

// MARK: - Message Helpers

extension Message {
    /// Create assistant message from completion response.
    static func fromResponse(_ response: CompletionResponse) -> Message {
        .assistant(response.content ?? "", toolCalls: response.toolCalls)
    }

    /// Create tool results message from call/output pairs.
    static func fromToolResults(_ results: [(ToolCall, ToolOutput)]) -> Message {
        .toolResults(results.map { call, output in
            ToolResultEntry(id: call.id, output: output)
        })
    }
}
