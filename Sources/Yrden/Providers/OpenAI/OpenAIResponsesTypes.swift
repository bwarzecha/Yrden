/// Internal wire format types for the OpenAI Responses API.
///
/// The Responses API is OpenAI's newer unified interface for GPT-5 and other
/// advanced models. It provides better intelligence, lower costs, and proper
/// handling of reasoning models compared to Chat Completions.
///
/// Key differences from Chat Completions:
/// - Endpoint: `/v1/responses` instead of `/chat/completions`
/// - Input: `input` field (string or message array) instead of `messages`
/// - Tools: `type: "function"` with different structure
/// - Tool results: `function_call_output` with `call_id`
/// - Response: `output` array with typed items (message, function_call, reasoning)
/// - Chaining: `previous_response_id` for multi-turn conversations

import Foundation

// MARK: - Type Constants

/// Output item type identifiers in Responses API.
enum ResponsesOutputType {
    static let message = "message"
    static let functionCall = "function_call"
    static let reasoning = "reasoning"
}

/// Content type identifiers in Responses API.
enum ResponsesContentType {
    static let inputText = "input_text"
    static let outputText = "output_text"
    static let inputImage = "input_image"
    static let refusal = "refusal"
}

/// Input item type identifiers in Responses API.
enum ResponsesInputType {
    static let functionCallOutput = "function_call_output"
}

// MARK: - Request Types

/// Request body for the OpenAI Responses API.
struct ResponsesAPIRequest: Encodable {
    let model: String
    let input: ResponsesInput
    let instructions: String?
    let tools: [ResponsesAPITool]?
    let tool_choice: ResponsesToolChoice?
    let parallel_tool_calls: Bool?
    let temperature: Double?
    let top_p: Double?
    let max_output_tokens: Int?
    let reasoning: ResponsesReasoning?
    let text: ResponsesTextFormat?
    let stream: Bool?
    let store: Bool?
    let prompt_cache_key: String?
    let prompt_cache_retention: String?  // "in-memory" or "24h"

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case instructions
        case tools
        case tool_choice
        case parallel_tool_calls
        case temperature
        case top_p
        case max_output_tokens
        case reasoning
        case text
        case stream
        case store
        case prompt_cache_key
        case prompt_cache_retention
    }
}

/// Input for the Responses API - can be a simple string or array of items.
enum ResponsesInput: Encodable {
    case text(String)
    case items([ResponsesInputItem])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .items(let items):
            try container.encode(items)
        }
    }
}

/// An input item in the Responses API.
enum ResponsesInputItem: Encodable {
    case message(role: String, content: [ResponsesContentPart])
    case functionCallOutput(callId: String, output: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case role
        case content
        case call_id
        case output
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let role, let content):
            // Messages don't have a "type" field - they're identified by having "role"
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)

        case .functionCallOutput(let callId, let output):
            try container.encode(ResponsesInputType.functionCallOutput, forKey: .type)
            try container.encode(callId, forKey: .call_id)
            try container.encode(output, forKey: .output)
        }
    }
}

/// Content part in a Responses API message.
enum ResponsesContentPart: Encodable {
    case inputText(String)
    case outputText(String)
    case inputImage(url: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case image_url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inputText(let text):
            try container.encode(ResponsesContentType.inputText, forKey: .type)
            try container.encode(text, forKey: .text)

        case .outputText(let text):
            try container.encode(ResponsesContentType.outputText, forKey: .type)
            try container.encode(text, forKey: .text)

        case .inputImage(let url):
            try container.encode(ResponsesContentType.inputImage, forKey: .type)
            try container.encode(url, forKey: .image_url)
        }
    }
}

/// Tool definition in Responses API format.
struct ResponsesAPITool: Encodable {
    let type: String
    let name: String
    let description: String
    let parameters: JSONValue
    let strict: Bool?

    init(name: String, description: String, parameters: JSONValue, strict: Bool? = nil) {
        self.type = "function"
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case description
        case parameters
        case strict
    }
}

/// Tool choice for Responses API.
enum ResponsesToolChoice: Encodable {
    case auto
    case none
    case required
    case function(name: String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto:
            try container.encode("auto")
        case .none:
            try container.encode("none")
        case .required:
            try container.encode("required")
        case .function(let name):
            try container.encode(["type": "function", "name": name])
        }
    }
}

/// Reasoning configuration for GPT-5 and other reasoning models.
struct ResponsesReasoning: Encodable {
    let effort: String  // "none", "low", "medium", "high", "xhigh"

    enum CodingKeys: String, CodingKey {
        case effort
    }
}

