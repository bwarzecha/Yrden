/// Tests for Agent tool failure and error propagation behavior.
///
/// Covers: tool throws, tool returns .failure, AgentError containment,
/// max iterations with tool loops, mixed results in batch, malformed
/// arguments, and failure recovery.
///
/// Key invariant: tool errors are ALWAYS contained. They become tool result
/// errors sent to the model — they never propagate as thrown exceptions.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Agent - Tool Failures")
struct AgentToolFailureTests {

    @Test("tool that throws sends error as tool result to model")
    func toolThrowsErrorSendsErrorToModel() async throws {
        let tool = ConfigurableTool.throwing(
            TestToolError.crashed("boom"),
            name: "crashy"
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "crashy",
                    arguments: #"{"input":"go"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultError(for: "tc-1"))
                return MockResponse.text("Recovered")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool]
        )

        let result = try await agent.run("Do it")
        #expect(result.output == "Recovered")
        #expect(result.requestCount == 2)
    }

    @Test("tool returning .failure sends error as tool result to model")
    func toolReturnsFailureSendsErrorToModel() async throws {
        let tool = ConfigurableTool.failing(
            TestToolError.processingFailed("bad data"),
            name: "failer"
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "failer",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultError(for: "tc-1"))
                return MockResponse.text("Handled")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool]
        )

        let result = try await agent.run("Process")
        #expect(result.output == "Handled")
        #expect(result.requestCount == 2)
    }

    @Test("tool throwing AgentError is contained — sent to model, not propagated")
    func toolThrowingAgentErrorContainedAsToolResult() async throws {
        // Even if a tool throws an AgentError, the engine contains it.
        // The error is sent to the model as a tool result, not propagated.
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "bad_tool",
            onCall: { _ in throw AgentError<String>.internalError("Test error") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "bad_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultError(for: "tc-1"))
                return MockResponse.text("Recovered from tool error")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool]
        )

        // Agent does NOT throw — error is contained and sent to model
        let result = try await agent.run("Go")
        #expect(result.output == "Recovered from tool error")
        #expect(result.requestCount == 2)
    }

    @Test("max iterations reached when model keeps requesting tool calls")
    func maxIterationsReachedWithRecurringToolCalls() async throws {
        let tool = ConfigurableTool.succeeding("ok", name: "looper")

        let callNum = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let n = await callNum.increment()
            return MockResponse.toolCall(
                name: "looper",
                arguments: #"{"input":"again"}"#,
                id: "tc-\(n)"
            )
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool],
            maxIterations: 3
        )

        do {
            _ = try await agent.run("Loop forever").result()
            Issue.record("Expected AgentError.iterationLimitReached")
        } catch let error as AgentError<String> {
            guard case .iterationLimitReached(let run) = error else {
                Issue.record("Expected .iterationLimitReached, got \(error)")
                return
            }
            #expect(run.requestCount == 3)
            #expect(run.toolCallCount == 3)
            #expect(!run.messages.isEmpty)
        }
    }

    @Test("mixed success and failure results in batch all sent to model")
    func mixedResultsInBatchAllSentToModel() async throws {
        let alpha = ConfigurableTool.succeeding("ok", name: "alpha")
        let beta = ConfigurableTool.throwing(
            TestToolError.crashed("exploded"),
            name: "beta"
        )
        let gamma = ConfigurableTool.succeeding("fine", name: "gamma")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCalls([
                    ToolCall(id: "tc-a", name: "alpha", arguments: #"{"input":"a"}"#),
                    ToolCall(id: "tc-b", name: "beta", arguments: #"{"input":"b"}"#),
                    ToolCall(id: "tc-c", name: "gamma", arguments: #"{"input":"c"}"#),
                ])
            case 2:
                #expect(request.toolResultCount == 3)
                #expect(try request.isToolResultSuccess(for: "tc-a"))
                #expect(request.toolResultContent(for: "tc-a") == "ok")
                #expect(try request.isToolResultError(for: "tc-b"))
                #expect(try request.isToolResultSuccess(for: "tc-c"))
                #expect(request.toolResultContent(for: "tc-c") == "fine")
                return MockResponse.text("All processed")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [alpha, beta, gamma]
        )

        let result = try await agent.run("Use all tools")
        #expect(result.output == "All processed")
        #expect(result.toolCallCount == 3)
    }

    @Test("malformed tool call arguments: tool never executed, error sent to model")
    func malformedToolCallToolNeverExecuted() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "target",
            onCall: { _ in .success("should not reach") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "target",
                    arguments: "{{not valid json",
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultError(for: "tc-1"))
                return MockResponse.text("Recovered")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool]
        )

        let result = try await agent.run("Go")
        #expect(result.output == "Recovered")

        let calls = await tool.calls
        #expect(calls.count == 0)
    }

    @Test("tool failure does not abort agent — loop continues after error sent to model")
    func toolReturnsFailureAgentContinuesLoop() async throws {
        let tool = ConfigurableTool.failing(
            TestToolError.generic("something went wrong"),
            name: "flaky"
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "flaky",
                    arguments: #"{"input":"try"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(request.hasToolResult(for: "tc-1"))
                return MockResponse.text("Worked around it")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool]
        )

        let result = try await agent.run("Do something")
        #expect(result.output == "Worked around it")
        #expect(result.requestCount == 2)
    }
}
