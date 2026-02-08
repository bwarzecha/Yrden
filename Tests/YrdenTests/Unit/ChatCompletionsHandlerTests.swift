/// Tests for ChatCompletionsHandler.
///
/// Test coverage:
/// - Request encoding with both MaxTokensParam configurations
/// - Request encoding with both ToolChoiceStrategy configurations
/// - Response decoding
/// - HTTP status handling

import Testing
import Foundation
@testable import Yrden

@Suite("ChatCompletionsHandler")
struct ChatCompletionsHandlerTests {

    // MARK: - Request Encoding

    @Test func encodeRequest_legacy_maxTokens() throws {
        let handler = ChatCompletionsHandler(
            maxTokensParam: .legacy,
            toolChoiceStrategy: .alwaysAuto,
            foreignThinkingBehavior: .drop,
            defaultMaxTokens: 2048,
            providerId: "local"
        )

        let request = CompletionRequest(messages: [.user("Hello")])
        let encoded = try handler.encodeRequest(request, modelName: "llama3.2", stream: false)

        #expect(encoded.max_tokens == 2048)
        #expect(encoded.max_completion_tokens == nil)
        #expect(encoded.model == "llama3.2")
    }

    @Test func encodeRequest_completionTokens_maxTokens() throws {
        let handler = ChatCompletionsHandler(
            maxTokensParam: .completionTokens,
            toolChoiceStrategy: .alwaysAuto,
            foreignThinkingBehavior: .drop,
            defaultMaxTokens: 4096,
            providerId: "openai"
        )

        let request = CompletionRequest(messages: [.user("Hello")])
        let encoded = try handler.encodeRequest(request, modelName: "gpt-5", stream: false)

        #expect(encoded.max_tokens == nil)
        #expect(encoded.max_completion_tokens == 4096)
    }