/// Text output format configuration.
struct ResponsesTextFormat: Encodable {
    let format: ResponsesOutputFormat

    enum CodingKeys: String, CodingKey {
        case format
    }
}

/// Output format options.
enum ResponsesOutputFormat: Encodable {
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
            try container.encode(JsonSchemaFormat(name: name, schema: schema, strict: strict))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }
}

// MARK: - Response Types

/// Response from the Responses API.
struct ResponsesAPIResponse: Decodable {
    let id: String
    let object: String
    let created_at: Double
    let model: String
    let status: String  // "completed", "failed", "in_progress", "incomplete", etc.
    let output: [ResponsesOutputItem]
    let output_text: String?
    let usage: ResponsesUsage?
    let error: ResponsesErrorInfo?
    let incomplete_details: ResponsesIncompleteDetails?
}

/// Details about why a response is incomplete.
struct ResponsesIncompleteDetails: Decodable {
    let reason: String?  // "max_output_tokens", "content_filter"
}

/// An output item in the Responses API response.
enum ResponsesOutputItem: Decodable {
    case message(id: String, role: String, content: [ResponsesOutputContent])
    case functionCall(id: String, callId: String, name: String, arguments: String)
    case reasoning(id: String, content: [String]?, summary: [String]?)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case role
        case content
        case call_id
        case name
        case arguments
        case summary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case ResponsesOutputType.message:
            let id = try container.decode(String.self, forKey: .id)
            let role = try container.decode(String.self, forKey: .role)
            let content = try container.decode([ResponsesOutputContent].self, forKey: .content)
            self = .message(id: id, role: role, content: content)

        case ResponsesOutputType.functionCall:
            let id = try container.decode(String.self, forKey: .id)
            let callId = try container.decode(String.self, forKey: .call_id)
            let name = try container.decode(String.self, forKey: .name)
            let arguments = try container.decode(String.self, forKey: .arguments)
            self = .functionCall(id: id, callId: callId, name: name, arguments: arguments)

        case ResponsesOutputType.reasoning:
            let id = try container.decode(String.self, forKey: .id)
            let content = try container.decodeIfPresent([String].self, forKey: .content)
            let summary = try container.decodeIfPresent([String].self, forKey: .summary)
            self = .reasoning(id: id, content: content, summary: summary)

        default:
            self = .unknown
        }
    }
}

/// Content within a message output.
enum ResponsesOutputContent: Decodable {
    case outputText(text: String, annotations: [String]?)
    case refusal(text: String)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case refusal
        case annotations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case ResponsesContentType.outputText:
            let text = try container.decode(String.self, forKey: .text)
            let annotations = try container.decodeIfPresent([String].self, forKey: .annotations)
            self = .outputText(text: text, annotations: annotations)

        case ResponsesContentType.refusal:
            let refusal = try container.decode(String.self, forKey: .refusal)
            self = .refusal(text: refusal)

        default:
            self = .unknown
        }
    }
}

/// Usage statistics from Responses API.
struct ResponsesUsage: Decodable {
    let input_tokens: Int
    let output_tokens: Int
    let total_tokens: Int
    let input_tokens_details: ResponsesInputTokensDetails?
    let output_tokens_details: ResponsesOutputTokensDetails?
}

/// Detailed breakdown of input tokens.
struct ResponsesInputTokensDetails: Decodable {
    let cached_tokens: Int?
}

/// Detailed breakdown of output tokens.
struct ResponsesOutputTokensDetails: Decodable {
    let reasoning_tokens: Int?
}

/// Error information in response.
struct ResponsesErrorInfo: Decodable {
    let message: String
    let code: String?
}

// MARK: - Streaming Types

/// Streaming event from Responses API.
struct ResponsesStreamEvent: Decodable {
    let type: String
    let response: ResponsesAPIResponse?
    let item: ResponsesStreamItem?
    let content_index: Int?
    let output_index: Int?
    let delta: String?
    /// Item ID for delta events (function_call_arguments.delta uses this)
    let item_id: String?
    let sequence_number: Int?
}

/// Item in streaming events (for output_item.added).
struct ResponsesStreamItem: Decodable {
    let type: String?
    /// The item's unique ID
    let id: String?
    /// The function call ID (for matching tool results)
    let call_id: String?
    let name: String?
    let arguments: String?
    let status: String?
}

// MARK: - Error Response

/// Error response from Responses API.
struct ResponsesAPIError: Decodable {
    let error: ResponsesAPIErrorDetail
}

/// Error details.
struct ResponsesAPIErrorDetail: Decodable {
    let message: String
    let type: String
    let param: String?
    let code: String?
}
