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

// MARK: - ToolResultEntry

/// A single tool result entry for multi-tool responses.
public struct ToolResultEntry: Sendable, Codable, Equatable, Hashable {
    /// ID of the ToolCall this responds to.
    public let id: String

    /// Output of the tool execution.
    public let output: ToolOutput

    public init(id: String, output: ToolOutput) {
        self.id = id
        self.output = output
    }

    /// Convenience for text output.
    public static func text(id: String, _ text: String) -> ToolResultEntry {
        ToolResultEntry(id: id, output: .text(text))
    }

    /// Convenience for error output.
    public static func error(id: String, _ message: String) -> ToolResultEntry {
        ToolResultEntry(id: id, output: .error(message))
    }
}

// MARK: - ThinkingBlock

/// Thinking/reasoning content from the model.
///
/// Represents internal reasoning from extended thinking features (Anthropic, OpenAI o-series).
/// Provider-agnostic design handles both visible and filtered content.
///
/// ## Provider Behavior
/// - **Anthropic**: Returns `providerData` containing signature for verification
/// - **OpenAI**: Returns reasoning content, no signature
/// - **Filtered content**: `content` is nil but `providerData` must be passed through
///
/// ## Example
/// ```swift
/// // Visible thinking from Anthropic
/// let block = ThinkingBlock(
///     content: "Let me analyze this step by step...",
///     providerData: "signature_abc123",
///     provider: "anthropic"
/// )
///
/// // Filtered thinking (must pass through unchanged)
/// let filtered = ThinkingBlock(
///     content: nil,
///     providerData: "encrypted_data",
///     provider: "anthropic"
/// )
/// ```
public struct ThinkingBlock: Sendable, Equatable, Hashable, Codable {
    /// The thinking content. Nil if content was filtered/redacted by the provider.
    public let content: String?

    /// Opaque provider data that must be passed back unchanged for cache compatibility.
    /// Contains verification signature (Anthropic) or encrypted content (filtered thinking).
    public let providerData: String?

    /// The provider that generated this thinking block.
    /// Used to determine handling when switching providers.
    public let provider: String

    public init(content: String?, providerData: String?, provider: String) {
        self.content = content
        self.providerData = providerData
        self.provider = provider
    }

    /// Whether the thinking content was filtered and is not available.
    public var isFiltered: Bool { content == nil && providerData != nil }
}

// MARK: - AssistantContentBlock

/// A content block within an assistant message.
///
/// Preserves block structure for cache compatibility across providers.
/// Content blocks are ordered and their exact sequence must be maintained
/// for prompt caching to work correctly.
///
/// ## Block Types
/// - `.text`: Regular text content
/// - `.thinking`: Reasoning/thinking content (extended thinking)
/// - `.toolUse`: Tool invocation request
///
/// ## Example
/// ```swift
/// let blocks: [AssistantContentBlock] = [
///     .thinking(ThinkingBlock(content: "Let me analyze...", providerData: "sig", provider: "anthropic")),
///     .text("Based on my analysis..."),
///     .toolUse(searchToolCall)
/// ]
/// ```
public enum AssistantContentBlock: Sendable, Equatable, Hashable {
    /// Regular text content.
    case text(String)

    /// Thinking/reasoning content.
    case thinking(ThinkingBlock)

    /// Tool use request from the model.
    case toolUse(ToolCall)
}

// MARK: - AssistantContentBlock Convenience

extension AssistantContentBlock {
    /// Text content if this is a text block.
    public var textContent: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    /// The thinking block if this is a thinking block.
    public var thinkingBlock: ThinkingBlock? {
        if case .thinking(let block) = self { return block }
        return nil
    }

    /// Thinking text content if this is a thinking block with visible content.
    public var thinkingContent: String? {
        thinkingBlock?.content
    }

    /// Tool call if this is a toolUse block.
    public var toolCall: ToolCall? {
        if case .toolUse(let call) = self { return call }
        return nil
    }

    /// Whether this block is thinking content (visible or filtered).
    public var isThinking: Bool {
        if case .thinking = self { return true }
        return false
    }
}

// MARK: - AssistantContentBlock Codable

