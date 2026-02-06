/// Tests for Agent tool execution timeout behavior.
///
/// Covers: timeout exceeded (error contained), completion within timeout,
/// no timeout configured, and per-call timeout isolation.
///
/// Key invariant: timeouts are contained like all other tool errors. They
/// become error tool results sent to the model — not thrown exceptions.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Agent - Tool Timeout")
struct AgentToolTimeoutTests {

    @Test("tool exceeding timeout sends error to model")
    func toolExceedingTimeoutSendsErrorToModel() async throws {
        let slow = SlowTool(delay: .seconds(5))

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "slow_tool",
                    arguments: #"{"input":"go"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultError(for: "tc-1"))
                return MockResponse.text("Recovered from timeout")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(slow)],
            toolTimeout: .milliseconds(50)
        )

        let result = try await agent.run("Do it", deps: ())
        #expect(result.output == "Recovered from timeout")
        #expect(result.requestCount == 2)
    }

    @Test("tool completing within timeout succeeds")
    func toolCompletingWithinTimeoutSucceeds() async throws {
        let slow = SlowTool(delay: .milliseconds(10))

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "slow_tool",
                    arguments: #"{"input":"data"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultSuccess(for: "tc-1"))
                return MockResponse.text("Got the result")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(slow)],
            toolTimeout: .seconds(5)
        )

        let result = try await agent.run("Do it", deps: ())
        #expect(result.output == "Got the result")
    }

    @Test("no timeout configured allows slow tool to complete")
    func noTimeoutConfiguredAllowsSlowToolToComplete() async throws {
        let slow = SlowTool(delay: .milliseconds(100))

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "slow_tool",
                    arguments: #"{"input":"data"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultSuccess(for: "tc-1"))
                return MockResponse.text("Completed")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(slow)]
            // No toolTimeout — defaults to nil
        )

        let result = try await agent.run("Do it", deps: ())
        #expect(result.output == "Completed")
    }

    @Test("timeout applies per tool call not total")
    func timeoutAppliesPerToolCallNotTotal() async throws {
        // Each call takes ~100ms. Timeout is 200ms per call.
        // Two sequential calls take ~200ms total, but each is within
        // the per-call timeout window.
        let slow = SlowTool(delay: .milliseconds(100))

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCalls([
                    ToolCall(id: "tc-1", name: "slow_tool", arguments: #"{"input":"first"}"#),
                    ToolCall(id: "tc-2", name: "slow_tool", arguments: #"{"input":"second"}"#),
                ])
            case 2:
                #expect(try request.isToolResultSuccess(for: "tc-1"))
                #expect(try request.isToolResultSuccess(for: "tc-2"))
                return MockResponse.text("Both completed")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(slow)],
            toolTimeout: .milliseconds(200)
        )

        let result = try await agent.run("Do it", deps: ())
        #expect(result.output == "Both completed")
        #expect(result.toolCallCount == 2)
    }
}
