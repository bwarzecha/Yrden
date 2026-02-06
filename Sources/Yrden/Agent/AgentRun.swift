/// Result of running an agent — a complete, serializable checkpoint.
///
/// `AgentRun` wraps `IterationState` (from iter()) and adds semantic status
/// explaining WHY the run stopped, not just WHERE it stopped.
///
/// This is Codable for cross-session persistence.
///
/// ## Usage Patterns
///
/// **Simple case (throws on pause):**
/// ```swift
/// let output = try await agent.run("Hello", deps: ()).result()
/// ```
///
/// **Handle all outcomes:**
/// ```swift
/// let run = try await agent.run("Delete files", deps: myDeps)
///
/// switch run.status {
/// case .completed(let output):
///     print("Done: \(output)")
/// case .needsApproval(let pending):
///     for p in pending where p.requiresApproval {
///         print("Tool \(p.call.name) needs approval")
///     }
/// case .iterationLimitReached(let limit):
///     print("Hit limit at \(limit)")
/// case .usageLimitReached(let kind):
///     print("Hit usage limit: \(kind)")
/// }
/// ```

import Foundation

// MARK: - AgentRun

public struct AgentRun<Output: SchemaType>: Sendable {

    // MARK: - Core State (from iter())

    /// Complete checkpoint state from iter().
    /// Contains: runID, messages, usage, iteration, toolCallCount, phase.
    public let state: IterationState<Output>

    // MARK: - Status

    /// Why this run stopped, with associated continuation data.
    public let status: Status

    /// How an agent run ended.
    public enum Status: Sendable {
        /// Run completed successfully with output.
        case completed(Output)

        /// Run paused — tools need human approval before continuing.
        /// Contains ALL pending tool decisions (including those not needing approval).
        /// Filter by `requiresApproval` to show only those needing user action.
        case needsApproval([PendingToolDecision])

        /// Run paused — iteration limit was reached.
        /// State contains the last completed iteration; ready to continue.
        case iterationLimitReached(limit: Int)

        /// Run stopped — a usage limit was reached.
        /// State preserved for inspection; cannot resume (would hit limit again).
        case usageLimitReached(UsageLimit)
    }

    // MARK: - Init

    public init(state: IterationState<Output>, status: Status) {
        self.state = state
        self.status = status
    }

    // MARK: - Convenience Accessors

    /// Unique identifier for this run (stable across resume calls).
    public var runID: String { state.runID }

    /// All messages accumulated during the run.
    public var messages: [Message] { state.messages }

    /// Total token usage for the run.
    public var usage: Usage { state.usage }

    /// Current iteration number (0-indexed).
    public var iteration: Int { state.iteration }

    /// Number of tool calls executed.
    public var toolCallCount: Int { state.toolCallCount }

    /// Number of model requests made (1-indexed for compatibility).
    /// This equals `iteration + 1` since iteration is 0-indexed.
    public var requestCount: Int { state.iteration + 1 }

    /// The output if status is `.completed`, nil otherwise.
    public var output: Output? {
        if case .completed(let output) = status { return output }
        return nil
    }

    /// Whether the run completed successfully.
    public var isCompleted: Bool {
        if case .completed = status { return true }
        return false
    }

    /// Whether the run can be resumed.
    public var canResume: Bool {
        switch status {
        case .completed, .usageLimitReached:
            return false
        case .needsApproval, .iterationLimitReached:
            return true
        }
    }

    /// Pending tool decisions if status is `.needsApproval`, empty otherwise.
    public var pendingApprovals: [PendingToolDecision] {
        if case .needsApproval(let pending) = status { return pending }
        return []
    }

    /// Tools that specifically require user approval.
    public var toolsRequiringApproval: [PendingToolDecision] {
        pendingApprovals.filter { $0.requiresApproval }
    }
}

// MARK: - Result Extraction

