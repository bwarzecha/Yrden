import Testing
@testable import Yrden
@testable import YrdenTestSupport

@Suite("FakeModel Smoke Tests")
struct FakeModelSmokeTests {

    @Test("Queue mode returns text response")
    func queueModeText() async throws {
        let model = FakeModel(responses: [MockResponse.text("Hello")])
        let request = CompletionRequest(messages: [.user("Hi")])
        let response = try await model.complete(request)
        #expect(response.content == "Hello")
    }

    @Test("Callback mode receives request and returns response")
    func callbackMode() async throws {
        let model = FakeModel(onComplete: { request in
            #expect(request.messages.count == 1)
            return MockResponse.text("From callback")
        })
        let request = CompletionRequest(messages: [.user("Test")])
        let response = try await model.complete(request)
        #expect(response.content == "From callback")
    }

    @Test("Queue exhaustion throws descriptive error")
    func queueExhaustion() async throws {
        let model = FakeModel(responses: [MockResponse.text("Only one")])
        let request = CompletionRequest(messages: [.user("First")])
        _ = try await model.complete(request)

        await #expect(throws: LLMError.self) {
            try await model.complete(request)
        }
    }

    @Test("Request recording tracks all calls")
    func requestRecording() async throws {
        let model = FakeModel(responses: [
            MockResponse.text("One"),
            MockResponse.text("Two"),
        ])
        let r1 = CompletionRequest(messages: [.user("First")])
        let r2 = CompletionRequest(messages: [.user("Second")])
        _ = try await model.complete(r1)
        _ = try await model.complete(r2)

        let requests = await model.requests
        #expect(requests.count == 2)
    }

    @Test("Stream queue mode returns events in order")
    func streamQueueMode() async throws {
        let response = MockResponse.text("Streamed")
        let model = FakeModel(streamEventSequences: [
            [.contentDelta("Stre"), .contentDelta("amed"), .done(response)],
        ])
        let request = CompletionRequest(messages: [.user("Stream")])

        var events: [StreamEvent] = []
        for try await event in model.stream(request) {
            events.append(event)
        }

        #expect(events.count == 3)
        if case .contentDelta(let text) = events[0] {
            #expect(text == "Stre")
        }
    }

    @Test("CallCounter increments correctly")
    func callCounterWorks() async {
        let counter = CallCounter()
        let first = await counter.increment()
        let second = await counter.increment()
        #expect(first == 1)
        #expect(second == 2)
        let current = await counter.current
        #expect(current == 2)
    }

    @Test("RequestMatchers find tool results")
    func requestMatchersWork() {
        let request = CompletionRequest(messages: [
            .user("Do something"),
            .toolResult(toolCallId: "abc-123", content: "Result here"),
        ])
        #expect(request.hasToolResult(for: "abc-123"))
        #expect(!request.hasToolResult(for: "wrong-id"))
        #expect(request.toolResultContent(for: "abc-123") == "Result here")
        #expect(request.toolResultCount == 1)
        #expect(request.toolResultIds == ["abc-123"])
    }
}
