/// Context objects for each iteration phase.
///
/// Contexts are classes (reference types) so mutations are immediately visible
/// to the iterator. Each context provides phase-specific functionality.

import Foundation

// MARK: - ModelStreamEvent

/// Events during model streaming.
public enum ModelStreamEvent: Sendable {
    /// Text content delta.
    /// - Parameters:
    ///   - content: The text delta
    ///   - kind: Type of content (text or thinking)
    case contentDelta(String, kind: ContentKind = .text)

    /// Tool call started.
    case toolCallStart(id: String, name: String)

    /// Tool call arguments delta.
    case toolCallDelta(id: String, delta: String)

    /// Tool call completed.
    case toolCallEnd(id: String)
}

// MARK: - ToolStreamEvent

/// Events during tool execution streaming.
public enum ToolStreamEvent: Sendable {
    /// Tool started execution.
    case toolStarted(call: ToolCall)

    /// Tool was denied by user.
    case toolDenied(call: ToolCall, message: String)

    /// Tool execution progress (for long-running tools).
    case toolProgress(callId: String, update: String)

    /// Tool completed execution.
    case toolCompleted(call: ToolCall, result: String, duration: Duration)

    /// Tool execution failed.
    case toolFailed(call: ToolCall, error: String, duration: Duration)
}

// MARK: - BeforeModelContext

/// Context for the beforeModel phase.
///
/// At this point:
/// - `state.messages` contains what will be sent to the model
/// - You can modify messages (context engineering)
/// - You can call `stream()` to observe token generation
/// - Continuing iteration will execute the model call
public final class BeforeModelContext<Output: SchemaType>: @unchecked Sendable {
    /// Current iteration state. Mutable for context engineering.
    public var state: IterationState<Output>

    /// Reference to the agent for model access.
    private let agent: Agent<Output>

    /// Whether stream() has been called or iterator advanced without streaming.
    internal var hasStreamed: Bool = false

    /// Response from streaming, if stream() was called.
    internal var streamedResponse: CompletionResponse?

    internal init(state: IterationState<Output>, agent: Agent<Output>) {
        self.state = state
        self.agent = agent
    }

