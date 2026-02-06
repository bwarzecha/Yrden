/// A node in the agent iteration graph.
///
/// Each node represents a decision point where you can:
/// - Inspect current state
/// - Modify state before proceeding
/// - Stream execution (for beforeModel, beforeTools)
/// - Serialize and resume later
///
/// ## Usage
/// ```swift
/// for try await node in agent.iter("Task", deps: deps) {
///     switch node {
///     case .beforeModel(let ctx):
///         // Optionally modify messages or stream
///         ctx.state.messages.append(.system("Extra context"))
///     case .afterModel(let ctx):
///         print("Model responded: \(ctx.response.content ?? "")")
///     case .beforeTools(let ctx):
///         // Approve or deny tools
///         for pending in ctx.pendingCalls {
///             ctx.approve(pending.call)
///         }
///     case .afterTools(let ctx):
///         print("Got \(ctx.results.count) results")
///     case .finished(let ctx):
///         print("Done: \(ctx.output)")
///     }
/// }
/// ```

import Foundation

// MARK: - IterationNode

public enum IterationNode<Deps: Sendable, Output: SchemaType>: Sendable {
    /// About to call the model.
    case beforeModel(BeforeModelContext<Deps, Output>)

    /// Model has responded.
    case afterModel(AfterModelContext<Deps, Output>)

    /// About to execute tools.
    case beforeTools(BeforeToolsContext<Deps, Output>)

    /// Tools have been executed.
    case afterTools(AfterToolsContext<Deps, Output>)

    /// Execution completed with final output.
    case finished(FinishedContext<Deps, Output>)
}
