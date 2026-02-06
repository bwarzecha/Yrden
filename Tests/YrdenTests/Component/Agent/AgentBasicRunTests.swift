/// Tests for Agent basic run behavior.
///
/// Covers the simplest agent scenario: prompt in, text out, no tools.
/// Also covers message history continuation.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Agent - Basic Run")
struct AgentBasicRunTests {

    @Test("run returns text response from model")
    func runReturnsText() async throws {
        let model = FakeModel(responses: [
            MockResponse.text("Hello from the model"),
        ])

        let agent = try Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: []
        )

        let result = try await agent.run("Say hello", deps: ())

        #expect(result.output == "Hello from the model")
        #expect(result.requestCount == 1)
        #expect(result.toolCallCount == 0)
        #expect(!result.runID.isEmpty)
    }

    @Test("consecutive runs produce independent results with unique runIDs")
    func consecutiveRunsAreIndependent() async throws {
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let call = await counter.increment()
            return MockResponse.text("Response \(call)")
        })

        let agent = try Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: []
        )

        let result1 = try await agent.run("First", deps: ())
        let result2 = try await agent.run("Second", deps: ())

        #expect(result1.output == "Response 1")
        #expect(result2.output == "Response 2")
        #expect(result1.runID != result2.runID)
    }

    @Test("run with message history appends user prompt to existing conversation")
    func runWithMessageHistory() async throws {
        let model = FakeModel(onComplete: { request in
            #expect(request.messages.contains(.user("Previous question")))
            #expect(request.messages.contains(.user("Follow-up question")))
            return MockResponse.text("Continuation")
        })

        let history: [Message] = [
            .user("Previous question"),
            .assistant("Previous answer"),
        ]

        let agent = try Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: []
        )

        let result = try await agent.run(
            "Follow-up question",
            deps: (),
            messageHistory: history
        )
        #expect(result.output == "Continuation")
    }
}
