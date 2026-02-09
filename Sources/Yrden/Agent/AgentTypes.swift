/// Supporting types for agent execution.
///
/// This module contains:
/// - `UsageLimits`: Constraints on agent resource consumption
/// - `EndStrategy`: How to handle multiple tool calls
/// - `AgentStreamEvent`: Events emitted during streaming execution
/// - `ToolCallResult`: Result of a single tool call
/// - `OutputValidator`: Validation/transformation of agent output
///
/// Note: HTTP-level retry (transient 429/5xx) is handled by providers via
/// `RetryConfig` in Retry.swift. The agent layer does not add its own retry.

import Foundation

// MARK: - UsageLimits

/// Limits on agent resource consumption.
///
/// Set limits to prevent runaway costs or infinite loops.
/// When any limit is exceeded, the agent returns `.usageLimitReached` status.
///
/// ## Example
/// ```swift
/// let limits = UsageLimits(
///     maxTotalTokens: 10000,
///     maxRequests: 5,
///     maxToolCalls: 20
/// )
///
/// let agent = Agent(
///     model: claude,
///     tools: [searchTool],
///     usageLimits: limits
/// )
/// ```
public struct UsageLimits: Sendable, Equatable, Hashable {
    /// Maximum input tokens allowed.
    public var maxInputTokens: Int?

    /// Maximum output tokens allowed.
    public var maxOutputTokens: Int?

    /// Maximum total tokens (input + output) allowed.
    public var maxTotalTokens: Int?

    /// Maximum number of model requests (iterations).
    public var maxRequests: Int?

    /// Maximum number of tool calls.
    public var maxToolCalls: Int?

    public init(
        maxInputTokens: Int? = nil,
        maxOutputTokens: Int? = nil,
        maxTotalTokens: Int? = nil,
        maxRequests: Int? = nil,
        maxToolCalls: Int? = nil
    ) {
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.maxTotalTokens = maxTotalTokens
        self.maxRequests = maxRequests
        self.maxToolCalls = maxToolCalls
    }

    /// No limits.
    public static let none = UsageLimits()

    /// Check if any limit is violated and return the first violation found.
    ///
    /// - Parameters:
    ///   - usage: Current token usage
    ///   - iteration: Current iteration number (0-indexed)
    ///   - toolCallCount: Total tool calls executed so far
    /// - Returns: The first limit violation found, or nil if all limits are satisfied
    public func violation(usage: Usage, iteration: Int, toolCallCount: Int) -> UsageLimit? {
        if let max = maxInputTokens, usage.inputTokens > max {
            return .inputTokens(used: usage.inputTokens, limit: max)
        }
        if let max = maxOutputTokens, usage.outputTokens > max {
            return .outputTokens(used: usage.outputTokens, limit: max)
        }
        if let max = maxTotalTokens, usage.totalTokens > max {
            return .totalTokens(used: usage.totalTokens, limit: max)
        }
        // For requests, we check iteration + 1 because iteration is 0-indexed
        if let max = maxRequests, iteration + 1 > max {
            return .requests(used: iteration + 1, limit: max)
        }
        if let max = maxToolCalls, toolCallCount > max {
            return .toolCalls(used: toolCallCount, limit: max)
        }
        return nil
    }
}

// MARK: - EndStrategy

/// Strategy for handling tool calls when output is available.
///
/// When the LLM makes multiple tool calls in one response, and one of them
/// produces the final output, this strategy determines what happens to
/// the other tool calls.
public enum EndStrategy: String, Sendable, Codable, Equatable, Hashable {
    /// Stop as soon as final output is available.
    /// Other pending tool calls are ignored.
    case early

    /// Execute all tool calls, even after output is found.
    /// Useful when side effects matter.
    case exhaustive
}

// MARK: - AgentStreamEvent

