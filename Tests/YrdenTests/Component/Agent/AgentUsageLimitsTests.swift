/// Tests for Agent usage limit enforcement.
///
/// Per the AgentExecutionAPI design, usage limits are expected operational
/// outcomes — they return as AgentRun.Status.usageLimitReached, not exceptions.
///
/// Use .result() to get the throw-on-pause convenience if desired.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Agent - Usage Limits")
struct AgentUsageLimitsTests {

    @Test("request limit returns usageLimitReached status")
    func requestLimitReturnsStatus() async throws {
        let callNum = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let n = await callNum.increment()
            return MockResponse.toolCall(
                name: "tool",
                arguments: #"{"input":"go"}"#,
                id: "tc-\(n)"
            )
        })

        let tool = ConfigurableTool.succeeding("ok", name: "tool")

        let agent = try Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool)],
            maxIterations: 20,
            usageLimits: UsageLimits(maxRequests: 2)
        )

        let run = try await agent.run("Use tool", deps: ())

        guard case .usageLimitReached(let limit) = run.status else {
            Issue.record("Expected .usageLimitReached, got \(run.status)")
            return
        }
        if case .requests(let used, let max) = limit {
            #expect(used >= max)
            #expect(max == 2)
        } else {
            Issue.record("Expected .requests limit, got \(limit)")
        }
        #expect(!run.messages.isEmpty)
    }

    @Test("tool call limit returns usageLimitReached status")
    func toolCallLimitReturnsStatus() async throws {
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                // Return 3 parallel tool calls — exceeds limit of 2
                return MockResponse.multipleToolCalls([
                    (name: "tool", arguments: #"{"input":"a"}"#, id: "tc-1"),
                    (name: "tool", arguments: #"{"input":"b"}"#, id: "tc-2"),
                    (name: "tool", arguments: #"{"input":"c"}"#, id: "tc-3"),
                ])
            default:
                return MockResponse.text("Done")
            }
        })

        let tool = ConfigurableTool.succeeding("ok", name: "tool")

        let agent = try Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool)],
            maxIterations: 10,
            usageLimits: UsageLimits(maxToolCalls: 2)
        )

        let run = try await agent.run("Use tools", deps: ())

        guard case .usageLimitReached(let limit) = run.status else {
            Issue.record("Expected .usageLimitReached, got \(run.status)")
            return
        }
        if case .toolCalls(let used, let max) = limit {
            #expect(used >= max)
            #expect(max == 2)
        } else {
            Issue.record("Expected .toolCalls limit, got \(limit)")
        }
    }

    @Test("total token limit returns usageLimitReached status")
    func tokenLimitReturnsStatus() async throws {
        let model = FakeModel(onComplete: { _ in
            // High token usage in first response
            MockResponse.toolCall(
                name: "tool",
                arguments: #"{"input":"test"}"#,
                id: "tc-1",
                usage: Usage(inputTokens: 1000, outputTokens: 500)
            )
        })

        let tool = ConfigurableTool.succeeding("ok", name: "tool")

        let agent = try Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool)],
            maxIterations: 10,
            usageLimits: UsageLimits(maxTotalTokens: 100)
        )

        let run = try await agent.run("Use tool", deps: ())

        guard case .usageLimitReached(let limit) = run.status else {
            Issue.record("Expected .usageLimitReached, got \(run.status)")
            return
        }
        if case .totalTokens(let used, let max) = limit {
            #expect(used > max)
            #expect(max == 100)
        } else {
            Issue.record("Expected .totalTokens limit, got \(limit)")
        }
        #expect(run.usage.totalTokens > 100)
    }
}
