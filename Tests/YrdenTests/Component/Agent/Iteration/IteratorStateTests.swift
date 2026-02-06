/// Tests for IterationState properties and helpers.
///
/// Covers:
/// - Copy methods (with(phase:))
/// - Usage tracking
/// - Phase enum
/// - Codable conformance (when implemented)

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Iterator - State")
struct IteratorStateTests {

    // MARK: - Test 7.1: with(phase:) creates new state

    @Test("state.with(phase:) returns new state with different phase")
    func withPhaseCreatesNewState() async throws {
        let state = IterationState<String>(
            runID: "run-1",
            messages: [.user("hi")],
            usage: Usage(inputTokens: 10, outputTokens: 5),
            iteration: 0,
            toolCallCount: 0,
            phase: .beforeModel
        )

        let response = CompletionResponse(
            content: "Hello",
            refusal: nil,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 10)
        )
        let newState = state.with(phase: .afterModel(response: response))

        // Check properties preserved
        #expect(newState.runID == state.runID)
        #expect(newState.messages == state.messages)

        // Check phases are different
        guard case .afterModel = newState.phase else {
            Issue.record("Expected afterModel phase")
            return
        }
        guard case .beforeModel = state.phase else {
            Issue.record("Original should still be beforeModel")
            return
        }
    }

    // MARK: - Test 7.2: with(phase:) preserves other properties

    @Test("with(phase:) preserves all other properties")
    func withPhasePreservesOtherProperties() async throws {
        let state = IterationState<String>(
            runID: "run-abc-123",
            messages: [.user("first"), .assistant("second")],
            usage: Usage(inputTokens: 100, outputTokens: 50),
            iteration: 3,
            toolCallCount: 7,
            phase: .beforeModel
        )

        let response = CompletionResponse(
            content: "test",
            refusal: nil,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 10)
        )
        let newState = state.with(phase: .afterModel(response: response))

        #expect(newState.runID == "run-abc-123")
        #expect(newState.messages.count == 2)
        #expect(newState.usage.inputTokens == 100)
        #expect(newState.usage.outputTokens == 50)
        #expect(newState.iteration == 3)
        #expect(newState.toolCallCount == 7)
    }

    // MARK: - Test 7.3: Usage available at every phase

    @Test("usage is accessible in all phases via state")
    func usageAvailableAtEveryPhase() async throws {
        let model = FakeModel(responses: [MockResponse.text("Hello")])
        let agent = Agent<Void, String>(model: model)

        var usageValues: [String: Usage] = [:]

        for try await node in agent.iter("Hi", deps: ()) {
            switch node {
            case .beforeModel(let ctx):
                usageValues["beforeModel"] = ctx.state.usage
            case .afterModel(let ctx):
                usageValues["afterModel"] = ctx.state.usage
            case .beforeTools(let ctx):
                usageValues["beforeTools"] = ctx.state.usage
            case .afterTools(let ctx):
                usageValues["afterTools"] = ctx.state.usage
            case .finished(let ctx):
                usageValues["finished"] = ctx.state.usage
            }
        }

        // Should have usage at beforeModel, afterModel, and finished
        #expect(usageValues["beforeModel"] != nil)
        #expect(usageValues["afterModel"] != nil)
        #expect(usageValues["finished"] != nil)
    }

    // MARK: - Test 7.4: Usage updated after model call

    @Test("usage is updated after model call with new tokens")
    func usageUpdatedAfterModelCall() async throws {
        let model = FakeModel(responses: [
            MockResponse.text("Hello", usage: Usage(inputTokens: 42, outputTokens: 17))
        ])
        let agent = Agent<Void, String>(model: model)

        var usageAfterModel: Usage?

        for try await node in agent.iter("Hi", deps: ()) {
            if case .afterModel(let ctx) = node {
                usageAfterModel = ctx.state.usage
            }
        }

        #expect(usageAfterModel?.inputTokens == 42)
        #expect(usageAfterModel?.outputTokens == 17)
    }

    // MARK: - Test 7.5: Usage accumulates across iterations

    @Test("usage accumulates across multiple model calls")
    func usageAccumulatesAcrossIterations() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return CompletionResponse(
                    content: nil,
                    refusal: nil,
                    toolCalls: [ToolCall(id: "tc-1", name: "my_tool", arguments: #"{"input":"x"}"#)],
                    stopReason: .toolUse,
                    usage: Usage(inputTokens: 100, outputTokens: 50)
                )
            case 2:
                return CompletionResponse(
                    content: "Done",
                    refusal: nil,
                    toolCalls: [],
                    stopReason: .endTurn,
                    usage: Usage(inputTokens: 150, outputTokens: 75)
                )
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var finalUsage: Usage?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .finished(let ctx) = node {
                finalUsage = ctx.usage
            }
        }

        // Should be sum of both calls
        #expect(finalUsage?.inputTokens == 250)  // 100 + 150
        #expect(finalUsage?.outputTokens == 125) // 50 + 75
    }

    // MARK: - Test 7.6: beforeModel phase has no associated value

    @Test("beforeModel phase is simple case without associated data")
    func beforeModelPhaseHasNoAssociatedValue() async throws {
        let state = IterationState<String>(
            runID: "run-1",
            messages: [],
            usage: Usage(inputTokens: 0, outputTokens: 0),
            iteration: 0,
            toolCallCount: 0,
            phase: .beforeModel
        )

        guard case .beforeModel = state.phase else {
            Issue.record("Expected beforeModel phase")
            return
        }
        // Success - beforeModel is a simple case
    }

    // MARK: - Test 7.7: afterModel phase contains response

    @Test("afterModel phase contains full completion response")
    func afterModelPhaseContainsResponse() async throws {
        let response = CompletionResponse(
            content: "Test content",
            refusal: nil,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 20)
        )

        let state = IterationState<String>(
            runID: "run-1",
            messages: [],
            usage: Usage(inputTokens: 0, outputTokens: 0),
            iteration: 0,
            toolCallCount: 0,
            phase: .afterModel(response: response)
        )

        guard case .afterModel(let r) = state.phase else {
            Issue.record("Expected afterModel phase")
            return
        }
        #expect(r.content == "Test content")
    }

    // MARK: - Test 7.8: beforeTools phase contains pending decisions

    @Test("beforeTools phase contains pending tool decisions array")
    func beforeToolsPhaseContainsPendingDecisions() async throws {
        let decisions = [
            PendingToolDecision(
                call: ToolCall(id: "tc-1", name: "tool_a", arguments: "{}"),
                requiresApproval: false,
                decision: .pending
            ),
            PendingToolDecision(
                call: ToolCall(id: "tc-2", name: "tool_b", arguments: "{}"),
                requiresApproval: true,
                decision: .approved
            )
        ]

        let state = IterationState<String>(
            runID: "run-1",
            messages: [],
            usage: Usage(inputTokens: 0, outputTokens: 0),
            iteration: 0,
            toolCallCount: 0,
            phase: .beforeTools(calls: decisions)
        )

        guard case .beforeTools(let calls) = state.phase else {
            Issue.record("Expected beforeTools phase")
            return
        }
        #expect(calls.count == 2)
        #expect(calls[0].call.name == "tool_a")
        #expect(calls[1].requiresApproval == true)
    }

    // MARK: - Test 7.9: afterTools phase contains results

    @Test("afterTools phase contains tool execution results array")
    func afterToolsPhaseContainsResults() async throws {
        let results = [
            ToolCallResult(
                call: ToolCall(id: "tc-1", name: "tool_a", arguments: "{}"),
                result: .success("result_a"),
                duration: .milliseconds(100)
            ),
            ToolCallResult(
                call: ToolCall(id: "tc-2", name: "tool_b", arguments: "{}"),
                result: .failure(TestToolError.generic("failed")),
                duration: .milliseconds(50)
            )
        ]

        let state = IterationState<String>(
            runID: "run-1",
            messages: [],
            usage: Usage(inputTokens: 0, outputTokens: 0),
            iteration: 0,
            toolCallCount: 0,
            phase: .afterTools(results: results)
        )

        guard case .afterTools(let r) = state.phase else {
            Issue.record("Expected afterTools phase")
            return
        }
        #expect(r.count == 2)
        #expect(r[0].call.name == "tool_a")
        if case .success(let value) = r[0].result {
            #expect(value == "result_a")
        } else {
            Issue.record("Expected success result")
        }
    }

    // MARK: - Test 7.10: State is Sendable

    @Test("IterationState is Sendable for concurrent use")
    func stateIsSendable() async throws {
        let state = IterationState<String>(
            runID: "run-1",
            messages: [.user("hi")],
            usage: Usage(inputTokens: 10, outputTokens: 5),
            iteration: 0,
            toolCallCount: 0,
            phase: .beforeModel
        )

        // Create a task that uses the state
        let task = Task {
            return state.runID
        }

        let result = await task.value
        #expect(result == "run-1")
    }

    // MARK: - Test 7.11: PendingToolDecision.Decision equality

    @Test("PendingToolDecision.Decision supports equality comparison")
    func pendingToolDecisionEquality() async throws {
        #expect(PendingToolDecision.Decision.pending == .pending)
        #expect(PendingToolDecision.Decision.approved == .approved)
        #expect(PendingToolDecision.Decision.denied("reason") == .denied("reason"))
        #expect(PendingToolDecision.Decision.denied("a") != .denied("b"))
        #expect(PendingToolDecision.Decision.replaced("value") == .replaced("value"))
        #expect(PendingToolDecision.Decision.pending != .approved)
    }

    // MARK: - Test 7.12: Messages array is mutable

    @Test("state.messages array supports mutations")
    func messagesArrayIsMutable() async throws {
        var state = IterationState<String>(
            runID: "run-1",
            messages: [.user("first")],
            usage: Usage(inputTokens: 0, outputTokens: 0),
            iteration: 0,
            toolCallCount: 0,
            phase: .beforeModel
        )

        state.messages.append(.assistant("second"))
        state.messages.append(.user("third"))

        #expect(state.messages.count == 3)
    }
}