extension AssistantContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case toolCall
    }

    private enum BlockType: String, Codable {
        case text
        case thinking
        case toolUse
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(BlockType.self, forKey: .type)

        switch type {
        case .text:
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case .thinking:
            let block = try container.decode(ThinkingBlock.self, forKey: .thinking)
            self = .thinking(block)
        case .toolUse:
            let call = try container.decode(ToolCall.self, forKey: .toolCall)
            self = .toolUse(call)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode(BlockType.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let block):
            try container.encode(BlockType.thinking, forKey: .type)
            try container.encode(block, forKey: .thinking)
        case .toolUse(let call):
            try container.encode(BlockType.toolUse, forKey: .type)
            try container.encode(call, forKey: .toolCall)
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
///     .assistant([.toolUse(weatherToolCall)]),
///     .toolResult(toolCallId: "call_123", content: "Paris: 18°C, sunny"),
///     .assistant("The weather in Paris is 18°C and sunny.")
/// ]
/// ```
public enum Message: Sendable, Equatable, Hashable {
    /// System message providing instructions to the LLM.
    case system(String)

    /// User message with one or more content parts.
    case user([ContentPart])

    /// Assistant (LLM) response with content blocks.
    ///
    /// Content blocks preserve exact ordering for cache compatibility.
    /// Blocks can include text, thinking content, and tool calls in any order.
    ///
    /// - Parameter blocks: Ordered content blocks (text, thinking, toolUse)
    case assistant([AssistantContentBlock])

    /// Result of executing a tool, sent back to the LLM.
    /// - Parameters:
    ///   - toolCallId: ID of the ToolCall this responds to
    ///   - content: String representation of the tool output
    case toolResult(toolCallId: String, content: String)

    /// Results of executing multiple tools, sent back to the LLM.
    /// Used when the LLM requested multiple tool calls in a single response.
    case toolResults([ToolResultEntry])
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

    /// Creates an assistant message with text content only.
    ///
    /// ```swift
    /// // Instead of:
    /// let message = Message.assistant([.text("Hello!")])
    ///
    /// // You can write:
    /// let message = Message.assistant("Hello!")
    /// ```
    public static func assistant(_ content: String) -> Message {
        .assistant(content.isEmpty ? [] : [.text(content)])
    }

    /// Creates an assistant message with text followed by tool calls.
    ///
    /// For interleaved content, use the array initializer directly.
    ///
    /// ```swift
    /// let message = Message.assistant("I'll search for that", toolCalls: [searchCall])
    /// ```
    public static func assistant(_ content: String, toolCalls: [ToolCall]) -> Message {
        var blocks: [AssistantContentBlock] = []
        if !content.isEmpty {
            blocks.append(.text(content))
        }
        blocks.append(contentsOf: toolCalls.map { .toolUse($0) })
        return .assistant(blocks)
    }

    /// Creates an assistant message with only tool calls (no text content).
    public static func assistantToolCalls(_ toolCalls: [ToolCall]) -> Message {
        .assistant(toolCalls.map { .toolUse($0) })
    }
}

// MARK: - Message Computed Properties

extension Message {
    /// All tool calls from an assistant message.
    /// Returns empty array for non-assistant messages.
    public var toolCalls: [ToolCall] {
        guard case .assistant(let blocks) = self else { return [] }
        return blocks.compactMap { $0.toolCall }
    }

    /// Combined text content from an assistant message (excludes thinking).
    /// Returns nil for non-assistant messages or if no text blocks present.
    public var assistantContent: String? {
        guard case .assistant(let blocks) = self else { return nil }
        let texts = blocks.compactMap { $0.textContent }
        return texts.isEmpty ? nil : texts.joined()
    }

    /// Combined thinking content from an assistant message.
    /// Returns nil for non-assistant messages or if no thinking blocks present.
    public var assistantThinking: String? {
        guard case .assistant(let blocks) = self else { return nil }
        let thoughts = blocks.compactMap { $0.thinkingContent }
        return thoughts.isEmpty ? nil : thoughts.joined()
    }

    /// The content blocks if this is an assistant message.
    /// Returns nil for non-assistant messages.
    public var assistantBlocks: [AssistantContentBlock]? {
        guard case .assistant(let blocks) = self else { return nil }
        return blocks
    }
}

// MARK: - Message Codable

extension Message: Codable {
    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case blocks
        case toolCallId
        case results
    }

    private enum Role: String, Codable {
        case system
        case user
        case assistant
        case toolResult = "tool_result"
        case toolResults = "tool_results"
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
            let blocks = try container.decode([AssistantContentBlock].self, forKey: .blocks)
            self = .assistant(blocks)
        case .toolResult:
            let toolCallId = try container.decode(String.self, forKey: .toolCallId)
            let content = try container.decode(String.self, forKey: .content)
            self = .toolResult(toolCallId: toolCallId, content: content)
        case .toolResults:
            let results = try container.decode([ToolResultEntry].self, forKey: .results)
            self = .toolResults(results)
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
        case .assistant(let blocks):
            try container.encode(Role.assistant, forKey: .role)
            try container.encode(blocks, forKey: .blocks)
        case .toolResult(let toolCallId, let content):
            try container.encode(Role.toolResult, forKey: .role)
            try container.encode(toolCallId, forKey: .toolCallId)
            try container.encode(content, forKey: .content)
        case .toolResults(let results):
            try container.encode(Role.toolResults, forKey: .role)
            try container.encode(results, forKey: .results)
        }
    }
}
