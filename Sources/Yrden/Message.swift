/// Message types for LLM conversations.
///
/// This module provides the core types for representing conversation history:
/// - `ContentPart`: Individual pieces of content (text, images)
/// - `Message`: A single message in the conversation
///
/// ## Wire Format Compatibility
///
/// These types map to provider-specific formats:
/// - Anthropic: `messages` array with `role` and `content`
/// - OpenAI: `messages` array with `role` and `content`
/// - Bedrock: Converse API message format
///
/// Provider-specific encoding is handled by Model implementations.

import Foundation

// MARK: - ContentPart

/// A piece of content within a message.
///
/// Messages can contain multiple content parts, enabling multimodal
/// conversations with text and images.
///
/// ## Example
/// ```swift
/// // Text-only message
/// let parts: [ContentPart] = [.text("Describe this image")]
///
/// // Multimodal message
/// let parts: [ContentPart] = [
///     .text("What's in this image?"),
///     .image(imageData, mimeType: "image/png")
/// ]
/// ```
public enum ContentPart: Sendable, Equatable, Hashable {
    /// Plain text content.
    case text(String)

    /// Image content with binary data and MIME type.
    /// Common MIME types: `image/png`, `image/jpeg`, `image/gif`, `image/webp`
    case image(Data, mimeType: String)
}

// MARK: - ContentPart Codable

extension ContentPart: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case data
        case mimeType
    }

    private enum ContentType: String, Codable {
        case text
        case image
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ContentType.self, forKey: .type)

        switch type {
        case .text:
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case .image:
            let data = try container.decode(Data.self, forKey: .data)
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            self = .image(data, mimeType: mimeType)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode(ContentType.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let data, let mimeType):
            try container.encode(ContentType.image, forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        }
    }
}

// MARK: - Message

/// A single message in a conversation.
///
/// Messages represent the conversation history sent to the LLM. The agent
/// loop builds up messages as the conversation progresses.
///
/// ## Message Types
///
/// - `.system`: Instructions for the LLM (usually first message)
/// - `.user`: Human input (text and/or images)
/// - `.assistant`: LLM response (text and/or tool calls)
/// - `.toolResult`: Result of executing a tool
///
/// ## Example
/// ```swift
/// let messages: [Message] = [
///     .system("You are a helpful assistant."),
///     .user("What's the weather in Paris?"),
///     .assistant("", toolCalls: [weatherToolCall]),
///     .toolResult(toolCallId: "call_123", content: "Paris: 18°C, sunny"),
///     .assistant("The weather in Paris is 18°C and sunny.", toolCalls: [])
/// ]
/// ```
public enum Message: Sendable, Equatable, Hashable {
    /// System message providing instructions to the LLM.
    case system(String)

    /// User message with one or more content parts.
    case user([ContentPart])

    /// Assistant (LLM) response with optional tool calls.
    /// - Parameters:
    ///   - content: Text response (may be empty if only tool calls)
    ///   - toolCalls: Tools the LLM wants to invoke
    case assistant(String, toolCalls: [ToolCall])

    /// Result of executing a tool, sent back to the LLM.
    /// - Parameters:
    ///   - toolCallId: ID of the ToolCall this responds to
    ///   - content: String representation of the tool output
    case toolResult(toolCallId: String, content: String)
}

// MARK: - Message Convenience

extension Message {
    /// Creates a user message with a single text content part.
    ///
    /// This is a convenience for the common case of text-only user input.
    ///
    /// ```swift
    /// // Instead of:
    /// let message = Message.user([.text("Hello")])
    ///
    /// // You can write:
    /// let message = Message.user("Hello")
    /// ```
    public static func user(_ text: String) -> Message {
        .user([.text(text)])
    }

    /// Creates an assistant message with text content and no tool calls.
    ///
    /// ```swift
    /// // Instead of:
    /// let message = Message.assistant("Hello!", toolCalls: [])
    ///
    /// // You can write:
    /// let message = Message.assistant("Hello!")
    /// ```
    public static func assistant(_ content: String) -> Message {
        .assistant(content, toolCalls: [])
    }
}

// MARK: - Message Codable

extension Message: Codable {
    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls
        case toolCallId
    }

    private enum Role: String, Codable {
        case system
        case user
        case assistant
        case toolResult = "tool_result"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(Role.self, forKey: .role)

        switch role {
        case .system:
            let content = try container.decode(String.self, forKey: .content)
            self = .system(content)
        case .user:
            let parts = try container.decode([ContentPart].self, forKey: .content)
            self = .user(parts)
        case .assistant:
            let content = try container.decode(String.self, forKey: .content)
            let toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
            self = .assistant(content, toolCalls: toolCalls)
        case .toolResult:
            let toolCallId = try container.decode(String.self, forKey: .toolCallId)
            let content = try container.decode(String.self, forKey: .content)
            self = .toolResult(toolCallId: toolCallId, content: content)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .system(let content):
            try container.encode(Role.system, forKey: .role)
            try container.encode(content, forKey: .content)
        case .user(let parts):
            try container.encode(Role.user, forKey: .role)
            try container.encode(parts, forKey: .content)
        case .assistant(let content, let toolCalls):
            try container.encode(Role.assistant, forKey: .role)
            try container.encode(content, forKey: .content)
            if !toolCalls.isEmpty {
                try container.encode(toolCalls, forKey: .toolCalls)
            }
        case .toolResult(let toolCallId, let content):
            try container.encode(Role.toolResult, forKey: .role)
            try container.encode(toolCallId, forKey: .toolCallId)
            try container.encode(content, forKey: .content)
        }
    }
}
