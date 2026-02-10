/// Hook points for the agent iteration loop.
///
/// Implement any subset of these methods to observe or modify agent behavior
/// at each phase. Default implementations are no-ops.
///
/// Hooks run inside `run()` and `runStream()` — they execute alongside
/// built-in behavior (background task injection, iteration limits, etc.)
/// without requiring you to reimplement it via `iter()`.
///
/// ## Example
/// ```swift
/// struct TurnCounter: AgentHooks {
///     typealias Output = String
///     let maxIterations: Int
///
///     func beforeModel(_ context: BeforeModelContext<String>) async {
///         let turn = context.state.iteration + 1
///         context.state.messages.append(
///             .system("[Turn \(turn) of \(maxIterations)]")
///         )
///     }
/// }
///
/// let agent = try Agent<String>(
///     model: model,
///     hooks: TurnCounter(maxIterations: 10)
/// )
/// ```
public protocol AgentHooks<Output>: Sendable {
    associatedtype Output: SchemaType

    /// Called before each model call. Modify `context.state.messages` to inject context.
    func beforeModel(_ context: BeforeModelContext<Output>) async

    /// Called after the model responds, before tool calls are processed.
    func afterModel(_ context: AfterModelContext<Output>) async

    /// Called before tool calls are executed. Inspect or modify pending decisions.
    func beforeTools(_ context: BeforeToolsContext<Output>) async

    /// Called after tool calls complete, before the next iteration.
    func afterTools(_ context: AfterToolsContext<Output>) async

    /// Called when the agent finishes (model responded without tool calls).
    func finished(_ context: FinishedContext<Output>) async
}

extension AgentHooks {
    public func beforeModel(_ context: BeforeModelContext<Output>) async {}
    public func afterModel(_ context: AfterModelContext<Output>) async {}
    public func beforeTools(_ context: BeforeToolsContext<Output>) async {}
    public func afterTools(_ context: AfterToolsContext<Output>) async {}
    public func finished(_ context: FinishedContext<Output>) async {}
}
