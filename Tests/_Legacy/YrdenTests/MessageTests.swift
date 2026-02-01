/// Tests for Message types: ContentPart, Message.
///
/// Test coverage:
/// - Codable round-trip for all message types
/// - Convenience constructors
/// - Equatable/Hashable behavior
/// - Edge cases (empty content, multimodal)

import Testing
import Foundation
@testable import Yrden

// MARK: - ContentPart Tests

@Suite("ContentPart")
struct ContentPartTests {

    // MARK: - Codable Round-Trip

    @Test func roundTrip_text() throws {
        let part = ContentPart.text("Hello, world!")

        let data = try JSONEncoder().encode(part)
        let decoded = try JSONDecoder().decode(ContentPart.self, from: data)

        #expect(decoded == part)
    }

    @Test func roundTrip_emptyText() throws {
        let part = ContentPart.text("")

        let data = try JSONEncoder().encode(part)
        let decoded = try JSONDecoder().decode(ContentPart.self, from: data)

        #expect(decoded == part)
    }

    @Test func roundTrip_unicodeText() throws {
        let part = ContentPart.text("héllo 🎉 世界")

        let data = try JSONEncoder().encode(part)
        let decoded = try JSONDecoder().decode(ContentPart.self, from: data)

        #expect(decoded == part)
    }

    @Test func roundTrip_image() throws {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])  // PNG header bytes
        let part = ContentPart.image(imageData, mimeType: "image/png")

        let data = try JSONEncoder().encode(part)
        let decoded = try JSONDecoder().decode(ContentPart.self, from: data)

        #expect(decoded == part)
    }

    @Test func roundTrip_emptyImage() throws {
        let part = ContentPart.image(Data(), mimeType: "image/jpeg")

        let data = try JSONEncoder().encode(part)
        let decoded = try JSONDecoder().decode(ContentPart.self, from: data)

        #expect(decoded == part)
    }

    // MARK: - Equatable

    @Test func equatable_sameText() {
        let part1 = ContentPart.text("hello")
        let part2 = ContentPart.text("hello")

        #expect(part1 == part2)
    }

    @Test func equatable_differentText() {
        let part1 = ContentPart.text("hello")
        let part2 = ContentPart.text("world")

        #expect(part1 != part2)
    }

    @Test func equatable_sameImage() {
        let data = Data([1, 2, 3])
        let part1 = ContentPart.image(data, mimeType: "image/png")
        let part2 = ContentPart.image(data, mimeType: "image/png")

        #expect(part1 == part2)
    }

    @Test func equatable_differentMimeType() {
        let data = Data([1, 2, 3])
        let part1 = ContentPart.image(data, mimeType: "image/png")
        let part2 = ContentPart.image(data, mimeType: "image/jpeg")

        #expect(part1 != part2)
    }

    @Test func equatable_textVsImage() {
        let text = ContentPart.text("image")
        let image = ContentPart.image(Data(), mimeType: "image/png")

        #expect(text != image)
    }

    // MARK: - Hashable

    @Test func hashable_inSet() {
        let parts: Set<ContentPart> = [
            .text("a"),
            .text("a"),  // duplicate
            .text("b"),
            .image(Data([1]), mimeType: "image/png")
        ]

        #expect(parts.count == 3)
    }
}

// MARK: - Message Tests

@Suite("Message")
struct MessageTests {

    // MARK: - Codable Round-Trip: System

    @Test func roundTrip_system() throws {
        let message = Message.system("You are a helpful assistant.")

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == message)
    }

    @Test func roundTrip_systemEmpty() throws {
        let message = Message.system("")

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == message)
    }

    // MARK: - Codable Round-Trip: User

    @Test func roundTrip_userText() throws {
        let message = Message.user([.text("What is Swift concurrency?")])

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == message)
    }

    @Test func roundTrip_userMultipart() throws {
        let message = Message.user([
            .text("Describe this image:"),
            .image(Data([1, 2, 3]), mimeType: "image/png")
        ])

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == message)
    }

    @Test func roundTrip_userEmpty() throws {
        let message = Message.user([])

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == message)
    }

    // MARK: - Codable Round-Trip: Assistant

    @Test func roundTrip_assistantTextOnly() throws {
        let message = Message.assistant("Here is my response.", toolCalls: [])

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == message)
    }

    @Test func roundTrip_assistantWithToolCalls() throws {
        let toolCall = ToolCall(
            id: "call_123",
            name: "search",
            arguments: #"{"query": "Swift"}"#
        )
        let message = Message.assistant("", toolCalls: [toolCall])

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == message)
    }

    @Test func roundTrip_assistantMultipleToolCalls() throws {
        let calls = [
            ToolCall(id: "1", name: "search", arguments: "{}"),
            ToolCall(id: "2", name: "calculate", arguments: "{}")
        ]
        let message = Message.assistant("I'll help with both.", toolCalls: calls)

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == message)
    }

    // MARK: - Codable Round-Trip: Tool Result

    @Test func roundTrip_toolResult() throws {
        let message = Message.toolResult(
            toolCallId: "call_123",
            content: "Found 5 matching documents."
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == message)
    }

    @Test func roundTrip_toolResultEmpty() throws {
        let message = Message.toolResult(toolCallId: "call_empty", content: "")

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == message)
    }

    // MARK: - Convenience Constructors

    @Test func convenience_userString() {
        let message = Message.user("Hello")
        let expected = Message.user([.text("Hello")])

        #expect(message == expected)
    }

    @Test func convenience_assistantString() {
        let message = Message.assistant("Hello")
        let expected = Message.assistant("Hello", toolCalls: [])

        #expect(message == expected)
    }

    // MARK: - Equatable

    @Test func equatable_sameSystem() {
        let msg1 = Message.system("test")
        let msg2 = Message.system("test")

        #expect(msg1 == msg2)
    }

    @Test func equatable_differentRoles() {
        let system = Message.system("test")
        let user = Message.user("test")

        #expect(system != user)
    }

    @Test func equatable_assistantWithDifferentToolCalls() {
        let msg1 = Message.assistant("text", toolCalls: [])
        let msg2 = Message.assistant("text", toolCalls: [
            ToolCall(id: "1", name: "test", arguments: "{}")
        ])

        #expect(msg1 != msg2)
    }

    // MARK: - Hashable

    @Test func hashable_inSet() {
        let messages: Set<Message> = [
            .system("sys"),
            .system("sys"),  // duplicate
            .user("user"),
            .assistant("assistant")
        ]

        #expect(messages.count == 3)
    }

    // MARK: - Full Conversation Round-Trip

    @Test func roundTrip_fullConversation() throws {
        let conversation: [Message] = [
            .system("You are helpful."),
            .user("What's 2+2?"),
            .assistant("Let me calculate.", toolCalls: [
                ToolCall(id: "calc_1", name: "add", arguments: #"{"a":2,"b":2}"#)
            ]),
            .toolResult(toolCallId: "calc_1", content: "4"),
            .assistant("2 + 2 = 4")
        ]

        let data = try JSONEncoder().encode(conversation)
        let decoded = try JSONDecoder().decode([Message].self, from: data)

        #expect(decoded == conversation)
        #expect(decoded.count == 5)
    }
}