/// Events emitted during streaming agent execution.
///
/// These events provide real-time visibility into the agent loop,
/// including model responses, tool execution, and final output.
///
/// ## Usage
/// ```swift
/// for try await event in agent.runStream("Analyze data") {
///     switch event {
///     case .contentDelta(let text):
///         print(text, terminator: "")
///     case .toolCallStart(let name, _):
///         print("\n[Calling \(name)...]")
///     case .toolResult(let id, let result):
///         print("[Tool returned: \(result.prefix(50))...]")
///     case .finished(let run):
///         if let output = run.output {
///             print("\n\nFinal: \(output)")
///         }
///     default:
///         break
///     }
/// }
/// ```
public enum AgentStreamEvent<Output: SchemaType>: Sendable {
    /// Text content delta from the model.
    /// - Parameters:
    ///   - content: The text delta
    ///   - kind: Type of content (text or thinking)
    case contentDelta(String, kind: ContentKind = .text)

    /// Tool call started.
    case toolCallStart(id: String, name: String)

    /// Tool call arguments delta.
    case toolCallDelta(id: String, delta: String)

    /// Tool call completed (ready to execute).
    case toolCallEnd(id: String)

    /// Tool execution result available.
    case toolResult(id: String, result: String)

    /// Usage update (tokens consumed so far).
    case usage(Usage)

    /// A background task completed.
    case backgroundTaskCompleted(id: String, exitCode: Int32, summary: String)

    /// Agent run finished (always last event).
    /// Contains the full `AgentRun` with status indicating how it ended.
    case finished(AgentRun<Output>)
}

// MARK: - ToolCallResult

/// Result of a single tool call execution.
public struct ToolCallResult: Sendable, Codable {
    /// The original tool call.
    public let call: ToolCall

    /// Result of execution.
    public let result: AnyToolResult

    /// Duration of execution.
    public let duration: Duration

    /// Convenience: the output string regardless of result type.
    ///
    /// Per design doc, formats are:
    /// - `.success(s)` → `s`
    /// - `.denied(m)` → `"Tool denied: {m}"`
    /// - `.replaced(r)` → `r`
    /// - `.failed(e)` → `"Tool failed: {e}"`
    public var output: String {
        result.output
    }

    public init(call: ToolCall, result: AnyToolResult, duration: Duration) {
        self.call = call
        self.result = result
        self.duration = duration
    }

    // Custom Codable to handle Duration (encode as nanoseconds)
    private enum CodingKeys: String, CodingKey {
        case call
        case result
        case durationNanoseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.call = try container.decode(ToolCall.self, forKey: .call)
        self.result = try container.decode(AnyToolResult.self, forKey: .result)
        let nanoseconds = try container.decode(Int64.self, forKey: .durationNanoseconds)
        self.duration = .nanoseconds(nanoseconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(call, forKey: .call)
        try container.encode(result, forKey: .result)
        let (seconds, attoseconds) = duration.components
        let nanoseconds = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        try container.encode(nanoseconds, forKey: .durationNanoseconds)
    }
}

// MARK: - OutputValidator

/// Validates and optionally transforms agent output.
///
/// Output validators run after the LLM produces structured output
/// but before returning to the caller. They can:
/// - Validate the output and throw `ValidationRetry` to ask the LLM to retry
/// - Transform the output (e.g., normalize, enrich)
/// - Log or audit the output
///
/// ## Example
/// ```swift
/// let validator = OutputValidator<Report> { context, report in
///     guard report.sections.count >= 3 else {
///         throw ValidationRetry("Report must have at least 3 sections")
///     }
///     return report
/// }
///
/// let agent = Agent(
///     model: claude,
///     outputValidators: [validator]
/// )
/// ```
public struct OutputValidator<Output: SchemaType>: Sendable {
    private let _validate: @Sendable (ToolContext, Output) async throws -> Output

    public init(
        _ validate: @escaping @Sendable (ToolContext, Output) async throws -> Output
    ) {
        self._validate = validate
    }

    /// Validate and optionally transform the output.
    public func validate(
        context: ToolContext,
        output: Output
    ) async throws -> Output {
        try await _validate(context, output)
    }
}

// MARK: - ValidationRetry

/// Throw from an output validator to request retry.
///
/// The message is sent back to the LLM to help it correct its output.
public struct ValidationRetry: Error, Sendable {
    /// Message to send to the LLM.
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

extension ValidationRetry: LocalizedError {
    public var errorDescription: String? {
        "Validation retry requested: \(message)"
    }
}
