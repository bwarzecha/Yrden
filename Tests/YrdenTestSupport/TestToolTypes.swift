import Foundation
@testable import Yrden

// All types are internal. Test targets access via `@testable import YrdenTestSupport`.

// MARK: - Retry Stateful Tool

/// A tool that tracks call count and changes behavior after N calls.
/// Useful for testing retry scenarios where tools fail then succeed.
actor RetryStatefulTool: AgentTool {
    typealias Deps = Void
    typealias Args = ConfigurableToolArgs

    private var callCount = 0
    private let failUntilCall: Int
    private let failBehavior: ConfigurableTool.Behavior
    private let successResult: String

    nonisolated let name: String
    nonisolated let description: String

    init(
        name: String = "stateful_tool",
        failUntilCall: Int,
        failWith behavior: ConfigurableTool.Behavior = .retry("Try again"),
        successResult: String = "Success"
    ) {
        self.name = name
        self.description = "A stateful test tool"
        self.failUntilCall = failUntilCall
        self.failBehavior = behavior
        self.successResult = successResult
    }

    nonisolated func call(
        context: AgentContext<Void>,
        arguments: Args
    ) async throws -> ToolResult<String> {
        try await execute(arguments: arguments)
    }

    private func execute(arguments: Args) throws -> ToolResult<String> {
        callCount += 1

        if callCount <= failUntilCall {
            switch failBehavior {
            case .success(let result):
                return .success(result)
            case .failure(let error):
                return .failure(error)
            case .throwError(let error):
                throw error
            case .retry(let message):
                return .retry(message: "\(message) (attempt \(callCount))")
            }
        }
        return .success(successResult)
    }

    var currentCallCount: Int {
        get async { callCount }
    }

    func reset() {
        callCount = 0
    }
}

// MARK: - Slow Tool

/// A tool that takes a configurable amount of time to complete.
/// Useful for testing timeouts and cancellation.
struct SlowTool: AgentTool {
    typealias Deps = Void
    typealias Args = ConfigurableToolArgs

    let delay: Duration
    let result: String

    var name: String { "slow_tool" }
    var description: String { "A tool that takes time to complete" }

    init(delay: Duration, result: String = "Completed after delay") {
        self.delay = delay
        self.result = result
    }

    func call(
        context: AgentContext<Void>,
        arguments: Args
    ) async throws -> ToolResult<String> {
        try await Task.sleep(for: delay)
        return .success("\(result): \(arguments.input)")
    }
}
