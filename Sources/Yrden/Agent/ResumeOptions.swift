/// Options for continuing a paused agent run.
///
/// Use factory methods to construct options based on how the run was paused:
/// - `.needsApproval`: use `.approve()`, `.deny()`, `.replace()`, or `.decisions()`
/// - `.iterationLimitReached`: use `.additionalIterations()`
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
/// **Mixed decisions:**
/// ```swift
/// let continued = try await agent.resume(
///     from: run,
///     with: .decisions([
///         "call-1": .approved,
///         "call-2": .denied("Not permitted"),
///         "call-3": .replaced("Cached result")
///     ]),
///     deps: myDeps
/// )
/// ```
///
/// **Continue after iteration limit:**
/// ```swift
/// let continued = try await agent.resume(
///     from: run,
///     with: .additionalIterations(10),
///     deps: myDeps
/// )
/// ```

import Foundation

// MARK: - ResumeOptions

public struct ResumeOptions: Sendable {
    /// Updated decisions for pending tools (for `.needsApproval` status).
    /// Key is the tool call ID, value is the new decision.
    public var decisions: [String: PendingToolDecision.Decision]?

    /// Additional iterations to allow (for `.iterationLimitReached` status).
    public var additionalIterations: Int?

    // MARK: - Initializers

    public init(
        decisions: [String: PendingToolDecision.Decision]? = nil,
        additionalIterations: Int? = nil
    ) {
        self.decisions = decisions
        self.additionalIterations = additionalIterations
    }

    // MARK: - Factory Methods

    /// Approve specific tool calls by ID.
    public static func approve(_ callIds: [String]) -> ResumeOptions {
        ResumeOptions(decisions: Dictionary(uniqueKeysWithValues: callIds.map { ($0, .approved) }))
    }

    /// Approve all pending tool calls.
    public static func approveAll(from run: AgentRun<some SchemaType>) -> ResumeOptions {
        let ids = run.pendingApprovals.map { $0.call.id }
        return approve(ids)
    }

    /// Deny specific tool calls with a message.
    public static func deny(_ callIds: [String], message: String) -> ResumeOptions {
        ResumeOptions(decisions: Dictionary(uniqueKeysWithValues: callIds.map { ($0, .denied(message)) }))
    }

    /// Deny all pending tool calls with a message.
    public static func denyAll(from run: AgentRun<some SchemaType>, message: String) -> ResumeOptions {
        let ids = run.pendingApprovals.map { $0.call.id }
        return deny(ids, message: message)
    }

    /// Replace tool calls with synthetic results.
    public static func replace(_ replacements: [String: String]) -> ResumeOptions {
        ResumeOptions(decisions: replacements.mapValues { .replaced($0) })
    }

    /// Provide explicit decisions for each tool call.
    public static func decisions(_ decisions: [String: PendingToolDecision.Decision]) -> ResumeOptions {
        ResumeOptions(decisions: decisions)
    }

    /// Allow additional iterations.
    public static func additionalIterations(_ count: Int) -> ResumeOptions {
        ResumeOptions(additionalIterations: count)
    }
}
