/// Tests for cross-agent resume functionality.
///
/// Covers resuming from state with a different agent:
/// - Same tools, different model (should work)
/// - Superset of tools (should work)
/// - Missing tool referenced in pending calls (should fail)
/// - Historical tool references in messages (should work)

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Iterator - Cross-Agent Resume")
struct IteratorCrossAgentResumeTests {

    // MARK: - Test 13.1: Resume with different agent, same tools

    @Test("resuming with different agent but same tools succeeds")
    func resumeWithDifferentAgentSameTools() async throws {
        let toolCounter = CallCounter()
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "my_tool",
            onCall: { _ in
                await toolCounter.increment()
                return .success("tool_result")
            }
        )

        // First model - will request a tool call
        let model1Counter = CallCounter()
        let model1 = FakeModel(onComplete: { _ in
            switch await model1Counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Model1 done")
            }
        })

        // Second model - will complete after tool execution
        let model2Counter = CallCounter()
        let model2 = FakeModel(onComplete: { _ in
            await model2Counter.increment()
            return MockResponse.text("Model2 completed")
        })

        let agent1 = try Agent<String>(model: model1, tools: [tool])
        let agent2 = try Agent<String>(model: model2, tools: [tool])

        // Run agent1 until beforeTools, then break
        var savedState: IterationState<String>?
        for try await node in agent1.iter("Use tool") {
            if case .beforeTools(let ctx) = node {
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state")
            return
        }

        // Tool should NOT have been executed yet
        let callsBeforeResume = await toolCounter.current
        #expect(callsBeforeResume == 0)

        // Resume with agent2 (different model, same tool)
        var output: String?
        for try await node in agent2.iter(from: state) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        // Tool should have been executed
        let callsAfterResume = await toolCounter.current
        #expect(callsAfterResume == 1, "Tool should be executed during resume")

        // Output should come from model2
        #expect(output == "Model2 completed")

        // model2 should have been called (to process tool result)
        let model2Calls = await model2Counter.current
        #expect(model2Calls == 1)
    }

    // MARK: - Test 13.2: Resume with superset of tools

    @Test("resuming with agent that has additional tools succeeds")
    func resumeWithSupersetOfTools() async throws {
        let tool1 = ConfigurableTool.succeeding("result1", name: "tool_1")
        let tool2 = ConfigurableTool.succeeding("result2", name: "tool_2")

        // First agent has only tool_1
        let model1Counter = CallCounter()
        let model1 = FakeModel(onComplete: { _ in
            switch await model1Counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "tool_1",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Agent1 done")
            }
        })

        let model2 = FakeModel(responses: [MockResponse.text("Agent2 completed")])

        let agent1 = try Agent<String>(model: model1, tools: [tool1])
        // Agent2 has BOTH tools (superset)
        let agent2 = try Agent<String>(model: model2, tools: [tool1, tool2])

        // Run agent1 until beforeTools
        var savedState: IterationState<String>?
        for try await node in agent1.iter("Use tool") {
            if case .beforeTools(let ctx) = node {
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state")
            return
        }

        // Resume with agent2 (has more tools) - should work
        var output: String?
        for try await node in agent2.iter(from: state) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output == "Agent2 completed")
    }

    // MARK: - Test 13.3: Resume fails when pending tool is missing

    @Test("resuming fails when pending tool call references unavailable tool")
    func resumeFailsWhenPendingToolMissing() async throws {
        let tool1 = ConfigurableTool.succeeding("result1", name: "tool_1")
        let tool2 = ConfigurableTool.succeeding("result2", name: "tool_2")

        // First agent has tool_1
        let model1 = FakeModel(responses: [
            MockResponse.toolCall(
                name: "tool_1",
                arguments: #"{"input":"x"}"#,
                id: "tc-1"
            )
        ])

        // Second agent has tool_2 (different tool!)
        let model2 = FakeModel(responses: [MockResponse.text("Should not reach here")])

        let agent1 = try Agent<String>(model: model1, tools: [tool1])
        let agent2 = try Agent<String>(model: model2, tools: [tool2])

        // Run agent1 until beforeTools (pending call for tool_1)
        var savedState: IterationState<String>?
        for try await node in agent1.iter("Use tool") {
            if case .beforeTools(let ctx) = node {
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state")
            return
        }

        // Verify state has pending call for tool_1
        guard case .beforeTools(let calls) = state.phase else {
            Issue.record("Expected beforeTools phase")
            return
        }
        #expect(calls[0].call.name == "tool_1")

        // Resume with agent2 (missing tool_1) - should fail
        var caughtError: AgentError<String>?
        do {
            for try await _ in agent2.iter(from: state) { }
        } catch let error as AgentError<String> {
            caughtError = error
        }

        // Should throw invalidConfiguration
        guard case .invalidConfiguration(let message) = caughtError else {
            Issue.record("Expected invalidConfiguration error, got: \(String(describing: caughtError))")
            return
        }
        #expect(message.contains("tool_1"), "Error should mention missing tool name")
    }

    // MARK: - Test 13.4: Resume works with historical tool references

    @Test("resuming works when messages reference tools not in new agent")
    func resumeWorksWithHistoricalToolReferences() async throws {
        let tool1 = ConfigurableTool.succeeding("result1", name: "tool_1")

        // First agent uses tool_1
        let model1Counter = CallCounter()
        let model1 = FakeModel(onComplete: { _ in
            switch await model1Counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "tool_1",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Agent1 done")
            }
        })

        let agent1 = try Agent<String>(model: model1, tools: [tool1])

        // Run agent1 through tool execution to afterTools
        var savedState: IterationState<String>?
        for try await node in agent1.iter("Use tool") {
            if case .afterTools(let ctx) = node {
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state")
            return
        }

        // State's messages now contain tool_1 call and result
        // But there's no PENDING call for tool_1

        // Resume with agent that has NO tools - should work
        // because the tool reference is just history, not pending
        let model2 = FakeModel(responses: [MockResponse.text("Agent2 completed")])
        let agent2 = try Agent<String>(model: model2, tools: [])  // No tools!

        var output: String?
        for try await node in agent2.iter(from: state) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output == "Agent2 completed")
    }

    // MARK: - Test 13.5: Resume validates only pending/approved calls

    @Test("resume validation ignores denied tool calls")
    func resumeValidationIgnoresDeniedCalls() async throws {
        let tool1 = ConfigurableTool.succeeding("result1", name: "tool_1")

        // First agent requests tool_1
        let model1 = FakeModel(responses: [
            MockResponse.toolCall(
                name: "tool_1",
                arguments: #"{"input":"x"}"#,
                id: "tc-1"
            )
        ])

        let agent1 = try Agent<String>(model: model1, tools: [tool1])

        // Run agent1 until beforeTools and DENY the call
        var savedState: IterationState<String>?
        for try await node in agent1.iter("Use tool") {
            if case .beforeTools(let ctx) = node {
                ctx.deny(ctx.pendingCalls[0].call, message: "Denied")
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state")
            return
        }

        // Resume with agent that has NO tools - should work
        // because the pending call is DENIED (won't execute)
        let model2 = FakeModel(responses: [MockResponse.text("Continued after denial")])
        let agent2 = try Agent<String>(model: model2, tools: [])  // No tools!

        var output: String?
        for try await node in agent2.iter(from: state) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output == "Continued after denial")
    }

    // MARK: - Test 13.6: Resume validates only pending/approved calls (replaced)

    @Test("resume validation ignores replaced tool calls")
    func resumeValidationIgnoresReplacedCalls() async throws {
        let tool1 = ConfigurableTool.succeeding("result1", name: "tool_1")

        // First agent requests tool_1
        let model1 = FakeModel(responses: [
            MockResponse.toolCall(
                name: "tool_1",
                arguments: #"{"input":"x"}"#,
                id: "tc-1"
            )
        ])

        let agent1 = try Agent<String>(model: model1, tools: [tool1])

        // Run agent1 until beforeTools and REPLACE the call
        var savedState: IterationState<String>?
        for try await node in agent1.iter("Use tool") {
            if case .beforeTools(let ctx) = node {
                ctx.replace(ctx.pendingCalls[0].call, withResult: "Cached result")
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state")
            return
        }

        // Resume with agent that has NO tools - should work
        // because the pending call is REPLACED (won't execute)
        let model2 = FakeModel(responses: [MockResponse.text("Continued with cached")])
        let agent2 = try Agent<String>(model: model2, tools: [])  // No tools!

        var output: String?
        for try await node in agent2.iter(from: state) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output == "Continued with cached")
    }

    // MARK: - Test 13.7: Resume from non-tool phase always succeeds

    @Test("resuming from beforeModel succeeds regardless of tool mismatch")
    func resumeFromNonToolPhaseSucceeds() async throws {
        let tool1 = ConfigurableTool.succeeding("result1", name: "tool_1")

        let model1 = FakeModel(responses: [MockResponse.text("Agent1 response")])
        let agent1 = try Agent<String>(model: model1, tools: [tool1])

        // Capture state at beforeModel (no pending tool calls)
        var savedState: IterationState<String>?
        for try await node in agent1.iter("Hi") {
            if case .beforeModel(let ctx) = node {
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state")
            return
        }

        // Resume with agent that has completely different tools
        let tool2 = ConfigurableTool.succeeding("result2", name: "totally_different_tool")
        let model2 = FakeModel(responses: [MockResponse.text("Agent2 response")])
        let agent2 = try Agent<String>(model: model2, tools: [tool2])

        var output: String?
        for try await node in agent2.iter(from: state) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output == "Agent2 response")
    }

    // MARK: - Test 13.8: Resume with multiple pending calls validates all

    @Test("resume validates all pending tool calls, not just first")
    func resumeValidatesAllPendingCalls() async throws {
        let tool1 = ConfigurableTool.succeeding("r1", name: "tool_1")
        let tool2 = ConfigurableTool.succeeding("r2", name: "tool_2")

        // First agent requests two tools
        let model1 = FakeModel(responses: [
            MockResponse.multipleToolCalls([
                (name: "tool_1", arguments: #"{"input":"a"}"#, id: "tc-1"),
                (name: "tool_2", arguments: #"{"input":"b"}"#, id: "tc-2")
            ])
        ])

        let agent1 = try Agent<String>(model: model1, tools: [tool1, tool2])

        // Capture state at beforeTools
        var savedState: IterationState<String>?
        for try await node in agent1.iter("Use tools") {
            if case .beforeTools(let ctx) = node {
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state")
            return
        }

        // Resume with agent that has only tool_1 (missing tool_2)
        let model2 = FakeModel(responses: [MockResponse.text("Should not reach")])
        let agent2 = try Agent<String>(model: model2, tools: [tool1])

        var caughtError: AgentError<String>?
        do {
            for try await _ in agent2.iter(from: state) { }
        } catch let error as AgentError<String> {
            caughtError = error
        }

        // Should fail because tool_2 is missing
        guard case .invalidConfiguration(let message) = caughtError else {
            Issue.record("Expected invalidConfiguration error")
            return
        }
        #expect(message.contains("tool_2"), "Error should mention the missing tool")
    }
}
