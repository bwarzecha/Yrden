/// Tests for Anthropic wire format types.
///
/// Test coverage:
/// - AnthropicContentBlock encoding/decoding
/// - AnthropicMessage encoding/decoding
/// - AnthropicRequest encoding
/// - AnthropicResponse decoding
/// - SSE event parsing

import Testing
import Foundation
@testable import Yrden

// MARK: - AnthropicContentBlock Tests

@Suite("AnthropicContentBlock")
struct AnthropicContentBlockTests {

    // MARK: - Text Block

    @Test func encode_textBlock() throws {
        let block = AnthropicContentBlock.text("Hello, world!")

        let data = try JSONEncoder().encode(block)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "text")
        #expect(json["text"] as? String == "Hello, world!")
    }

    @Test func decode_textBlock() throws {
        let json = #"{"type": "text", "text": "Hello"}"#

        let block = try JSONDecoder().decode(
            AnthropicContentBlock.self,
            from: Data(json.utf8)
        )

        if case .text(let text) = block {
            #expect(text == "Hello")
        } else {
            Issue.record("Expected text block")
        }
    }

    // MARK: - Image Block

    @Test func encode_imageBlock() throws {
        let block = AnthropicContentBlock.image(base64: "aGVsbG8=", mediaType: "image/png")

        let data = try JSONEncoder().encode(block)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "image")
        let source = json["source"] as! [String: Any]
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == "aGVsbG8=")
    }

    @Test func decode_imageBlock() throws {
        let json = """
        {
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": "image/jpeg",
                "data": "dGVzdA=="
            }
        }
        """

        let block = try JSONDecoder().decode(
            AnthropicContentBlock.self,
            from: Data(json.utf8)
        )

        if case .image(let base64, let mediaType) = block {
            #expect(base64 == "dGVzdA==")
            #expect(mediaType == "image/jpeg")
        } else {
            Issue.record("Expected image block")
        }
    }

    // MARK: - Tool Use Block

    @Test func encode_toolUseBlock() throws {
        let input: JSONValue = ["query": "swift"]
        let block = AnthropicContentBlock.toolUse(id: "call_123", name: "search", input: input)

        let data = try JSONEncoder().encode(block)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "tool_use")
        #expect(json["id"] as? String == "call_123")
        #expect(json["name"] as? String == "search")
        let inputJson = json["input"] as! [String: Any]
        #expect(inputJson["query"] as? String == "swift")
    }

    @Test func decode_toolUseBlock() throws {
        let json = """
        {
            "type": "tool_use",
            "id": "tu_123",
            "name": "calculator",
            "input": {"expression": "2+2"}
        }
        """

        let block = try JSONDecoder().decode(
            AnthropicContentBlock.self,
            from: Data(json.utf8)
        )

        if case .toolUse(let id, let name, let input) = block {
            #expect(id == "tu_123")
            #expect(name == "calculator")
            #expect(input == ["expression": "2+2"])
        } else {
            Issue.record("Expected tool_use block")
        }
    }

    // MARK: - Tool Result Block

    @Test func encode_toolResultBlock() throws {
        let block = AnthropicContentBlock.toolResult(
            toolUseId: "call_123",
            content: "Result: 4",
            isError: nil
        )

        let data = try JSONEncoder().encode(block)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "tool_result")
        #expect(json["tool_use_id"] as? String == "call_123")
        #expect(json["content"] as? String == "Result: 4")
    }

    @Test func encode_toolResultBlock_withError() throws {
        let block = AnthropicContentBlock.toolResult(
            toolUseId: "call_456",
            content: "Error: not found",
            isError: true
        )

        let data = try JSONEncoder().encode(block)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["is_error"] as? Bool == true)
    }

    @Test func decode_toolResultBlock() throws {
        let json = """
        {
            "type": "tool_result",
            "tool_use_id": "tu_789",
            "content": "Success"
        }
        """

        let block = try JSONDecoder().decode(
            AnthropicContentBlock.self,
            from: Data(json.utf8)
        )

        if case .toolResult(let toolUseId, let content, let isError) = block {
            #expect(toolUseId == "tu_789")
            #expect(content == "Success")
            #expect(isError == nil)
        } else {
            Issue.record("Expected tool_result block")
        }
    }
}

