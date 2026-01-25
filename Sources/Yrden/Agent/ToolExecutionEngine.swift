/// Tool execution engine with retry and timeout support.
///
/// This engine handles the mechanics of executing tool calls without knowing
/// about output tools or agent-level semantics. The Agent filters output tool
/// calls before delegating regular tools here.
///
/// ## Usage
/// ```swift
/// let engine = ToolExecutionEngine(tools: myTools, timeout: .seconds(30))
///
/// // Single tool execution
/// let result = try await engine.execute(call: toolCall, context: context)
///
/// // Multiple tools
/// let results = try await engine.executeAll(
///     calls: toolCalls,
///     baseContext: context
/// )
/// ```

import Foundation

// MARK: - ToolExecutionEngine

/// Executes tool calls with retry and timeout support.
public struct ToolExecutionEngine<Deps: Sendable>: Sendable {
    /// Available tools for execution.
    private let tools: [AnyAgentTool<Deps>]

    /// Optional timeout for tool execution.
    private let timeout: Duration?

    /// Create a tool execution engine.
    ///
    /// - Parameters:
    ///   - tools: Tools available for execution
    ///   - timeout: Optional timeout applied to each tool call
    public init(tools: [AnyAgentTool<Deps>], timeout: Duration?) {
        self.tools = tools
        self.timeout = timeout
    }

    // MARK: - Single Tool Execution

    /// Execute a single tool call.
    ///
    /// Looks up the tool by name, executes it with retry support, and applies
    /// timeout if configured.
    ///
    /// - Parameters:
    ///   - call: The tool call to execute
    ///   - context: Execution context with dependencies
    /// - Returns: Execution result
    /// - Throws: `AgentError.toolTimeout` if timeout exceeded, `AgentError.cancelled` on cancellation
    public func execute(
        call: ToolCall,
        context: AgentContext<Deps>
    ) async throws -> AnyToolResult {
        guard let tool = tools.first(where: { $0.name == call.name }) else {
            return .failure(ToolExecutionError.toolNotFound(call.name))
        }

        return try await executeWithRetries(
            tool: tool,
            call: call,
            context: context
        )
    }

    // MARK: - Batch Execution

    /// Result of executing multiple tool calls.
    public struct BatchResult: Sendable {
        /// Results for each executed tool call.
        public let results: [(call: ToolCall, result: AnyToolResult, duration: Duration)]

        /// Whether execution stopped due to a deferred tool.
        public let stoppedOnDeferral: Bool

        /// All deferred tool calls (if any).
        public var deferredCalls: [(call: ToolCall, deferral: DeferredToolCall)] {
            results.compactMap { item in
                if case .deferred(let deferral) = item.result {
                    return (item.call, deferral)
                }
                return nil
            }
        }
    }

    /// Execute multiple tool calls.
    ///
    /// Executes tools in order. Stops early if any tool returns a deferred result.
    /// Each tool receives a context derived from `baseContext` with the tool call info added.
    ///
    /// - Parameters:
    ///   - calls: Tool calls to execute
    ///   - baseContext: Base context to derive per-call contexts from
    /// - Returns: Batch result containing all execution results
    /// - Throws: `AgentError` for unrecoverable errors (timeout, cancellation)
    public func executeAll(
        calls: [ToolCall],
        baseContext: AgentContext<Deps>
    ) async throws -> BatchResult {
        var results: [(call: ToolCall, result: AnyToolResult, duration: Duration)] = []
        var stoppedOnDeferral = false

        for call in calls {
            let startTime = ContinuousClock.now
            let context = baseContext.forToolCall(id: call.id, name: call.name)
            let result = try await execute(call: call, context: context)
            let duration = ContinuousClock.now - startTime

            results.append((call, result, duration))

            // Stop on deferral
            if result.isDeferred {
                stoppedOnDeferral = true
                break
            }
        }

        return BatchResult(results: results, stoppedOnDeferral: stoppedOnDeferral)
    }

    // MARK: - Private: Retry Logic

    /// Execute a tool with retry support.
    private func executeWithRetries(
        tool: AnyAgentTool<Deps>,
        call: ToolCall,
        context: AgentContext<Deps>
    ) async throws -> AnyToolResult {
        var retries = 0
        var lastResult: AnyToolResult?

        while retries <= tool.maxRetries {
            let retryContext = context.forToolCall(
                id: call.id,
                name: call.name,
                retries: retries
            )

            do {
                let result = try await executeWithTimeout(
                    tool: tool,
                    context: retryContext,
                    argumentsJSON: call.arguments
                )
                lastResult = result

                // Return immediately if not a retry
                if !result.needsRetry {
                    return result
                }

                retries += 1
            } catch {
                // Re-throw agent errors (timeout, cancellation)
                if error is AgentError {
                    throw error
                }
                return .failure(error)
            }
        }

        // Return last result (will be a retry that exceeded max)
        return lastResult ?? .failure(ToolExecutionError.maxRetriesExceeded(
            toolName: tool.name,
            attempts: retries
        ))
    }

    // MARK: - Private: Timeout Logic

    /// Execute a tool with optional timeout.
    private func executeWithTimeout(
        tool: AnyAgentTool<Deps>,
        context: AgentContext<Deps>,
        argumentsJSON: String
    ) async throws -> AnyToolResult {
        guard let timeout = timeout else {
            // No timeout - execute directly
            return try await tool.call(context: context, argumentsJSON: argumentsJSON)
        }

        // Execute with timeout using task group
        do {
            return try await withThrowingTaskGroup(of: AnyToolResult.self) { group in
                group.addTask {
                    try await tool.call(context: context, argumentsJSON: argumentsJSON)
                }

                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw AgentError.toolTimeout(toolName: tool.name, timeout: timeout)
                }

                // Return whichever completes first
                if let result = try await group.next() {
                    group.cancelAll()
                    return result
                }

                throw AgentError.toolTimeout(toolName: tool.name, timeout: timeout)
            }
        } catch is CancellationError {
            throw AgentError.cancelled
        }
    }
}
