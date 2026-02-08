/// Tests that agent usage tracking reflects the context window snapshot,
/// not an accumulation across iterations.
///
/// Each API response's `input_tokens` reports the FULL context window for
/// that request. The agent stores the latest response's usage directly,
/// giving an accurate picture of the current context window size.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Agent - Usage Tracking (Context Window)")
struct AgentUsageTrackingTests {

    /// Simulates realistic context window growth across a 2-iteration agent run.
    /// Response 1 reports 500 input tokens (system + user message).
    /// Response 2 reports 650 input tokens (all prior messages re-sent + tool result).
    /// The correct context window after the run is 650 + 50 = 700.
    @Test("usage reflects context window from last response")
    func usageReflectsContextWindow() async throws {
        let counter = CallCounter()

        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "tool",
                    arguments: #"{"input":"test"}"#,
                    id: "tc-1",
                    usage: Usage(inputTokens: 500, outputTokens: 100)
                )
            default:
                return MockResponse.text(
                    "Done",
                    usage: Usage(inputTokens: 650, outputTokens: 50)
                )
            }
        })

        let tool = ConfigurableTool.succeeding("ok", name: "tool")

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool],
            maxIterations: 10
        )

        let run = try await agent.run("Do something")

        // Usage is a snapshot from the last response
        #expect(run.usage.inputTokens == 650)
        #expect(run.usage.outputTokens == 50)
        #expect(run.usage.totalTokens == 700)
    }

    /// With 3 iterations, usage still reflects the last response's snapshot.
    @Test("usage reflects last response even with many iterations")
    func usageReflectsLastResponseWithManyIterations() async throws {
        let counter = CallCounter()

        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "tool",
                    arguments: #"{"input":"a"}"#,
                    id: "tc-1",
                    usage: Usage(inputTokens: 500, outputTokens: 100)
                )
            case 2:
                return MockResponse.toolCall(
                    name: "tool",
                    arguments: #"{"input":"b"}"#,
                    id: "tc-2",
                    usage: Usage(inputTokens: 700, outputTokens: 80)
                )
            default:
                return MockResponse.text(
                    "Final answer",
                    usage: Usage(inputTokens: 850, outputTokens: 40)
                )
            }
        })

        let tool = ConfigurableTool.succeeding("ok", name: "tool")

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool],
            maxIterations: 10
        )

        let run = try await agent.run("Do something complex")

        // Last response: 850 input + 40 output = 890 total
        #expect(run.usage.inputTokens == 850)
        #expect(run.usage.outputTokens == 40)
        #expect(run.usage.totalTokens == 890)
    }
}