extension AgentRun {
    /// Get the output, throwing if not completed.
    ///
    /// Use this when you want the simple "throw on pause" behavior:
    /// ```swift
    /// let output = try agent.run("task", deps: ()).result()
    /// ```
    public func result() throws -> Output {
        switch status {
        case .completed(let output):
            return output
        case .needsApproval:
            throw AgentError<Output>.needsApproval(self)
        case .iterationLimitReached:
            throw AgentError<Output>.iterationLimitReached(self)
        case .usageLimitReached:
            throw AgentError<Output>.usageLimitReached(self)
        }
    }
}

// MARK: - Codable

extension AgentRun: Codable where Output: Codable {
    private enum CodingKeys: String, CodingKey {
        case state
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.state = try container.decode(IterationState<Output>.self, forKey: .state)
        self.status = try container.decode(Status.self, forKey: .status)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(status, forKey: .status)
    }
}

extension AgentRun.Status: Codable where Output: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case output
        case pending
        case limit
        case usageLimit
    }

    private enum StatusType: String, Codable {
        case completed
        case needsApproval
        case iterationLimitReached
        case usageLimitReached
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(StatusType.self, forKey: .type)

        switch type {
        case .completed:
            let output = try container.decode(Output.self, forKey: .output)
            self = .completed(output)
        case .needsApproval:
            let pending = try container.decode([PendingToolDecision].self, forKey: .pending)
            self = .needsApproval(pending)
        case .iterationLimitReached:
            let limit = try container.decode(Int.self, forKey: .limit)
            self = .iterationLimitReached(limit: limit)
        case .usageLimitReached:
            let usageLimit = try container.decode(UsageLimit.self, forKey: .usageLimit)
            self = .usageLimitReached(usageLimit)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .completed(let output):
            try container.encode(StatusType.completed, forKey: .type)
            try container.encode(output, forKey: .output)
        case .needsApproval(let pending):
            try container.encode(StatusType.needsApproval, forKey: .type)
            try container.encode(pending, forKey: .pending)
        case .iterationLimitReached(let limit):
            try container.encode(StatusType.iterationLimitReached, forKey: .type)
            try container.encode(limit, forKey: .limit)
        case .usageLimitReached(let usageLimit):
            try container.encode(StatusType.usageLimitReached, forKey: .type)
            try container.encode(usageLimit, forKey: .usageLimit)
        }
    }
}

// MARK: - UsageLimit Codable

extension UsageLimit: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case used
        case limit
    }

    private enum LimitType: String, Codable {
        case inputTokens
        case outputTokens
        case totalTokens
        case requests
        case toolCalls
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(LimitType.self, forKey: .type)
        let used = try container.decode(Int.self, forKey: .used)
        let limit = try container.decode(Int.self, forKey: .limit)

        switch type {
        case .inputTokens:
            self = .inputTokens(used: used, limit: limit)
        case .outputTokens:
            self = .outputTokens(used: used, limit: limit)
        case .totalTokens:
            self = .totalTokens(used: used, limit: limit)
        case .requests:
            self = .requests(used: used, limit: limit)
        case .toolCalls:
            self = .toolCalls(used: used, limit: limit)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .inputTokens(let used, let limit):
            try container.encode(LimitType.inputTokens, forKey: .type)
            try container.encode(used, forKey: .used)
            try container.encode(limit, forKey: .limit)
        case .outputTokens(let used, let limit):
            try container.encode(LimitType.outputTokens, forKey: .type)
            try container.encode(used, forKey: .used)
            try container.encode(limit, forKey: .limit)
        case .totalTokens(let used, let limit):
            try container.encode(LimitType.totalTokens, forKey: .type)
            try container.encode(used, forKey: .used)
            try container.encode(limit, forKey: .limit)
        case .requests(let used, let limit):
            try container.encode(LimitType.requests, forKey: .type)
            try container.encode(used, forKey: .used)
            try container.encode(limit, forKey: .limit)
        case .toolCalls(let used, let limit):
            try container.encode(LimitType.toolCalls, forKey: .type)
            try container.encode(used, forKey: .used)
            try container.encode(limit, forKey: .limit)
        }
    }
}