    /// Stream the model response with token-by-token events.
    ///
    /// After streaming completes, the next iteration yields `afterModel`.
    /// If you don't call `stream()`, the model executes without streaming.
    ///
    /// - Note: Can only be called once per context. Subsequent calls return an empty stream.
    public func stream() -> AsyncThrowingStream<ModelStreamEvent, Error> {
        // Check if already streamed - return empty stream
        guard !hasStreamed else {
            return AsyncThrowingStream { $0.finish() }
        }
        hasStreamed = true

        return AsyncThrowingStream { [self] continuation in
            let task = Task {
                do {
                    // Build request from current state
                    let request = await buildCompletionRequest()

                    // Stream from model
                    let model = await agent.model
                    var currentToolCallId: String?

                    for try await event in model.stream(request) {
                        try Task.checkCancellation()

                        switch event {
                        case .contentDelta(let text, let kind):
                            continuation.yield(.contentDelta(text, kind: kind))

                        case .toolCallStart(let id, let name):
                            currentToolCallId = id
                            continuation.yield(.toolCallStart(id: id, name: name))

                        case .toolCallDelta(let delta):
                            // Map provider event (no id) to agent event (with id)
                            if let id = currentToolCallId {
                                continuation.yield(.toolCallDelta(id: id, delta: delta))
                            }

                        case .toolCallEnd(let id):
                            continuation.yield(.toolCallEnd(id: id))
                            currentToolCallId = nil

                        case .done(let response):
                            // Cache response for iterator to use
                            self.streamedResponse = response
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // Cancel the streaming task if the consumer stops iterating
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Build the completion request from current state.
    private func buildCompletionRequest() async -> CompletionRequest {
        // Build new array with append instead of copy + insert to avoid COW copy
        var requestMessages: [Message] = []
        requestMessages.reserveCapacity(state.messages.count + 1)
        if !state.systemPrompt.isEmpty {
            requestMessages.append(.system(state.systemPrompt))
        }
        requestMessages.append(contentsOf: state.messages)

        let agentTools = await agent.tools
        var toolDefinitions: [ToolDefinition] = agentTools.map { $0.definition }

        // Add the output tool for structured output (non-String types)
        if Output.self != String.self {
            let outputToolName = await agent.outputToolName
            let outputToolDescription = await agent.outputToolDescription
            toolDefinitions.append(ToolDefinition(
                name: outputToolName,
                description: outputToolDescription,
                inputSchema: Output.jsonSchema
            ))
        }

        return CompletionRequest(
            messages: requestMessages,
            tools: toolDefinitions.isEmpty ? nil : toolDefinitions
        )
    }
}

// MARK: - AfterModelContext

/// Context for the afterModel phase.
///
/// At this point:
/// - Model has responded
/// - `response` contains the full completion response
/// - Continuing iteration will process tool calls (or finish if none)
public final class AfterModelContext<Output: SchemaType>: @unchecked Sendable {
    /// Current iteration state.
    public var state: IterationState<Output>

    /// The model's response.
    public var response: CompletionResponse {
        guard case .afterModel(let resp) = state.phase else {
            fatalError("Invalid phase for AfterModelContext")
        }
        return resp
    }

    internal init(state: IterationState<Output>) {
        self.state = state
    }
}

// MARK: - BeforeToolsContext

/// Context for the beforeTools phase.
///
/// At this point:
/// - Model requested tool calls
/// - You can approve, deny, or replace each tool call
/// - You can call `stream()` to observe tool execution events
/// - Continuing iteration executes approved tools
public final class BeforeToolsContext<Output: SchemaType>: @unchecked Sendable {
    /// Current iteration state.
    public var state: IterationState<Output>

    /// Reference to the agent for tool execution.
    private let agent: Agent<Output>

    /// Whether stream() has been called or iterator advanced without streaming.
    internal var hasStreamed: Bool = false

    /// Results from streaming execution, if stream() was called.
    internal var streamedResults: [ToolCallResult]?

    /// Pending tool calls with their decisions.
    public var pendingCalls: [PendingToolDecision] {
        guard case .beforeTools(let calls) = state.phase else {
            return []
        }
        return calls
    }

    internal init(state: IterationState<Output>, agent: Agent<Output>) {
        self.state = state
        self.agent = agent
    }

    /// Approve a tool call for execution.
    public func approve(_ call: ToolCall) {
        updateDecision(for: call.id, to: .approved)
    }

    /// Deny a tool call with a message sent back to the model.
    public func deny(_ call: ToolCall, message: String) {
        updateDecision(for: call.id, to: .denied(message))
    }

    /// Replace a tool call with a synthetic result (skip execution).
    public func replace(_ call: ToolCall, withResult result: String) {
        updateDecision(for: call.id, to: .replaced(result))
    }

    /// Stream tool execution events.
    ///
    /// Events follow the lifecycle:
    /// - Denied tools: `.toolDenied` (no `.toolStarted`)
    /// - Replaced tools: No events (synthetic result)
    /// - Executed tools: `.toolStarted` → `.toolCompleted` or `.toolFailed`
    ///
    /// - Note: Can only be called once per context. Subsequent calls return an empty stream.
    public func stream() -> AsyncThrowingStream<ToolStreamEvent, Error> {
        // Check if already streamed - return empty stream
        guard !hasStreamed else {
            return AsyncThrowingStream { $0.finish() }
        }
        hasStreamed = true

        return AsyncThrowingStream { [self] continuation in
            let task = Task {
                do {
                    guard case .beforeTools(let pendingCalls) = state.phase else {
                        continuation.finish()
                        return
                    }

                    var results: [ToolCallResult] = []
                    let agentTools = await agent.tools
                    let model = await agent.model
                    let defaultTimeout = await agent.toolTimeout

                    for pending in pendingCalls {
                        try Task.checkCancellation()

                        let startTime = ContinuousClock.now

                        // Check decision FIRST - before any tool lookup or execution
                        switch pending.decision {
                        case .denied(let message):
                            // Emit denied event immediately, no execution
                            continuation.yield(.toolDenied(call: pending.call, message: message))
                            results.append(ToolCallResult(
                                call: pending.call,
                                result: .denied(message),
                                duration: ContinuousClock.now - startTime
                            ))
                            continue

                        case .replaced(let syntheticResult):
                            // No events for replaced (synthetic), just add to results
                            results.append(ToolCallResult(
                                call: pending.call,
                                result: .replaced(syntheticResult),
                                duration: ContinuousClock.now - startTime
                            ))
                            continue

                        case .pending, .approved:
                            // Continue to execution below
                            break
                        }

                        // Emit started event
                        continuation.yield(.toolStarted(call: pending.call))

                        // Find and execute the tool
                        let toolName = pending.call.name
                        guard let tool = agentTools.first(where: { $0.definition.name == toolName }) else {
                            let duration = ContinuousClock.now - startTime
                            let error = ToolExecutionError.toolNotFound(toolName, available: agentTools.map { $0.definition.name }.joined(separator: ", "))
                            continuation.yield(.toolFailed(
                                call: pending.call,
                                error: error.localizedDescription,
                                duration: duration
                            ))
                            results.append(ToolCallResult(
                                call: pending.call,
                                result: .failed(error),
                                duration: duration
                            ))
                            continue
                        }

                        // Build context and execute
                        let toolContext = ToolContext(
                            model: model,
                            usage: state.usage,
                            toolCallID: pending.call.id,
                            toolName: toolName,
                            runStep: state.iteration,
                            runID: state.runID,
                            messages: state.messages
                        )

                        // Execute with optional timeout
                        let result = await executeToolWithTimeout(
                            tool: tool,
                            context: toolContext,
                            arguments: pending.call.arguments,
                            timeout: defaultTimeout
                        )

                        let duration = ContinuousClock.now - startTime

                        // Emit completed or failed event
                        switch result {
                        case .success(let output):
                            continuation.yield(.toolCompleted(
                                call: pending.call,
                                result: output,
                                duration: duration
                            ))
                        case .failed(let error), .failure(let error):
                            continuation.yield(.toolFailed(
                                call: pending.call,
                                error: error.localizedDescription,
                                duration: duration
                            ))
                        case .denied, .replaced, .deferred:
                            // Should not happen here (already handled above)
                            break
                        }

                        results.append(ToolCallResult(
                            call: pending.call,
                            result: result,
                            duration: duration
                        ))
                    }

                    // Cache results for iterator to use
                    self.streamedResults = results
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // Cancel the streaming task if the consumer stops iterating
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Execute a single tool call with optional timeout.
    private func executeToolWithTimeout(
        tool: any Tool,
        context: ToolContext,
        arguments: String,
        timeout: Duration?
    ) async -> AnyToolResult {
        guard let timeout = timeout else {
            // No timeout - execute directly
            do {
                return try await tool.call(context: context, argumentsJSON: arguments)
            } catch is CancellationError {
                return .failed(ToolExecutionError.custom("Cancelled"))
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
                        throw CancellationError()
                    } catch {
                        return .failed(error)
                    }
                }

                // Task 2: Timeout
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ToolTimeoutError(toolName: tool.name, timeout: timeout)
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
            return .failed(ToolExecutionError.custom("Cancelled"))
        } catch let error as ToolTimeoutError {
            return .failed(error)
        } catch {
            return .failed(error)
        }
    }

    private func updateDecision(for callId: String, to decision: PendingToolDecision.Decision) {
        guard case .beforeTools(var calls) = state.phase else { return }
        if let index = calls.firstIndex(where: { $0.call.id == callId }) {
            calls[index].decision = decision
            state.phase = .beforeTools(calls: calls)
        }
    }
}

// MARK: - AfterToolsContext

/// Context for the afterTools phase.
///
/// At this point:
/// - Tools have been executed (or denied/replaced)
/// - Results are in `results`
/// - You can modify results before they're added to messages
/// - Continuing iteration adds results to messages and starts next iteration
public final class AfterToolsContext<Output: SchemaType>: @unchecked Sendable {
    /// Current iteration state.
    public var state: IterationState<Output>

    /// Tool execution results.
    public var results: [ToolCallResult] {
        guard case .afterTools(let r) = state.phase else { return [] }
        return r
    }

    internal init(state: IterationState<Output>) {
        self.state = state
    }

    /// Replace a tool result with a transformed version.
    public func replaceResult(forCallId id: String, with newResult: String) {
        fatalError("Not implemented")
    }
}

// MARK: - FinishedContext

/// Context when iteration completes successfully.
public struct FinishedContext<Output: SchemaType>: Sendable {
    /// Final iteration state.
    public let state: IterationState<Output>

    /// The structured output extracted from the model response.
    public let output: Output

    /// Convenience: total token usage.
    public var usage: Usage { state.usage }

    /// Convenience: all messages in conversation.
    public var messages: [Message] { state.messages }

    /// Convenience: run identifier.
    public var runID: String { state.runID }

    public init(state: IterationState<Output>, output: Output) {
        self.state = state
        self.output = output
    }
}
