/// Tests for ToolExecutionEngine.
///
/// Tests the isolated tool execution logic:
/// - Basic tool execution
/// - Tool not found handling
/// - Timeout enforcement
/// - Retry behavior
/// - Batch execution with deferral stopping
/// - Observer callbacks

import Testing
import Foundation
@testable import Yrden

// MARK: - Test Mock Model (Minimal)

/// Minimal model for creating contexts in tests.
private actor MinimalMockModel: Model {
    nonisolated let name: String = "minimal-mock"
    nonisolated let capabilities = ModelCapabilities.claude35

    nonisolated func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        fatalError("Not implemented - tests don't call model")
    }

    nonisolated func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        fatalError("Not implemented - tests don't call model")
    }
}

// MARK: - Test Tools

/// A simple tool that returns a fixed result.
private struct TEESimpleMockTool: AgentTool {
    typealias Deps = Void

    @Schema(description: "Mock arguments")
    struct Args {
        @Guide(description: "Input value")
        let input: String
    }

    let result: ToolResult<String>
    var name: String { "simple_mock" }
    var description: String { "A simple mock tool" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        result
    }
}

/// A tool that fails N times then succeeds.
private actor TEERetryCountingTool: AgentTool {
    typealias Deps = Void

    @Schema(description: "Empty args")
    struct Args {}

    nonisolated var name: String { "retry_counting" }
    nonisolated var description: String { "Fails then succeeds" }
    nonisolated var maxRetries: Int { 3 }

    private var failuresRemaining: Int

    init(failCount: Int) {
        self.failuresRemaining = failCount
    }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            return .retry(message: "Please try again (\(failuresRemaining) failures remaining)")
        }
        return .success("Success after retries")
    }
}

/// A tool that always defers.
private struct TEEDeferringTool: AgentTool {
    typealias Deps = Void

    @Schema(description: "Empty args")
    struct Args {}

    var name: String { "deferring_tool" }
    var description: String { "Always defers" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        .deferred(.needsApproval(reason: "Needs human approval"))
    }
}

/// A slow tool for timeout testing.
private struct TEESlowTool: AgentTool {
    typealias Deps = Void

    @Schema(description: "Empty args")
    struct Args {}

    let delay: Duration
    var name: String { "slow_tool" }
    var description: String { "Takes time to execute" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        try await Task.sleep(for: delay)
        return .success("Completed after delay")
    }
}

/// A tool that throws an error.
private struct TEEThrowingTool: AgentTool {
    typealias Deps = Void

    @Schema(description: "Empty args")
    struct Args {}

    var name: String { "throwing_tool" }
    var description: String { "Always throws" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        throw ToolExecutionError.custom("Tool threw an error")
    }
}

// MARK: - Helper

private func makeContext() -> AgentContext<Void> {
    AgentContext(model: MinimalMockModel())
}

private func makeToolCall(name: String, arguments: String = "{}") -> ToolCall {
    ToolCall(id: UUID().uuidString, name: name, arguments: arguments)
}

// MARK: - Basic Execution Tests

@Suite("ToolExecutionEngine - Basic Execution")
struct ToolExecutionEngineBasicTests {

    @Test("executes tool and returns success result")
    func basicExecution() async throws {
        let tool = TEESimpleMockTool(result: .success("done"))
        let engine = ToolExecutionEngine(
            tools: [AnyAgentTool(tool)],
            timeout: nil
        )

        let call = makeToolCall(name: "simple_mock", arguments: "{\"input\": \"test\"}")
        let result = try await engine.execute(call: call, context: makeContext())

        guard case .success(let value) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(value == "done")
    }

    @Test("returns failure for unknown tool")
    func toolNotFound() async throws {
        let engine = ToolExecutionEngine<Void>(tools: [], timeout: nil)

        let call = makeToolCall(name: "nonexistent")
        let result = try await engine.execute(call: call, context: makeContext())

        guard case .failure(let error) = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }

