/// Tests for OpenAI wire format types.
///
/// Test coverage:
/// - OpenAIContentPart encoding/decoding
/// - OpenAIContent encoding/decoding
/// - OpenAIMessage encoding/decoding
/// - OpenAIRequest encoding
/// - OpenAIResponse decoding
/// - OpenAIStreamChunk decoding
/// - OpenAIError decoding

import Testing
import Foundation
@testable import Yrden

// MARK: - OpenAIContentPart Tests

@Suite("OpenAIContentPart")
struct OpenAIContentPartTests {

    @Test func encode_textPart() throws {
        let part = OpenAIContentPart.text("Hello, world!")

        let data = try JSONEncoder().encode(part)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "text")
        #expect(json["text"] as? String == "Hello, world!")
    }

    @Test func decode_textPart() throws {
        let json = #"{"type": "text", "text": "Hello"}"#

        let part = try JSONDecoder().decode(
            OpenAIContentPart.self,
            from: Data(json.utf8)
        )

        if case .text(let text) = part {
            #expect(text == "Hello")
        } else {
            Issue.record("Expected text part")
        }
    }

    @Test func encode_imageURLPart() throws {
        let part = OpenAIContentPart.imageURL(
            url: "data:image/png;base64,aGVsbG8=",
            detail: "high"
        )

        let data = try JSONEncoder().encode(part)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "image_url")
        let imageURL = json["image_url"] as! [String: Any]
        #expect(imageURL["url"] as? String == "data:image/png;base64,aGVsbG8=")
        #expect(imageURL["detail"] as? String == "high")
    }

    @Test func encode_imageURLPart_noDetail() throws {
        let part = OpenAIContentPart.imageURL(
            url: "https://example.com/image.png",
            detail: nil
        )

        let data = try JSONEncoder().encode(part)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let imageURL = json["image_url"] as! [String: Any]
        #expect(imageURL["url"] as? String == "https://example.com/image.png")
        #expect(imageURL["detail"] == nil)
    }

    @Test func decode_imageURLPart() throws {
        let json = """
        {
            "type": "image_url",
            "image_url": {
                "url": "https://example.com/test.jpg",
                "detail": "low"
            }
        }
        """

        let part = try JSONDecoder().decode(
            OpenAIContentPart.self,
            from: Data(json.utf8)
        )

        if case .imageURL(let url, let detail) = part {
            #expect(url == "https://example.com/test.jpg")
            #expect(detail == "low")
        } else {
            Issue.record("Expected image_url part")
        }
    }

    @Test func roundTrip_textPart() throws {
        let original = OpenAIContentPart.text("Test content")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenAIContentPart.self, from: data)

        if case .text(let text) = decoded {
            #expect(text == "Test content")
        } else {
            Issue.record("Expected text part")
        }
    }
}

// MARK: - OpenAIContent Tests

@Suite("OpenAIContent")
struct OpenAIContentTests {

    @Test func encode_textContent() throws {
        let content = OpenAIContent.text("Simple text")

        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(String.self, from: data)

        #expect(decoded == "Simple text")
    }

    @Test func decode_textContent() throws {
        let json = #""Just a string""#

        let content = try JSONDecoder().decode(
            OpenAIContent.self,
            from: Data(json.utf8)
        )

        if case .text(let text) = content {
            #expect(text == "Just a string")
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test func encode_partsContent() throws {
        let content = OpenAIContent.parts([
            .text("Look at this:"),
            .imageURL(url: "https://example.com/img.png", detail: nil)
        ])

        let data = try JSONEncoder().encode(content)
        let array = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

        #expect(array.count == 2)
        #expect(array[0]["type"] as? String == "text")
        #expect(array[1]["type"] as? String == "image_url")
    }

    @Test func decode_partsContent() throws {
        let json = """
        [
            {"type": "text", "text": "First"},
            {"type": "text", "text": "Second"}
        ]
        """

        let content = try JSONDecoder().decode(
            OpenAIContent.self,
            from: Data(json.utf8)
        )

        if case .parts(let parts) = content {
            #expect(parts.count == 2)
        } else {
            Issue.record("Expected parts content")
        }
    }
}

// MARK: - OpenAIMessage Tests

@Suite("OpenAIMessage")
struct OpenAIMessageTests {

    @Test func encode_systemMessage() throws {
        let message = OpenAIMessage(
            role: "system",
            content: .text("You are helpful.")
        )

        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["role"] as? String == "system")
        #expect(json["content"] as? String == "You are helpful.")
    }

    @Test func encode_userMessage_text() throws {
        let message = OpenAIMessage(
            role: "user",
            content: .text("Hello!")
        )

        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["role"] as? String == "user")
        #expect(json["content"] as? String == "Hello!")
    }

