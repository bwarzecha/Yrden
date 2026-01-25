/// Supporting types for agent execution.
///
/// This module contains:
/// - `UsageLimits`: Constraints on agent resource consumption
/// - `EndStrategy`: How to handle multiple tool calls
/// - `AgentNode`: Steps in the agent execution graph
/// - `AgentResult`: Final output of an agent run
/// - `OutputValidator`: Validation/transformation of agent output

import Foundation

// MARK: - UsageLimits

/// Limits on agent resource consumption.
///
/// Set limits to prevent runaway costs or infinite loops.
/// When any limit is exceeded, the agent throws `AgentError.usageLimitExceeded`.
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
/// for try await event in agent.runStream("Analyze data", deps: myDeps) {
///     switch event {
///     case .contentDelta(let text):
///         print(text, terminator: "")
///     case .toolCallStart(let name, _):
///         print("\n[Calling \(name)...]")
///     case .toolResult(let id, let result):
///         print("[Tool returned: \(result.prefix(50))...]")
///     case .result(let result):
///         print("\n\nFinal: \(result.output)")
///     default:
///         break
///     }
/// }
/// ```
public enum AgentStreamEvent<Output: SchemaType>: Sendable {
    /// Text content delta from the model.
    case contentDelta(String)

    /// Tool call started.
    case toolCallStart(name: String, id: String)

    /// Tool call arguments delta.
    case toolCallDelta(id: String, delta: String)

    /// Tool call completed (ready to execute).
    case toolCallEnd(id: String)

    /// Tool execution result available.
    case toolResult(id: String, result: String)

    /// Usage update (tokens consumed so far).
    case usage(Usage)

    /// Final result (always last event on success).
    case result(AgentResult<Output>)
}

// MARK: - AgentNode

/// A node in the agent execution graph.
///
/// Used for iteration over agent execution. Each node represents
/// a step that the agent will take or has taken.
///
/// ## Iteration Example
/// ```swift
/// for try await node in agent.iter("Query data", deps: myDeps) {
///     switch node {
///     case .userPrompt(let prompt):
///         print("Starting with: \(prompt)")
///     case .modelRequest(let request):
///         print("Sending \(request.messages.count) messages to model")
///     case .modelResponse(let response):
///         print("Model responded: \(response.content ?? "no content")")
///     case .toolExecution(let calls):
///         print("Executing \(calls.count) tools")
///     case .toolResults(let results):
///         print("Got \(results.count) tool results")
///     case .end(let result):
///         print("Done: \(result.output)")
///     }
/// }
/// ```
public enum AgentNode<Deps: Sendable, Output: SchemaType>: Sendable {
    /// Initial user prompt.
    case userPrompt(String)

    /// About to send request to model.
    case modelRequest(CompletionRequest)

    /// Model responded.
    case modelResponse(CompletionResponse)

    /// About to execute tool calls.
    case toolExecution([ToolCall])

    /// Tool execution completed.
    case toolResults([ToolCallResult])

    /// Run completed with final output.
    case end(AgentResult<Output>)
}

// MARK: - ToolCallResult

/// Result of a single tool call execution.
public struct ToolCallResult: Sendable {
    /// The original tool call.
    public let call: ToolCall

    /// Result of execution.
    public let result: AnyToolResult

    /// Duration of execution.
    public let duration: Duration

    public init(call: ToolCall, result: AnyToolResult, duration: Duration) {
        self.call = call
        self.result = result
        self.duration = duration
    }
}

// MARK: - AgentResult

/// Final result of an agent run.
///
/// Contains the typed output plus metadata about the run.
public struct AgentResult<Output: SchemaType>: Sendable {
    /// The typed output.
    public let output: Output

    /// Total token usage for the run.
    public let usage: Usage

    /// All messages in the conversation.
    public let messages: [Message]

    /// Name of tool that produced output (nil if from text).
    public let outputToolName: String?

    /// Unique identifier for this run.
    public let runID: String

    /// Number of model requests made.
    public let requestCount: Int

    /// Number of tool calls executed.
    public let toolCallCount: Int