// MARK: - AnthropicMessage Tests

@Suite("AnthropicMessage")
struct AnthropicMessageTests {

    @Test func encode_userMessage() throws {
        let message = AnthropicMessage(
            role: "user",
            content: [.text("Hello")]
        )

        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["role"] as? String == "user")
        let content = json["content"] as! [[String: Any]]
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "text")
    }

    @Test func decode_assistantMessage() throws {
        let json = """
        {
            "role": "assistant",
            "content": [
                {"type": "text", "text": "Let me help you."},
                {"type": "tool_use", "id": "1", "name": "search", "input": {}}
            ]
        }
        """

        let message = try JSONDecoder().decode(
            AnthropicMessage.self,
            from: Data(json.utf8)
        )

        #expect(message.role == "assistant")
        #expect(message.content.count == 2)
    }

    @Test func roundTrip_multimodalMessage() throws {
        let message = AnthropicMessage(
            role: "user",
            content: [
                .text("What's in this image?"),
                .image(base64: "abc123", mediaType: "image/png")
            ]
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(AnthropicMessage.self, from: data)

        #expect(decoded.role == message.role)
        #expect(decoded.content.count == 2)

        if case .text(let text) = decoded.content[0] {
            #expect(text == "What's in this image?")
        } else {
            Issue.record("Expected text block at index 0")
        }

        if case .image(let base64, let mediaType) = decoded.content[1] {
            #expect(base64 == "abc123")
            #expect(mediaType == "image/png")
        } else {
            Issue.record("Expected image block at index 1")
        }
    }
}

// MARK: - AnthropicRequest Tests

@Suite("AnthropicRequest")
struct AnthropicRequestTests {

    @Test func encode_minimalRequest() throws {
        let request = AnthropicRequest(
            model: "claude-3-haiku-20240307",
            max_tokens: 1024,
            messages: [
                AnthropicMessage(role: "user", content: [.text("Hi")])
            ],
            system: nil,
            tools: nil,
            temperature: nil,
            stop_sequences: nil,
            stream: nil
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["model"] as? String == "claude-3-haiku-20240307")
        #expect(json["max_tokens"] as? Int == 1024)
        #expect((json["messages"] as? [[String: Any]])?.count == 1)
        #expect(json["system"] == nil)
        #expect(json["tools"] == nil)
    }

    @Test func encode_fullRequest() throws {
        let tool = AnthropicTool(
            name: "search",
            description: "Search documents",
            input_schema: ["type": "object"]
        )

        let request = AnthropicRequest(
            model: "claude-3-5-sonnet-20241022",
            max_tokens: 4096,
            messages: [
                AnthropicMessage(role: "user", content: [.text("Search for Swift")])
            ],
            system: "You are helpful.",
            tools: [tool],
            temperature: 0.7,
            stop_sequences: ["END"],
            stream: true
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["system"] as? String == "You are helpful.")
        #expect((json["tools"] as? [[String: Any]])?.count == 1)
        #expect(json["temperature"] as? Double == 0.7)
        #expect(json["stop_sequences"] as? [String] == ["END"])
        #expect(json["stream"] as? Bool == true)
    }
}

// MARK: - AnthropicResponse Tests

@Suite("AnthropicResponse")
struct AnthropicResponseTests {

