/// Tests for cross-session resume via iter(from: state, deps:).
///
/// Covers resumption functionality:
/// - Resume from each phase (beforeModel, afterModel, beforeTools, afterTools)
/// - State preservation (messages, usage, iteration, runID)
/// - Decision preservation across serialization
/// - Decision modification on resume

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Iterator - Resume")
struct IteratorResumeTests {

    // MARK: - Test 12.1: Resume from beforeModel continues

    @Test("resuming from beforeModel phase continues and completes execution")
    func resumeFromBeforeModelContinues() async throws {
        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            await modelCounter.increment()
            return MockResponse.text("Completed")
        })
        let agent = try Agent<Void, String>(model: model)

        // First run - capture state at beforeModel and break (model not yet called)
        var savedState: IterationState<String>?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .beforeModel(let ctx) = node {
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture beforeModel state")
            return
        }

        // Model should NOT have been called yet
        let callsBeforeResume = await modelCounter.current
        #expect(callsBeforeResume == 0, "Model should not be called when breaking at beforeModel")

        // Resume from saved state
        var output: String?
        for try await node in agent.iter(from: state, deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        // Model should now have been called
        let callsAfterResume = await modelCounter.current
        #expect(callsAfterResume == 1, "Model should be called exactly once after resume")
        #expect(output == "Completed")
    }

    // MARK: - Test 12.2: Resume from afterModel continues

    @Test("resuming from afterModel phase continues without re-calling model")
    func resumeFromAfterModelContinues() async throws {
        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            await modelCounter.increment()
            return MockResponse.text("Hello")
        })
        let agent = try Agent<Void, String>(model: model)

        // First run - capture state at afterModel and break
        var savedState: IterationState<String>?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .afterModel(let ctx) = node {
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture afterModel state")
            return
        }

        let callsBeforeResume = await modelCounter.current
        #expect(callsBeforeResume == 1, "Model should be called once to reach afterModel")

        // Resume from saved state - should proceed to finished WITHOUT calling model again
        var output: String?
        for try await node in agent.iter(from: state, deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        let callsAfterResume = await modelCounter.current
        #expect(callsAfterResume == 1, "Model should NOT be called again when resuming from afterModel")
        #expect(output == "Hello")
    }

    // MARK: - Test 12.3: Resume from beforeTools executes tools

    @Test("resuming from beforeTools phase executes tools")
    func resumeFromBeforeToolsExecutesTool() async throws {
        let toolCounter = CallCounter()
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "my_tool",
            onCall: { _ in
                await toolCounter.increment()
                return .success("tool_executed")
            }
        )

        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await modelCounter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Done")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        // First run - capture state at beforeTools (tool NOT executed yet)
        var savedState: IterationState<String>?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeTools(let ctx) = node {
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture beforeTools state")
            return
        }

        // Tool should NOT have been called yet
        let toolCallsBeforeResume = await toolCounter.current
        #expect(toolCallsBeforeResume == 0, "Tool should not be called at beforeTools")

        // Resume from saved state - should execute tools
        var output: String?
        var sawAfterTools = false
        for try await node in agent.iter(from: state, deps: ()) {
            if case .afterTools(let ctx) = node {
                sawAfterTools = true
                // Verify tool result is present
                #expect(ctx.results.count == 1)
                if case .success(let result) = ctx.results[0].result {
                    #expect(result == "tool_executed")
                }
            }
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        // Tool should now have been called
        let toolCallsAfterResume = await toolCounter.current
        #expect(toolCallsAfterResume == 1, "Tool should be called exactly once after resume")
        #expect(sawAfterTools, "Should have seen afterTools phase")
        #expect(output == "Done")
    }

    // MARK: - Test 12.4: Resume from afterTools doesn't re-execute tools

    @Test("resuming from afterTools phase does NOT re-execute tools")
    func resumeFromAfterToolsDoesNotReexecute() async throws {
        let toolCounter = CallCounter()
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "my_tool",
            onCall: { _ in
                await toolCounter.increment()
                return .success("tool_result")
            }
        )

        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await modelCounter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Final response")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        // First run - capture state at afterTools
        var savedState: IterationState<String>?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .afterTools(let ctx) = node {
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture afterTools state")
            return
        }

        let toolCallsBeforeResume = await toolCounter.current
        #expect(toolCallsBeforeResume == 1, "Tool should be called once to reach afterTools")

        // Resume - should NOT call tool again
        var output: String?
        for try await node in agent.iter(from: state, deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        let toolCallsAfterResume = await toolCounter.current
        #expect(toolCallsAfterResume == 1, "Tool should NOT be called again when resuming from afterTools")
        #expect(output == "Final response")
    }

    // MARK: - Test 12.5: Resume preserves messages

    @Test("resuming preserves all messages including tool results")
    func resumePreservesMessages() async throws {
        let tool = ConfigurableTool.succeeding("tool_result_abc", name: "my_tool")

        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await modelCounter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"test"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Done")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        // Run through tool execution and capture state
        var savedState: IterationState<String>?
        for try await node in agent.iter("Original prompt", deps: ()) {
            if case .afterTools(let ctx) = node {
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state")
            return
        }

        // Verify messages contain:
        // 1. System prompt (if any)
        // 2. User message with "Original prompt"
        // 3. Assistant message with tool call
        // 4. Tool result message
        #expect(state.messages.count >= 3, "Should have user, assistant, and tool messages")

        // Check user message exists
        let hasUserMessage = state.messages.contains { msg in
            if case .user(let parts) = msg {
                return parts.contains { part in
                    if case .text(let text) = part {
                        return text.contains("Original prompt")
                    }
                    return false
                }
            }
            return false
        }
        #expect(hasUserMessage, "Should have user message with original prompt")

        // Resume and verify messages still correct
        for try await node in agent.iter(from: state, deps: ()) {
            if case .beforeModel(let ctx) = node {
                // All original messages should be present
                #expect(ctx.state.messages.count >= state.messages.count)
                break
            }
        }
    }

    // MARK: - Test 12.6: Resume preserves usage accurately

    @Test("resuming preserves exact token usage")
    func resumePreservesUsage() async throws {
        let model = FakeModel(responses: [
            MockResponse.text("Hello", usage: Usage(inputTokens: 123, outputTokens: 456))
        ])
        let agent = try Agent<Void, String>(model: model)

        // Capture state after model call
        var savedState: IterationState<String>?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .afterModel(let ctx) = node {
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state")
            return
        }

        // Verify exact usage values
        #expect(state.usage.inputTokens == 123, "Input tokens should be exactly 123")
        #expect(state.usage.outputTokens == 456, "Output tokens should be exactly 456")
        #expect(state.usage.totalTokens == 579, "Total tokens should be exactly 579")

        // Serialize and deserialize
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(IterationState<String>.self, from: data)

        // Verify usage survives serialization
        #expect(restored.usage.inputTokens == 123)
        #expect(restored.usage.outputTokens == 456)
        #expect(restored.usage.totalTokens == 579)
    }

    // MARK: - Test 12.7: Resume preserves iteration counter

    @Test("resuming preserves and continues iteration counter correctly")
    func resumePreservesIteration() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await modelCounter.increment() {
            case 1, 2:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-\(await modelCounter.current)"
                )
            default:
                return MockResponse.text("Done")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        // Run through one full iteration, then capture at second iteration
        var savedState: IterationState<String>?
        var iterationsBeforeSave: [Int] = []

        for try await node in agent.iter("Multi-turn", deps: ()) {
            if case .beforeModel(let ctx) = node {
                iterationsBeforeSave.append(ctx.state.iteration)
                if ctx.state.iteration == 1 {
                    savedState = ctx.state
                    break
                }
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state at iteration 1")
            return
        }

        #expect(state.iteration == 1, "Saved state should be at iteration 1")
        #expect(iterationsBeforeSave == [0, 1], "Should have seen iterations 0 and 1")

        // Resume and verify iteration continues
        var iterationsAfterResume: [Int] = []
        for try await node in agent.iter(from: state, deps: ()) {
            if case .beforeModel(let ctx) = node {
                iterationsAfterResume.append(ctx.state.iteration)
            }
            if case .finished = node {
                break
            }
        }

        // Should continue from iteration 1 (not restart at 0)
        #expect(iterationsAfterResume.first == 1, "Should resume at iteration 1, not 0")
    }

    // MARK: - Test 12.8: Resume preserves runID

    @Test("resuming preserves the exact same runID")
    func resumePreservesRunID() async throws {
        let model = FakeModel(responses: [MockResponse.text("Hello")])
        let agent = try Agent<Void, String>(model: model)

        // Capture original runID
        var originalRunID: String?
        var savedState: IterationState<String>?

        for try await node in agent.iter("Hi", deps: ()) {
            if case .beforeModel(let ctx) = node {
                originalRunID = ctx.state.runID
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState, let runID = originalRunID else {
            Issue.record("Failed to capture state")
            return
        }

        #expect(!runID.isEmpty, "RunID should not be empty")

        // Serialize and deserialize
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(IterationState<String>.self, from: data)

        #expect(restored.runID == runID, "RunID should survive serialization")

        // Resume and verify runID in all phases
        var runIDsInResume: Set<String> = []
        for try await node in agent.iter(from: restored, deps: ()) {
            switch node {
            case .beforeModel(let ctx): runIDsInResume.insert(ctx.state.runID)
            case .afterModel(let ctx): runIDsInResume.insert(ctx.state.runID)
            case .finished(let ctx): runIDsInResume.insert(ctx.state.runID)
            default: break
            }
        }

        #expect(runIDsInResume.count == 1, "All phases should have same runID")
        #expect(runIDsInResume.first == runID, "RunID should match original")
    }

    // MARK: - Test 12.9: Resume preserves approved decision

    @Test("resuming preserves approved tool decisions and executes tool")
    func resumePreservesApprovedDecision() async throws {
        let toolCounter = CallCounter()
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "my_tool",
            onCall: { _ in
                await toolCounter.increment()
                return .success("executed")
            }
        )

        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await modelCounter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Done")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        // Approve tool and capture state
        var savedState: IterationState<String>?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeTools(let ctx) = node {
                ctx.approve(ctx.pendingCalls[0].call)
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state")
            return
        }

        // Verify decision is approved
        guard case .beforeTools(let calls) = state.phase else {
            Issue.record("Expected beforeTools phase")
            return
        }
        #expect(calls[0].decision == .approved)

        // Serialize, deserialize, resume
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(IterationState<String>.self, from: data)

        var output: String?
        for try await node in agent.iter(from: restored, deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        // Tool should have been executed (decision was approved)
        let toolCalls = await toolCounter.current
        #expect(toolCalls == 1, "Tool should be executed when decision is approved")
        #expect(output == "Done")
    }

    // MARK: - Test 12.10: Resume preserves denied decision

    @Test("resuming preserves denied tool decisions and skips execution")
    func resumePreservesDeniedDecision() async throws {
        let toolCounter = CallCounter()
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "my_tool",
            onCall: { _ in
                await toolCounter.increment()
                return .success("should not see this")
            }
        )

        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await modelCounter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Continued after denial")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        // Deny tool and capture state
        var savedState: IterationState<String>?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeTools(let ctx) = node {
                ctx.deny(ctx.pendingCalls[0].call, message: "Forbidden action")
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state")
            return
        }

        // Verify decision
        guard case .beforeTools(let calls) = state.phase else {
            Issue.record("Expected beforeTools phase")
            return
        }
        #expect(calls[0].decision == .denied("Forbidden action"))

        // Serialize, deserialize, resume
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(IterationState<String>.self, from: data)

        var output: String?
        for try await node in agent.iter(from: restored, deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        // Tool should NOT have been executed
        let toolCalls = await toolCounter.current
        #expect(toolCalls == 0, "Tool should NOT be executed when decision is denied")
        #expect(output == "Continued after denial")
    }

    // MARK: - Test 12.11: Resume preserves replaced decision

    @Test("resuming preserves replaced tool decisions and uses synthetic result")
    func resumePreservesReplacedDecision() async throws {
        let toolCounter = CallCounter()
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "my_tool",
            onCall: { _ in
                await toolCounter.increment()
                return .success("real result")
            }
        )

        actor ResultCapture {
            var capturedResult: String?
            func capture(_ result: String) { capturedResult = result }
        }
        let resultCapture = ResultCapture()

        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { request in
            let count = await modelCounter.increment()
            if count == 1 {
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            }
            // Check if tool result message contains our synthetic result
            for msg in request.messages {
                if case .toolResults(let entries) = msg {
                    for entry in entries {
                        if case .text(let content) = entry.output {
                            await resultCapture.capture(content)
                        }
                    }
                }
            }
            return MockResponse.text("Done")
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        // Replace tool with synthetic result and capture state
        var savedState: IterationState<String>?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeTools(let ctx) = node {
                ctx.replace(ctx.pendingCalls[0].call, withResult: "SYNTHETIC_CACHED_RESULT")
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state")
            return
        }

        // Serialize, deserialize, resume
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(IterationState<String>.self, from: data)

        for try await node in agent.iter(from: restored, deps: ()) {
            if case .finished = node { break }
        }

        // Tool should NOT have been executed
        let toolCalls = await toolCounter.current
        #expect(toolCalls == 0, "Tool should NOT be executed when decision is replaced")

        // Model should have received synthetic result
        let captured = await resultCapture.capturedResult
        #expect(captured == "SYNTHETIC_CACHED_RESULT", "Model should receive synthetic result")
    }

    // MARK: - Test 12.12: Resume allows decision change

    @Test("resuming allows changing tool decision from denied to approved")
    func resumeAllowsDecisionChange() async throws {
        let toolCounter = CallCounter()
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "my_tool",
            onCall: { _ in
                await toolCounter.increment()
                return .success("tool_was_executed")
            }
        )

        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await modelCounter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Done")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        // First: deny tool and capture state
        var savedState: IterationState<String>?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeTools(let ctx) = node {
                ctx.deny(ctx.pendingCalls[0].call, message: "Initially denied")
                savedState = ctx.state
                break
            }
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state")
            return
        }

        // Tool should not have been called
        let callsAfterDeny = await toolCounter.current
        #expect(callsAfterDeny == 0)

        // Resume and CHANGE decision to approved
        var output: String?
        for try await node in agent.iter(from: state, deps: ()) {
            if case .beforeTools(let ctx) = node {
                // Override the denial with approval
                ctx.approve(ctx.pendingCalls[0].call)
            }
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        // Now tool SHOULD have been called
        let callsAfterApprove = await toolCounter.current
        #expect(callsAfterApprove == 1, "Tool should be executed after changing decision to approved")
        #expect(output == "Done")
    }
}