        guard let toolError = error as? ToolExecutionError,
              case .toolNotFound("nonexistent") = toolError else {
            Issue.record("Expected toolNotFound error, got \(error)")
            return
        }
    }

    @Test("returns failure result from tool")
    func toolReturnsFailure() async throws {
        let tool = TEESimpleMockTool(result: .failure(ToolExecutionError.custom("intentional failure")))
        let engine = ToolExecutionEngine(
            tools: [AnyAgentTool(tool)],
            timeout: nil
        )

        let call = makeToolCall(name: "simple_mock", arguments: "{\"input\": \"test\"}")
        let result = try await engine.execute(call: call, context: makeContext())

        guard case .failure = result else {
            Issue.record("Expected failure, got \(result)")
            return
        }
    }

    @Test("returns deferred result from tool")
    func toolReturnsDeferred() async throws {
        let tool = TEEDeferringTool()
        let engine = ToolExecutionEngine(
            tools: [AnyAgentTool(tool)],
            timeout: nil
        )

        let call = makeToolCall(name: "deferring_tool")
        let result = try await engine.execute(call: call, context: makeContext())

        guard case .deferred(let deferral) = result else {
            Issue.record("Expected deferred, got \(result)")
            return
        }
        #expect(deferral.kind == .approval)
    }
}

// MARK: - Timeout Tests

@Suite("ToolExecutionEngine - Timeout")
struct ToolExecutionEngineTimeoutTests {

    @Test("respects timeout and throws error")
    func timeoutEnforcement() async throws {
        let slowTool = TEESlowTool(delay: .seconds(5))
        let engine = ToolExecutionEngine(
            tools: [AnyAgentTool(slowTool)],
            timeout: .milliseconds(50)
        )

        let call = makeToolCall(name: "slow_tool")

        do {
            _ = try await engine.execute(call: call, context: makeContext())
            Issue.record("Expected timeout error")
        } catch let error as AgentError {
            guard case .toolTimeout(let name, _) = error else {
                Issue.record("Expected toolTimeout, got \(error)")
                return
            }
            #expect(name == "slow_tool")
        }
    }

    @Test("completes before timeout")
    func completesBeforeTimeout() async throws {
        let tool = TEESimpleMockTool(result: .success("fast"))
        let engine = ToolExecutionEngine(
            tools: [AnyAgentTool(tool)],
            timeout: .seconds(5)
        )

        let call = makeToolCall(name: "simple_mock", arguments: "{\"input\": \"test\"}")
        let result = try await engine.execute(call: call, context: makeContext())

        guard case .success(let value) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(value == "fast")
    }

    @Test("no timeout when nil")
    func noTimeoutWhenNil() async throws {
        let slowTool = TEESlowTool(delay: .milliseconds(50))
        let engine = ToolExecutionEngine(
            tools: [AnyAgentTool(slowTool)],
            timeout: nil
        )

        let call = makeToolCall(name: "slow_tool")
        let result = try await engine.execute(call: call, context: makeContext())

        guard case .success = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
    }
}

// MARK: - Retry Tests

@Suite("ToolExecutionEngine - Retry")
struct ToolExecutionEngineRetryTests {

    @Test("retries on retry result and eventually succeeds")
    func retryThenSucceed() async throws {
        let retryTool = TEERetryCountingTool(failCount: 2)
        let engine = ToolExecutionEngine(
            tools: [AnyAgentTool(retryTool)],
            timeout: nil
        )

        let call = makeToolCall(name: "retry_counting")
        let result = try await engine.execute(call: call, context: makeContext())

        guard case .success(let value) = result else {
            Issue.record("Expected success after retries, got \(result)")
            return
        }
        #expect(value == "Success after retries")
    }

    @Test("returns retry result when max retries exceeded")
    func maxRetriesExceeded() async throws {
        // Tool has maxRetries=3, so 4 failures will exceed
        let retryTool = TEERetryCountingTool(failCount: 10)
        let engine = ToolExecutionEngine(
            tools: [AnyAgentTool(retryTool)],
            timeout: nil
        )

        let call = makeToolCall(name: "retry_counting")
        let result = try await engine.execute(call: call, context: makeContext())

        // Should return the last retry result (not throw)
        guard case .retry = result else {
            Issue.record("Expected retry result after max retries, got \(result)")
            return
        }
    }
}

// MARK: - Batch Execution Tests

@Suite("ToolExecutionEngine - Batch Execution")
struct ToolExecutionEngineBatchTests {

