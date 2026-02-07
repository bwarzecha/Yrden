import Foundation
@testable import Yrden

// All types are internal. Test targets access via `@testable import YrdenTestSupport`.

// MARK: - Slow Tool

/// A tool that takes a configurable amount of time to complete.
/// Useful for testing timeouts and cancellation.
struct SlowTool: TypedTool {
    typealias Args = ConfigurableToolArgs

    let delay: Duration
    let result: String

    var name: String { "slow_tool" }
    var description: String { "A tool that takes time to complete" }

    init(delay: Duration, result: String = "Completed after delay") {
        self.delay = delay
        self.result = result
    }

    func execute(
        context: ToolContext,
        arguments: Args
    ) async throws -> ToolResult<String> {
        try await Task.sleep(for: delay)
        return .success("\(result): \(arguments.input)")
    }
}
