/// Tests for state mutation via context objects.
///
/// State mutation is how users do context engineering:
/// - Compacting messages before model calls
/// - Injecting system prompts dynamically
/// - Modifying tool results before they enter context

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Iterator - State Mutation")
struct IteratorStateMutationTests {

    // MARK: - Test 5.1: Append message before model affects request

    @Test("appending message before model call affects what's sent")
    func appendMessageBeforeModelAffectsRequest() async throws {
        actor InjectionTracker {
            var sawInjected = false
            func markSeen() { sawInjected = true }
        }

        let tracker = InjectionTracker()
        let model = FakeModel(onComplete: { request in
            // Check that our injected message is present
            let hasInjected = request.messages.contains { msg in
                if case .system(let text) = msg {
                    return text.contains("INJECTED")
                }
                return false
            }
            if hasInjected {
                await tracker.markSeen()
            }
            return MockResponse.text("Done")
        })

        let agent = try Agent<String>(model: model)

        for try await node in agent.iter("Hi") {
            if case .beforeModel(let ctx) = node {
                ctx.state.messages.append(.system("INJECTED CONTEXT"))
            }
        }

        let sawInjectedMessage = await tracker.sawInjected
        #expect(sawInjectedMessage, "Injected message should be in request")
    }

    // MARK: - Test 5.2: Modify messages array before model

    @Test("replacing messages entirely works")
    func modifyMessagesArrayBeforeModel() async throws {
        actor CountCapture {
            var count: Int?
            func set(_ c: Int) { count = c }
        }

        let capture = CountCapture()
        let model = FakeModel(onComplete: { request in
            // Count non-system messages in request
            let count = request.messages.filter {
                if case .system = $0 { return false }
                return true
            }.count
            await capture.set(count)
            return MockResponse.text("Done")
        })

        let agent = try Agent<String>(model: model)

        for try await node in agent.iter("Hi") {
            if case .beforeModel(let ctx) = node {
                // Replace with just one user message
                ctx.state.messages = [.user("Only this")]
            }
        }

        let messageCountInRequest = await capture.count
        #expect(messageCountInRequest == 1)
    }

    // MARK: - Test 5.3: Compact messages before model

    @Test("context compaction keeps only recent messages")
    func compactMessagesBeforeModel() async throws {
        // Create a long history
        var history: [Message] = []
        for i in 1...100 {
            history.append(.user("Message \(i)"))
            history.append(.assistant("Response \(i)"))
        }

        actor CountCapture {
            var count: Int?
            func set(_ c: Int) { count = c }
        }

        let capture = CountCapture()
        let model = FakeModel(onComplete: { request in
            // Count messages (excluding system prompt)
            let count = request.messages.filter {
                if case .system = $0 { return false }
                return true
            }.count
            await capture.set(count)
            return MockResponse.text("Done")
        })

        let agent = try Agent<String>(model: model)

        for try await node in agent.iter("New message", messageHistory: history) {
            if case .beforeModel(let ctx) = node {
                // Keep only last 10 messages plus the new one
                ctx.state.messages = Array(ctx.state.messages.suffix(11))
            }
        }

        let messageCountInRequest = await capture.count
        #expect(messageCountInRequest == 11)
    }

    // MARK: - Test 5.4: Context is reference type

    @Test("context is a class - mutations visible without reassignment")
    func contextIsReferenceType() async throws {
        let model = FakeModel(responses: [MockResponse.text("Hello")])
        let agent = try Agent<String>(model: model)

        var mutationVisible = false
        for try await node in agent.iter("Hi") {
            if case .beforeModel(let ctx) = node {
                let originalCount = ctx.state.messages.count
                ctx.state.messages.append(.system("Added"))

                // Without reassigning ctx, check it's visible
                if ctx.state.messages.count == originalCount + 1 {
                    mutationVisible = true
                }
            }
        }

        #expect(mutationVisible)
    }

    // MARK: - Test 5.5: State change visible to iterator

    @Test("state changes made through context are visible in subsequent phases")
    func stateChangeVisibleToIterator() async throws {
        let model = FakeModel(responses: [MockResponse.text("Hello")])
        let agent = try Agent<String>(model: model)

        var messageCountBeforeModel: Int?
        var messageCountAfterModel: Int?

        for try await node in agent.iter("Hi") {
            if case .beforeModel(let ctx) = node {
                ctx.state.messages.append(.system("Added in beforeModel"))
                messageCountBeforeModel = ctx.state.messages.count
            }
            if case .afterModel(let ctx) = node {
                // Should see the message we added
                messageCountAfterModel = ctx.state.messages.count
            }
        }

        // afterModel should have at least as many messages
        // (model response is added by the time we reach afterModel)
        #expect(messageCountBeforeModel != nil)
        #expect(messageCountAfterModel != nil)
        #expect(messageCountAfterModel! >= messageCountBeforeModel!)
    }

    // MARK: - Test 5.6: Early loop termination cleanup

    @Test("breaking out of iteration loop early doesn't break agent")
    func earlyLoopTerminationCleanup() async throws {
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let n = await counter.increment()
            return MockResponse.text("Response \(n)")
        })

        let agent = try Agent<String>(model: model)

        // First iteration - break early
        for try await node in agent.iter("Hi") {
            if case .beforeModel = node {
                break  // Exit early, before finished
            }
        }

        // Agent should be usable for new iteration
        var output: String?
        for try await node in agent.iter("Second") {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output != nil)
    }

    // MARK: - Test 5.7: Messages modified in beforeModel persist to next iteration

    @Test("messages modified in beforeModel persist across tool iterations")
    func messagesModifiedPersistAcrossIterations() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

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

        let agent = try Agent<String>(model: model, tools: [tool])

        var addedMessageInIteration0 = false
        var sawMessageInIteration1 = false

        for try await node in agent.iter("Hi") {
            if case .beforeModel(let ctx) = node {
                if ctx.state.iteration == 0 {
                    ctx.state.messages.append(.system("PERSISTENT_MARKER"))
                    addedMessageInIteration0 = true
                } else if ctx.state.iteration == 1 {
                    // Check if our marker persisted
                    let hasMarker = ctx.state.messages.contains { msg in
                        if case .system(let text) = msg {
                            return text.contains("PERSISTENT_MARKER")
                        }
                        return false
                    }
                    sawMessageInIteration1 = hasMarker
                }
            }
        }

        #expect(addedMessageInIteration0)
        #expect(sawMessageInIteration1)
    }

    // MARK: - Test 5.8: Usage tracking is available

    @Test("usage is available and updated after model calls")
    func usageTrackingAvailable() async throws {
        let model = FakeModel(responses: [
            MockResponse.text("Hello", usage: Usage(inputTokens: 50, outputTokens: 25))
        ])
        let agent = try Agent<String>(model: model)

        var usageInAfterModel: Usage?
        var usageInFinished: Usage?

        for try await node in agent.iter("Hi") {
            if case .afterModel(let ctx) = node {
                usageInAfterModel = ctx.state.usage
            }
            if case .finished(let ctx) = node {
                usageInFinished = ctx.usage
            }
        }

        #expect(usageInAfterModel?.inputTokens == 50)
        #expect(usageInAfterModel?.outputTokens == 25)
        #expect(usageInFinished?.inputTokens == 50)
        #expect(usageInFinished?.outputTokens == 25)
    }

    // MARK: - Test 5.9: Dependencies accessible in all contexts
    // NOTE: Removed - Deps generic parameter removed from Agent/Tool protocol.
    // Dependencies are no longer part of the agent/context API.
}
