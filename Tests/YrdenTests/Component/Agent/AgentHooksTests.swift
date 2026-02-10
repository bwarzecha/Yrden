/// Tests for AgentHooks protocol integration with run() and runStream().

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

// MARK: - Test Hook

/// Records every hook call in order for verification.
actor TrackingHook: AgentHooks {
    typealias Output = String
    var calls: [String] = []
    var injectedMessages: [String] = []

    func beforeModel(_ context: BeforeModelContext<String>) async {
        calls.append("beforeModel(\(context.state.iteration))")
    }

    func afterModel(_ context: AfterModelContext<String>) async {
        calls.append("afterModel")
    }

    func beforeTools(_ context: BeforeToolsContext<String>) async {
        calls.append("beforeTools")
    }

    func afterTools(_ context: AfterToolsContext<String>) async {
        calls.append("afterTools")
    }

    func finished(_ context: FinishedContext<String>) async {
        calls.append("finished")
    }
}

/// Hook that injects a system message at each beforeModel call.
actor InjectingHook: AgentHooks {
    typealias Output = String
    var callCount = 0

    func beforeModel(_ context: BeforeModelContext<String>) async {
        callCount += 1
        let turn = context.state.iteration + 1
        context.state.messages.append(.system("[Turn \(turn)]"))
    }
}

// MARK: - Tests

@Suite("Agent - Hooks")
struct AgentHooksTests {

    @Test("hooks called in correct order for text-only response")
    func hooksCalledInCorrectOrder() async throws {
        let model = FakeModel(responses: [MockResponse.text("Hello")])
        let hook = TrackingHook()

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            hooks: hook
        )

        let result = try await agent.run("Hi")
        #expect(result.output == "Hello")

        let calls = await hook.calls
        #expect(calls == ["beforeModel(0)", "afterModel", "finished"])
    }

    @Test("hooks called with tool calls follow full phase sequence")
    func hooksCalledWithToolCalls() async throws {
        let tool = ConfigurableTool.succeeding("ok", name: "test_tool")
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "test_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let hook = TrackingHook()
        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool],
            hooks: hook
        )

        let result = try await agent.run("Use the tool")
        #expect(result.output == "Done")

        let calls = await hook.calls
        #expect(calls == [
            "beforeModel(0)",
            "afterModel",
            "beforeTools",
            "afterTools",
            "beforeModel(1)",
            "afterModel",
            "finished",
        ])
    }

    @Test("beforeModel hook can inject messages visible to model")
    func beforeModelHookCanInjectMessages() async throws {
        let model = FakeModel(responses: [MockResponse.text("Got it")])
        let hook = InjectingHook()

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            hooks: hook
        )

        _ = try await agent.run("Hi")

        // The injected message should appear in the model's request
        let requests = await model.requests
        #expect(requests.count == 1)
        let messages = requests[0].messages
        let systemMessages = messages.compactMap { msg -> String? in
            if case .system(let text) = msg { return text }
            return nil
        }
        #expect(systemMessages.contains("[Turn 1]"))
    }

    @Test("agent works normally when hooks are nil")
    func hookNotCalledWhenNil() async throws {
        let model = FakeModel(responses: [MockResponse.text("Hello")])

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        let result = try await agent.run("Hi")
        #expect(result.output == "Hello")
    }

    @Test("beforeModel hook called on every iteration")
    func hookCalledOnEachIteration() async throws {
        let tool = ConfigurableTool.succeeding("ok", name: "test_tool")
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "test_tool",
                    arguments: #"{"input":"a"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.toolCall(
                    name: "test_tool",
                    arguments: #"{"input":"b"}"#,
                    id: "tc-2"
                )
            case 3:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let hook = InjectingHook()
        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool],
            hooks: hook
        )

        _ = try await agent.run("Do two things")

        let callCount = await hook.callCount
        #expect(callCount == 3)

        // Each request after the first should have the injected turn message
        let requests = await model.requests
        #expect(requests.count == 3)

        // Request 2 should have [Turn 1] from iteration 0's beforeModel
        // and [Turn 2] from iteration 1's beforeModel (since messages accumulate)
        let req3Messages = requests[2].messages
        let systemTexts = req3Messages.compactMap { msg -> String? in
            if case .system(let text) = msg { return text }
            return nil
        }
        #expect(systemTexts.contains("[Turn 1]"))
        #expect(systemTexts.contains("[Turn 2]"))
        #expect(systemTexts.contains("[Turn 3]"))
    }

    @Test("hooks work with runStream")
    func hooksWorkWithRunStream() async throws {
        let response = MockResponse.text("Hello")
        let model = FakeModel(
            streamEventSequences: [[
                .contentDelta("Hello"),
                .done(response),
            ]]
        )
        let hook = InjectingHook()

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            hooks: hook
        )

        var run: AgentRun<String>?
        for try await event in agent.runStream("Hi") {
            if case .finished(let r) = event {
                run = r
            }
        }

        #expect(run?.output == "Hello")

        // Verify the hook was called and injected the message
        let callCount = await hook.callCount
        #expect(callCount == 1)

        let requests = await model.requests
        let systemMessages = requests[0].messages.compactMap { msg -> String? in
            if case .system(let text) = msg { return text }
            return nil
        }
        #expect(systemMessages.contains("[Turn 1]"))
    }
}