    @Test func encode_userMessage_multimodal() throws {
        let message = OpenAIMessage(
            role: "user",
            content: .parts([
                .text("What's in this image?"),
                .imageURL(url: "data:image/png;base64,abc", detail: nil)
            ])
        )

        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["role"] as? String == "user")
        let content = json["content"] as! [[String: Any]]
        #expect(content.count == 2)
    }

    @Test func encode_assistantMessage_withToolCalls() throws {
        let toolCall = OpenAIToolCall(
            id: "call_123",
            type: "function",
            function: OpenAIFunctionCall(name: "search", arguments: #"{"query":"swift"}"#)
        )

        let message = OpenAIMessage(
            role: "assistant",
            content: .text("Let me search for that."),
            tool_calls: [toolCall]
        )

        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["role"] as? String == "assistant")
        let toolCalls = json["tool_calls"] as! [[String: Any]]
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0]["id"] as? String == "call_123")
    }

    @Test func encode_toolResultMessage() throws {
        let message = OpenAIMessage(
            role: "tool",
            content: .text("Search result: Found 5 items"),
            tool_call_id: "call_123"
        )

        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["role"] as? String == "tool")
        #expect(json["content"] as? String == "Search result: Found 5 items")
        #expect(json["tool_call_id"] as? String == "call_123")
    }

    @Test func decode_assistantMessage() throws {
        let json = """
        {
            "role": "assistant",
            "content": "Hello! How can I help?",
            "tool_calls": null
        }
        """

        let message = try JSONDecoder().decode(
            OpenAIMessage.self,
            from: Data(json.utf8)
        )

        #expect(message.role == "assistant")
        if case .text(let content) = message.content {
            #expect(content == "Hello! How can I help?")
        } else {
            Issue.record("Expected text content")
        }
    }
}

// MARK: - OpenAIToolChoice Tests

@Suite("OpenAIToolChoice")
struct OpenAIToolChoiceTests {

    @Test func encode_auto() throws {
        let choice = OpenAIToolChoice.auto

        let data = try JSONEncoder().encode(choice)
        let str = String(data: data, encoding: .utf8)!

        #expect(str == "\"auto\"")
    }

    @Test func encode_none() throws {
        let choice = OpenAIToolChoice.none

        let data = try JSONEncoder().encode(choice)
        let str = String(data: data, encoding: .utf8)!

        #expect(str == "\"none\"")
    }

    @Test func encode_required() throws {
        let choice = OpenAIToolChoice.required

        let data = try JSONEncoder().encode(choice)
        let str = String(data: data, encoding: .utf8)!

        #expect(str == "\"required\"")
    }

    @Test func encode_function() throws {
        let choice = OpenAIToolChoice.function(name: "search")

        let data = try JSONEncoder().encode(choice)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "function")
        let function = json["function"] as! [String: Any]
        #expect(function["name"] as? String == "search")
    }
}

// MARK: - OpenAIResponseFormat Tests

@Suite("OpenAIResponseFormat")
struct OpenAIResponseFormatTests {

    @Test func encode_text() throws {
        let format = OpenAIResponseFormat.text

        let data = try JSONEncoder().encode(format)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "text")
    }

    @Test func encode_jsonObject() throws {
        let format = OpenAIResponseFormat.jsonObject

        let data = try JSONEncoder().encode(format)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "json_object")
    }

    @Test func encode_jsonSchema() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "name": ["type": "string"]
            ]
        ]
        let format = OpenAIResponseFormat.jsonSchema(name: "person", schema: schema, strict: true)

        let data = try JSONEncoder().encode(format)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "json_schema")
        let jsonSchema = json["json_schema"] as! [String: Any]
        #expect(jsonSchema["name"] as? String == "person")
        #expect(jsonSchema["strict"] as? Bool == true)
    }
}

// MARK: - OpenAIRequest Tests

@Suite("OpenAIRequest")
struct OpenAIRequestTests {

