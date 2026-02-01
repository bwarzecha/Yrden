/// Tests for ToolExecutionEngine approval/deferral functionality.
///
/// Tests the requiresApproval behavior:
/// - Single tool requiring approval returns deferred
/// - Multiple tools with all requiring approval
/// - Multiple tools with some requiring approval (key: no execution)
/// - Multiple tools with none requiring approval
/// - Tool not found handling

import Testing
import Foundation
@testable import Yrden

// MARK: - Test Mock Model

private actor ApprovalTestMockModel: Model {
    nonisolated let name: String = "approval-test-mock"
    nonisolated let capabilities = ModelCapabilities.claude35

    nonisolated func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        fatalError("Not implemented - tests don't call model")
    }

    nonisolated func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        fatalError("Not implemented - tests don't call model")
    }
}

// MARK: - Helper

private func makeContext() -> AgentContext<Void> {
    AgentContext(model: ApprovalTestMockModel())
}

private func makeToolCall(name: String, arguments: String = "{}") -> ToolCall {
    ToolCall(id: UUID().uuidString, name: name, arguments: arguments)
}

/// Thread-safe call counter for tracking tool invocations.
private actor ToolCallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

/// Creates a test tool with configurable approval flag and call tracking.
private func makeTool(
    name: String,
    requiresApproval: Bool,
    callCounter: ToolCallCounter? = nil
) -> AnyAgentTool<Void> {
    AnyAgentTool<Void>(
        name: name,
        description: "Test tool: \(name)",
        definition: ToolDefinition(name: name, description: "Test tool", inputSchema: [:]),
        requiresApproval: requiresApproval,
        call: { _, _ in
            await callCounter?.increment()
            return .success("\(name) result")
        }
    )
}

/// Formats AnyToolResult for display in error messages.
private func describe(_ result: AnyToolResult) -> String {
    switch result {
    case .success(let value): return "success(\(value))"
    case .retry(let message): return "retry(\(message))"
    case .failure(let error): return "failure(\(error))"
    case .deferred(let call): return "deferred(\(call.reason))"
    }
}

// MARK: - Single Tool Approval Tests

@Suite("ToolExecutionEngine - Single Tool Approval")
struct ToolExecutionEngineSingleApprovalTests {

    @Test("tool with requiresApproval=true returns deferred without executing")
    func singleToolRequiresApproval() async throws {
        let counter = ToolCallCounter()
        let tool = makeTool(name: "approval_tool", requiresApproval: true, callCounter: counter)

        let engine = ToolExecutionEngine(tools: [tool], timeout: nil)
        let call = makeToolCall(name: "approval_tool")

        let result = try await engine.execute(call: call, context: makeContext())

        guard case .deferred(let deferral) = result else {
            Issue.record("Expected deferred result, got \(describe(result))")
            return
        }

        #expect(deferral.kind == .approval)
        #expect(deferral.id == call.id)
        #expect(deferral.reason.contains("approval_tool"))

        let callCount = await counter.count
        #expect(callCount == 0, "Tool should not have been called")
    }

    @Test("tool with requiresApproval=false executes normally")
    func singleToolNoApproval() async throws {
        let counter = ToolCallCounter()
        let tool = makeTool(name: "normal_tool", requiresApproval: false, callCounter: counter)

        let engine = ToolExecutionEngine(tools: [tool], timeout: nil)
        let call = makeToolCall(name: "normal_tool")

        let result = try await engine.execute(call: call, context: makeContext())

        guard case .success(let value) = result else {
            Issue.record("Expected success, got \(describe(result))")
            return
        }

        #expect(value == "normal_tool result")

        let callCount = await counter.count
        #expect(callCount == 1)
    }
}

// MARK: - Batch Approval Tests

@Suite("ToolExecutionEngine - Batch Approval")
struct ToolExecutionEngineBatchApprovalTests {

