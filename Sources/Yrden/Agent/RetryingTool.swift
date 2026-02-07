/// A tool wrapper that retries on failure.
///
/// Wraps any `Tool` and retries when the tool:
/// - Returns `.failed(error)`
/// - Throws an error (except `CancellationError`)
///
/// `.success` and `.deferred` results are returned immediately without retry.
///
/// ## Usage
/// ```swift
/// // Wrap directly
/// let reliable = RetryingTool(myFlakyTool, maxRetries: 3)
///
/// // Or use convenience
/// let reliable = myFlakyTool.withRetries(3)
///
/// // Use in agent — no wrapping needed
/// let agent = try Agent(
///     model: model,
///     systemPrompt: "...",
///     tools: [reliable]
/// )
/// ```
public struct RetryingTool<Wrapped: Tool>: Tool {
    private let wrapped: Wrapped

    /// Maximum number of retries after the initial attempt.
    /// Total attempts = 1 + maxRetries.
    public let maxRetries: Int

    public var name: String { wrapped.name }
    public var description: String { wrapped.description }
    public var definition: ToolDefinition { wrapped.definition }
    public var requiresApproval: Bool { wrapped.requiresApproval }

    /// Create a retrying wrapper around a tool.
    ///
    /// - Parameters:
    ///   - tool: The tool to wrap
    ///   - maxRetries: Maximum retries after initial attempt (default: 3)
    public init(_ tool: Wrapped, maxRetries: Int = 3) {
        precondition(maxRetries >= 0, "maxRetries must be non-negative")
        self.wrapped = tool
        self.maxRetries = maxRetries
    }

    public func call(
        context: ToolContext,
        argumentsJSON: String
    ) async throws -> AnyToolResult {
        var lastError: Error?

        for attempt in 0...maxRetries {
            let retryContext = context.withRetryAttempt(attempt)
            do {
                let result = try await wrapped.call(context: retryContext, argumentsJSON: argumentsJSON)
                switch result {
                case .success, .deferred, .denied, .replaced:
                    return result
                case .failed(let error), .failure(let error):
                    lastError = error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        return .failed(lastError ?? ToolExecutionError.custom("All \(maxRetries + 1) attempts failed"))
    }
}

// MARK: - Convenience

extension Tool {
    /// Wrap this tool with retry behavior.
    ///
    /// - Parameter maxRetries: Maximum retries after initial attempt (default: 3)
    /// - Returns: A tool that retries on failure
    public func withRetries(_ maxRetries: Int = 3) -> RetryingTool<Self> {
        RetryingTool(self, maxRetries: maxRetries)
    }
}