    @Test func encode_minimalRequest() throws {
        let request = OpenAIRequest(
            model: "gpt-4o-mini",
            messages: [
                OpenAIMessage(role: "user", content: .text("Hi"))
            ],
            max_tokens: nil,
            max_completion_tokens: nil,
            temperature: nil,
            stop: nil,
            tools: nil,
            tool_choice: nil,
            response_format: nil,
            stream: nil,
            stream_options: nil
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["model"] as? String == "gpt-4o-mini")
        #expect((json["messages"] as? [[String: Any]])?.count == 1)
        #expect(json["max_tokens"] == nil)
        #expect(json["tools"] == nil)
    }

    @Test func encode_fullRequest() throws {
        let tool = OpenAITool(
            function: OpenAIFunction(
                name: "search",
                description: "Search documents",
                parameters: ["type": "object"],
                strict: nil
            )
        )

        let request = OpenAIRequest(
            model: "gpt-4o",
            messages: [
                OpenAIMessage(role: "system", content: .text("Be helpful.")),
                OpenAIMessage(role: "user", content: .text("Search for Swift"))
            ],
            max_tokens: 4096,
            max_completion_tokens: nil,
            temperature: 0.7,
            stop: ["END", "STOP"],
            tools: [tool],
            tool_choice: .auto,
            response_format: nil,
            stream: false,
            stream_options: nil
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["model"] as? String == "gpt-4o")
        #expect((json["messages"] as? [[String: Any]])?.count == 2)
        #expect(json["max_tokens"] as? Int == 4096)
        #expect(json["temperature"] as? Double == 0.7)
        #expect(json["stop"] as? [String] == ["END", "STOP"])
        #expect((json["tools"] as? [[String: Any]])?.count == 1)
        #expect(json["tool_choice"] as? String == "auto")
    }

    @Test func encode_streamingRequest() throws {
        let request = OpenAIRequest(
            model: "gpt-4o",
            messages: [
                OpenAIMessage(role: "user", content: .text("Hi"))
            ],
            max_tokens: 1024,
            max_completion_tokens: nil,
            temperature: nil,
            stop: nil,
            tools: nil,
            tool_choice: nil,
            response_format: nil,
            stream: true,
            stream_options: OpenAIStreamOptions(include_usage: true)
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["stream"] as? Bool == true)
        let streamOptions = json["stream_options"] as! [String: Any]
        #expect(streamOptions["include_usage"] as? Bool == true)
    }

    @Test func encode_structuredOutputRequest() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "sentiment": ["type": "string", "enum": ["positive", "negative", "neutral"]],
                "confidence": ["type": "number"]
            ],
            "required": ["sentiment", "confidence"],
            "additionalProperties": false
        ]

        let request = OpenAIRequest(
            model: "gpt-4o-mini",
            messages: [
                OpenAIMessage(role: "user", content: .text("Analyze sentiment"))
            ],
            max_tokens: 100,
            max_completion_tokens: nil,
            temperature: nil,
            stop: nil,
            tools: nil,
            tool_choice: nil,
            response_format: .jsonSchema(name: "sentiment_analysis", schema: schema, strict: true),
            stream: nil,
            stream_options: nil
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Verify response_format structure
        let responseFormat = json["response_format"] as! [String: Any]
        #expect(responseFormat["type"] as? String == "json_schema")

        let jsonSchema = responseFormat["json_schema"] as! [String: Any]
        #expect(jsonSchema["name"] as? String == "sentiment_analysis")
        #expect(jsonSchema["strict"] as? Bool == true)

        // Verify schema is included
        let schemaObj = jsonSchema["schema"] as! [String: Any]
        #expect(schemaObj["type"] as? String == "object")
        #expect((schemaObj["required"] as? [String])?.contains("sentiment") == true)
    }
}

// MARK: - OpenAIResponse Tests

@Suite("OpenAIResponse")
struct OpenAIResponseTests {

    @Test func decode_textResponse() throws {
        let json = """
        {
            "id": "chatcmpl-123",
            "object": "chat.completion",
            "created": 1677652288,
            "model": "gpt-4o-mini",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "Hello! How can I help you today?"
                    },
                    "finish_reason": "stop"
                }
            ],
            "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 12,
                "total_tokens": 22
            }
        }
        """

        let response = try JSONDecoder().decode(
            OpenAIResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.id == "chatcmpl-123")
        #expect(response.model == "gpt-4o-mini")
        #expect(response.choices.count == 1)
        #expect(response.choices[0].message.content == "Hello! How can I help you today?")
        #expect(response.choices[0].finish_reason == "stop")
        #expect(response.usage?.prompt_tokens == 10)
        #expect(response.usage?.completion_tokens == 12)
    }

