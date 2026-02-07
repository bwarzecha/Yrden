/// Context available to tools during agent execution.
///
/// ToolContext provides tools with access to:
/// - Current execution state (usage, messages)
/// - Run metadata (runID, step number)
///
/// User dependencies are handled via constructor injection or @TaskLocal,
/// not through the context object.
///
/// ## Example
/// ```swift
/// struct SearchTool: TypedTool {
///     let apiClient: APIClient  // dependency via constructor injection
///
///     func execute(
///         context: ToolContext,
///         arguments: SearchArgs
///     ) async throws -> ToolResult<String> {
///         let results = try await apiClient.search(arguments.query)
///         return .success(results.formatted())
///     }
/// }
/// ```

import Foundation

// MARK: - ToolContext

/// Framework context passed to every tool call.
/// Contains execution metadata — NOT user dependencies.
/// User dependencies are handled via constructor injection or @TaskLocal.
public struct ToolContext: Sendable {
    /// The model being used for this run.
    public let model: any Model

    /// Accumulated token usage for this run.
    public let usage: Usage

    /// ID of the current tool call (when executing inside a tool).
    /// nil when not in a tool execution context.
    public let toolCallID: String?

    /// Name of the current tool being executed.
    /// nil when not in a tool execution context.
    public let toolName: String?

    /// Current step in the agent run (increments each model call).
    public let runStep: Int

    /// Unique identifier for this agent run.
    public let runID: String

    /// All messages in the conversation so far.
    public let messages: [Message]

    /// Current retry attempt (0 on first call, incremented by RetryingTool).
    public let retryAttempt: Int

    public init(
        model: any Model,
        usage: Usage = Usage(inputTokens: 0, outputTokens: 0),
        toolCallID: String? = nil,
        toolName: String? = nil,
        runStep: Int = 0,
        runID: String = UUID().uuidString,
        messages: [Message] = [],
        retryAttempt: Int = 0
    ) {
        self.model = model
        self.usage = usage
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.runStep = runStep
        self.runID = runID
        self.messages = messages
        self.retryAttempt = retryAttempt
    }
}

// MARK: - Context Updates

extension ToolContext {
    /// Create a new context with updated usage.
    func withUsage(_ usage: Usage) -> ToolContext {
        ToolContext(
            model: model,
            usage: usage,
            toolCallID: toolCallID,
            toolName: toolName,
            runStep: runStep,
            runID: runID,
            messages: messages,
            retryAttempt: retryAttempt
        )
    }

    /// Create a new context for a tool call.
    func forToolCall(id: String, name: String) -> ToolContext {
        ToolContext(
            model: model,
            usage: usage,
            toolCallID: id,
            toolName: name,
            runStep: runStep,
            runID: runID,
            messages: messages,
            retryAttempt: 0
        )
    }

    /// Create a new context with incremented step.
    func nextStep() -> ToolContext {
        ToolContext(
            model: model,
            usage: usage,
            toolCallID: toolCallID,
            toolName: toolName,
            runStep: runStep + 1,
            runID: runID,
            messages: messages,
            retryAttempt: retryAttempt
        )
    }

    /// Create a new context with updated messages.
    func withMessages(_ messages: [Message]) -> ToolContext {
        ToolContext(
            model: model,
            usage: usage,
            toolCallID: toolCallID,
            toolName: toolName,
            runStep: runStep,
            runID: runID,
            messages: messages,
            retryAttempt: retryAttempt
        )
    }

    /// Create a new context with incremented retry attempt.
    func withRetryAttempt(_ attempt: Int) -> ToolContext {
        ToolContext(
            model: model,
            usage: usage,
            toolCallID: toolCallID,
            toolName: toolName,
            runStep: runStep,
            runID: runID,
            messages: messages,
            retryAttempt: attempt
        )
    }
}
