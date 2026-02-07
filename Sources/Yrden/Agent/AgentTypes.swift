/// Supporting types for agent execution.
///
/// This module contains:
/// - `UsageLimits`: Constraints on agent resource consumption
/// - `EndStrategy`: How to handle multiple tool calls
/// - `AgentStreamEvent`: Events emitted during streaming execution
/// - `ToolCallResult`: Result of a single tool call
/// - `OutputValidator`: Validation/transformation of agent output

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

// MARK: - RetryPolicy

/// Configuration for retrying failed LLM requests.
///
/// Use this to handle transient network errors, rate limits, and server errors
/// with exponential backoff.
///
/// ## Example
/// ```swift
/// let policy = RetryPolicy(
///     maxAttempts: 3,
///     initialDelay: .milliseconds(100),
///     maxDelay: .seconds(5),
///     backoffMultiplier: 2.0,
///     jitter: 0.1
/// )
///
/// let agent = Agent(
///     model: claude,
///     retryPolicy: policy
/// )
/// ```
public struct RetryPolicy: Sendable, Equatable {
    /// Maximum number of attempts (including initial).
    public var maxAttempts: Int

    /// Initial delay between attempts.
    public var initialDelay: Duration

    /// Maximum delay between attempts (caps exponential growth).
    public var maxDelay: Duration

    /// Multiplier for exponential backoff.
    public var backoffMultiplier: Double

    /// Random jitter as fraction of delay (0.0 to 1.0).
    /// Helps prevent thundering herd.
    public var jitter: Double

    /// Errors that should trigger a retry.
    /// By default, retries on rate limits and transient server errors.
    public var retryableErrors: Set<RetryableErrorKind>

    public init(
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(100),
        maxDelay: Duration = .seconds(30),
        backoffMultiplier: Double = 2.0,
        jitter: Double = 0.1,
        retryableErrors: Set<RetryableErrorKind> = [.rateLimited, .serverError, .networkError]
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
        self.jitter = jitter
        self.retryableErrors = retryableErrors
    }

    /// No retries - fail immediately on any error.
    public static let none = RetryPolicy(maxAttempts: 1, retryableErrors: [])

    /// Default policy: 3 attempts with exponential backoff.
    public static let `default` = RetryPolicy()

    /// Aggressive retry for high-availability: 5 attempts with longer waits.
    public static let aggressive = RetryPolicy(
        maxAttempts: 5,
        initialDelay: .milliseconds(200),
        maxDelay: .seconds(60),
        backoffMultiplier: 2.5,
        jitter: 0.2
    )

    /// Calculate delay for a given attempt number (0-indexed).
    public func delay(forAttempt attempt: Int) -> Duration {
        guard attempt > 0 else { return .zero }

        // Calculate exponential delay using Duration arithmetic
        let multiplier = pow(backoffMultiplier, Double(attempt - 1))

        // Convert initial delay to nanoseconds for calculation
        let components = initialDelay.components
        let baseNanos = Double(components.seconds) * 1_000_000_000.0 +
                        Double(components.attoseconds) / 1_000_000_000.0
        var delayNanos = baseNanos * multiplier

        // Cap at maxDelay
        let maxComponents = maxDelay.components
        let maxNanos = Double(maxComponents.seconds) * 1_000_000_000.0 +
                       Double(maxComponents.attoseconds) / 1_000_000_000.0
        delayNanos = min(delayNanos, maxNanos)

        // Add jitter
        if jitter > 0 {
            let jitterRange = delayNanos * jitter
            let jitterValue = Double.random(in: -jitterRange...jitterRange)
            delayNanos = max(0, delayNanos + jitterValue)
        }

        return .nanoseconds(Int64(delayNanos))
    }

    /// Check if an error should trigger a retry.
    public func shouldRetry(_ error: Error) -> Bool {
        guard let llmError = error as? LLMError else {
            return false
        }

        switch llmError {
        case .rateLimited:
            return retryableErrors.contains(.rateLimited)
        case .serverError:
            return retryableErrors.contains(.serverError)
        case .networkError:
            return retryableErrors.contains(.networkError)
        default:
            return false
        }
    }
}

/// Types of errors that can trigger retries.
public enum RetryableErrorKind: String, Sendable, Hashable, CaseIterable {
    /// Rate limit exceeded (429).
    case rateLimited

    /// Server error (5xx).
    case serverError

    /// Network connectivity issue.
    case networkError
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
