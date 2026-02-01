import Foundation
@testable import Yrden

// All types are internal. Test targets access via `@testable import YrdenTestSupport`.

/// Delegate-based fake tool for testing, mirroring FakeModel's `onComplete` pattern.
///
/// Generic over input schema (`A`) and output type (`R`). Both are inferred from
/// the `onCall` closure — annotate the closure parameter to specify the input type,
/// and return the desired output from `.success(...)`.
///
/// ## String output (inferred)
/// ```swift
/// let tool = FakeTool(onCall: { (args: ConfigurableToolArgs) in
///     .success("processed: \(args.input)")
/// })
/// // Infers FakeTool<ConfigurableToolArgs, String>
/// ```
///
/// ## Structured output (inferred)
/// ```swift
/// let tool = FakeTool(onCall: { (args: WeatherArgs) in
///     .success(WeatherResult(temp: 72, condition: "sunny"))
/// })
/// // Infers FakeTool<WeatherArgs, WeatherResult>
/// ```
///
/// ## Recording
/// Every call's decoded arguments are recorded in `calls` for verification:
/// ```swift
/// let received = await tool.calls
/// #expect(received.count == 1)
/// #expect(received[0].input == "hello")
/// ```
actor FakeTool<A: SchemaType, R: Sendable>: AgentTool {
    typealias Deps = Void
    typealias Args = A
    typealias Output = R

    nonisolated let name: String
    nonisolated let description: String

    /// Every decoded argument set received, in order.
    private(set) var calls: [A] = []

    private let onCall: @Sendable (A) async throws -> ToolResult<R>

    init(
        name: String = "test_tool",
        onCall: @escaping @Sendable (A) async throws -> ToolResult<R>
    ) {
        self.name = name
        self.description = "Fake tool for testing"
        self.onCall = onCall
    }

    nonisolated func call(
        context: AgentContext<Void>,
        arguments: A
    ) async throws -> ToolResult<R> {
        await record(arguments)
        return try await onCall(arguments)
    }

    private func record(_ args: A) {
        calls.append(args)
    }
}