    @Test("executeAll processes all tools")
    func executeAllProcessesAll() async throws {
        // Need different names for lookup
        let anyTool1 = AnyAgentTool<Void>(
            name: "tool1",
            description: "Tool 1",
            definition: ToolDefinition(name: "tool1", description: "Tool 1", inputSchema: [:]),
            call: { _, _ in .success("result1") }
        )
        let anyTool2 = AnyAgentTool<Void>(
            name: "tool2",
            description: "Tool 2",
            definition: ToolDefinition(name: "tool2", description: "Tool 2", inputSchema: [:]),
            call: { _, _ in .success("result2") }
        )

        let engine = ToolExecutionEngine(
            tools: [anyTool1, anyTool2],
            timeout: nil
        )

        let calls = [
            makeToolCall(name: "tool1"),
            makeToolCall(name: "tool2")
        ]

        let batch = try await engine.executeAll(
            calls: calls,
            baseContext: makeContext()
        )

        #expect(batch.results.count == 2)
        #expect(!batch.stoppedOnDeferral)

        guard case .success("result1") = batch.results[0].result else {
            Issue.record("Expected success for tool1")
            return
        }
        guard case .success("result2") = batch.results[1].result else {
            Issue.record("Expected success for tool2")
            return
        }
    }

    @Test("executeAll stops on deferral")
    func executeAllStopsOnDeferral() async throws {
        let normalTool = AnyAgentTool<Void>(
            name: "normal",
            description: "Normal",
            definition: ToolDefinition(name: "normal", description: "Normal", inputSchema: [:]),
            call: { _, _ in .success("ok") }
        )
        let deferringTool = AnyAgentTool<Void>(TEEDeferringTool())
        let afterDeferralTool = AnyAgentTool<Void>(
            name: "after",
            description: "After",
            definition: ToolDefinition(name: "after", description: "After", inputSchema: [:]),
            call: { _, _ in .success("should not run") }
        )

        let engine = ToolExecutionEngine(
            tools: [normalTool, deferringTool, afterDeferralTool],
            timeout: nil
        )

        let calls = [
            makeToolCall(name: "normal"),
            makeToolCall(name: "deferring_tool"),
            makeToolCall(name: "after")
        ]

        let batch = try await engine.executeAll(
            calls: calls,
            baseContext: makeContext()
        )

        #expect(batch.results.count == 2, "Should stop after deferral, not execute third tool")
        #expect(batch.stoppedOnDeferral)
        #expect(batch.deferredCalls.count == 1)
    }

    @Test("executeAll tracks duration for each tool")
    func executeAllTracksDuration() async throws {
        let slowTool = AnyAgentTool<Void>(
            name: "slow",
            description: "Slow",
            definition: ToolDefinition(name: "slow", description: "Slow", inputSchema: [:]),
            call: { _, _ in
                try await Task.sleep(for: .milliseconds(50))
                return .success("done")
            }
        )

        let engine = ToolExecutionEngine<Void>(tools: [slowTool], timeout: nil)
        let calls = [makeToolCall(name: "slow")]

        let batch = try await engine.executeAll(
            calls: calls,
            baseContext: makeContext()
        )

        #expect(batch.results.count == 1)

        // Duration should be at least 50ms
        let duration = batch.results[0].duration
        #expect(duration >= .milliseconds(50))
    }
}

// MARK: - Error Handling Tests

@Suite("ToolExecutionEngine - Error Handling")
struct ToolExecutionEngineErrorTests {

    @Test("catches tool exception and returns failure")
    func catchesToolException() async throws {
        let throwingTool = TEEThrowingTool()
        let engine = ToolExecutionEngine(
            tools: [AnyAgentTool(throwingTool)],
            timeout: nil
        )

        let call = makeToolCall(name: "throwing_tool")
        let result = try await engine.execute(call: call, context: makeContext())

        guard case .failure = result else {
            Issue.record("Expected failure for throwing tool, got \(result)")
            return
        }
    }

    @Test("propagates AgentError (does not catch)")
    func propagatesAgentError() async throws {
        let tool = AnyAgentTool<Void>(
            name: "agent_error_tool",
            description: "Throws AgentError",
            definition: ToolDefinition(name: "agent_error_tool", description: "Throws AgentError", inputSchema: [:]),
            call: { _, _ in
                throw AgentError.cancelled
            }
        )

        let engine = ToolExecutionEngine(tools: [tool], timeout: nil)
        let call = makeToolCall(name: "agent_error_tool")

        do {
            _ = try await engine.execute(call: call, context: makeContext())
            Issue.record("Expected AgentError to be thrown")
        } catch let error as AgentError {
            guard case .cancelled = error else {
                Issue.record("Expected cancelled error, got \(error)")
                return
            }
        }
    }
}
