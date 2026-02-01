/// Tests for Agent tool call round-trip behavior.
///
/// Covers happy path: single tool calls, sequential calls across iterations,
/// parallel calls in a single response, usage accumulation, and same-tool batching.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Agent - Tool Call Round-Trip")
struct AgentToolCallTests {

    @Test("single tool call executes and result flows back to model")
    func singleToolCallRoundTrip() async throws {
        let tool = ConfigurableTool.succeeding("processed: hello", name: "test_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "test_tool",
                    arguments: #"{"input":"hello"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(request.toolResultContent(for: "tc-1") == "processed: hello")
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool)]
        )

        let result = try await agent.run("Use the tool", deps: ())

        #expect(result.output == "Done")
        #expect(result.requestCount == 2)
        #expect(result.toolCallCount == 1)
    }

    @Test("tool result ID matches the original tool call ID exactly")
    func toolResultIDMatchesOriginalCallID() async throws {
        let tool = ConfigurableTool.succeeding("ok", name: "test_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "test_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "call-abc-123"
                )
            case 2:
                #expect(request.toolResultIds == ["call-abc-123"])
                #expect(request.toolResultCount == 1)
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool)]
        )

        let result = try await agent.run("Go", deps: ())
        #expect(result.output == "Done")
    }

    @Test("multiple sequential tool calls across iterations flow correctly")
    func multipleSequentialToolCallsAcrossIterations() async throws {
        let searchTool = ConfigurableTool.succeeding("found it", name: "search")
        let calcTool = ConfigurableTool.succeeding("4", name: "calc")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "search",
                    arguments: #"{"input":"query"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(request.toolResultContent(for: "tc-1") == "found it")
                return MockResponse.toolCall(
                    name: "calc",
                    arguments: #"{"input":"2+2"}"#,
                    id: "tc-2"
                )
            case 3:
                #expect(request.toolResultContent(for: "tc-2") == "4")
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(searchTool), AnyAgentTool(calcTool)]
        )

        let result = try await agent.run("Search and calculate", deps: ())

        #expect(result.output == "Done")
        #expect(result.requestCount == 3)
        #expect(result.toolCallCount == 2)
    }

    @Test("multiple parallel tool calls in single response both execute and return results")
    func multipleParallelToolCallsInSingleResponse() async throws {
        let alphaTool = ConfigurableTool.succeeding("result-a", name: "alpha")
        let betaTool = ConfigurableTool.succeeding("result-b", name: "beta")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCalls([
                    ToolCall(id: "tc-1", name: "alpha", arguments: #"{"input":"a"}"#),
                    ToolCall(id: "tc-2", name: "beta", arguments: #"{"input":"b"}"#),
                ])
            case 2:
                #expect(request.toolResultCount == 2)
                #expect(request.toolResultContent(for: "tc-1") == "result-a")
                #expect(request.toolResultContent(for: "tc-2") == "result-b")
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(alphaTool), AnyAgentTool(betaTool)]
        )

        let result = try await agent.run("Use both tools", deps: ())

        #expect(result.output == "Done")
        #expect(result.toolCallCount == 2)
    }

    @Test("usage accumulates across tool call rounds")
    func usageAccumulatesAcrossToolRounds() async throws {
        let tool = ConfigurableTool.succeeding("ok", name: "test_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "test_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1",
                    usage: Usage(inputTokens: 100, outputTokens: 50)
                )
            case 2:
                return MockResponse.text(
                    "Done",
                    usage: Usage(inputTokens: 200, outputTokens: 75)
                )
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool)]
        )

        let result = try await agent.run("Go", deps: ())

        #expect(result.usage.inputTokens == 300)
        #expect(result.usage.outputTokens == 125)
        #expect(result.usage.totalTokens == 425)
    }

    @Test("same tool called multiple times in batch with different IDs")
    func sameToolCalledMultipleTimesInBatch() async throws {
        let searchTool = ConfigurableTool.succeeding("search result", name: "search")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCalls([
                    ToolCall(
                        id: "tc-1", name: "search",
                        arguments: #"{"input":"first query"}"#
                    ),
                    ToolCall(
                        id: "tc-2", name: "search",
                        arguments: #"{"input":"second query"}"#
                    ),
                ])
            case 2:
                #expect(try request.isToolResultSuccess(for: "tc-1"))
                #expect(try request.isToolResultSuccess(for: "tc-2"))
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(searchTool)]
        )

        let result = try await agent.run("Search twice", deps: ())
        #expect(result.output == "Done")
        #expect(result.toolCallCount == 2)
    }
}
