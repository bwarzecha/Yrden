/// Errors that can occur during agent execution.
///
/// `AgentError` covers failures specific to agent orchestration,
/// distinct from `LLMError` (provider-level) and `ToolExecutionError` (tool-level).
///
/// All resumable errors carry `IterationState` for recovery.
///
/// ## Error Handling with iter()
/// ```swift
/// do {
///     for try await node in agent.iter("Task", deps: deps) {
///         if case .finished(let ctx) = node { return ctx.output }
///     }
/// } catch let error as AgentError<MyOutput> {
///     switch error {
///     case .maxIterationsReached(let state):
///         // Resume from state with iter(from: state, deps:)
///         print("Paused at iteration \(state.iteration)")
///     case .usageLimitExceeded(let state, let limit):
///         print("Hit limit: \(limit), state available for resume")
///     case .cancelled(let state, let during):
///         print("Cancelled during \(during), can resume from state")
///     default:
///         print("Agent error: \(error)")
///     }
/// }
/// ```

import Foundation

// MARK: - AgentError

/// Errors that can occur during agent execution.
///
/// For the `iter()` API, errors that can be recovered from carry `IterationState`
/// which can be used to resume via `agent.iter(from: state, deps:)`.
///
/// All resumable errors carry state. Non-resumable errors indicate no valid
/// state exists (internal bugs or invalid configuration).
public enum AgentError<Output: SchemaType>: Error, Sendable {
    // MARK: Resumable errors - all carry state

    /// Agent run was cancelled.
    /// Contains the last valid state and what operation was interrupted.
    case cancelled(state: IterationState<Output>, during: CancelledOperation)

    /// Model call failed (network, timeout, rate limit, etc.).
    /// State is at `.beforeModel` - retry the model call.
    case modelError(state: IterationState<Output>, underlying: Error)

    /// Model refused to respond (safety filter, content policy, etc.).
    /// State is at `.afterModel` with the refusal message.
    case modelRefusal(state: IterationState<Output>, refusal: String)

    /// Output validation failed.
    /// State is at `.afterModel` with the invalid output (if parseable).
    case validationFailed(state: IterationState<Output>, output: Output?, message: String)

    /// Tool execution failed (error during tool call).
    /// State is at `.beforeTools` - can retry with modified decisions.
    case toolError(state: IterationState<Output>, toolName: String, underlying: Error)

    /// Agent reached maximum iterations without completing.
    /// State is at current phase - increase limit and continue.
    case maxIterationsReached(state: IterationState<Output>)

    /// Usage limit was exceeded (tokens, requests, etc.).
    /// State is at current phase - user decides whether to continue.
    case usageLimitExceeded(state: IterationState<Output>, limit: UsageLimit)

    // MARK: Non-resumable errors - no valid state exists

    /// Internal error - indicates a bug in the library.
    /// No state is available because this shouldn't happen.
    case internalError(String)

    /// Invalid configuration detected before agent could start.
    /// No state exists because execution never began.
    case invalidConfiguration(String)

    // MARK: - run() API errors (carry AgentRun for easy access)

    /// Agent run requires approval before continuing.
    /// Thrown by `AgentRun.result()` when status is `.needsApproval`.
    case needsApproval(AgentRun<Output>)

    /// Agent run hit iteration limit and paused.
    /// Thrown by `AgentRun.result()` when status is `.iterationLimitReached`.
    case iterationLimitReached(AgentRun<Output>)

    /// Agent run hit usage limit and stopped.
    /// Thrown by `AgentRun.result()` when status is `.usageLimitReached`.
    case usageLimitReached(AgentRun<Output>)

    /// Invalid resume options for the current status.
    case invalidResume(String)
}

// MARK: - CancelledOperation

/// What operation was in progress when cancellation occurred.
public enum CancelledOperation: Codable, Sendable {
    /// Cancelled during model API call.
    case modelCall

    /// Cancelled during tool execution.
    /// - completed: Tools that finished before cancellation
    /// - pending: Tools that were still running or queued
    case toolExecution(completed: [ToolCallResult], pending: [ToolCall])

    /// Cancelled during streaming.
    /// - tokensReceived: How many tokens were received before cancellation
    case streaming(tokensReceived: Int)

    /// Cancelled during phase transition.
    case phaseTransition
}

// MARK: - ResponseUnusable

/// Response was received from the model but is unusable.
///
/// This is distinct from API-level failures (LLMError). The request
/// succeeded, but the response cannot be used to continue the agent loop.
///
/// Used as the `underlying` error in `AgentError.modelError`.
public enum ResponseUnusable: Error, Sendable, Equatable {
    /// Response was truncated due to max tokens limit.
    /// - Parameter partialContent: Any content received before truncation.
    case maxTokensReached(partialContent: String?)

    /// Response was filtered by content policy.
    /// This corresponds to `stopReason == .contentFiltered`.
    case contentFiltered

    /// Response has no content, no tool calls, and no refusal.
    case emptyResponse
}

extension ResponseUnusable: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .maxTokensReached(let partial):
            if let content = partial, !content.isEmpty {
                return "Response truncated at max tokens. Partial: \(content.prefix(100))..."
            }
            return "Response truncated at max tokens"
        case .contentFiltered:
            return "Response filtered by content policy"
        case .emptyResponse:
            return "Model returned empty response"
        }
    }
}

// MARK: - ToolTimeoutError

/// Tool execution timed out.
///
/// Used as the `underlying` error in `AgentError.toolError`.
public struct ToolTimeoutError: Error, Sendable, Equatable {
    /// Name of the tool that timed out.
    public let toolName: String

