/// Context available to tools during agent execution.
///
/// AgentContext provides tools with access to:
/// - User-provided dependencies (database clients, API clients, etc.)
/// - Current execution state (usage, messages, retries)
/// - Run metadata (runID, step number)
///
/// ## Example
/// ```swift
/// struct SearchTool: AgentTool {
///     func call(
///         context: AgentContext<AppDeps>,
///         arguments: SearchArgs
///     ) async throws -> ToolResult<String> {
///         // Access dependencies
///         let results = try await context.deps.searchClient.search(arguments.query)
///
///         // Check usage
///         if context.usage.totalTokens > 10000 {
///             return .retry(message: "Token budget low, simplify query")
///         }
///
///         return .success(results.formatted())
///     }
/// }
/// ```

import Foundation

// MARK: - AgentContext

/// Context passed to tools during agent execution.
public struct AgentContext<Deps: Sendable>: Sendable {
    /// User-provided dependencies (database clients, API clients, etc.)
    public let deps: Deps

    /// The model being used for this run.
    public let model: any Model

    /// Accumulated token usage for this run.
    public let usage: Usage

    /// Number of retry attempts for the current tool call.
    /// Starts at 0, increments each time the tool returns `.retry`.
    public let retries: Int

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

    public init(
        deps: Deps,
        model: any Model,
        usage: Usage = Usage(inputTokens: 0, outputTokens: 0),
        retries: Int = 0,
        toolCallID: String? = nil,
        toolName: String? = nil,
        runStep: Int = 0,
        runID: String = UUID().uuidString,
        messages: [Message] = []
    ) {
        self.deps = deps
        self.model = model
        self.usage = usage
        self.retries = retries
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.runStep = runStep
        self.runID = runID
        self.messages = messages
    }
}

// MARK: - Context Updates

extension AgentContext {
    /// Create a new context with updated usage.
    func withUsage(_ usage: Usage) -> AgentContext {
        AgentContext(
            deps: deps,
            model: model,
            usage: usage,
            retries: retries,
            toolCallID: toolCallID,
            toolName: toolName,
            runStep: runStep,
            runID: runID,
            messages: messages
        )
    }

    /// Create a new context for a tool call.
    func forToolCall(id: String, name: String, retries: Int = 0) -> AgentContext {
        AgentContext(
            deps: deps,
            model: model,
            usage: usage,
            retries: retries,
            toolCallID: id,
            toolName: name,
            runStep: runStep,
            runID: runID,
            messages: messages
        )
    }

    /// Create a new context with incremented step.
    func nextStep() -> AgentContext {
        AgentContext(
            deps: deps,
            model: model,
            usage: usage,
            retries: retries,
            toolCallID: toolCallID,
            toolName: toolName,
            runStep: runStep + 1,
            runID: runID,
            messages: messages
        )
    }

    /// Create a new context with updated messages.
    func withMessages(_ messages: [Message]) -> AgentContext {
        AgentContext(
            deps: deps,
            model: model,
            usage: usage,
            retries: retries,
            toolCallID: toolCallID,
            toolName: toolName,
            runStep: runStep,
            runID: runID,
            messages: messages
        )
    }

    /// Create a new context with incremented retries.
    func withRetry() -> AgentContext {
        AgentContext(
            deps: deps,
            model: model,
            usage: usage,
            retries: retries + 1,
            toolCallID: toolCallID,
            toolName: toolName,
            runStep: runStep,
            runID: runID,
            messages: messages
        )
    }
}

// MARK: - Void Dependencies

extension AgentContext where Deps == Void {
    /// Convenience initializer for agents without dependencies.
    public init(
        model: any Model,
        usage: Usage = Usage(inputTokens: 0, outputTokens: 0),
        retries: Int = 0,
        toolCallID: String? = nil,
        toolName: String? = nil,
        runStep: Int = 0,
        runID: String = UUID().uuidString,
        messages: [Message] = []
    ) {
        self.init(
            deps: (),
            model: model,
            usage: usage,
            retries: retries,
            toolCallID: toolCallID,
            toolName: toolName,
            runStep: runStep,
            runID: runID,
            messages: messages
        )
    }
}
