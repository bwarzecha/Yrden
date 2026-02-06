/// State at any iteration checkpoint.
///
/// This struct captures everything needed to:
/// 1. Continue execution in the current session
/// 2. Serialize and resume in a future session (via Codable)
/// 3. Understand what happened so far

import Foundation

// MARK: - IterationState

public struct IterationState<Output: SchemaType>: Sendable, Codable {
    /// Unique identifier for this run (stable across iterations).
    public let runID: String

    /// Conversation messages accumulated so far.
    /// Mutable to allow context engineering.
    public var messages: [Message]

    /// Accumulated token usage.
    public var usage: Usage

    /// Current iteration number (0-indexed).
    public internal(set) var iteration: Int

    /// Number of tool calls executed so far.
    public internal(set) var toolCallCount: Int

    /// Number of validation retries performed (separate from iteration count).
    public internal(set) var validationRetryCount: Int

    /// Current phase within the iteration.
    public internal(set) var phase: Phase

    /// Maximum iterations allowed for this run.
    /// Set by the agent on creation; updated by resume with additional iterations.
    /// The iterator uses this instead of agent.maxIterations.
    public internal(set) var maxIterations: Int

    public init(
        runID: String,
        messages: [Message],
        usage: Usage,
        iteration: Int,
        toolCallCount: Int,
        validationRetryCount: Int = 0,
        phase: Phase,
        maxIterations: Int = .max
    ) {
        self.runID = runID
        self.messages = messages
        self.usage = usage
        self.iteration = iteration
        self.toolCallCount = toolCallCount
        self.validationRetryCount = validationRetryCount
        self.phase = phase
        self.maxIterations = maxIterations
    }

    /// Creates a copy with a different phase.
    /// Useful for creating checkpoints or forking state without mutating the original.
    public func with(phase newPhase: Phase) -> IterationState<Output> {
        IterationState(
            runID: runID,
            messages: messages,
            usage: usage,
            iteration: iteration,
            toolCallCount: toolCallCount,
            validationRetryCount: validationRetryCount,
            phase: newPhase,
            maxIterations: maxIterations
        )
    }
}

// MARK: - Phase

extension IterationState {
    /// Phase within an iteration.
    public enum Phase: Sendable, Codable {
        /// About to send request to model.
        case beforeModel

        /// Model has responded.
        case afterModel(response: CompletionResponse)

        /// About to execute tool calls.
        case beforeTools(calls: [PendingToolDecision])

        /// Tools have been executed.
        case afterTools(results: [ToolCallResult])

        // Custom Codable for enum with associated values
        private enum CodingKeys: String, CodingKey {
            case type
            case response
            case calls
            case results
        }

        private enum PhaseType: String, Codable {
            case beforeModel
            case afterModel
            case beforeTools
            case afterTools
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(PhaseType.self, forKey: .type)

            switch type {
            case .beforeModel:
                self = .beforeModel
            case .afterModel:
                let response = try container.decode(CompletionResponse.self, forKey: .response)
                self = .afterModel(response: response)
            case .beforeTools:
                let calls = try container.decode([PendingToolDecision].self, forKey: .calls)
                self = .beforeTools(calls: calls)
            case .afterTools:
                let results = try container.decode([ToolCallResult].self, forKey: .results)
                self = .afterTools(results: results)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case .beforeModel:
                try container.encode(PhaseType.beforeModel, forKey: .type)
            case .afterModel(let response):
                try container.encode(PhaseType.afterModel, forKey: .type)
                try container.encode(response, forKey: .response)
            case .beforeTools(let calls):
                try container.encode(PhaseType.beforeTools, forKey: .type)
                try container.encode(calls, forKey: .calls)
            case .afterTools(let results):
                try container.encode(PhaseType.afterTools, forKey: .type)
                try container.encode(results, forKey: .results)
            }
        }
    }
}

// MARK: - PendingToolDecision

/// A pending tool call with its approval decision.
public struct PendingToolDecision: Sendable, Codable {
    /// The tool call from the model.
    public let call: ToolCall

    /// Whether this tool was marked as requiring approval in its definition.
    public let requiresApproval: Bool

    /// Current decision for this tool call.
    public var decision: Decision

    public init(call: ToolCall, requiresApproval: Bool, decision: Decision = .pending) {
        self.call = call
        self.requiresApproval = requiresApproval
        self.decision = decision
    }

    /// Decision outcomes for a pending tool call.
    public enum Decision: Sendable, Codable, Equatable {
        /// Will execute (default).
        case pending

        /// Will execute (explicit approval).
        case approved

        /// Won't execute, message sent to model.
        case denied(String)

        /// Won't execute, synthetic result used.
        case replaced(String)

        // Custom Codable for enum with associated values
        private enum CodingKeys: String, CodingKey {
            case type
            case message
        }

        private enum DecisionType: String, Codable {
            case pending
            case approved
            case denied
            case replaced
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(DecisionType.self, forKey: .type)

            switch type {
            case .pending:
                self = .pending
            case .approved:
                self = .approved
            case .denied:
                let message = try container.decode(String.self, forKey: .message)
                self = .denied(message)
            case .replaced:
                let message = try container.decode(String.self, forKey: .message)
                self = .replaced(message)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case .pending:
                try container.encode(DecisionType.pending, forKey: .type)
            case .approved:
                try container.encode(DecisionType.approved, forKey: .type)
            case .denied(let message):
                try container.encode(DecisionType.denied, forKey: .type)
                try container.encode(message, forKey: .message)
            case .replaced(let message):
                try container.encode(DecisionType.replaced, forKey: .type)
                try container.encode(message, forKey: .message)
            }
        }
    }
}