    @Test func decode_textResponse() throws {
        let json = """
        {
            "id": "msg_123",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "text", "text": "Hello, how can I help you?"}
            ],
            "model": "claude-3-haiku-20240307",
            "stop_reason": "end_turn",
            "stop_sequence": null,
            "usage": {
                "input_tokens": 10,
                "output_tokens": 20
            }
        }
        """

        let response = try JSONDecoder().decode(
            AnthropicResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.id == "msg_123")
        #expect(response.role == "assistant")
        #expect(response.content.count == 1)
        #expect(response.content[0].type == "text")
        #expect(response.content[0].text == "Hello, how can I help you?")
        #expect(response.stop_reason == "end_turn")
        #expect(response.usage.input_tokens == 10)
        #expect(response.usage.output_tokens == 20)
    }

    @Test func decode_toolUseResponse() throws {
        let json = """
        {
            "id": "msg_456",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "text", "text": "Let me search for that."},
                {
                    "type": "tool_use",
                    "id": "tu_123",
                    "name": "search",
                    "input": {"query": "swift concurrency"}
                }
            ],
            "model": "claude-3-5-sonnet-20241022",
            "stop_reason": "tool_use",
            "stop_sequence": null,
            "usage": {
                "input_tokens": 50,
                "output_tokens": 30
            }
        }
        """

        let response = try JSONDecoder().decode(
            AnthropicResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.content.count == 2)
        #expect(response.content[0].type == "text")
        #expect(response.content[1].type == "tool_use")
        #expect(response.content[1].id == "tu_123")
        #expect(response.content[1].name == "search")
        #expect(response.stop_reason == "tool_use")
    }

    @Test func decode_stopSequenceResponse() throws {
        let json = """
        {
            "id": "msg_789",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "text", "text": "1, 2, 3, 4"}
            ],
            "model": "claude-3-haiku-20240307",
            "stop_reason": "stop_sequence",
            "stop_sequence": "5",
            "usage": {
                "input_tokens": 15,
                "output_tokens": 8
            }
        }
        """

        let response = try JSONDecoder().decode(
            AnthropicResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.stop_reason == "stop_sequence")
        #expect(response.stop_sequence == "5")
        #expect(response.content[0].text == "1, 2, 3, 4")
    }

    @Test func decode_maxTokensResponse() throws {
        let json = """
        {
            "id": "msg_truncated",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "text", "text": "This response was cut"}
            ],
            "model": "claude-3-haiku-20240307",
            "stop_reason": "max_tokens",
            "stop_sequence": null,
            "usage": {
                "input_tokens": 10,
                "output_tokens": 100
            }
        }
        """

        let response = try JSONDecoder().decode(
            AnthropicResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.stop_reason == "max_tokens")
        #expect(response.stop_sequence == nil)
    }
}

// MARK: - SSE Event Parsing Tests

@Suite("AnthropicSSEEvent")
struct AnthropicSSEEventTests {

    @Test func parse_messageStart() throws {
        let data = """
        {
            "message": {
                "id": "msg_1",
                "type": "message",
                "role": "assistant",
                "content": [],
                "model": "claude-3-haiku-20240307",
                "stop_reason": null,
                "stop_sequence": null,
                "usage": {"input_tokens": 10, "output_tokens": 0}
            }
        }
        """

        let event = AnthropicSSEEvent(event: "message_start", data: data)
        let parsed = try event.parse()

        if case .messageStart(let response) = parsed {
            #expect(response.id == "msg_1")
            #expect(response.usage.input_tokens == 10)
        } else {
            Issue.record("Expected messageStart event")
        }
    }

    @Test func parse_contentBlockStart_text() throws {
        let data = """
        {"index": 0, "content_block": {"type": "text", "text": ""}}
        """

        let event = AnthropicSSEEvent(event: "content_block_start", data: data)
        let parsed = try event.parse()

        if case .contentBlockStart(let index, let block) = parsed {
            #expect(index == 0)
            #expect(block.type == "text")
        } else {
            Issue.record("Expected contentBlockStart event")
        }
    }