    @Test func decode_toolCallResponse() throws {
        let json = """
        {
            "id": "chatcmpl-456",
            "object": "chat.completion",
            "created": 1677652288,
            "model": "gpt-4o",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": null,
                        "tool_calls": [
                            {
                                "id": "call_abc",
                                "type": "function",
                                "function": {
                                    "name": "search",
                                    "arguments": "{\\"query\\": \\"swift concurrency\\"}"
                                }
                            }
                        ]
                    },
                    "finish_reason": "tool_calls"
                }
            ],
            "usage": {
                "prompt_tokens": 50,
                "completion_tokens": 30,
                "total_tokens": 80
            }
        }
        """

        let response = try JSONDecoder().decode(
            OpenAIResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.choices[0].finish_reason == "tool_calls")
        #expect(response.choices[0].message.tool_calls?.count == 1)

        let toolCall = response.choices[0].message.tool_calls![0]
        #expect(toolCall.id == "call_abc")
        #expect(toolCall.function.name == "search")
        #expect(toolCall.function.arguments.contains("swift concurrency"))
    }

    @Test func decode_stopReason_length() throws {
        let json = """
        {
            "id": "chatcmpl-truncated",
            "object": "chat.completion",
            "created": 1677652288,
            "model": "gpt-4o-mini",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "This is a long response that got cut"
                    },
                    "finish_reason": "length"
                }
            ],
            "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 100,
                "total_tokens": 110
            }
        }
        """

        let response = try JSONDecoder().decode(
            OpenAIResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.choices[0].finish_reason == "length")
    }

    @Test func decode_stopReason_contentFilter() throws {
        let json = """
        {
            "id": "chatcmpl-filtered",
            "object": "chat.completion",
            "created": 1677652288,
            "model": "gpt-4o-mini",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": ""
                    },
                    "finish_reason": "content_filter"
                }
            ],
            "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 0,
                "total_tokens": 10
            }
        }
        """

        let response = try JSONDecoder().decode(
            OpenAIResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.choices[0].finish_reason == "content_filter")
    }

    @Test func decode_multipleToolCalls() throws {
        let json = """
        {
            "id": "chatcmpl-multi",
            "object": "chat.completion",
            "created": 1677652288,
            "model": "gpt-4o",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "I'll check both for you.",
                        "tool_calls": [
                            {
                                "id": "call_1",
                                "type": "function",
                                "function": {"name": "get_weather", "arguments": "{\\"city\\": \\"NYC\\"}"}
                            },
                            {
                                "id": "call_2",
                                "type": "function",
                                "function": {"name": "get_weather", "arguments": "{\\"city\\": \\"LA\\"}"}
                            }
                        ]
                    },
                    "finish_reason": "tool_calls"
                }
            ],
            "usage": {
                "prompt_tokens": 60,
                "completion_tokens": 50,
                "total_tokens": 110
            }
        }
        """

        let response = try JSONDecoder().decode(
            OpenAIResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.choices[0].message.tool_calls?.count == 2)
        #expect(response.choices[0].message.content == "I'll check both for you.")
    }
}

// MARK: - OpenAIStreamChunk Tests

@Suite("OpenAIStreamChunk")
struct OpenAIStreamChunkTests {

    @Test func decode_contentDelta() throws {
        let json = """
        {
            "id": "chatcmpl-stream",
            "object": "chat.completion.chunk",
            "created": 1677652288,
            "model": "gpt-4o",
            "choices": [
                {
                    "index": 0,
                    "delta": {
                        "content": "Hello"
                    },
                    "finish_reason": null
                }
            ]
        }
        """

        let chunk = try JSONDecoder().decode(
            OpenAIStreamChunk.self,
            from: Data(json.utf8)
        )

        #expect(chunk.id == "chatcmpl-stream")
        #expect(chunk.choices[0].delta.content == "Hello")
        #expect(chunk.choices[0].finish_reason == nil)
    }