    @Test("executeAll with ALL tools requiring approval returns deferred for all")
    func allToolsRequireApproval() async throws {
        let counter1 = ToolCallCounter()
        let counter2 = ToolCallCounter()
        let counter3 = ToolCallCounter()

        let tool1 = makeTool(name: "approval_1", requiresApproval: true, callCounter: counter1)
        let tool2 = makeTool(name: "approval_2", requiresApproval: true, callCounter: counter2)
        let tool3 = makeTool(name: "approval_3", requiresApproval: true, callCounter: counter3)

        let engine = ToolExecutionEngine(tools: [tool1, tool2, tool3], timeout: nil)
        let calls = [
            makeToolCall(name: "approval_1"),
            makeToolCall(name: "approval_2"),
            makeToolCall(name: "approval_3")
        ]

        let batch = try await engine.executeAll(calls: calls, baseContext: makeContext())

        #expect(batch.results.count == 3, "Should return deferred for all 3 tools")
        #expect(batch.stoppedOnDeferral)
        #expect(batch.deferredCalls.count == 3)

        // Verify all results are deferred with correct info
        for (index, item) in batch.results.enumerated() {
            guard case .deferred(let deferral) = item.result else {
                Issue.record("Expected deferred for tool \(index + 1), got \(describe(item.result))")
                continue
            }
            #expect(deferral.kind == .approval)
            #expect(deferral.id == calls[index].id)
        }

        // Verify no tools were called
        let count1 = await counter1.count
        let count2 = await counter2.count
        let count3 = await counter3.count
        #expect(count1 == 0, "Tool 1 should not have been called")
        #expect(count2 == 0, "Tool 2 should not have been called")
        #expect(count3 == 0, "Tool 3 should not have been called")
    }

    @Test("executeAll with SOME tools requiring approval returns deferred only for those, executes NONE")
    func someToolsRequireApproval() async throws {
        let normalCounter1 = ToolCallCounter()
        let approvalCounter = ToolCallCounter()
        let normalCounter2 = ToolCallCounter()

        let normalTool1 = makeTool(name: "normal_1", requiresApproval: false, callCounter: normalCounter1)
        let approvalTool = makeTool(name: "approval_tool", requiresApproval: true, callCounter: approvalCounter)
        let normalTool2 = makeTool(name: "normal_2", requiresApproval: false, callCounter: normalCounter2)

        let engine = ToolExecutionEngine(
            tools: [normalTool1, approvalTool, normalTool2],
            timeout: nil
        )
        let calls = [
            makeToolCall(name: "normal_1"),
            makeToolCall(name: "approval_tool"),
            makeToolCall(name: "normal_2")
        ]

        let batch = try await engine.executeAll(calls: calls, baseContext: makeContext())

        // Key behavior: only tools requiring approval should be in results
        #expect(batch.results.count == 1, "Should only return deferred for the one tool requiring approval")
        #expect(batch.stoppedOnDeferral)
        #expect(batch.deferredCalls.count == 1)

        // Verify the deferred result is for the approval tool
        guard case .deferred(let deferral) = batch.results[0].result else {
            Issue.record("Expected deferred result, got \(describe(batch.results[0].result))")
            return
        }
        #expect(deferral.kind == .approval)
        #expect(batch.results[0].call.name == "approval_tool")

        // Key assertion: NO tools should have been executed
        let normalCount1 = await normalCounter1.count
        let approvalCount = await approvalCounter.count
        let normalCount2 = await normalCounter2.count
        #expect(normalCount1 == 0, "Normal tool 1 should NOT have been called")
        #expect(approvalCount == 0, "Approval tool should NOT have been called")
        #expect(normalCount2 == 0, "Normal tool 2 should NOT have been called")
    }

