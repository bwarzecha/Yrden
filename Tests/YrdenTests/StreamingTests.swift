/// Tests for StreamEvent.
///
/// Test coverage:
/// - Codable round-trip for all event types
/// - Equatable/Hashable behavior

import Testing
import Foundation
@testable import Yrden

@Suite("StreamEvent")
struct StreamEventTests {

    // MARK: - Codable Round-Trip: contentDelta

    @Test func roundTrip_contentDelta() throws {
        let event = StreamEvent.contentDelta("Hello, ")

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded == event)
    }

    @Test func roundTrip_contentDeltaEmpty() throws {
        let event = StreamEvent.contentDelta("")

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded == event)
    }

    @Test func roundTrip_contentDeltaUnicode() throws {
        let event = StreamEvent.contentDelta("héllo 🎉 世界")

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded == event)
    }

    // MARK: - Codable Round-Trip: toolCallStart

    @Test func roundTrip_toolCallStart() throws {
        let event = StreamEvent.toolCallStart(id: "call_123", name: "search")

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded == event)
    }

    @Test func roundTrip_toolCallStartEmptyName() throws {
        let event = StreamEvent.toolCallStart(id: "1", name: "")

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded == event)
    }

    // MARK: - Codable Round-Trip: toolCallDelta

    @Test func roundTrip_toolCallDelta() throws {
        let event = StreamEvent.toolCallDelta(argumentsDelta: #"{"query": "#)

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded == event)
    }

    @Test func roundTrip_toolCallDeltaEmpty() throws {
        let event = StreamEvent.toolCallDelta(argumentsDelta: "")

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded == event)
    }

    // MARK: - Codable Round-Trip: toolCallEnd

    @Test func roundTrip_toolCallEnd() throws {
        let event = StreamEvent.toolCallEnd(id: "call_123")

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded == event)
    }

    // MARK: - Codable Round-Trip: done

    @Test func roundTrip_done() throws {
        let response = CompletionResponse(
            content: "Hello, world!",
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 5)
        )
        let event = StreamEvent.done(response)

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded == event)
    }

    @Test func roundTrip_doneWithToolCalls() throws {
        let response = CompletionResponse(
            content: nil,
            toolCalls: [
                ToolCall(id: "1", name: "search", arguments: #"{"query":"swift"}"#)
            ],
            stopReason: .toolUse,
            usage: Usage(inputTokens: 20, outputTokens: 15)
        )
        let event = StreamEvent.done(response)

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)

        #expect(decoded == event)
    }

    // MARK: - Equatable

    @Test func equatable_sameContentDelta() {
        let event1 = StreamEvent.contentDelta("Hello")
        let event2 = StreamEvent.contentDelta("Hello")

        #expect(event1 == event2)
    }

    @Test func equatable_differentContentDelta() {
        let event1 = StreamEvent.contentDelta("Hello")
        let event2 = StreamEvent.contentDelta("World")

        #expect(event1 != event2)
    }

    @Test func equatable_sameToolCallStart() {
        let event1 = StreamEvent.toolCallStart(id: "1", name: "search")
        let event2 = StreamEvent.toolCallStart(id: "1", name: "search")

        #expect(event1 == event2)
    }

    @Test func equatable_differentToolCallStart() {
        let event1 = StreamEvent.toolCallStart(id: "1", name: "search")
        let event2 = StreamEvent.toolCallStart(id: "2", name: "search")

        #expect(event1 != event2)
    }

    @Test func equatable_differentEventTypes() {
        let delta = StreamEvent.contentDelta("test")
        let start = StreamEvent.toolCallStart(id: "test", name: "test")

        #expect(delta != start)
    }

    // MARK: - Hashable

    @Test func hashable_inSet() {
        let events: Set<StreamEvent> = [
            .contentDelta("a"),
            .contentDelta("a"),  // duplicate
            .contentDelta("b"),
            .toolCallStart(id: "1", name: "search"),
            .toolCallEnd(id: "1")
        ]

        #expect(events.count == 4)
    }

    @Test func hashable_asDictionaryKey() {
        var dict: [StreamEvent: String] = [:]
        dict[.contentDelta("test")] = "delta"
        dict[.toolCallStart(id: "1", name: "search")] = "start"

        #expect(dict[.contentDelta("test")] == "delta")
        #expect(dict[.toolCallStart(id: "1", name: "search")] == "start")
    }

    // MARK: - Event Sequences

    @Test func sequence_textOnlyResponse() {
        // Simulated stream of events for a text-only response
        let events: [StreamEvent] = [
            .contentDelta("Hello"),
            .contentDelta(", "),
            .contentDelta("world"),
            .contentDelta("!"),
            .done(CompletionResponse(
                content: "Hello, world!",
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 5, outputTokens: 4)
            ))
        ]

        // Verify we can accumulate content
        var accumulated = ""
        for event in events {
            if case .contentDelta(let delta) = event {
                accumulated += delta
            }
        }

        #expect(accumulated == "Hello, world!")
    }

    @Test func sequence_toolCallResponse() {
        // Simulated stream of events for a tool call response
        let events: [StreamEvent] = [
            .toolCallStart(id: "call_1", name: "search"),
            .toolCallDelta(argumentsDelta: #"{"#),
            .toolCallDelta(argumentsDelta: #""query""#),
            .toolCallDelta(argumentsDelta: #":"#),
            .toolCallDelta(argumentsDelta: #""swift"}"#),
            .toolCallEnd(id: "call_1"),
            .done(CompletionResponse(
                content: nil,
                toolCalls: [ToolCall(id: "call_1", name: "search", arguments: #"{"query":"swift"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 8)
            ))
        ]

        // Verify we can accumulate arguments
        var args = ""
        var inToolCall = false
        var toolName = ""

        for event in events {
            switch event {
            case .toolCallStart(_, let name):
                inToolCall = true
                toolName = name
            case .toolCallDelta(let delta):
                if inToolCall {
                    args += delta
                }
            case .toolCallEnd:
                inToolCall = false
            default:
                break
            }
        }

        #expect(toolName == "search")
        #expect(args == #"{"query":"swift"}"#)
    }

    @Test func sequence_mixedResponse() {
        // Text followed by tool call
        let events: [StreamEvent] = [
            .contentDelta("Let me search for that..."),
            .toolCallStart(id: "1", name: "search"),
            .toolCallDelta(argumentsDelta: "{}"),
            .toolCallEnd(id: "1"),
            .done(CompletionResponse(
                content: "Let me search for that...",
                toolCalls: [ToolCall(id: "1", name: "search", arguments: "{}")],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 12)
            ))
        ]

        #expect(events.count == 5)

        // First event is content
        if case .contentDelta(let text) = events[0] {
            #expect(text == "Let me search for that...")
        } else {
            Issue.record("Expected contentDelta")
        }

        // Last event is done
        if case .done(let response) = events[4] {
            #expect(response.stopReason == .toolUse)
        } else {
            Issue.record("Expected done")
        }
    }
}