    @Test func decode_toolCallDelta_start() throws {
        let json = """
        {
            "id": "chatcmpl-stream",
            "object": "chat.completion.chunk",
            "created": 1677652288,
            "model": "gpt-4o",
            "choices": [
                {
                    "index": 0,
                    "delta": {
                        "tool_calls": [
                            {
                                "index": 0,
                                "id": "call_xyz",
                                "type": "function",
                                "function": {"name": "search"}
                            }
                        ]
                    },
                    "finish_reason": null
                }
            ]
        }
        """

        let chunk = try JSONDecoder().decode(
            OpenAIStreamChunk.self,
            from: Data(json.utf8)
        )

        let toolCall = chunk.choices[0].delta.tool_calls![0]
        #expect(toolCall.index == 0)
        #expect(toolCall.id == "call_xyz")
        #expect(toolCall.function?.name == "search")
    }

    @Test func decode_toolCallDelta_arguments() throws {
        let json = """
        {
            "id": "chatcmpl-stream",
            "object": "chat.completion.chunk",
            "created": 1677652288,
            "model": "gpt-4o",
            "choices": [
                {
                    "index": 0,
                    "delta": {
                        "tool_calls": [
                            {
                                "index": 0,
                                "function": {"arguments": "{\\"query\\""}
                            }
                        ]
                    },
                    "finish_reason": null
                }
            ]
        }
        """

        let chunk = try JSONDecoder().decode(
            OpenAIStreamChunk.self,
            from: Data(json.utf8)
        )

        let toolCall = chunk.choices[0].delta.tool_calls![0]
        #expect(toolCall.function?.arguments == #"{"query""#)
        #expect(toolCall.id == nil)  // Only in first chunk
    }

    @Test func decode_finishReason() throws {
        let json = """
        {
            "id": "chatcmpl-stream",
            "object": "chat.completion.chunk",
            "created": 1677652288,
            "model": "gpt-4o",
            "choices": [
                {
                    "index": 0,
                    "delta": {},
                    "finish_reason": "stop"
                }
            ]
        }
        """

        let chunk = try JSONDecoder().decode(
            OpenAIStreamChunk.self,
            from: Data(json.utf8)
        )

        #expect(chunk.choices[0].finish_reason == "stop")
    }

    @Test func decode_usageChunk() throws {
        let json = """
        {
            "id": "chatcmpl-stream",
            "object": "chat.completion.chunk",
            "created": 1677652288,
            "model": "gpt-4o",
            "choices": [],
            "usage": {
                "prompt_tokens": 20,
                "completion_tokens": 50,
                "total_tokens": 70
            }
        }
        """

        let chunk = try JSONDecoder().decode(
            OpenAIStreamChunk.self,
            from: Data(json.utf8)
        )

        #expect(chunk.usage?.prompt_tokens == 20)
        #expect(chunk.usage?.completion_tokens == 50)
    }
}

// MARK: - OpenAIError Tests

@Suite("OpenAIError")
struct OpenAIErrorTests {

    @Test func decode_error() throws {
        let json = """
        {
            "error": {
                "message": "Incorrect API key provided",
                "type": "invalid_request_error",
                "param": null,
                "code": "invalid_api_key"
            }
        }
        """

        let error = try JSONDecoder().decode(
            OpenAIError.self,
            from: Data(json.utf8)
        )

        #expect(error.error.message == "Incorrect API key provided")
        #expect(error.error.type == "invalid_request_error")
        #expect(error.error.code == "invalid_api_key")
    }

    @Test func decode_error_withParam() throws {
        let json = """
        {
            "error": {
                "message": "max_tokens must be greater than 0",
                "type": "invalid_request_error",
                "param": "max_tokens",
                "code": null
            }
        }
        """

        let error = try JSONDecoder().decode(
            OpenAIError.self,
            from: Data(json.utf8)
        )

        #expect(error.error.param == "max_tokens")
        #expect(error.error.code == nil)
    }
}

// MARK: - OpenAIModelsResponse Tests

@Suite("OpenAIModelsResponse")
struct OpenAIModelsResponseTests {

    @Test func decode_modelsResponse() throws {
        let json = """
        {
            "object": "list",
            "data": [
                {
                    "id": "gpt-4o",
                    "object": "model",
                    "created": 1706048358,
                    "owned_by": "openai"
                },
                {
                    "id": "gpt-4o-mini",
                    "object": "model",
                    "created": 1721172741,
                    "owned_by": "openai"
                }
            ]
        }
        """

        let response = try JSONDecoder().decode(
            OpenAIModelsResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.object == "list")
        #expect(response.data.count == 2)
        #expect(response.data[0].id == "gpt-4o")
        #expect(response.data[1].id == "gpt-4o-mini")
    }
}
