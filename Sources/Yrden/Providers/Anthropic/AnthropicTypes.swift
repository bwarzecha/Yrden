/// Internal wire format types for the Anthropic Messages API.
///
/// These types handle encoding requests to and decoding responses from
/// the Anthropic API. They are internal to the Yrden library.
///
/// Key differences from our public types:
/// - System messages go in request `system` field, not messages array
/// - Tool arguments are parsed JSON objects, not strings
/// - Images need base64 encoding with `media_type`
/// - Streaming uses SSE with specific event types

import Foundation

// MARK: - Request Types

/// Request body for the Anthropic Messages API.
struct AnthropicRequest: Encodable {
    let model: String
    let max_tokens: Int
    let messages: [AnthropicMessage]
    let system: String?
    let tools: [AnthropicTool]?
    let temperature: Double?
    let stop_sequences: [String]?
    let stream: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case max_tokens
        case messages
        case system
        case tools
        case temperature
        case stop_sequences
        case stream
    }
}

/// A message in the Anthropic format.
struct AnthropicMessage: Codable {
    let role: String  // "user" or "assistant"
    let content: [AnthropicContentBlock]
}

/// Content block in Anthropic messages.
enum AnthropicContentBlock: Codable {
    case text(String)
    case image(base64: String, mediaType: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: String, isError: Bool?)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case source
        case id
        case name
        case input
        case tool_use_id
        case content
        case is_error
    }

    private enum BlockType: String, Codable {
        case text
        case image
        case tool_use
        case tool_result
    }

    private enum SourceType: String, Codable {
        case base64
    }

    private struct ImageSource: Codable {
        let type: SourceType
        let media_type: String
        let data: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(BlockType.self, forKey: .type)

        switch type {
        case .text:
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)

        case .image:
            let source = try container.decode(ImageSource.self, forKey: .source)
            self = .image(base64: source.data, mediaType: source.media_type)

        case .tool_use:
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let input = try container.decode(JSONValue.self, forKey: .input)
            self = .toolUse(id: id, name: name, input: input)

        case .tool_result:
            let toolUseId = try container.decode(String.self, forKey: .tool_use_id)
            let content = try container.decode(String.self, forKey: .content)
            let isError = try container.decodeIfPresent(Bool.self, forKey: .is_error)
            self = .toolResult(toolUseId: toolUseId, content: content, isError: isError)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode(BlockType.text, forKey: .type)
            try container.encode(text, forKey: .text)

        case .image(let base64, let mediaType):
            try container.encode(BlockType.image, forKey: .type)
            let source = ImageSource(type: .base64, media_type: mediaType, data: base64)
            try container.encode(source, forKey: .source)

        case .toolUse(let id, let name, let input):
            try container.encode(BlockType.tool_use, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)

        case .toolResult(let toolUseId, let content, let isError):
            try container.encode(BlockType.tool_result, forKey: .type)
            try container.encode(toolUseId, forKey: .tool_use_id)
            try container.encode(content, forKey: .content)
            if let isError = isError {
                try container.encode(isError, forKey: .is_error)
            }
        }
    }
}

/// Tool definition in Anthropic format.
struct AnthropicTool: Encodable {
    let name: String
    let description: String
    let input_schema: JSONValue

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case input_schema
    }
}

// MARK: - Response Types

/// Response from the Anthropic Messages API.
struct AnthropicResponse: Decodable {
    let id: String
    let type: String
    let role: String
    let content: [AnthropicResponseBlock]
    let model: String
    let stop_reason: String?
    let stop_sequence: String?
    let usage: AnthropicUsage
}

/// Content block in Anthropic response.
struct AnthropicResponseBlock: Decodable {
    let type: String
    let text: String?
    let id: String?        // For tool_use
    let name: String?      // For tool_use
    let input: JSONValue?  // For tool_use (parsed object)
}

/// Usage statistics from Anthropic.
struct AnthropicUsage: Decodable {
    let input_tokens: Int
    let output_tokens: Int
}

/// Error response from Anthropic.
struct AnthropicError: Decodable {
    let type: String
    let error: AnthropicErrorDetail
}