    /// The timeout duration that was exceeded.
    public let timeout: Duration

    public init(toolName: String, timeout: Duration) {
        self.toolName = toolName
        self.timeout = timeout
    }
}

extension ToolTimeoutError: LocalizedError {
    public var errorDescription: String? {
        "Tool '\(toolName)' timed out after \(timeout)"
    }
}

// MARK: - UsageLimit

/// Type of usage limit that was exceeded.
public enum UsageLimit: Sendable, Equatable {
    case inputTokens(used: Int, limit: Int)
    case outputTokens(used: Int, limit: Int)
    case totalTokens(used: Int, limit: Int)
    case requests(used: Int, limit: Int)
    case toolCalls(used: Int, limit: Int)
}

extension UsageLimit: CustomStringConvertible {
    public var description: String {
        switch self {
        case .inputTokens(let used, let limit):
            return "Input tokens: \(used)/\(limit)"
        case .outputTokens(let used, let limit):
            return "Output tokens: \(used)/\(limit)"
        case .totalTokens(let used, let limit):
            return "Total tokens: \(used)/\(limit)"
        case .requests(let used, let limit):
            return "Requests: \(used)/\(limit)"
        case .toolCalls(let used, let limit):
            return "Tool calls: \(used)/\(limit)"
        }
    }
}

// MARK: - Convenience accessors

extension AgentError {
    /// Get the state from any resumable error, or nil for non-resumable errors.
    public var state: IterationState<Output>? {
        switch self {
        case .cancelled(let state, _),
             .modelError(let state, _),
             .modelRefusal(let state, _),
             .validationFailed(let state, _, _),
             .toolError(let state, _, _),
             .maxIterationsReached(let state),
             .usageLimitExceeded(let state, _):
            return state
        case .internalError, .invalidConfiguration,
             .needsApproval, .iterationLimitReached, .usageLimitReached, .invalidResume:
            return nil
        }
    }

    /// Whether this error is resumable (has state for continuation).
    public var isResumable: Bool {
        state != nil
    }
}

// MARK: - LocalizedError

extension AgentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        // New iter() API errors
        case .cancelled(let state, let operation):
            return "Agent cancelled during \(operation) at iteration \(state.iteration)"
        case .modelError(let state, let underlying):
            return "Model error at iteration \(state.iteration): \(underlying.localizedDescription)"
        case .modelRefusal(let state, let refusal):
            return "Model refused at iteration \(state.iteration): \(refusal)"
        case .validationFailed(let state, _, let message):
            return "Validation failed at iteration \(state.iteration): \(message)"
        case .toolError(let state, let toolName, let underlying):
            return "Tool '\(toolName)' failed at iteration \(state.iteration): \(underlying.localizedDescription)"
        case .maxIterationsReached(let state):
            return "Agent reached maximum iterations (\(state.iteration)) without completing. " +
                   "Tokens used: \(state.usage.totalTokens). Can be resumed with iter(from: state, deps:)."
        case .usageLimitExceeded(let state, let limit):
            return "Usage limit exceeded at iteration \(state.iteration): \(limit)"
        case .internalError(let message):
            return "Internal error: \(message)"
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"

        // run() API errors
        case .needsApproval(let run):
            let count = run.toolsRequiringApproval.count
            let names = run.toolsRequiringApproval.map { $0.call.name }.joined(separator: ", ")
            return "Agent has \(count) tool(s) awaiting approval: \(names)"
        case .iterationLimitReached(let run):
            return "Agent hit iteration limit at iteration \(run.iteration). " +
                   "Tokens used: \(run.usage.totalTokens). Can be resumed with .additionalIterations()."
        case .usageLimitReached(let run):
            if case .usageLimitReached(let limit) = run.status {
                return "Agent hit usage limit: \(limit)"
            }
            return "Agent hit usage limit"
        case .invalidResume(let message):
            return "Invalid resume: \(message)"
        }
    }
}

// MARK: - Type aliases

/// Convenience alias for String output (common case).
public typealias AgentErrorString = AgentError<String>

// MARK: - CancelledOperation Codable

extension CancelledOperation {
    private enum CodingKeys: String, CodingKey {
        case type
        case completed
        case pending
        case tokensReceived
    }

    private enum OperationType: String, Codable {
        case modelCall
        case toolExecution
        case streaming
        case phaseTransition
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(OperationType.self, forKey: .type)

        switch type {
        case .modelCall:
            self = .modelCall
        case .toolExecution:
            let completed = try container.decode([ToolCallResult].self, forKey: .completed)
            let pending = try container.decode([ToolCall].self, forKey: .pending)
            self = .toolExecution(completed: completed, pending: pending)
        case .streaming:
            let tokens = try container.decode(Int.self, forKey: .tokensReceived)
            self = .streaming(tokensReceived: tokens)
        case .phaseTransition:
            self = .phaseTransition
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .modelCall:
            try container.encode(OperationType.modelCall, forKey: .type)
        case .toolExecution(let completed, let pending):
            try container.encode(OperationType.toolExecution, forKey: .type)
            try container.encode(completed, forKey: .completed)
            try container.encode(pending, forKey: .pending)
        case .streaming(let tokensReceived):
            try container.encode(OperationType.streaming, forKey: .type)
            try container.encode(tokensReceived, forKey: .tokensReceived)
        case .phaseTransition:
            try container.encode(OperationType.phaseTransition, forKey: .type)
        }
    }
}