    @Test func encodeRequest_alwaysAuto_toolChoice() throws {
        let handler = ChatCompletionsHandler(
            maxTokensParam: .legacy,
            toolChoiceStrategy: .alwaysAuto,
            foreignThinkingBehavior: .drop,
            defaultMaxTokens: 2048,
            providerId: "local"
        )

        let tool = ToolDefinition(
            name: "search",
            description: "Search docs",
            inputSchema: ["type": "object"]
        )
        let request = CompletionRequest(
            messages: [.user("Search for Swift")],
            tools: [tool]
        )
        let encoded = try handler.encodeRequest(request, modelName: "llama3.2", stream: false)

        // alwaysAuto should use auto even on first turn
        let data = try JSONEncoder().encode(encoded.tool_choice)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "\"auto\"")
    }

    @Test func encodeRequest_requiredFirstTurn_toolChoice_noToolResults() throws {
        let handler = ChatCompletionsHandler(
            maxTokensParam: .completionTokens,
            toolChoiceStrategy: .requiredFirstTurn,
            foreignThinkingBehavior: .drop,
            defaultMaxTokens: 4096,
            providerId: "openai"
        )

        let tool = ToolDefinition(
            name: "search",
            description: "Search docs",
            inputSchema: ["type": "object"]
        )
        let request = CompletionRequest(
            messages: [.user("Search for Swift")],
            tools: [tool]
        )
        let encoded = try handler.encodeRequest(request, modelName: "gpt-4o", stream: false)

        // First turn (no tool results) should use "required"
        let data = try JSONEncoder().encode(encoded.tool_choice)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "\"required\"")
    }

    @Test func encodeRequest_requiredFirstTurn_toolChoice_withToolResults() throws {
        let handler = ChatCompletionsHandler(
            maxTokensParam: .completionTokens,
            toolChoiceStrategy: .requiredFirstTurn,
            foreignThinkingBehavior: .drop,
            defaultMaxTokens: 4096,
            providerId: "openai"
        )

        let tool = ToolDefinition(
            name: "search",
            description: "Search docs",
            inputSchema: ["type": "object"]
        )
        let request = CompletionRequest(
            messages: [
                .user("Search for Swift"),
                .assistant([.toolUse(ToolCall(id: "call_1", name: "search", arguments: "{}"))]),
                .toolResult(toolCallId: "call_1", content: "Found results"),
            ],
            tools: [tool]
        )
        let encoded = try handler.encodeRequest(request, modelName: "gpt-4o", stream: false)

        // Subsequent turn (has tool results) should use "auto"
        let data = try JSONEncoder().encode(encoded.tool_choice)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "\"auto\"")
    }

    @Test func encodeRequest_noTools_noToolChoice() throws {
        let handler = ChatCompletionsHandler(
            maxTokensParam: .legacy,
            toolChoiceStrategy: .requiredFirstTurn,
            foreignThinkingBehavior: .drop,
            defaultMaxTokens: 2048,
            providerId: "local"
        )

        let request = CompletionRequest(messages: [.user("Hello")])
        let encoded = try handler.encodeRequest(request, modelName: "llama3.2", stream: false)

        #expect(encoded.tool_choice == nil)
        #expect(encoded.tools == nil)
    }

    @Test func encodeRequest_streaming() throws {
        let handler = ChatCompletionsHandler(
            maxTokensParam: .legacy,
            toolChoiceStrategy: .alwaysAuto,
            foreignThinkingBehavior: .drop,
            defaultMaxTokens: 2048,
            providerId: "local"
        )

        let request = CompletionRequest(messages: [.user("Hello")])
        let encoded = try handler.encodeRequest(request, modelName: "llama3.2", stream: true)

        #expect(encoded.stream == true)
        #expect(encoded.stream_options?.include_usage == true)
    }

    @Test func encodeRequest_notStreaming() throws {
        let handler = ChatCompletionsHandler(
            maxTokensParam: .legacy,
            toolChoiceStrategy: .alwaysAuto,
            foreignThinkingBehavior: .drop,
            defaultMaxTokens: 2048,
            providerId: "local"
        )

        let request = CompletionRequest(messages: [.user("Hello")])
        let encoded = try handler.encodeRequest(request, modelName: "llama3.2", stream: false)

        #expect(encoded.stream == nil)
        #expect(encoded.stream_options == nil)
    }

    // MARK: - Response Decoding

    @Test func decodeResponse_textResponse() throws {
        let handler = ChatCompletionsHandler(
            maxTokensParam: .legacy,
            toolChoiceStrategy: .alwaysAuto,
            foreignThinkingBehavior: .drop,
            defaultMaxTokens: 2048,
            providerId: "local"
        )

        let json = """
        {
            "id": "chatcmpl-123",
            "object": "chat.completion",
            "created": 1677652288,
            "model": "llama3.2",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "Hello!"},
                "finish_reason": "stop"
            }],
            "usage": {"prompt_tokens": 5, "completion_tokens": 3, "total_tokens": 8}
        }
        """

        let response = try handler.decodeResponse(Data(json.utf8))

        #expect(response.contentBlocks.count == 1)
        if case .text(let text) = response.contentBlocks[0] {
            #expect(text == "Hello!")
        } else {
            Issue.record("Expected text block")
        }
        #expect(response.stopReason == .endTurn)
        #expect(response.usage.inputTokens == 5)
        #expect(response.usage.outputTokens == 3)
    }

    @Test func decodeResponse_toolCallResponse() throws {
        let handler = ChatCompletionsHandler(
            maxTokensParam: .legacy,
            toolChoiceStrategy: .alwaysAuto,
            foreignThinkingBehavior: .drop,
            defaultMaxTokens: 2048,
            providerId: "local"
        )

        let json = """
        {
            "id": "chatcmpl-456",
            "object": "chat.completion",
            "created": 1677652288,
            "model": "llama3.2",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": null,
                    "tool_calls": [{
                        "id": "call_abc",
                        "type": "function",
                        "function": {"name": "search", "arguments": "{\\"q\\": \\"swift\\"}"}
                    }]
                },
                "finish_reason": "tool_calls"
            }],
            "usage": {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30}
        }
        """

        let response = try handler.decodeResponse(Data(json.utf8))

        #expect(response.contentBlocks.count == 1)
        if case .toolUse(let call) = response.contentBlocks[0] {
            #expect(call.id == "call_abc")
            #expect(call.name == "search")
            #expect(call.arguments == #"{"q": "swift"}"#)
        } else {
            Issue.record("Expected toolUse block")
        }
        #expect(response.stopReason == .toolUse)
    }

    // MARK: - HTTP Status Handling

    @Test func handleHTTPStatus_success() throws {
        let handler = ChatCompletionsHandler(
            maxTokensParam: .legacy,
            toolChoiceStrategy: .alwaysAuto,
            foreignThinkingBehavior: .drop,
            defaultMaxTokens: 2048,
            providerId: "local"
        )

        // Should not throw for 200
        try handler.handleHTTPStatus(200, data: Data(), modelName: "test", maxContextTokens: nil)
    }

    @Test func handleHTTPStatus_unauthorized() throws {
        let handler = ChatCompletionsHandler(
            maxTokensParam: .legacy,
            toolChoiceStrategy: .alwaysAuto,
            foreignThinkingBehavior: .drop,
            defaultMaxTokens: 2048,
            providerId: "local"
        )

        #expect(throws: LLMError.self) {
            try handler.handleHTTPStatus(401, data: Data(), modelName: "test", maxContextTokens: nil)
        }
    }

    @Test func handleHTTPStatus_notFound() throws {
        let handler = ChatCompletionsHandler(
            maxTokensParam: .legacy,
            toolChoiceStrategy: .alwaysAuto,
            foreignThinkingBehavior: .drop,
            defaultMaxTokens: 2048,
            providerId: "local"
        )

        #expect(throws: LLMError.self) {
            try handler.handleHTTPStatus(404, data: Data(), modelName: "my-model", maxContextTokens: nil)
        }
    }

    // MARK: - Utility

    @Test func requestHasToolResults_withToolResult() {
        let request = CompletionRequest(messages: [
            .user("Hello"),
            .assistant([.toolUse(ToolCall(id: "call_1", name: "search", arguments: "{}"))]),
            .toolResult(toolCallId: "call_1", content: "result"),
        ])

        #expect(ChatCompletionsHandler.requestHasToolResults(request) == true)
    }

    @Test func requestHasToolResults_withoutToolResult() {
        let request = CompletionRequest(messages: [.user("Hello")])

        #expect(ChatCompletionsHandler.requestHasToolResults(request) == false)
    }
}
