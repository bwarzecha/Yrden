/// Tests for basic iterator behavior.
///
/// Covers the simplest iteration scenarios: simple text responses
/// without tool calls, verifying phase sequences.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Iterator - Basic")
struct IteratorBasicTests {

    // MARK: - Phase Sequence Tests

    @Test("simple text response yields: beforeModel → afterModel → finished")
    func simpleTextPhaseSequence() async throws {
        let model = FakeModel(responses: [
            MockResponse.text("Hello"),
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful."
        )

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

        #expect(phases == ["beforeModel", "afterModel", "finished"])
    }

    @Test("beforeModel is always first node")
    func beforeModelIsFirst() async throws {
        let model = FakeModel(responses: [MockResponse.text("Hello")])
        let agent = Agent<Void, String>(model: model)

        var firstNode: IterationNode<Void, String>?
        for try await node in agent.iter("Hi", deps: ()) {
            firstNode = node
            break
        }

        guard case .beforeModel = firstNode else {
            Issue.record("Expected .beforeModel as first node, got \(String(describing: firstNode))")
            return
        }
    }

    @Test("finished is always last node")
    func finishedIsLast() async throws {
        let model = FakeModel(responses: [MockResponse.text("Hello")])
        let agent = Agent<Void, String>(model: model)

        var lastNode: IterationNode<Void, String>?
        for try await node in agent.iter("Hi", deps: ()) {
            lastNode = node
        }

        guard case .finished = lastNode else {
            Issue.record("Expected .finished as last node, got \(String(describing: lastNode))")
            return
        }
    }

    // MARK: - Output Tests

    @Test("finished context contains correct output")
    func finishedContainsOutput() async throws {
        let model = FakeModel(responses: [MockResponse.text("Hello from model")])
        let agent = Agent<Void, String>(model: model)

        var output: String?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output == "Hello from model")
    }

    @Test("finished context contains accumulated messages")
    func finishedContainsMessages() async throws {
        let model = FakeModel(responses: [MockResponse.text("Response")])
        let agent = Agent<Void, String>(model: model, systemPrompt: "System")

        var messages: [Message]?
        for try await node in agent.iter("User prompt", deps: ()) {
            if case .finished(let ctx) = node {
                messages = ctx.messages
            }
        }

        // Should have: user message + assistant response (system is added at request time)
        #expect(messages?.count == 2)
        #expect(messages?.contains(where: { if case .user = $0 { return true } else { return false } }) == true)
        #expect(messages?.contains(where: { if case .assistant = $0 { return true } else { return false } }) == true)
    }

    // MARK: - State Tests

    @Test("beforeModel state contains user message")
    func beforeModelHasUserMessage() async throws {
        let model = FakeModel(responses: [MockResponse.text("Hi")])
        let agent = Agent<Void, String>(model: model)

        var beforeModelMessages: [Message]?
        for try await node in agent.iter("Hello world", deps: ()) {
            if case .beforeModel(let ctx) = node {
                beforeModelMessages = ctx.state.messages
            }
        }

        #expect(beforeModelMessages?.contains(.user("Hello world")) == true)
    }

    @Test("afterModel state contains response")
    func afterModelHasResponse() async throws {
        let model = FakeModel(responses: [MockResponse.text("Model says hi")])
        let agent = Agent<Void, String>(model: model)

        var response: CompletionResponse?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .afterModel(let ctx) = node {
                response = ctx.response
            }
        }

        #expect(response?.content == "Model says hi")
    }

    @Test("each node has same runID")
    func consistentRunID() async throws {
        let model = FakeModel(responses: [MockResponse.text("Hi")])
        let agent = Agent<Void, String>(model: model)

        var runIDs: Set<String> = []
        for try await node in agent.iter("Hi", deps: ()) {
            switch node {
            case .beforeModel(let ctx): runIDs.insert(ctx.state.runID)
            case .afterModel(let ctx): runIDs.insert(ctx.state.runID)
            case .beforeTools(let ctx): runIDs.insert(ctx.state.runID)
            case .afterTools(let ctx): runIDs.insert(ctx.state.runID)
            case .finished(let ctx): runIDs.insert(ctx.runID)
            }
        }

        #expect(runIDs.count == 1, "All nodes should have same runID")
        #expect(runIDs.first?.isEmpty == false, "runID should not be empty")
    }

    // MARK: - Message History Tests

    @Test("iter with message history includes previous messages")
    func iterWithHistory() async throws {
        let model = FakeModel(responses: [MockResponse.text("Continuation")])
        let agent = Agent<Void, String>(model: model)

        let history: [Message] = [
            .user("First"),
            .assistant("Response to first"),
        ]

        var beforeModelMessages: [Message]?
        for try await node in agent.iter("Second", deps: (), messageHistory: history) {
            if case .beforeModel(let ctx) = node {
                beforeModelMessages = ctx.state.messages
            }
        }

        #expect(beforeModelMessages?.count == 3) // history (2) + new prompt (1)
        #expect(beforeModelMessages?.contains(.user("First")) == true)
        #expect(beforeModelMessages?.contains(.user("Second")) == true)
    }

    // MARK: - Multiple Iterations

    @Test("consecutive iter calls are independent")
    func consecutiveIterationsIndependent() async throws {
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let n = await counter.increment()
            return MockResponse.text("Response \(n)")
        })
        let agent = Agent<Void, String>(model: model)

        var output1: String?
        for try await node in agent.iter("First", deps: ()) {
            if case .finished(let ctx) = node { output1 = ctx.output }
        }

        var output2: String?
        for try await node in agent.iter("Second", deps: ()) {
            if case .finished(let ctx) = node { output2 = ctx.output }
        }

        #expect(output1 == "Response 1")
        #expect(output2 == "Response 2")
    }
}