    public init(
        output: Output,
        usage: Usage,
        messages: [Message],
        outputToolName: String? = nil,
        runID: String,
        requestCount: Int,
        toolCallCount: Int
    ) {
        self.output = output
        self.usage = usage
        self.messages = messages
        self.outputToolName = outputToolName
        self.runID = runID
        self.requestCount = requestCount
        self.toolCallCount = toolCallCount
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
/// let validator = OutputValidator<MyDeps, Report> { context, report in
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
public struct OutputValidator<Deps: Sendable, Output: SchemaType>: Sendable {
    private let _validate: @Sendable (AgentContext<Deps>, Output) async throws -> Output

    public init(
        _ validate: @escaping @Sendable (AgentContext<Deps>, Output) async throws -> Output
    ) {
        self._validate = validate
    }

    /// Validate and optionally transform the output.
    public func validate(
        context: AgentContext<Deps>,
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

// MARK: - Pending Approvals

/// Collection of deferred tool calls awaiting resolution.
///
/// When tools return `.deferred`, the agent pauses and provides
/// this information for external resolution.
public struct PendingApprovals: Sendable {
    /// Tools awaiting human approval.
    public let approvals: [DeferredToolCall]

    /// Tools awaiting external results.
    public let external: [DeferredToolCall]

    /// All pending deferrals.
    public var all: [DeferredToolCall] {
        approvals + external
    }

    /// Whether there are any pending items.
    public var isEmpty: Bool {
        approvals.isEmpty && external.isEmpty
    }

    public init(approvals: [DeferredToolCall] = [], external: [DeferredToolCall] = []) {
        self.approvals = approvals
        self.external = external
    }
}

// MARK: - Resolved Tool

/// A resolved deferred tool call.
public struct ResolvedTool: Sendable {
    /// ID of the deferred call (must match DeferredToolCall.id).
    public let id: String

    /// Resolution result.
    public let resolution: Resolution

    public init(id: String, resolution: Resolution) {
        self.id = id
        self.resolution = resolution
    }

    /// Resolution outcomes.
    public enum Resolution: Sendable {
        /// Tool was approved and should proceed.
        case approved

        /// Tool was denied.
        case denied(reason: String)

        /// External operation completed with result.
        case completed(result: String)

        /// External operation failed.
        case failed(error: String)
    }
}

// MARK: - PausedAgentRun

/// State captured when an agent pauses due to deferred tools.
///
/// This struct contains all information needed to resume execution
/// after deferred tool calls are resolved by an external process.
///
/// ## Human-in-the-Loop Pattern
/// ```swift
/// do {
///     let result = try await agent.run("Execute risky operation", deps: myDeps)
/// } catch let error as AgentError {
///     if case .hasDeferredTools(let paused) = error {
///         // Present to user for approval
///         print("Tools need approval:")
///         for pending in paused.pendingCalls {
///             print("- \(pending.toolCall.name): \(pending.deferral.reason)")
///         }
///
///         // Get user decisions
///         let resolutions = await getUserApprovals(paused.pendingCalls)
///
///         // Resume with resolutions
///         let result = try await agent.resume(paused: paused, resolutions: resolutions, deps: myDeps)
///     }
/// }
/// ```
public struct PausedAgentRun: Sendable {
    /// Unique identifier for this run.
    public let runID: String

    /// Conversation messages up to the point of deferral.
    public let messages: [Message]

    /// Accumulated token usage.
    public let usage: Usage

    /// Number of model requests made so far.
    public let requestCount: Int

    /// Number of tool calls executed so far.
    public let toolCallCount: Int

    /// Pending tool calls that need resolution.
    public let pendingCalls: [PendingToolCall]

    public init(
        runID: String,
        messages: [Message],
        usage: Usage,
        requestCount: Int,
        toolCallCount: Int,
        pendingCalls: [PendingToolCall]
    ) {
        self.runID = runID
        self.messages = messages
        self.usage = usage
        self.requestCount = requestCount
        self.toolCallCount = toolCallCount
        self.pendingCalls = pendingCalls
    }

    /// Get all deferred calls (for display purposes).
    public var deferrals: [DeferredToolCall] {
        pendingCalls.map { $0.deferral }
    }
}

// MARK: - PendingToolCall

/// A tool call that is pending resolution.
///
/// Pairs the original LLM tool call with the deferral information
/// returned by the tool.
public struct PendingToolCall: Sendable {
    /// The original tool call from the LLM.
    public let toolCall: ToolCall

    /// Deferral information from the tool.
    public let deferral: DeferredToolCall

    public init(toolCall: ToolCall, deferral: DeferredToolCall) {
        self.toolCall = toolCall
        self.deferral = deferral
    }
}
