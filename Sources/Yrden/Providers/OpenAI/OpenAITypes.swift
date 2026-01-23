/// Internal wire format types for the OpenAI Chat Completions API.
///
/// These types handle encoding requests to and decoding responses from
/// the OpenAI API. They are internal to the Yrden library.
///
/// Key differences from Anthropic:
/// - System messages stay in messages array (role: "system")
/// - Tool results use separate messages (role: "tool")
/// - Images use data URL format
/// - Streaming uses `data: [DONE]` terminator

import Foundation

// MARK: - Request Types

/// Request body for the OpenAI Chat Completions API.
struct OpenAIRequest: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    /// Legacy max tokens parameter (for older models like gpt-4o).
    let max_tokens: Int?
    /// New max completion tokens parameter (for newer models like gpt-5.x, o3).
    let max_completion_tokens: Int?
    let temperature: Double?
    let stop: [String]?
    let tools: [OpenAITool]?
    let tool_choice: OpenAIToolChoice?
    let response_format: OpenAIResponseFormat?
    let stream: Bool?
    let stream_options: OpenAIStreamOptions?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case max_tokens
        case max_completion_tokens
        case temperature
        case stop
        case tools
        case tool_choice
        case response_format
        case stream
        case stream_options
    }
}

/// A message in OpenAI format.
struct OpenAIMessage: Codable {
    let role: String  // "system", "user", "assistant", "tool"
    let content: OpenAIContent?
    let tool_calls: [OpenAIToolCall]?
    let tool_call_id: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case tool_calls
        case tool_call_id
    }

    init(
        role: String,
        content: OpenAIContent?,
        tool_calls: [OpenAIToolCall]? = nil,
        tool_call_id: String? = nil
    ) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
    }
}

/// Content in OpenAI messages - can be string or array of parts.
enum OpenAIContent: Codable {
    case text(String)
    case parts([OpenAIContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try string first
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }

        // Try array of parts
        if let parts = try? container.decode([OpenAIContentPart].self) {
            self = .parts(parts)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Content must be string or array of parts"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .text(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

/// Content part for multimodal messages.
enum OpenAIContentPart: Codable {
    case text(String)
    case imageURL(url: String, detail: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case image_url
    }

    private enum PartType: String, Codable {
        case text
        case image_url
    }

    private struct ImageURLData: Codable {
        let url: String
        let detail: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(PartType.self, forKey: .type)

        switch type {
        case .text:
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)

        case .image_url:
            let imageData = try container.decode(ImageURLData.self, forKey: .image_url)
            self = .imageURL(url: imageData.url, detail: imageData.detail)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode(PartType.text, forKey: .type)
            try container.encode(text, forKey: .text)

        case .imageURL(let url, let detail):
            try container.encode(PartType.image_url, forKey: .type)
            let imageData = ImageURLData(url: url, detail: detail)
            try container.encode(imageData, forKey: .image_url)
        }
    }
}

/// Tool definition in OpenAI format.
struct OpenAITool: Encodable {
    let type: String = "function"
    let function: OpenAIFunction

    enum CodingKeys: String, CodingKey {
        case type
        case function
    }
}

/// Function definition within a tool.
struct OpenAIFunction: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
    let strict: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case parameters
        case strict
    }
}

/// Tool call in assistant response.
struct OpenAIToolCall: Codable {
    let id: String
    let type: String
    let function: OpenAIFunctionCall

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case function
    }
}

/// Function call details.
struct OpenAIFunctionCall: Codable {
    let name: String
    let arguments: String

    enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }
}

/// Tool choice options for controlling tool use.
enum OpenAIToolChoice: Encodable {
    case auto
    case none
    case required
    case function(name: String)

    private enum SimpleChoice: String, Encodable {
        case auto
        case none
        case required
    }

    private struct FunctionChoice: Encodable {
        let type: String = "function"
        let function: FunctionName
    }

    private struct FunctionName: Encodable {
        let name: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .auto:
            try container.encode(SimpleChoice.auto)
        case .none:
            try container.encode(SimpleChoice.none)
        case .required:
            try container.encode(SimpleChoice.required)
        case .function(let name):
            let choice = FunctionChoice(function: FunctionName(name: name))
            try container.encode(choice)
        }
    }
}

/// Response format for structured output.
enum OpenAIResponseFormat: Encodable {
    case text
    case jsonObject
    case jsonSchema(name: String, schema: JSONValue, strict: Bool)

    private enum FormatType: String, Encodable {
        case text
        case json_object
        case json_schema
    }

    private struct JsonSchemaFormat: Encodable {
        let type: FormatType = .json_schema
        let json_schema: JsonSchemaSpec
    }

    private struct JsonSchemaSpec: Encodable {
        let name: String
        let schema: JSONValue
        let strict: Bool
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(FormatType.text, forKey: .type)

        case .jsonObject:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(FormatType.json_object, forKey: .type)

        case .jsonSchema(let name, let schema, let strict):
            var container = encoder.singleValueContainer()
            let format = JsonSchemaFormat(
                json_schema: JsonSchemaSpec(name: name, schema: schema, strict: strict)
            )
            try container.encode(format)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }
}

/// Stream options for controlling streaming behavior.
struct OpenAIStreamOptions: Encodable {
    let include_usage: Bool

    enum CodingKeys: String, CodingKey {
        case include_usage
    }
}

// MARK: - Response Types

/// Response from the OpenAI Chat Completions API.
struct OpenAIResponse: Decodable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [OpenAIChoice]
    let usage: OpenAIUsage?
}

/// A choice in the response.
struct OpenAIChoice: Decodable {
    let index: Int
    let message: OpenAIResponseMessage
    let finish_reason: String?
}

/// Message content in response.
struct OpenAIResponseMessage: Decodable {
    let role: String
    let content: String?
    let tool_calls: [OpenAIToolCall]?
}

/// Usage statistics from OpenAI.
struct OpenAIUsage: Decodable {
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int
}

/// Error response from OpenAI.
struct OpenAIError: Decodable {
    let error: OpenAIErrorDetail
}

/// Error details.
struct OpenAIErrorDetail: Decodable {
    let message: String
    let type: String
    let param: String?
    let code: String?
}

// MARK: - Streaming Types

/// Streaming chunk from OpenAI.
struct OpenAIStreamChunk: Decodable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [OpenAIStreamChoice]
    let usage: OpenAIUsage?
}

/// A choice in a streaming chunk.
struct OpenAIStreamChoice: Decodable {
    let index: Int
    let delta: OpenAIStreamDelta
    let finish_reason: String?
}

/// Delta content in streaming.
struct OpenAIStreamDelta: Decodable {
    let role: String?
    let content: String?
    let tool_calls: [OpenAIStreamToolCall]?
}

/// Tool call delta in streaming.
struct OpenAIStreamToolCall: Decodable {
    let index: Int
    let id: String?
    let type: String?
    let function: OpenAIStreamFunction?
}

/// Function delta in streaming.
struct OpenAIStreamFunction: Decodable {
    let name: String?
    let arguments: String?
}

// MARK: - Model Listing

/// Response from the OpenAI models endpoint.
struct OpenAIModelsResponse: Decodable {
    let object: String
    let data: [OpenAIModelInfo]
}

/// Model information from OpenAI.
struct OpenAIModelInfo: Decodable {
    let id: String
    let object: String
    let created: Int
    let owned_by: String
}
