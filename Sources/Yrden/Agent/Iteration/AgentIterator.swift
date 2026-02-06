/// Iterator for step-by-step agent execution.
///
/// Conforms to `AsyncSequence` for use with `for await`:
/// ```swift
/// for await node in agent.iter("Task", deps: deps) {
///     switch node {
///     case .beforeModel(let ctx): ...
///     case .afterModel(let ctx): ...
///     case .beforeTools(let ctx): ...
///     case .afterTools(let ctx): ...
///     case .finished(let ctx): print(ctx.output)
///     }
/// }
/// ```

import Foundation

// MARK: - AgentIterator

public struct   AgentIterator<Deps: Sendable, Output: SchemaType>: AsyncSequence, Sendable {
    public typealias Element = IterationNode<Deps, Output>

    private let agent: Agent<Deps, Output>
    private let initialPrompt: String
    private let deps: Deps
    private let messageHistory: [Message]
    private let resumeState: IterationState<Output>?

    internal init(
        agent: Agent<Deps, Output>,
        prompt: String,
        deps: Deps,
        messageHistory: [Message]
    ) {
        self.agent = agent
        self.initialPrompt = prompt
        self.deps = deps
        self.messageHistory = messageHistory
        self.resumeState = nil
    }

    internal init(
        agent: Agent<Deps, Output>,
        resumeFrom state: IterationState<Output>,
        deps: Deps
    ) {
        self.agent = agent
        self.initialPrompt = ""
        self.deps = deps
        self.messageHistory = []
        self.resumeState = state
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            agent: agent,
            initialPrompt: initialPrompt,
            deps: deps,
            messageHistory: messageHistory,
            resumeState: resumeState
        )
    }

    // MARK: - AsyncIterator

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let agent: Agent<Deps, Output>
        private let deps: Deps

        /// The current state - nil means iteration complete.
        private var state: IterationState<Output>?

        /// Retained context references for reading back user modifications.
        /// Context classes modify their internal state; we read it back in executeAndTransition.
        private var currentBeforeModelContext: BeforeModelContext<Deps, Output>?
        private var currentBeforeToolsContext: BeforeToolsContext<Deps, Output>?

        /// Internal step within the current phase.
        /// Used to track whether we've yielded the current phase yet.
        private enum Step {
            case yieldPhase           // Yield the current phase node
            case executeAndTransition // Execute logic and transition to next phase
            case yieldFinished(Output) // Yield finished with output
            case done                 // Iteration complete
        }
        private var step: Step = .yieldPhase

        /// Whether we're resuming into a beforeTools phase and need to validate tools.
        /// Only true when resuming from saved state with pending tool calls.
        private var needsToolValidationOnResume: Bool = false

        internal init(
            agent: Agent<Deps, Output>,
            initialPrompt: String,
            deps: Deps,
            messageHistory: [Message],
            resumeState: IterationState<Output>?
        ) {
            self.agent = agent
            self.deps = deps

            if let resumeState {
                self.state = resumeState
                // Only validate tools if resuming into beforeTools phase
                if case .beforeTools = resumeState.phase {
                    self.needsToolValidationOnResume = true
                }
            } else {
                // Build initial state with user message
                var messages = messageHistory
                messages.append(.user(initialPrompt))
                self.state = IterationState(
                    runID: UUID().uuidString,
                    messages: messages,
                    usage: Usage(inputTokens: 0, outputTokens: 0),
                    iteration: 0,
                    toolCallCount: 0,
                    phase: .beforeModel
                )
            }
        }

        public mutating func next() async throws -> IterationNode<Deps, Output>? {
            switch step {
            case .done:
                return nil

            case .yieldFinished(let output):
                guard let finalState = state else {
                    step = .done
                    return nil
                }
                let finishedContext = FinishedContext(state: finalState, output: output, deps: deps)
                step = .done
                state = nil
                return .finished(finishedContext)

            case .yieldPhase:
                guard state != nil else {
                    step = .done
                    return nil
                }
                return try await yieldCurrentPhase()

            case .executeAndTransition:
                guard state != nil else {
                    step = .done
                    return nil
                }
                return try await executeAndTransition()
            }
        }

        /// Yield the current phase node.
        private mutating func yieldCurrentPhase() async throws -> IterationNode<Deps, Output>? {
            // Clear any previous context references
            currentBeforeModelContext = nil
            currentBeforeToolsContext = nil

            switch state!.phase {
            case .beforeModel:
                let context = BeforeModelContext<Deps, Output>(state: state!, deps: deps, agent: agent)
                currentBeforeModelContext = context  // Retain for reading back modifications
                step = .executeAndTransition
                return .beforeModel(context)

            case .afterModel:
                let context = AfterModelContext<Deps, Output>(state: state!, deps: deps)
                step = .executeAndTransition
                return .afterModel(context)

            case .beforeTools(let pendingCalls):
                // Validate tools only when resuming from saved state (not during normal execution)
                if needsToolValidationOnResume {
                    try await validatePendingToolsAvailable(pendingCalls: pendingCalls)
                    needsToolValidationOnResume = false  // Clear flag after validation
                }

                let context = BeforeToolsContext<Deps, Output>(state: state!, deps: deps, agent: agent)
                currentBeforeToolsContext = context  // Retain for reading back modifications
                step = .executeAndTransition
                return .beforeTools(context)

            case .afterTools:
                let context = AfterToolsContext<Deps, Output>(state: state!, deps: deps)
                step = .executeAndTransition
                return .afterTools(context)
            }
        }

        /// Execute logic for current phase and transition to next.
        private mutating func executeAndTransition() async throws -> IterationNode<Deps, Output>? {
            switch state!.phase {
            case .beforeModel:
                // Apply potentially modified state from context (for message modifications)
                if let ctx = currentBeforeModelContext {
                    state = ctx.state
                }

                // Check if streaming already executed - use cached response if available
                let response: CompletionResponse
                if let cached = currentBeforeModelContext?.streamedResponse {
                    response = cached
                } else {
                    // Mark as streamed so late stream() calls return empty
                    currentBeforeModelContext?.hasStreamed = true
                    response = try await callModel()
                }
                currentBeforeModelContext = nil  // Release context's reference before mutating

                // Check for unusable responses
                try checkResponseUsable(response)

                // Mutate state in place — messages array is close to uniquely referenced
                state!.messages.append(.fromResponse(response))
                state!.usage = Usage(
                    inputTokens: state!.usage.inputTokens + response.usage.inputTokens,
                    outputTokens: state!.usage.outputTokens + response.usage.outputTokens
                )
                state!.phase = .afterModel(response: response)

                // Check usage limits after accumulating
                try await checkUsageLimits()

                step = .yieldPhase
                return try await next()

            case .afterModel(let response):
                // Check for output tool (structured output via tool call)
                do {
                    if let (parsedOutput, remainingCalls) = try await extractOutputFromToolCall(response) {
                        if remainingCalls.isEmpty {
                            // Output tool only - finish with validated output
                            let validatedOutput = try await runOutputValidators(output: parsedOutput)
                            step = .yieldFinished(validatedOutput)
                            return try await next()
                        } else {
                            // Output tool + regular tools: execute regular tools first
                            let agentTools = await agent.tools
                            let pendingCalls = makePendingDecisions(from: remainingCalls, using: agentTools)
                            state!.phase = .beforeTools(calls: pendingCalls)
                            step = .yieldPhase
                            return try await next()
                        }
                    }

                    // No output tool - check for regular tool calls
                    if !response.toolCalls.isEmpty {
                        // Transition to beforeTools
                        let agentTools = await agent.tools
                        let pendingCalls = makePendingDecisions(from: response.toolCalls, using: agentTools)
                        state!.phase = .beforeTools(calls: pendingCalls)
                        step = .yieldPhase
                        return try await next()
                    } else {
                        // No tool calls - extract output from content and finish
                        let output = try await extractOutput(from: response)
                        step = .yieldFinished(output)
                        return try await next()
                    }
                } catch let retry as ValidationRetry {
                    return try await retryWithValidationMessage(retry.message)
                }

            case .beforeTools:
                // Apply potentially modified state from context (for approval decisions)
                if let ctx = currentBeforeToolsContext {
                    state = ctx.state
                }

                guard case .beforeTools(let pendingCalls) = state!.phase else {
                    currentBeforeToolsContext = nil
                    throw AgentError<Output>.internalError("beforeTools phase mismatch")
                }

                // Check if streaming already executed - use cached results if available
                let results: [ToolCallResult]
                if let cached = currentBeforeToolsContext?.streamedResults {
                    results = cached
                } else {
                    // Mark as streamed so late stream() calls return empty
                    currentBeforeToolsContext?.hasStreamed = true
                    results = try await executeTools(calls: pendingCalls)
                }
                currentBeforeToolsContext = nil  // Release context's reference before mutating

                // Add tool results to messages — mutate in place
                let toolResultEntries = results.map { result in
                    ToolResultEntry(id: result.call.id, output: result.result.toolOutput)
                }
                state!.messages.append(.toolResults(toolResultEntries))
                state!.toolCallCount += results.count
                state!.phase = .afterTools(results: results)

                step = .yieldPhase
                return try await next()

            case .afterTools:
                // Start next iteration — mutate in place
                state!.iteration += 1

                // Check max iterations before starting next loop
                let maxIterations = agent.maxIterations
                if state!.iteration >= maxIterations {
                    throw AgentError<Output>.maxIterationsReached(state: state!)
                }

                state!.phase = .beforeModel

                step = .yieldPhase
                return try await next()
            }
        }

        private func callModel() async throws -> CompletionResponse {
            // Build request messages — append instead of insert to avoid COW copy
            let systemPrompt = await agent.systemPrompt
            var requestMessages: [Message] = []
            requestMessages.reserveCapacity(state!.messages.count + 1)
            if !systemPrompt.isEmpty {
                requestMessages.append(.system(systemPrompt))
            }
            requestMessages.append(contentsOf: state!.messages)

            // Get tools from agent
            let agentTools = await agent.tools
            let toolDefinitions: [ToolDefinition]? = agentTools.isEmpty ? nil : agentTools.map { $0.definition }

            let request = CompletionRequest(
                messages: requestMessages,
                tools: toolDefinitions
            )

            let model = await agent.model
            return try await model.complete(request)
        }

        private func executeTools(
            calls: [PendingToolDecision]
        ) async throws -> [ToolCallResult] {
            let agentTools = await agent.tools
            let model = await agent.model
            let defaultTimeout = await agent.toolTimeout
            var results: [ToolCallResult] = []

            for pending in calls {
                // Check for task cancellation before each tool execution
                try Task.checkCancellation()

                let startTime = ContinuousClock.now
                let toolName = pending.call.name

                // Check decision FIRST - before any tool lookup or execution
                switch pending.decision {
                case .denied(let message):
                    // Return denied result immediately, no execution
                    results.append(ToolCallResult(
                        call: pending.call,
                        result: .denied(message),
                        duration: ContinuousClock.now - startTime
                    ))
                    continue

                case .replaced(let syntheticResult):
                    // Return replacement result immediately, no execution
                    results.append(ToolCallResult(
                        call: pending.call,
                        result: .replaced(syntheticResult),
                        duration: ContinuousClock.now - startTime
                    ))
                    continue

                case .pending, .approved:
                    // Continue to actual execution below
                    break
                }

                // Find the tool (only for .pending and .approved)
                guard let tool = agentTools.first(where: { $0.definition.name == toolName }) else {
                    let duration = ContinuousClock.now - startTime
                    results.append(ToolCallResult(
                        call: pending.call,
                        result: .failed(ToolExecutionError.toolNotFound(toolName)),
                        duration: duration
                    ))
                    continue
                }

                // Build context — reads from self.state without triggering COW
                let toolContext = AgentContext<Deps>(
                    deps: deps,
                    model: model,
                    usage: state!.usage,
                    toolCallID: pending.call.id,
                    toolName: toolName,
                    runStep: state!.iteration,
                    runID: state!.runID,
                    messages: state!.messages
                )

                // Execute with optional timeout
                let result = try await executeToolWithTimeout(
                    tool: tool,
                    context: toolContext,
                    arguments: pending.call.arguments,
                    timeout: defaultTimeout,
                    startTime: startTime
                )
                results.append(ToolCallResult(
                    call: pending.call,
                    result: result,
                    duration: ContinuousClock.now - startTime
                ))
            }

            return results
        }

        /// Execute a single tool call with optional timeout.
        private func executeToolWithTimeout(
            tool: AnyAgentTool<Deps>,
            context: AgentContext<Deps>,
            arguments: String,
            timeout: Duration?,
            startTime: ContinuousClock.Instant
        ) async throws -> AnyToolResult {
            guard let timeout = timeout else {
                // No timeout - execute directly
                do {
                    return try await tool.call(context: context, argumentsJSON: arguments)
                } catch is CancellationError {
                    throw CancellationError()  // Propagate cancellation
                } catch {
                    return .failed(error)
                }
            }

            // Execute with timeout using task group racing
            do {
                return try await withThrowingTaskGroup(of: AnyToolResult.self) { group in
                    // Task 1: Actual tool execution
                    group.addTask {
                        do {
                            return try await tool.call(context: context, argumentsJSON: arguments)
                        } catch is CancellationError {
                            throw CancellationError()  // Propagate cancellation
                        } catch {
                            return .failed(error)
                        }
                    }

                    // Task 2: Timeout
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw ToolTimeoutError(toolName: tool.definition.name, timeout: timeout)
                    }

                    // Wait for first result
                    guard let result = try await group.next() else {
                        return .failed(ToolExecutionError.custom("Task group returned no result"))
                    }

                    // Cancel remaining tasks
                    group.cancelAll()
                    return result
                }
            } catch is CancellationError {
                throw CancellationError()  // Propagate cancellation
            } catch let error as ToolTimeoutError {
                return .failed(error)
            } catch {
                return .failed(error)
            }
        }

        private func extractOutput(from response: CompletionResponse) async throws -> Output {
            // Check for model refusal first
            if let refusal = response.refusal {
                throw AgentError<Output>.modelRefusal(state: state!, refusal: refusal)
            }

            // Parse the output
            var output: Output

            // For String output, just return the content (empty string is valid)
            if Output.self == String.self {
                let content = response.content ?? ""
                // swiftlint:disable:next force_cast
                output = content as! Output
            } else {
                // For structured output, parse the content as JSON
                guard let content = response.content else {
                    throw AgentError<Output>.modelError(
                        state: state!,
                        underlying: ResponseUnusable.emptyResponse
                    )
                }

                guard let data = content.data(using: .utf8) else {
                    throw AgentError<Output>.validationFailed(
                        state: state!,
                        output: nil,
                        message: "Response content is not valid UTF-8"
                    )
                }

                do {
                    output = try JSONDecoder().decode(Output.self, from: data)
                } catch {
                    throw AgentError<Output>.validationFailed(
                        state: state!,
                        output: nil,
                        message: "Failed to decode output: \(error.localizedDescription)"
                    )
                }
            }

            // Run output validators
            let validators = await agent.outputValidators
            let model = await agent.model
            for validator in validators {
                let context = AgentContext<Deps>(
                    deps: deps,
                    model: model,
                    usage: state!.usage,
                    runStep: state!.iteration,
                    runID: state!.runID,
                    messages: state!.messages
                )
                output = try await validator.validate(context: context, output: output)
            }

            return output
        }

        // MARK: - Response Validation

        // MARK: - Validation Helpers

        /// Validate that all pending/approved tool calls reference available tools.
        /// Called when resuming from beforeTools phase to catch missing tools early.
        private func validatePendingToolsAvailable(
            pendingCalls: [PendingToolDecision]
        ) async throws {
            let agentTools = await agent.tools
            let availableToolNames = Set(agentTools.map { $0.definition.name })

            for pending in pendingCalls {
                // Only validate pending and approved calls - denied/replaced don't need the tool
                switch pending.decision {
                case .pending, .approved:
                    if !availableToolNames.contains(pending.call.name) {
                        throw AgentError<Output>.invalidConfiguration(
                            "Cannot resume: pending tool call '\(pending.call.name)' references a tool not available in this agent"
                        )
                    }
                case .denied, .replaced:
                    // These don't require the tool to be present
                    continue
                }
            }
        }

        /// Check if response is usable (not truncated, not filtered, no refusal).
        private func checkResponseUsable(_ response: CompletionResponse) throws {
            // Check for refusal
            if let refusal = response.refusal {
                throw AgentError<Output>.modelRefusal(state: state!, refusal: refusal)
            }

            // Check for max tokens truncation
            if response.stopReason == .maxTokens {
                throw AgentError<Output>.modelError(
                    state: state!,
                    underlying: ResponseUnusable.maxTokensReached(partialContent: response.content)
                )
            }

            // Check for content filtering
            if response.stopReason == .contentFiltered {
                throw AgentError<Output>.modelError(
                    state: state!,
                    underlying: ResponseUnusable.contentFiltered
                )
            }
        }

        /// Check if usage limits have been exceeded.
        private func checkUsageLimits() async throws {
            let limits = await agent.usageLimits
            if let violation = limits.violation(
                usage: state!.usage,
                iteration: state!.iteration,
                toolCallCount: state!.toolCallCount
            ) {
                throw AgentError<Output>.usageLimitExceeded(state: state!, limit: violation)
            }
        }

        // MARK: - Output Tool Pattern

        /// Extract output from the output tool call if present.
        /// Returns (parsed output, remaining tool calls) or nil if no output tool.
        private func extractOutputFromToolCall(
            _ response: CompletionResponse
        ) async throws -> (Output, [ToolCall])? {
            // String output doesn't use output tool
            guard Output.self != String.self else { return nil }

            let outputToolName = await agent.outputToolName

            // Find output tool call
            guard let outputCall = response.toolCalls.first(where: { $0.name == outputToolName }) else {
                return nil
            }

            // Parse arguments as Output
            let output = try parseOutputFromArguments(outputCall.arguments)

            // Filter out the output tool from remaining calls
            let remaining = response.toolCalls.filter { $0.name != outputToolName }

            return (output, remaining)
        }

        /// Parse output tool arguments as Output type.
        private func parseOutputFromArguments(_ arguments: String) throws -> Output {
            guard let data = arguments.data(using: .utf8) else {
                throw ValidationRetry("Output tool arguments are not valid UTF-8. Please provide valid JSON.")
            }

            do {
                return try JSONDecoder().decode(Output.self, from: data)
            } catch {
                throw ValidationRetry("Failed to parse output: \(error.localizedDescription). Please provide valid JSON matching the schema.")
            }
        }

        /// Run output validators on the parsed output.
        private func runOutputValidators(output: Output) async throws -> Output {
            var result = output
            let validators = await agent.outputValidators
            let model = await agent.model

            for validator in validators {
                let context = AgentContext<Deps>(
                    deps: deps,
                    model: model,
                    usage: state!.usage,
                    runStep: state!.iteration,
                    runID: state!.runID,
                    messages: state!.messages
                )
                result = try await validator.validate(context: context, output: result)
            }

            return result
        }

        /// Create pending tool decisions from tool calls, looking up approval requirements.
        private func makePendingDecisions(
            from calls: [ToolCall],
            using tools: [AnyAgentTool<Deps>]
        ) -> [PendingToolDecision] {
            calls.map { call in
                let tool = tools.first { $0.definition.name == call.name }
                let requiresApproval = tool?.requiresApproval ?? false
                return PendingToolDecision(call: call, requiresApproval: requiresApproval, decision: .pending)
            }
        }

        /// Retry with a validation message - transition back to beforeModel.
        /// Validation retries do NOT consume iterations but have their own limit.
        private mutating func retryWithValidationMessage(
            _ message: String
        ) async throws -> IterationNode<Deps, Output>? {
            // Increment validation retry count
            state!.validationRetryCount += 1

            // Check if we've exceeded the max validation retries
            let maxRetries = await agent.maxValidationRetries
            if state!.validationRetryCount >= maxRetries {
                throw AgentError<Output>.validationFailed(
                    state: state!,
                    output: nil,
                    message: "Exceeded max validation retries (\(maxRetries)): \(message)"
                )
            }

            // Mutate in place — append retry message, stay on same iteration
            state!.messages.append(.user(message))
            state!.phase = .beforeModel

            step = .yieldPhase
            return try await next()
        }
    }
}
