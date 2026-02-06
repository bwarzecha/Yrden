/// Agent - Orchestration layer for LLM tool use and structured output.
///
/// An Agent:
/// 1. Sends prompts to an LLM
/// 2. Processes tool calls from the LLM response
/// 3. Feeds tool results back to the LLM
/// 4. Continues until the LLM provides a final answer
/// 5. Validates and returns typed output
///
/// ## Basic Usage
/// ```swift
/// // Define tools
/// struct SearchTool: AgentTool {
///     @Schema struct Args: SchemaType { let query: String }
///     var name: String { "search" }
///     var description: String { "Search the knowledge base" }
///
///     func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
///         return .success("Results for: \(arguments.query)")
///     }
/// }
///
/// // Create agent
/// let agent = Agent<Void, Report>(
///     model: claude,
///     systemPrompt: "You are a research assistant.",
///     tools: [AnyAgentTool(SearchTool())]
/// )
///
/// // Run and get output
/// let run = try await agent.run("Find information about Swift", deps: ())
/// if let output = run.output {
///     print(output)
/// }
///
/// // Or use .result() for throw-on-pause behavior
/// let output = try await agent.run("Find information about Swift", deps: ()).result()
/// ```

import Foundation

// MARK: - Agent

/// An agent that orchestrates LLM tool use and produces typed output.
public actor Agent<Deps: Sendable, Output: SchemaType> {
    /// The model to use for completions.
    public let model: any Model

    /// System prompt prepended to all conversations.
    public let systemPrompt: String

    /// Available tools.
    public let tools: [AnyAgentTool<Deps>]

    /// Output validators run after LLM produces output.
    public let outputValidators: [OutputValidator<Deps, Output>]

    /// Maximum iterations before pausing.
    public let maxIterations: Int

    /// Usage limits for the run.
    public let usageLimits: UsageLimits

    /// Strategy for handling multiple tool calls.
    public let endStrategy: EndStrategy

    /// Name for the output tool (when using tool-based structured output).
    public let outputToolName: String

    /// Description for the output tool.
    public let outputToolDescription: String

    /// Retry policy for transient LLM errors.
    public let retryPolicy: RetryPolicy

    /// Default timeout for tool execution.
    public let toolTimeout: Duration?

    /// Maximum number of validation retries before failing.
    public let maxValidationRetries: Int

    public init(
        model: any Model,
        systemPrompt: String = "",
        tools: [AnyAgentTool<Deps>] = [],
        maxIterations: Int = 10,
        maxValidationRetries: Int = 3,
        outputValidators: [OutputValidator<Deps, Output>] = [],
        usageLimits: UsageLimits = .none,
        endStrategy: EndStrategy = .early,
        outputToolName: String = "final_result",
        outputToolDescription: String = "Provide the final result",
        retryPolicy: RetryPolicy = .none,
        toolTimeout: Duration? = nil
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.maxIterations = maxIterations
        self.maxValidationRetries = maxValidationRetries
        self.outputValidators = outputValidators
        self.usageLimits = usageLimits
        self.endStrategy = endStrategy
        self.outputToolName = outputToolName
        self.outputToolDescription = outputToolDescription
        self.retryPolicy = retryPolicy
        self.toolTimeout = toolTimeout
    }

    // MARK: - Run

    /// Run the agent with the given prompt and return an AgentRun.
    ///
    /// The returned `AgentRun` contains the result status:
    /// - `.completed(Output)`: Agent finished successfully
    /// - `.needsApproval([PendingToolDecision])`: Tools need user approval
    /// - `.iterationLimitReached(limit:)`: Hit max iterations, can continue
    /// - `.usageLimitReached(UsageLimit)`: Hit usage limit, cannot continue
    ///
    /// For the simple "throw on pause" pattern, use `.result()`:
    /// ```swift
    /// let output = try await agent.run("task", deps: ()).result()
    /// ```
    ///
    /// - Parameters:
    ///   - prompt: User prompt to start the conversation
    ///   - deps: Dependencies to pass to tools
    ///   - messageHistory: Optional previous messages to continue from
    /// - Returns: AgentRun containing status and full state
    /// - Throws: `AgentError` for actual errors (not pauses)
    public func run(
        _ prompt: String,
        deps: Deps,
        messageHistory: [Message] = []
    ) async throws -> AgentRun<Output> {
        throw AgentError<Output>.internalError("run() not implemented - use iter() instead")
    }

    /// Run the agent continuing from a previous run.
    ///
    /// Use this to continue a conversation from a previous run, adding a new user prompt.
    /// If the previous run has pending approvals, they are auto-cancelled.
    ///
    /// - Parameters:
    ///   - prompt: New user prompt
    ///   - deps: Dependencies to pass to tools
    ///   - continuingFrom: Previous AgentRun to continue from
    /// - Returns: AgentRun containing status and full state
    public func run(
        _ prompt: String,
        deps: Deps,
        continuingFrom previous: AgentRun<Output>
    ) async throws -> AgentRun<Output> {
        throw AgentError<Output>.internalError("run(continuingFrom:) not implemented")
    }

    // MARK: - Resume

    /// Resume a paused run with appropriate options.
    ///
    /// The required options depend on `run.status`:
    /// - `.needsApproval`: provide decisions via `.approve()`, `.deny()`, or `.decisions()`
    /// - `.iterationLimitReached`: provide `.additionalIterations(N)`
    ///
    /// ## Examples
    ///
    /// **Approve all pending tools:**
    /// ```swift
    /// let continued = try await agent.resume(
    ///     from: run,
    ///     with: .approveAll(from: run),
    ///     deps: myDeps
    /// )
    /// ```
    ///
    /// **Continue with more iterations:**
    /// ```swift
    /// let continued = try await agent.resume(
    ///     from: run,
    ///     with: .additionalIterations(10),
    ///     deps: myDeps
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - run: The paused AgentRun to resume
    ///   - options: ResumeOptions appropriate for the run's status
    ///   - deps: Dependencies to pass to tools
    /// - Returns: New AgentRun with updated status
    /// - Throws: `AgentError.invalidResume` if options don't match status
    public func resume(
        from run: AgentRun<Output>,
        with options: ResumeOptions,
        deps: Deps
    ) async throws -> AgentRun<Output> {
        throw AgentError<Output>.internalError("resume() not implemented")
    }

    // MARK: - Run Stream

    /// Run the agent with streaming events.
    ///
    /// Returns an `AsyncThrowingStream` that yields events as the agent executes:
    /// - Content deltas from the model
    /// - Tool call start/delta/end events
    /// - Tool execution results
    /// - Final `.finished(AgentRun)` event
    ///
    /// - Parameters:
    ///   - prompt: User prompt to start the conversation
    ///   - deps: Dependencies to pass to tools
    ///   - messageHistory: Optional previous messages to continue from
    /// - Returns: Stream of `AgentStreamEvent` values
    public nonisolated func runStream(
        _ prompt: String,
        deps: Deps,
        messageHistory: [Message] = []
    ) -> AsyncThrowingStream<AgentStreamEvent<Output>, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AgentError<Output>.internalError("runStream() not implemented"))
        }
    }

    /// Resume a paused run with streaming events.
    ///
    /// - Parameters:
    ///   - run: The paused AgentRun to resume
    ///   - options: ResumeOptions appropriate for the run's status
    ///   - deps: Dependencies to pass to tools
    /// - Returns: Stream of `AgentStreamEvent` values
    public nonisolated func resumeStream(
        from run: AgentRun<Output>,
        with options: ResumeOptions,
        deps: Deps
    ) -> AsyncThrowingStream<AgentStreamEvent<Output>, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AgentError<Output>.internalError("resumeStream() not implemented"))
        }
    }

    // MARK: - Iteration

    /// Iterate through agent execution step-by-step.
    ///
    /// Returns an `AgentIterator` that yields nodes at each phase.
    /// Each node contains complete state that can be inspected or modified.
    ///
    /// ## Usage
    /// ```swift
    /// for try await node in agent.iter("Task", deps: deps) {
    ///     switch node {
    ///     case .beforeModel(let ctx):
    ///         // Modify messages before model call
    ///         ctx.state.messages.append(.system("Extra context"))
    ///     case .afterModel(let ctx):
    ///         print("Model responded")
    ///     case .beforeTools(let ctx):
    ///         // Approve or deny tool calls
    ///         for pending in ctx.pendingCalls {
    ///             ctx.approve(pending.call)
    ///         }
    ///     case .afterTools(let ctx):
    ///         print("Tools executed")
    ///     case .finished(let ctx):
    ///         print("Done: \(ctx.output)")
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - prompt: User prompt to start the conversation
    ///   - deps: Dependencies to pass to tools
    ///   - messageHistory: Optional previous messages to continue from
    /// - Returns: An `AgentIterator` that yields `IterationNode` values
    public nonisolated func iter(
        _ prompt: String,
        deps: Deps,
        messageHistory: [Message] = []
    ) -> AgentIterator<Deps, Output> {
        AgentIterator(
            agent: self,
            prompt: prompt,
            deps: deps,
            messageHistory: messageHistory
        )
    }

    /// Resume iteration from a previously saved state.
    ///
    /// Use this to continue execution across sessions:
    /// 1. Save `node.state` when pausing
    /// 2. Later, call `iter(from: savedState, deps: deps)` to continue
    ///
    /// - Parameters:
    ///   - state: Previously saved iteration state
    ///   - deps: Dependencies to pass to tools
    /// - Returns: An `AgentIterator` that continues from the saved state
    public nonisolated func iter(
        from state: IterationState<Output>,
        deps: Deps
    ) -> AgentIterator<Deps, Output> {
        AgentIterator(
            agent: self,
            resumeFrom: state,
            deps: deps
        )
    }
}

// MARK: - Message Helpers

extension Message {
    /// Create assistant message from completion response.
    ///
    /// Preserves all content blocks (text, thinking, tool calls) in their
    /// exact order for cache compatibility.
    static func fromResponse(_ response: CompletionResponse) -> Message {
        .assistant(response.contentBlocks)
    }

    /// Create tool results message from call/output pairs.
    static func fromToolResults(_ results: [(ToolCall, ToolOutput)]) -> Message {
        .toolResults(results.map { call, output in
            ToolResultEntry(id: call.id, output: output)
        })
    }
}
