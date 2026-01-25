/// Errors that can occur during agent execution.
///
/// `AgentError` covers failures specific to agent orchestration,
/// distinct from `LLMError` (provider-level) and `ToolExecutionError` (tool-level).
///
/// ## Error Handling
/// ```swift
/// do {
///     let result = try await agent.run("Analyze data", deps: myDeps)
/// } catch let error as AgentError {
///     switch error {
///     case .maxIterationsReached(let count):
///         print("Agent ran too long: \(count) iterations")
///     case .usageLimitExceeded(let kind):
///         print("Hit limit: \(kind)")
///     case .noOutput:
///         print("Agent finished without producing output")
///     default:
///         print("Agent error: \(error)")
///     }
/// }
/// ```

import Foundation

// MARK: - AgentError

/// Errors that can occur during agent execution.
public enum AgentError: Error, Sendable {
    /// Agent reached maximum iterations without completing.
    case maxIterationsReached(Int)

    /// Usage limit was exceeded.
    case usageLimitExceeded(UsageLimitKind)

    /// Agent finished without producing valid output.
    case noOutput

    /// Output validation failed.
    case outputValidationFailed(String)

    /// Model returned unexpected response format.
    case unexpectedModelBehavior(String)

    /// Agent run was cancelled.
    case cancelled

    /// Tool execution failed (wraps ToolExecutionError).
    case toolFailed(toolName: String, error: Error)

    /// Tool execution timed out.
    case toolTimeout(toolName: String, timeout: Duration)

    /// Agent has pending deferred tool calls that need resolution.
    /// The associated `PausedAgentRun` contains all state needed to resume.
    case hasDeferredTools(PausedAgentRun)

    /// LLM request failed after retry attempts exhausted.
    case retriesExhausted(attempts: Int, lastError: Error)

    /// Internal error - indicates a bug in the library.
    case internalError(String)
}

// MARK: - UsageLimitKind

/// Type of usage limit that was exceeded.
public enum UsageLimitKind: Sendable, Equatable {
    case inputTokens(used: Int, limit: Int)
    case outputTokens(used: Int, limit: Int)
    case totalTokens(used: Int, limit: Int)
    case requests(used: Int, limit: Int)
    case toolCalls(used: Int, limit: Int)
}

extension UsageLimitKind: CustomStringConvertible {
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

// MARK: - LocalizedError

extension AgentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .maxIterationsReached(let count):
            return "Agent reached maximum iterations (\(count)) without completing"
        case .usageLimitExceeded(let kind):
            return "Usage limit exceeded: \(kind)"
        case .noOutput:
            return "Agent finished without producing output"
        case .outputValidationFailed(let message):
            return "Output validation failed: \(message)"
        case .unexpectedModelBehavior(let details):
            return "Unexpected model behavior: \(details)"
        case .cancelled:
            return "Agent run was cancelled"
        case .toolFailed(let name, let error):
            return "Tool '\(name)' failed: \(error.localizedDescription)"
        case .toolTimeout(let name, let timeout):
            return "Tool '\(name)' timed out after \(timeout)"
        case .hasDeferredTools(let paused):
            let names = paused.pendingCalls.map { $0.toolCall.name }.joined(separator: ", ")
            return "Agent has \(paused.pendingCalls.count) deferred tool(s) awaiting resolution: \(names)"
        case .retriesExhausted(let attempts, let lastError):
            return "LLM request failed after \(attempts) attempts: \(lastError.localizedDescription)"
        case .internalError(let message):
            return "Internal error: \(message)"
        }
    }
}