struct AnthropicErrorDetail: Decodable {
    let type: String
    let message: String
}

// MARK: - Streaming Types

/// Streaming event types from Anthropic SSE.
enum AnthropicStreamEvent {
    case messageStart(response: AnthropicMessageStart)
    case contentBlockStart(index: Int, block: AnthropicStreamContentBlock)
    case contentBlockDelta(index: Int, delta: AnthropicStreamDelta)
    case contentBlockStop(index: Int)
    case messageDelta(delta: AnthropicMessageDelta, usage: AnthropicStreamUsage)
    case messageStop
    case ping
    case error(message: String)
}

struct AnthropicMessageStart: Decodable {
    let id: String
    let type: String
    let role: String
    let content: [AnthropicStreamContentBlock]
    let model: String
    let stop_reason: String?
    let stop_sequence: String?
    let usage: AnthropicUsage
}

struct AnthropicStreamContentBlock: Decodable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: JSONValue?
}

enum AnthropicStreamDelta: Decodable {
    case textDelta(String)
    case inputJsonDelta(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case partial_json
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text_delta":
            let text = try container.decode(String.self, forKey: .text)
            self = .textDelta(text)
        case "input_json_delta":
            let json = try container.decode(String.self, forKey: .partial_json)
            self = .inputJsonDelta(json)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown delta type: \(type)"
            )
        }
    }
}

struct AnthropicMessageDelta: Decodable {
    let stop_reason: String?
    let stop_sequence: String?
}

struct AnthropicStreamUsage: Decodable {
    let output_tokens: Int
}

// MARK: - SSE Event Parsing

/// Raw SSE event from Anthropic stream.
struct AnthropicSSEEvent {
    let event: String
    let data: String
}

extension AnthropicSSEEvent {
    /// Parse SSE event into typed stream event.
    func parse() throws -> AnthropicStreamEvent {
        switch event {
        case "message_start":
            let wrapper = try JSONDecoder().decode(
                MessageStartWrapper.self,
                from: Data(data.utf8)
            )
            return .messageStart(response: wrapper.message)

        case "content_block_start":
            let wrapper = try JSONDecoder().decode(
                ContentBlockStartWrapper.self,
                from: Data(data.utf8)
            )
            return .contentBlockStart(index: wrapper.index, block: wrapper.content_block)

        case "content_block_delta":
            let wrapper = try JSONDecoder().decode(
                ContentBlockDeltaWrapper.self,
                from: Data(data.utf8)
            )
            return .contentBlockDelta(index: wrapper.index, delta: wrapper.delta)

        case "content_block_stop":
            let wrapper = try JSONDecoder().decode(
                ContentBlockStopWrapper.self,
                from: Data(data.utf8)
            )
            return .contentBlockStop(index: wrapper.index)

        case "message_delta":
            let wrapper = try JSONDecoder().decode(
                MessageDeltaWrapper.self,
                from: Data(data.utf8)
            )
            return .messageDelta(delta: wrapper.delta, usage: wrapper.usage)

        case "message_stop":
            return .messageStop

        case "ping":
            return .ping

        case "error":
            let wrapper = try JSONDecoder().decode(
                ErrorWrapper.self,
                from: Data(data.utf8)
            )
            return .error(message: wrapper.error.message)

        default:
            throw LLMError.decodingError("Unknown SSE event type: \(event)")
        }
    }
}

// MARK: - SSE Wrapper Types

private struct MessageStartWrapper: Decodable {
    let message: AnthropicMessageStart
}

private struct ContentBlockStartWrapper: Decodable {
    let index: Int
    let content_block: AnthropicStreamContentBlock
}

private struct ContentBlockDeltaWrapper: Decodable {
    let index: Int
    let delta: AnthropicStreamDelta
}

private struct ContentBlockStopWrapper: Decodable {
    let index: Int
}

private struct MessageDeltaWrapper: Decodable {
    let delta: AnthropicMessageDelta
    let usage: AnthropicStreamUsage
}

private struct ErrorWrapper: Decodable {
    let error: AnthropicErrorDetail
}
