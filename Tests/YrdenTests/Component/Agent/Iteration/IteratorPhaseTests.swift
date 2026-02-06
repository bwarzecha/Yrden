/// Tests for phase transitions involving tool calls.
///
/// Covers the complex state machine transitions when tools are involved:
/// - Tool call sequences
/// - Multiple iterations
/// - Output tool behavior
/// - maxIterations limits

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Iterator - Phase Transitions")
struct IteratorPhaseTests {

    // MARK: - Test 2.1: Tool Call Phase Sequence

    @Test("tool call yields full 5-phase sequence: beforeModel → afterModel → beforeTools → afterTools → beforeModel → afterModel → finished")
    func toolCallYieldsBeforeToolsPhase() async throws {
        let tool = ConfigurableTool.succeeding("tool result", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            tools: [AnyAgentTool(tool)]
        )

        var phases: [String] = []
        for try await node in agent.iter("Use tool", deps: ()) {
            switch node {
            case .beforeModel: phases.append("beforeModel")
            case .afterModel: phases.append("afterModel")
            case .beforeTools: phases.append("beforeTools")
            case .afterTools: phases.append("afterTools")
            case .finished: phases.append("finished")
            }
        }

        #expect(phases == [
            "beforeModel",   // First model call
            "afterModel",    // Model returned tool call
            "beforeTools",   // About to execute tool
            "afterTools",    // Tool executed
            "beforeModel",   // Second model call (with tool result)
            "afterModel",    // Model returned text
            "finished"       // Done
        ])
    }

    // MARK: - Test 2.2: afterTools follows beforeTools

    @Test("afterTools immediately follows beforeTools")
    func afterToolsFollowsBeforeTools() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(name: "my_tool", arguments: #"{"input":"x"}"#, id: "tc-1")
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var seenBeforeTools = false
        var phaseAfterBeforeTools: String?

        for try await node in agent.iter("Use tool", deps: ()) {
            if seenBeforeTools && phaseAfterBeforeTools == nil {
                switch node {
                case .beforeModel: phaseAfterBeforeTools = "beforeModel"
                case .afterModel: phaseAfterBeforeTools = "afterModel"
                case .beforeTools: phaseAfterBeforeTools = "beforeTools"
                case .afterTools: phaseAfterBeforeTools = "afterTools"
                case .finished: phaseAfterBeforeTools = "finished"
                }
            }
            if case .beforeTools = node {
                seenBeforeTools = true
            }
        }

        #expect(phaseAfterBeforeTools == "afterTools")
    }

    // MARK: - Test 2.3: Multiple tool calls in single beforeTools

    @Test("multiple tool calls from single model response appear in one beforeTools")
    func multipleToolCallsInSingleBeforeTools() async throws {
        let toolA = ConfigurableTool.succeeding("a-result", name: "tool_a")
        let toolB = ConfigurableTool.succeeding("b-result", name: "tool_b")
        let toolC = ConfigurableTool.succeeding("c-result", name: "tool_c")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCalls([
                    ToolCall(id: "tc-a", name: "tool_a", arguments: #"{"input":"a"}"#),
                    ToolCall(id: "tc-b", name: "tool_b", arguments: #"{"input":"b"}"#),
                    ToolCall(id: "tc-c", name: "tool_c", arguments: #"{"input":"c"}"#),
                ])
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            tools: [AnyAgentTool(toolA), AnyAgentTool(toolB), AnyAgentTool(toolC)]
        )

        var pendingCallCount: Int?
        for try await node in agent.iter("Use all tools", deps: ()) {
            if case .beforeTools(let ctx) = node {
                pendingCallCount = ctx.pendingCalls.count
            }
        }

        #expect(pendingCallCount == 3)
    }

    // MARK: - Test 2.4: Loop continues after tools if no output

    @Test("loop continues after tools if no output")
    func loopContinuesAfterToolsIfNoOutput() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(name: "my_tool", arguments: #"{"input":"x"}"#, id: "tc-1")
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var beforeModelCount = 0
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeModel = node {
                beforeModelCount += 1
            }
        }

        #expect(beforeModelCount == 2) // Initial + after tools
    }

    // MARK: - Test 2.5: Multiple iterations yield multiple beforeModel

    @Test("multiple iterations yield multiple beforeModel phases")
    func multipleIterationsYieldMultipleBeforeModel() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(name: "my_tool", arguments: #"{"input":"1"}"#, id: "tc-1")
            case 2:
                return MockResponse.toolCall(name: "my_tool", arguments: #"{"input":"2"}"#, id: "tc-2")
            case 3:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var beforeModelCount = 0
        for try await node in agent.iter("Use tool twice", deps: ()) {
            if case .beforeModel = node {
                beforeModelCount += 1
            }
        }

        #expect(beforeModelCount == 3) // Initial + 2 after-tool loops
    }

    // MARK: - Test 2.6: No tools skips tool phases

    @Test("no tool calls skips beforeTools and afterTools phases")
    func noToolsSkipsToolPhases() async throws {
        let model = FakeModel(responses: [MockResponse.text("Just text")])
        let agent = Agent<Void, String>(model: model)

        var phases: [String] = []
        for try await node in agent.iter("Hi", deps: ()) {
            switch node {
            case .beforeModel: phases.append("beforeModel")
            case .afterModel: phases.append("afterModel")
            case .beforeTools: phases.append("beforeTools")
            case .afterTools: phases.append("afterTools")
            case .finished: phases.append("finished")
            }
        }

        #expect(!phases.contains("beforeTools"))
        #expect(!phases.contains("afterTools"))
    }

    // MARK: - Test 2.7: Iteration counter increments

    @Test("iteration counter increments with each model call loop")
    func iterationCounterIncrements() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(name: "my_tool", arguments: #"{"input":"1"}"#, id: "tc-1")
            case 2:
                return MockResponse.toolCall(name: "my_tool", arguments: #"{"input":"2"}"#, id: "tc-2")
            case 3:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var iterations: [Int] = []
        for try await node in agent.iter("Multi-turn", deps: ()) {
            if case .beforeModel(let ctx) = node {
                iterations.append(ctx.state.iteration)
            }
        }

        #expect(iterations == [0, 1, 2]) // 0-indexed
    }

    // MARK: - Test 2.8: Tool call count accumulates

    @Test("tool call count accumulates across iterations")
    func toolCallCountAccumulates() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(name: "my_tool", arguments: #"{"input":"1"}"#, id: "tc-1")
            case 2:
                return MockResponse.toolCall(name: "my_tool", arguments: #"{"input":"2"}"#, id: "tc-2")
            case 3:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var finalToolCallCount: Int?
        for try await node in agent.iter("Multi-tool", deps: ()) {
            if case .finished(let ctx) = node {
                finalToolCallCount = ctx.state.toolCallCount
            }
        }

        #expect(finalToolCallCount == 2)
    }

    // MARK: - Test 2.9: Output tool yields finished directly
    // NOTE: This test requires @Schema macro support for structured output.
    // For now, we skip it as String output doesn't use output tool.

    // MARK: - Test 2.10: Invalid output tool continues loop
    // NOTE: Requires structured output support

    // MARK: - Test 2.11: Output tool with regular tools (early strategy)
    // NOTE: Requires structured output support

    // MARK: - Test 2.12: Output tool with regular tools (exhaustive strategy)
    // NOTE: Requires structured output support

    // MARK: - Test 2.13: maxIterations throws after limit

    @Test("exceeding maxIterations throws error")
    func maxIterationsThrowsAfterLimit() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        // Model always returns tool call (infinite loop without limit)
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let callID = await counter.increment()
            return MockResponse.toolCall(
                name: "my_tool",
                arguments: #"{"input":"x"}"#,
                id: "tc-\(callID)"
            )
        })

        let agent = Agent<Void, String>(
            model: model,
            tools: [AnyAgentTool(tool)],
            maxIterations: 3
        )

        do {
            for try await _ in agent.iter("Loop forever", deps: ()) { }
            Issue.record("Expected maxIterationsReached error")
        } catch let error as AgentError<String> {
            guard case .maxIterationsReached(let state) = error else {
                Issue.record("Expected .maxIterationsReached, got \(error)")
                return
            }
            // Verify state contains progress
            #expect(state.iteration >= 1)
        }
    }

    // MARK: - Test 2.14: Empty model response for String output succeeds

    @Test("empty string content is valid for String output type")
    func emptyModelResponseForStringOutputSucceeds() async throws {
        let model = FakeModel(responses: [
            CompletionResponse(
                content: "",
                refusal: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 10, outputTokens: 0)
            )
        ])

        let agent = Agent<Void, String>(model: model)

        var output: String?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output == "") // Empty string is valid
    }

    // MARK: - Test 2.15: Empty model response for structured output continues
    // NOTE: Requires structured output support

    // MARK: - Test 2.16: beforeTools has pending calls with correct data

    @Test("beforeTools phase contains pending calls with correct tool call data")
    func beforeToolsHasPendingCallsWithCorrectData() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"test_value"}"#,
                    id: "tc-abc-123"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var pendingCall: PendingToolDecision?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeTools(let ctx) = node {
                pendingCall = ctx.pendingCalls.first
            }
        }

        #expect(pendingCall?.call.id == "tc-abc-123")
        #expect(pendingCall?.call.name == "my_tool")
        #expect(pendingCall?.call.arguments.contains("test_value") == true)
    }

    // MARK: - Test 2.17: afterTools has results with correct data

    @Test("afterTools phase contains results with correct tool execution data")
    func afterToolsHasResultsWithCorrectData() async throws {
        let tool = ConfigurableTool.succeeding("tool_result_value", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var toolResult: ToolCallResult?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .afterTools(let ctx) = node {
                toolResult = ctx.results.first
            }
        }

        #expect(toolResult?.call.id == "tc-1")
        #expect(toolResult?.call.name == "my_tool")
        if case .success(let value) = toolResult?.result {
            #expect(value == "tool_result_value")
        } else {
            Issue.record("Expected success result")
        }
    }
}