    @Test("executeAll with NO tools requiring approval executes all normally")
    func noToolsRequireApproval() async throws {
        let counter1 = ToolCallCounter()
        let counter2 = ToolCallCounter()

        let tool1 = makeTool(name: "normal_1", requiresApproval: false, callCounter: counter1)
        let tool2 = makeTool(name: "normal_2", requiresApproval: false, callCounter: counter2)

        let engine = ToolExecutionEngine(tools: [tool1, tool2], timeout: nil)
        let calls = [
            makeToolCall(name: "normal_1"),
            makeToolCall(name: "normal_2")
        ]

        let batch = try await engine.executeAll(calls: calls, baseContext: makeContext())

        #expect(batch.results.count == 2)
        #expect(!batch.stoppedOnDeferral)
        #expect(batch.deferredCalls.isEmpty)

        guard case .success("normal_1 result") = batch.results[0].result else {
            Issue.record("Expected success for tool1, got \(describe(batch.results[0].result))")
            return
        }
        guard case .success("normal_2 result") = batch.results[1].result else {
            Issue.record("Expected success for tool2, got \(describe(batch.results[1].result))")
            return
        }

        let count1 = await counter1.count
        let count2 = await counter2.count
        #expect(count1 == 1, "Tool 1 should have been called once")
        #expect(count2 == 1, "Tool 2 should have been called once")
    }
}

// MARK: - Tool Not Found Tests

@Suite("ToolExecutionEngine - Tool Not Found")
struct ToolExecutionEngineToolNotFoundTests {

    @Test("execute returns failure for unknown tool")
    func executeToolNotFound() async throws {
        let engine = ToolExecutionEngine<Void>(tools: [], timeout: nil)
        let call = makeToolCall(name: "nonexistent_tool")

        let result = try await engine.execute(call: call, context: makeContext())

        guard case .failure(let error) = result else {
            Issue.record("Expected failure, got \(describe(result))")
            return
        }

        guard let toolError = error as? ToolExecutionError,
              case .toolNotFound("nonexistent_tool") = toolError else {
            Issue.record("Expected toolNotFound error, got \(error)")
            return
        }
    }

    @Test("executeAll with unknown tool returns toolNotFound failure (not treated as approval)")
    func executeAllUnknownToolNotDeferred() async throws {
        let counter = ToolCallCounter()
        let normalTool = makeTool(name: "known_tool", requiresApproval: false, callCounter: counter)

        let engine = ToolExecutionEngine(tools: [normalTool], timeout: nil)
        let calls = [
            makeToolCall(name: "known_tool"),
            makeToolCall(name: "unknown_tool")
        ]

        let batch = try await engine.executeAll(calls: calls, baseContext: makeContext())

        // First tool executes, second fails with toolNotFound
        #expect(batch.results.count == 2)
        #expect(!batch.stoppedOnDeferral)

        guard case .success("known_tool result") = batch.results[0].result else {
            Issue.record("Expected success for known tool, got \(describe(batch.results[0].result))")
            return
        }

        guard case .failure(let error) = batch.results[1].result,
              let toolError = error as? ToolExecutionError,
              case .toolNotFound("unknown_tool") = toolError else {
            Issue.record("Expected toolNotFound for unknown tool, got \(describe(batch.results[1].result))")
            return
        }

        let count = await counter.count
        #expect(count == 1)
    }
}

// MARK: - withRequiresApproval Tests

@Suite("ToolExecutionEngine - withRequiresApproval")
struct ToolExecutionEngineWithRequiresApprovalTests {

    @Test("withRequiresApproval creates tool copy with approval flag set")
    func withRequiresApprovalSetsFlag() async throws {
        let counter = ToolCallCounter()
        let originalTool = makeTool(name: "original", requiresApproval: false, callCounter: counter)

        #expect(!originalTool.requiresApproval)

        let approvalTool = originalTool.withRequiresApproval(true)

        #expect(approvalTool.requiresApproval)
        #expect(approvalTool.name == originalTool.name)
        #expect(approvalTool.description == originalTool.description)

        // Verify the approval tool returns deferred
        let engine = ToolExecutionEngine(tools: [approvalTool], timeout: nil)
        let call = makeToolCall(name: "original")
        let result = try await engine.execute(call: call, context: makeContext())

        guard case .deferred(let deferral) = result else {
            Issue.record("Expected deferred, got \(describe(result))")
            return
        }
        #expect(deferral.kind == .approval)

        let count = await counter.count
        #expect(count == 0, "Tool should not have been executed")
    }
}
