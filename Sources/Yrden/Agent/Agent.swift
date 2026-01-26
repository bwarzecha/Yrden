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

    /// Retry policy for transient LLM errors.
    public let retryPolicy: RetryPolicy

    /// Default timeout for tool execution.
    public let toolTimeout: Duration?

    public init(
        model: any Model,
        systemPrompt: String = "",
        tools: [AnyAgentTool<Deps>] = [],
        outputValidators: [OutputValidator<Deps, Output>] = [],
        maxIterations: Int = 10,
        usageLimits: UsageLimits = .none,
        endStrategy: EndStrategy = .early,
        outputToolName: String = "final_result",
        outputToolDescription: String = "Provide the final result",
        retryPolicy: RetryPolicy = .none,
        toolTimeout: Duration? = nil
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
        self.retryPolicy = retryPolicy
        self.toolTimeout = toolTimeout
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
        var messages = messageHistory
        messages.append(.user(prompt))

        return try await runLoop(
            prompt: prompt,
            initialMessages: messages,
            deps: deps,
            observer: NoOpLoopObserver<Deps, Output>()
        )
    }

    // MARK: - Run Stream

    /// Run the agent with streaming events.
    ///
    /// Returns an `AsyncThrowingStream` that yields events as the agent executes:
    /// - Content deltas from the model
    /// - Tool call start/delta/end events
    /// - Tool execution results
    /// - Final typed result
    ///
    /// - Parameters:
    ///   - prompt: User prompt to start the conversation
    ///   - deps: Dependencies to pass to tools
    ///   - messageHistory: Optional previous messages to continue from
    /// - Returns: Stream of `AgentStreamEvent` values
    public nonisolated func runStream(
        _ prompt: String,
        deps: Deps,
        messageHistory: [Message] = []
    ) -> AsyncThrowingStream<AgentStreamEvent<Output>, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await self.runStreamInternal(
                        prompt: prompt,
                        deps: deps,
                        messageHistory: messageHistory,
                        continuation: continuation
                    )
                    continuation.yield(.result(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func runStreamInternal(
        prompt: String,
        deps: Deps,
        messageHistory: [Message],
        continuation: AsyncThrowingStream<AgentStreamEvent<Output>, Error>.Continuation
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

            // Stream from model
            let response = try await streamModelResponse(
                request: request,
                continuation: continuation
            )
            state.requestCount += 1
            state.usage = accumulateUsage(current: state.usage, new: response.usage)

            // Yield usage update
            continuation.yield(.usage(state.usage))

            // Add assistant message
            state.addResponse(response)

            // Handle response with streaming callback for tool results
            let action = try await handleModelResponse(
                response: response,
                state: &state
            ) { call, toolResult, _ in
                continuation.yield(.toolResult(id: call.id, result: self.formatToolResult(toolResult)))
            }

            switch action {
            case .returnOutput(let output, let outputToolUsed):
                return state.makeResult(output: output, outputToolUsed: outputToolUsed)
            case .continueLoop:
                continue
            }
        }

        throw AgentError.maxIterationsReached(maxIterations)
    }

    /// Format a tool result for streaming output.
    private nonisolated func formatToolResult(_ result: AnyToolResult) -> String {
        switch result {
        case .success(let value):
            return value
        case .retry(let message):
            return "Error: \(message)"
        case .failure(let error):
            return "Error: \(error.localizedDescription)"
        case .deferred(let deferral):
            return "Deferred: \(deferral.reason)"
        }
    }

    /// Stream model response and forward events to continuation.
    private func streamModelResponse(
        request: CompletionRequest,
        continuation: AsyncThrowingStream<AgentStreamEvent<Output>, Error>.Continuation
    ) async throws -> CompletionResponse {
        var response: CompletionResponse?
        var currentToolCallId: String?

        for try await event in model.stream(request) {
            switch event {
            case .contentDelta(let delta):
                continuation.yield(.contentDelta(delta))

            case .toolCallStart(let id, let name):
                currentToolCallId = id
                continuation.yield(.toolCallStart(name: name, id: id))

            case .toolCallDelta(let delta):
                // Use tracked tool call id (StreamEvent doesn't include id in delta)
                let id = currentToolCallId ?? ""
                continuation.yield(.toolCallDelta(id: id, delta: delta))

            case .toolCallEnd(let id):
                currentToolCallId = nil
                continuation.yield(.toolCallEnd(id: id))

            case .done(let completionResponse):
                response = completionResponse
            }
        }

        guard let finalResponse = response else {
            throw AgentError.unexpectedModelBehavior("Stream ended without done event")
        }

        return finalResponse
    }

    // MARK: - Iteration

    /// Run the agent with manual control over each step.
    ///
    /// Returns an `AsyncThrowingStream` that yields `AgentNode` for each step:
    /// - `.userPrompt` - Initial prompt
    /// - `.modelRequest` - About to send request
    /// - `.modelResponse` - Model responded
    /// - `.toolExecution` - About to execute tools
    /// - `.toolResults` - Tool execution completed
    /// - `.end` - Run completed with final result
    ///
    /// ## Usage
    /// ```swift
    /// for try await node in agent.iter("Analyze data", deps: myDeps) {
    ///     switch node {
    ///     case .userPrompt(let prompt):
    ///         print("Starting: \(prompt)")
    ///     case .modelRequest(let request):
    ///         print("Sending \(request.messages.count) messages")
    ///     case .modelResponse(let response):
    ///         print("Model: \(response.content ?? "")")
    ///     case .toolExecution(let calls):
    ///         for call in calls {
    ///             print("Executing: \(call.name)")
    ///         }
    ///     case .toolResults(let results):
    ///         print("Got \(results.count) results")
    ///     case .end(let result):
    ///         print("Done: \(result.output)")
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - prompt: User prompt to start the conversation
    ///   - deps: Dependencies to pass to tools
    ///   - messageHistory: Optional previous messages to continue from
    /// - Returns: Stream of `AgentNode` values for each execution step
    public nonisolated func iter(
        _ prompt: String,
        deps: Deps,
        messageHistory: [Message] = []
    ) -> AsyncThrowingStream<AgentNode<Deps, Output>, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.iterInternal(
                        prompt: prompt,
                        deps: deps,
                        messageHistory: messageHistory,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func iterInternal(
        prompt: String,
        deps: Deps,
        messageHistory: [Message],
        continuation: AsyncThrowingStream<AgentNode<Deps, Output>, Error>.Continuation
    ) async throws {
        var messages = messageHistory
        messages.append(.user(prompt))

        let observer = IteratingLoopObserver<Deps, Output>(continuation: continuation)
        _ = try await runLoop(
            prompt: prompt,
            initialMessages: messages,
            deps: deps,
            observer: observer
        )
    }

    // MARK: - Resume After Deferral

    /// Resume a paused agent run after deferred tools are resolved.
    ///
    /// When an agent run throws `AgentError.hasDeferredTools`, you can:
    /// 1. Present the pending tools to the user for approval
    /// 2. Collect resolutions for each pending tool
    /// 3. Call this method to continue execution
    ///
    /// ## Example
    /// ```swift
    /// do {
    ///     let result = try await agent.run("Delete important files", deps: myDeps)
    /// } catch let error as AgentError {
    ///     if case .hasDeferredTools(let paused) = error {
    ///         // Get user approval
    ///         var resolutions: [ResolvedTool] = []
    ///         for pending in paused.pendingCalls {
    ///             let approved = await askUser("Allow \(pending.toolCall.name)?")
    ///             resolutions.append(ResolvedTool(
    ///                 id: pending.deferral.id,
    ///                 resolution: approved ? .approved : .denied(reason: "User rejected")
    ///             ))
    ///         }
    ///
    ///         // Continue execution
    ///         let result = try await agent.resume(
    ///             paused: paused,
    ///             resolutions: resolutions,
    ///             deps: myDeps
    ///         )
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - paused: The paused run state from `AgentError.hasDeferredTools`
    ///   - resolutions: Resolution for each pending tool (by deferral ID)
    ///   - deps: Dependencies to pass to tools (for approved tool execution)
    /// - Returns: Final result with typed output and metadata
    /// - Throws: `AgentError` for agent-level failures, `LLMError` for provider failures
    public func resume(
        paused: PausedAgentRun,
        resolutions: [ResolvedTool],
        deps: Deps
    ) async throws -> AgentResult<Output> {
        // Build resolution lookup by deferral ID
        let resolutionMap = Dictionary(uniqueKeysWithValues: resolutions.map { ($0.id, $0.resolution) })

        // Process each pending call with its resolution
        var toolResults: [(ToolCall, ToolOutput)] = []

        for pending in paused.pendingCalls {
            guard let resolution = resolutionMap[pending.deferral.id] else {
                // No resolution provided - treat as denied
                toolResults.append((
                    pending.toolCall,
                    .error("No resolution provided for deferred tool")
                ))
                continue
            }

            switch resolution {
            case .approved:
                // Execute the tool now
                guard let tool = tools.first(where: { $0.name == pending.toolCall.name }) else {
                    let errorMsg = ToolExecutionError.toolNotFound(pending.toolCall.name).localizedDescription
                    toolResults.append((pending.toolCall, .error(errorMsg)))
                    continue
                }

                // Build context for execution
                let context = AgentContext(
                    deps: deps,
                    model: model,
                    usage: paused.usage,
                    retries: 0,
                    toolCallID: pending.toolCall.id,
                    toolName: pending.toolCall.name,
                    runStep: paused.requestCount,
                    runID: paused.runID,
                    messages: paused.messages
                )

                do {
                    let result = try await tool.call(context: context, argumentsJSON: pending.toolCall.arguments)
                    switch result {
                    case .success(let value):
                        toolResults.append((pending.toolCall, .text(value)))
                    case .retry(let message):
                        toolResults.append((pending.toolCall, .error("Tool requested retry: \(message)")))
                    case .failure(let error):
                        toolResults.append((pending.toolCall, .error(error.localizedDescription)))
                    case .deferred(let newDeferral):
                        // Tool deferred again - this is unusual but handle it
                        throw AgentError.hasDeferredTools(PausedAgentRun(
                            runID: paused.runID,
                            messages: paused.messages,
                            usage: paused.usage,
                            requestCount: paused.requestCount,
                            toolCallCount: paused.toolCallCount,
                            pendingCalls: [PendingToolCall(toolCall: pending.toolCall, deferral: newDeferral)]
                        ))
                    }
                } catch {
                    if error is AgentError {
                        throw error
                    }
                    toolResults.append((pending.toolCall, .error(error.localizedDescription)))
                }

            case .denied(let reason):
                toolResults.append((pending.toolCall, .error("Tool denied: \(reason)")))

            case .completed(let result):
                // Use the provided result directly
                toolResults.append((pending.toolCall, .text(result)))

            case .failed(let errorMsg):
                toolResults.append((pending.toolCall, .error("External operation failed: \(errorMsg)")))
            }
        }

        // Resume from the paused state
        var state = RunState.resume(from: paused, deps: deps)

        // Add tool results to messages
        state.addToolResults(toolResults)

        // Continue the agent loop
        while state.requestCount < maxIterations {
            try Task.checkCancellation()
            try checkUsageLimits(state: state)

            let request = buildRequest(state: state)
            let response = try await completeWithRetry(request: request)
            state.requestCount += 1
            state.usage = accumulateUsage(current: state.usage, new: response.usage)
            state.addResponse(response)

            // Handle response
            switch try await handleModelResponse(response: response, state: &state) {
            case .returnOutput(let output, let outputToolUsed):
                return state.makeResult(output: output, outputToolUsed: outputToolUsed)
            case .continueLoop:
                continue
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
        var pendingCalls: [PendingToolCall] = []

        /// Resume from a paused agent run.
        static func resume(from paused: PausedAgentRun, deps: Deps) -> RunState {
            RunState(
                runID: paused.runID,
                deps: deps,
                messages: paused.messages,
                usage: paused.usage,
                requestCount: paused.requestCount,
                toolCallCount: paused.toolCallCount
            )
        }

        /// Build an AgentResult from current state with the given output.
        func makeResult(output: Output, outputToolUsed: String?) -> AgentResult<Output> {
            AgentResult(
                output: output,
                usage: usage,
                messages: messages,
                outputToolName: outputToolUsed,
                runID: runID,
                requestCount: requestCount,
                toolCallCount: toolCallCount
            )
        }

        /// Add a model response to the message history.
        mutating func addResponse(_ response: CompletionResponse) {
            messages.append(.fromResponse(response))
        }

        /// Add tool results to the message history.
        mutating func addToolResults(_ results: [(ToolCall, ToolOutput)]) {
            messages.append(.fromToolResults(results))
        }
    }

    /// Action to take after processing a model response.
    private enum ResponseAction {
        case returnOutput(Output, outputToolUsed: String?)
        case continueLoop
    }

    // MARK: - Unified Loop

    /// Core agent loop shared by run() and iter().
    ///
    /// This consolidates the main loop logic, with the observer receiving events
    /// at appropriate points. Different execution modes provide different observers.
    ///
    /// - Parameters:
    ///   - prompt: User prompt (for observer notification)
    ///   - initialMessages: Messages to start with (including user prompt)
    ///   - deps: Dependencies for tool execution
    ///   - observer: Observer to notify of loop events
    /// - Returns: Final agent result
    /// - Throws: Agent or LLM errors
    private func runLoop<Observer: AgentLoopObserver>(
        prompt: String,
        initialMessages: [Message],
        deps: Deps,
        observer: Observer
    ) async throws -> AgentResult<Output> where Observer.Deps == Deps, Observer.Output == Output {
        let runID = UUID().uuidString
        var state = RunState(
            runID: runID,
            deps: deps,
            messages: initialMessages,
            usage: Usage(inputTokens: 0, outputTokens: 0)
        )

        // Notify observer of loop start
        observer.onLoopStart(prompt: prompt)

        // Collect tool results for observer callback
        var toolResults: [ToolCallResult] = []

        // Main agent loop
        while state.requestCount < maxIterations {
            // Check for cancellation
            try Task.checkCancellation()

            // Check usage limits
            try checkUsageLimits(state: state)

            // Build and notify
            let request = buildRequest(state: state)
            observer.onBeforeModelCall(request: request)

            // Send to model with retry
            let response = try await completeWithRetry(request: request)
            state.requestCount += 1
            state.usage = accumulateUsage(current: state.usage, new: response.usage)

            // Notify of response
            observer.onModelResponse(response: response, usage: state.usage)

            // Add assistant message
            state.addResponse(response)

            // Handle response with observer callbacks
            toolResults.removeAll()
            let action = try await handleModelResponse(
                response: response,
                state: &state,
                onToolComplete: { call, result, duration in
                    let tcr = ToolCallResult(call: call, result: result, duration: duration)
                    toolResults.append(tcr)
                    observer.onToolComplete(call: call, result: result, duration: duration)
                },
                beforeToolProcessing: { calls in
                    observer.onBeforeToolProcessing(calls: calls)
                },
                afterToolProcessing: {
                    observer.onAfterToolProcessing(results: toolResults)
                }
            )

            switch action {
            case .returnOutput(let output, let outputToolUsed):
                let result = state.makeResult(output: output, outputToolUsed: outputToolUsed)
                observer.onEnd(result: result)
                return result
            case .continueLoop:
                continue
            }
        }

        throw AgentError.maxIterationsReached(maxIterations)
    }

    // MARK: - Response Handling

    /// Handle model response - checks for errors and processes based on stop reason.
    ///
    /// This consolidates the stop reason switch logic used across all execution modes.
    /// Returns an action telling the caller what to do next.
    ///
    /// - Parameters:
    ///   - response: The model response to process
    ///   - state: Current run state (mutated)
    ///   - onToolComplete: Called after each tool completes (for streaming/iteration)
    ///   - beforeToolProcessing: Called before tool processing starts (for iteration nodes)
    ///   - afterToolProcessing: Called after tool processing completes (for iteration nodes)
    private func handleModelResponse(
        response: CompletionResponse,
        state: inout RunState,
        onToolComplete: ((ToolCall, AnyToolResult, Duration) -> Void)? = nil,
        beforeToolProcessing: (([ToolCall]) -> Void)? = nil,
        afterToolProcessing: (() -> Void)? = nil
    ) async throws -> ResponseAction {
        // Check for refusal
        if let refusal = response.refusal {
            throw AgentError.unexpectedModelBehavior("Model refused: \(refusal)")
        }

        // Handle based on stop reason
        switch response.stopReason {
        case .endTurn, .stopSequence:
            // Try to extract output from text
            if let output = try await extractTextOutput(
                response: response,
                context: buildContext(state: state)
            ) {
                return .returnOutput(output, outputToolUsed: nil)
            }

            // If we have tool calls, process them
            if !response.toolCalls.isEmpty {
                beforeToolProcessing?(response.toolCalls)
                let result = try await processToolCalls(
                    response: response,
                    state: &state,
                    onToolComplete: onToolComplete
                )
                afterToolProcessing?()
                if let output = result.output {
                    return .returnOutput(output, outputToolUsed: result.outputToolUsed)
                }
                return .continueLoop
            }

            // No output and no tools - unexpected
            throw AgentError.unexpectedModelBehavior("Model ended without output or tool calls")

        case .toolUse:
            beforeToolProcessing?(response.toolCalls)
            let result = try await processToolCalls(
                response: response,
                state: &state,
                onToolComplete: onToolComplete
            )
            afterToolProcessing?()
            if let output = result.output {
                return .returnOutput(output, outputToolUsed: result.outputToolUsed)
            }
            return .continueLoop

        case .maxTokens:
            throw AgentError.unexpectedModelBehavior("Response truncated due to max tokens")

        case .contentFiltered:
            throw AgentError.unexpectedModelBehavior("Response was content filtered")
        }
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

    /// Result of processing tool calls.
    private struct ToolProcessingResult {
        let output: Output?
        let outputToolUsed: String?
        let pendingCalls: [PendingToolCall]
    }

    /// Tool execution engine - handles retry and timeout logic.
    private var toolEngine: ToolExecutionEngine<Deps> {
        ToolExecutionEngine(tools: tools, timeout: toolTimeout)
    }

    /// Unified tool call processor with optional observation callback.
    ///
    /// - Parameters:
    ///   - response: The model response containing tool calls
    ///   - state: Current run state (mutated to update toolCallCount and messages)
    ///   - onToolComplete: Optional callback invoked after each tool completes
    /// - Returns: Processing result with optional output and pending calls
    /// - Throws: `AgentError.hasDeferredTools` if any tools are deferred
    private func processToolCalls(
        response: CompletionResponse,
        state: inout RunState,
        onToolComplete: ((ToolCall, AnyToolResult, Duration) -> Void)? = nil
    ) async throws -> ToolProcessingResult {
        var toolResults: [(ToolCall, ToolOutput)] = []
        var outputResult: Output?
        var outputToolUsed: String?
        var pendingCalls: [PendingToolCall] = []

        // Separate output tool calls from regular tool calls
        let outputToolCalls = response.toolCalls.filter { $0.name == outputToolName }
        let regularToolCalls = response.toolCalls.filter { $0.name != outputToolName }

        // Process output tool calls first (if early strategy, we might skip regular tools)
        for call in outputToolCalls {
            state.toolCallCount += 1
            let startTime = ContinuousClock.now

            do {
                if let output = try await parseAndValidateOutput(
                    json: call.arguments,
                    context: buildContext(state: state).forToolCall(id: call.id, name: call.name)
                ) {
                    outputResult = output
                    outputToolUsed = call.name

                    let duration = ContinuousClock.now - startTime
                    let result = AnyToolResult.success("Output accepted")
                    toolResults.append((call, .text("Output accepted")))
                    onToolComplete?(call, result, duration)

                    // If early end strategy, skip remaining tools
                    if endStrategy == .early {
                        // Add tool results to messages and return early
                        if !toolResults.isEmpty {
                            state.addToolResults(toolResults)
                        }
                        return ToolProcessingResult(
                            output: outputResult,
                            outputToolUsed: outputToolUsed,
                            pendingCalls: []
                        )
                    }
                }
            } catch let retry as ValidationRetry {
                let duration = ContinuousClock.now - startTime
                let errorMsg = "Validation failed: \(retry.message)"
                let result = AnyToolResult.retry(message: retry.message)
                toolResults.append((call, .error(errorMsg)))
                onToolComplete?(call, result, duration)
            }
        }

        // Execute regular tools via engine
        if !regularToolCalls.isEmpty {
            let baseContext = buildContext(state: state)
            let batch = try await toolEngine.executeAll(
                calls: regularToolCalls,
                baseContext: baseContext
            )

            // Update tool call count
            state.toolCallCount += batch.results.count

            // Process results and notify observer
            for (call, result, duration) in batch.results {
                // Notify observer of completion
                onToolComplete?(call, result, duration)

                switch result {
                case .success(let value):
                    toolResults.append((call, .text(value)))

                case .retry(let message):
                    toolResults.append((call, .error("Tool failed after retries: \(message)")))

                case .failure(let error):
                    toolResults.append((call, .error(error.localizedDescription)))

                case .deferred(let deferral):
                    pendingCalls.append(PendingToolCall(toolCall: call, deferral: deferral))
                }
            }
        }

        // Check for deferred tools
        if !pendingCalls.isEmpty {
            if !toolResults.isEmpty {
                state.addToolResults(toolResults)
            }

            let paused = PausedAgentRun(
                runID: state.runID,
                messages: state.messages,
                usage: state.usage,
                requestCount: state.requestCount,
                toolCallCount: state.toolCallCount,
                pendingCalls: pendingCalls
            )
            throw AgentError.hasDeferredTools(paused)
        }

        // Add tool results to messages
        if !toolResults.isEmpty {
            state.addToolResults(toolResults)
        }

        return ToolProcessingResult(
            output: outputResult,
            outputToolUsed: outputToolUsed,
            pendingCalls: pendingCalls
        )
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
        // Safe cast with internal error - should never fail since we checked Output.self == String.self
        guard var output = content as? Output else {
            throw AgentError.internalError("Failed to cast String content to Output type (expected String)")
        }
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

    // MARK: - Retryable LLM Calls

    /// Call model with retry policy for transient errors.
    private func completeWithRetry(
        request: CompletionRequest
    ) async throws -> CompletionResponse {
        var lastError: Error?
        var attempt = 0

        while attempt < retryPolicy.maxAttempts {
            // Check for cancellation
            try Task.checkCancellation()

            do {
                return try await model.complete(request)
            } catch {
                lastError = error

                // Check if we should retry
                guard retryPolicy.shouldRetry(error) else {
                    throw error
                }

                attempt += 1

                // If more attempts remain, delay and retry
                if attempt < retryPolicy.maxAttempts {
                    let delay = retryPolicy.delay(forAttempt: attempt)
                    try await Task.sleep(for: delay)
                }
            }
        }

        // All retries exhausted
        throw AgentError.retriesExhausted(
            attempts: retryPolicy.maxAttempts,
            lastError: lastError ?? LLMError.serverError("Unknown error")
        )
    }

    /// Stream from model with retry policy for transient errors.
    private func streamWithRetry(
        request: CompletionRequest
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var lastError: Error?
                var attempt = 0

                retryLoop: while attempt < retryPolicy.maxAttempts {
                    // Check for cancellation
                    do {
                        try Task.checkCancellation()
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }

                    do {
                        for try await event in model.stream(request) {
                            continuation.yield(event)
                        }
                        continuation.finish()
                        return
                    } catch {
                        lastError = error

                        // Check if we should retry
                        guard retryPolicy.shouldRetry(error) else {
                            continuation.finish(throwing: error)
                            return
                        }

                        attempt += 1

                        // If more attempts remain, delay and retry
                        if attempt < retryPolicy.maxAttempts {
                            let delay = retryPolicy.delay(forAttempt: attempt)
                            do {
                                try await Task.sleep(for: delay)
                            } catch {
                                continuation.finish(throwing: error)
                                return
                            }
                        }
                    }
                }

                // All retries exhausted
                continuation.finish(throwing: AgentError.retriesExhausted(
                    attempts: retryPolicy.maxAttempts,
                    lastError: lastError ?? LLMError.serverError("Unknown error")
                ))
            }
        }
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