    @Test func parse_contentBlockStart_toolUse() throws {
        let data = """
        {
            "index": 1,
            "content_block": {
                "type": "tool_use",
                "id": "tu_abc",
                "name": "search",
                "input": {}
            }
        }
        """

        let event = AnthropicSSEEvent(event: "content_block_start", data: data)
        let parsed = try event.parse()

        if case .contentBlockStart(let index, let block) = parsed {
            #expect(index == 1)
            #expect(block.type == "tool_use")
            #expect(block.id == "tu_abc")
            #expect(block.name == "search")
        } else {
            Issue.record("Expected contentBlockStart event")
        }
    }

    @Test func parse_contentBlockDelta_text() throws {
        let data = """
        {"index": 0, "delta": {"type": "text_delta", "text": "Hello"}}
        """

        let event = AnthropicSSEEvent(event: "content_block_delta", data: data)
        let parsed = try event.parse()

        if case .contentBlockDelta(let index, let delta) = parsed {
            #expect(index == 0)
            if case .textDelta(let text) = delta {
                #expect(text == "Hello")
            } else {
                Issue.record("Expected text delta")
            }
        } else {
            Issue.record("Expected contentBlockDelta event")
        }
    }

    @Test func parse_contentBlockDelta_inputJson() throws {
        let data = """
        {"index": 1, "delta": {"type": "input_json_delta", "partial_json": "{\\"query\\""}}
        """

        let event = AnthropicSSEEvent(event: "content_block_delta", data: data)
        let parsed = try event.parse()

        if case .contentBlockDelta(let index, let delta) = parsed {
            #expect(index == 1)
            if case .inputJsonDelta(let json) = delta {
                #expect(json == #"{"query""#)
            } else {
                Issue.record("Expected input_json delta")
            }
        } else {
            Issue.record("Expected contentBlockDelta event")
        }
    }

    @Test func parse_contentBlockStop() throws {
        let data = """
        {"index": 0}
        """

        let event = AnthropicSSEEvent(event: "content_block_stop", data: data)
        let parsed = try event.parse()

        if case .contentBlockStop(let index) = parsed {
            #expect(index == 0)
        } else {
            Issue.record("Expected contentBlockStop event")
        }
    }

    @Test func parse_messageDelta() throws {
        let data = """
        {
            "delta": {"stop_reason": "end_turn", "stop_sequence": null},
            "usage": {"output_tokens": 15}
        }
        """

        let event = AnthropicSSEEvent(event: "message_delta", data: data)
        let parsed = try event.parse()

        if case .messageDelta(let delta, let usage) = parsed {
            #expect(delta.stop_reason == "end_turn")
            #expect(usage.output_tokens == 15)
        } else {
            Issue.record("Expected messageDelta event")
        }
    }

    @Test func parse_messageStop() throws {
        let event = AnthropicSSEEvent(event: "message_stop", data: "{}")
        let parsed = try event.parse()

        if case .messageStop = parsed {
            // Success
        } else {
            Issue.record("Expected messageStop event")
        }
    }

    @Test func parse_ping() throws {
        let event = AnthropicSSEEvent(event: "ping", data: "{}")
        let parsed = try event.parse()

        if case .ping = parsed {
            // Success
        } else {
            Issue.record("Expected ping event")
        }
    }

    @Test func parse_error() throws {
        let data = """
        {"error": {"type": "invalid_request", "message": "Bad request"}}
        """

        let event = AnthropicSSEEvent(event: "error", data: data)
        let parsed = try event.parse()

        if case .error(let message) = parsed {
            #expect(message == "Bad request")
        } else {
            Issue.record("Expected error event")
        }
    }
}

// MARK: - AnthropicError Tests

@Suite("AnthropicError")
struct AnthropicErrorTests {

    @Test func decode_error() throws {
        let json = """
        {
            "type": "error",
            "error": {
                "type": "invalid_request_error",
                "message": "max_tokens must be greater than 0"
            }
        }
        """

        let error = try JSONDecoder().decode(
            AnthropicError.self,
            from: Data(json.utf8)
        )

        #expect(error.type == "error")
        #expect(error.error.type == "invalid_request_error")
        #expect(error.error.message == "max_tokens must be greater than 0")
    }
}
