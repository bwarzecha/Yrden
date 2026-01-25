/// Observer protocol for agent loop events.
///
/// Enables different behaviors (run, iteration, streaming) without duplicating
/// the core loop logic. Each execution mode implements this protocol to receive
/// events at appropriate points during execution.
///
/// ## Observer Lifecycle
/// ```
/// onLoopStart(prompt)
/// while running:
///     onBeforeModelCall(request)
///     onModelResponse(response, usage)
///     if hasToolCalls:
///         onBeforeToolProcessing(calls)
///         for each tool:
///             onToolComplete(call, result, duration)
///         onAfterToolProcessing(results)
///     if done:
///         onEnd(result)
/// ```

import Foundation

// MARK: - AgentLoopObserver Protocol

/// Observer for agent loop events.
///
/// Implement this protocol to customize behavior at each step of the agent loop.
/// The observer is notified of events but cannot modify the loop's behavior.
protocol AgentLoopObserver<Deps, Output>: Sendable {
    associatedtype Deps: Sendable
    associatedtype Output: SchemaType

    /// Called when the loop starts, after user message is added.
    func onLoopStart(prompt: String)

    /// Called before each model API call.
    func onBeforeModelCall(request: CompletionRequest)

    /// Called after model responds with accumulated usage.
    func onModelResponse(response: CompletionResponse, usage: Usage)

    /// Called before tool processing begins.
    func onBeforeToolProcessing(calls: [ToolCall])

    /// Called after each tool completes.
    func onToolComplete(call: ToolCall, result: AnyToolResult, duration: Duration)

    /// Called after all tools complete in a batch.
    func onAfterToolProcessing(results: [ToolCallResult])

    /// Called when the loop ends with a final result.
    func onEnd(result: AgentResult<Output>)
}

// MARK: - NoOpLoopObserver

/// Observer that does nothing - used for simple `run()` calls.
struct NoOpLoopObserver<Deps: Sendable, Output: SchemaType>: AgentLoopObserver {
    func onLoopStart(prompt: String) {}
    func onBeforeModelCall(request: CompletionRequest) {}
    func onModelResponse(response: CompletionResponse, usage: Usage) {}
    func onBeforeToolProcessing(calls: [ToolCall]) {}
    func onToolComplete(call: ToolCall, result: AnyToolResult, duration: Duration) {}
    func onAfterToolProcessing(results: [ToolCallResult]) {}
    func onEnd(result: AgentResult<Output>) {}
}

// MARK: - IteratingLoopObserver

/// Observer that yields `AgentNode` events for iteration mode.
struct IteratingLoopObserver<Deps: Sendable, Output: SchemaType>: AgentLoopObserver {
    private let continuation: AsyncThrowingStream<AgentNode<Deps, Output>, Error>.Continuation

    /// Collected results during tool processing.
    /// Using a class to allow mutation from within the observer callbacks.
    private let resultsCollector: ResultsCollector

    init(continuation: AsyncThrowingStream<AgentNode<Deps, Output>, Error>.Continuation) {
        self.continuation = continuation
        self.resultsCollector = ResultsCollector()
    }

    func onLoopStart(prompt: String) {
        continuation.yield(.userPrompt(prompt))
    }

    func onBeforeModelCall(request: CompletionRequest) {
        continuation.yield(.modelRequest(request))
    }

    func onModelResponse(response: CompletionResponse, usage: Usage) {
        continuation.yield(.modelResponse(response))
    }

    func onBeforeToolProcessing(calls: [ToolCall]) {
        resultsCollector.clear()
        continuation.yield(.toolExecution(calls))
    }

    func onToolComplete(call: ToolCall, result: AnyToolResult, duration: Duration) {
        resultsCollector.add(ToolCallResult(call: call, result: result, duration: duration))
    }

    func onAfterToolProcessing(results: [ToolCallResult]) {
        continuation.yield(.toolResults(results))
    }

    func onEnd(result: AgentResult<Output>) {
        continuation.yield(.end(result))
    }
}

/// Thread-safe collector for tool results.
private final class ResultsCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ToolCallResult] = []

    func add(_ result: ToolCallResult) {
        lock.lock()
        defer { lock.unlock() }
        results.append(result)
    }

    func getAll() -> [ToolCallResult] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        results.removeAll()
    }
}

// MARK: - StreamingLoopObserver

/// Observer that yields `AgentStreamEvent` for streaming mode.
///
/// Note: This observer handles non-streaming events. The actual streaming
/// of content deltas and tool call deltas is handled separately by the
/// stream model response method.
struct StreamingLoopObserver<Deps: Sendable, Output: SchemaType>: AgentLoopObserver {
    private let continuation: AsyncThrowingStream<AgentStreamEvent<Output>, Error>.Continuation
    private let formatResult: @Sendable (AnyToolResult) -> String

    init(
        continuation: AsyncThrowingStream<AgentStreamEvent<Output>, Error>.Continuation,
        formatResult: @escaping @Sendable (AnyToolResult) -> String
    ) {
        self.continuation = continuation
        self.formatResult = formatResult
    }

    func onLoopStart(prompt: String) {
        // Streaming doesn't emit a start event
    }

    func onBeforeModelCall(request: CompletionRequest) {
        // Streaming doesn't emit before model call - the streaming itself provides feedback
    }

    func onModelResponse(response: CompletionResponse, usage: Usage) {
        continuation.yield(.usage(usage))
    }

    func onBeforeToolProcessing(calls: [ToolCall]) {
        // Tool call events are emitted during streaming
    }

    func onToolComplete(call: ToolCall, result: AnyToolResult, duration: Duration) {
        continuation.yield(.toolResult(id: call.id, result: formatResult(result)))
    }

    func onAfterToolProcessing(results: [ToolCallResult]) {
        // No batch completion event in streaming mode
    }

    func onEnd(result: AgentResult<Output>) {
        continuation.yield(.result(result))
    }
}
