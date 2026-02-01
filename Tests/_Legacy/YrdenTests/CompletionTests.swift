/// Tests for Completion types: CompletionConfig, CompletionRequest, CompletionResponse, StopReason, Usage.
///
/// Test coverage:
/// - Codable round-trip for all types
/// - Default values and convenience constructors
/// - Equatable/Hashable behavior

import Testing
import Foundation
@testable import Yrden

// MARK: - CompletionConfig Tests

@Suite("CompletionConfig")
struct CompletionConfigTests {

    // MARK: - Codable Round-Trip

    @Test func roundTrip_allParameters() throws {
        let config = CompletionConfig(
            temperature: 0.7,
            maxTokens: 1000,
            stopSequences: ["END", "STOP"]
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CompletionConfig.self, from: data)

        #expect(decoded == config)
        #expect(decoded.temperature == 0.7)
        #expect(decoded.maxTokens == 1000)
        #expect(decoded.stopSequences == ["END", "STOP"])
    }

    @Test func roundTrip_nilParameters() throws {
        let config = CompletionConfig()

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CompletionConfig.self, from: data)

        #expect(decoded == config)
        #expect(decoded.temperature == nil)
        #expect(decoded.maxTokens == nil)
        #expect(decoded.stopSequences == nil)
    }

    @Test func roundTrip_partialParameters() throws {
        let config = CompletionConfig(temperature: 0.5)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CompletionConfig.self, from: data)

        #expect(decoded == config)
        #expect(decoded.temperature == 0.5)
        #expect(decoded.maxTokens == nil)
    }

    // MARK: - Default

    @Test func default_allNil() {
        let config = CompletionConfig.default

        #expect(config.temperature == nil)
        #expect(config.maxTokens == nil)
        #expect(config.stopSequences == nil)
    }

    // MARK: - Equatable

    @Test func equatable_sameValues() {
        let config1 = CompletionConfig(temperature: 0.7, maxTokens: 100)
        let config2 = CompletionConfig(temperature: 0.7, maxTokens: 100)

        #expect(config1 == config2)
    }

    @Test func equatable_differentValues() {
        let config1 = CompletionConfig(temperature: 0.7)
        let config2 = CompletionConfig(temperature: 0.8)

        #expect(config1 != config2)
    }

    // MARK: - Hashable

    @Test func hashable_inSet() {
        let configs: Set<CompletionConfig> = [
            CompletionConfig(temperature: 0.5),
            CompletionConfig(temperature: 0.5),  // duplicate
            CompletionConfig(temperature: 0.7)
        ]

        #expect(configs.count == 2)
    }
}

// MARK: - CompletionRequest Tests

@Suite("CompletionRequest")
struct CompletionRequestTests {

    // MARK: - Codable Round-Trip

    @Test func roundTrip_minimal() throws {
        let request = CompletionRequest(
            messages: [.user("Hello")]
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CompletionRequest.self, from: data)

        #expect(decoded == request)
        #expect(decoded.messages.count == 1)
        #expect(decoded.tools == nil)
        #expect(decoded.outputSchema == nil)
    }

    @Test func roundTrip_withTools() throws {
        let tool = ToolDefinition(
            name: "search",
            description: "Search documents",
            inputSchema: ["type": "object"]
        )
        let request = CompletionRequest(
            messages: [.user("Search for Swift docs")],
            tools: [tool]
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CompletionRequest.self, from: data)

        #expect(decoded == request)
        #expect(decoded.tools?.count == 1)
        #expect(decoded.tools?.first?.name == "search")
    }

    @Test func roundTrip_withOutputSchema() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "score": ["type": "number"]
            ],
            "required": ["summary", "score"]
        ]
        let request = CompletionRequest(
            messages: [.user("Analyze this")],
            outputSchema: schema
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CompletionRequest.self, from: data)

        #expect(decoded == request)
        #expect(decoded.outputSchema != nil)
    }

    @Test func roundTrip_withConfig() throws {
        let request = CompletionRequest(
            messages: [.user("Generate creatively")],
            config: CompletionConfig(temperature: 1.0, maxTokens: 500)
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CompletionRequest.self, from: data)

        #expect(decoded == request)
        #expect(decoded.config.temperature == 1.0)
        #expect(decoded.config.maxTokens == 500)
    }

    @Test func roundTrip_fullConversation() throws {
        let request = CompletionRequest(
            messages: [
                .system("You are helpful."),
                .user("Hello"),
                .assistant("Hi there!"),
                .user("How are you?")
            ],
            tools: [
                ToolDefinition(name: "mood", description: "Get mood", inputSchema: .null)
            ],
            config: CompletionConfig(temperature: 0.5)
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CompletionRequest.self, from: data)

        #expect(decoded == request)
        #expect(decoded.messages.count == 4)
    }

    // MARK: - Equatable

    @Test func equatable_sameMessages() {
        let req1 = CompletionRequest(messages: [.user("Hi")])
        let req2 = CompletionRequest(messages: [.user("Hi")])

        #expect(req1 == req2)
    }

    @Test func equatable_differentTools() {
        let req1 = CompletionRequest(messages: [.user("Hi")], tools: nil)
        let req2 = CompletionRequest(messages: [.user("Hi")], tools: [])

        #expect(req1 != req2)
    }
}

// MARK: - StopReason Tests

@Suite("StopReason")
struct StopReasonTests {

    @Test func codable_endTurn() throws {
        let reason = StopReason.endTurn

        let data = try JSONEncoder().encode(reason)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"end_turn\"")

        let decoded = try JSONDecoder().decode(StopReason.self, from: data)
        #expect(decoded == reason)
    }

    @Test func codable_toolUse() throws {
        let reason = StopReason.toolUse

        let data = try JSONEncoder().encode(reason)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"tool_use\"")
    }

    @Test func codable_maxTokens() throws {
        let reason = StopReason.maxTokens

        let data = try JSONEncoder().encode(reason)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"max_tokens\"")
    }

    @Test func codable_stopSequence() throws {
        let reason = StopReason.stopSequence

        let data = try JSONEncoder().encode(reason)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"stop_sequence\"")
    }

    @Test func codable_contentFiltered() throws {
        let reason = StopReason.contentFiltered

        let data = try JSONEncoder().encode(reason)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"content_filtered\"")
    }

    @Test func hashable_inSet() {
        let reasons: Set<StopReason> = [
            .endTurn,
            .endTurn,  // duplicate
            .toolUse,
            .maxTokens
        ]

        #expect(reasons.count == 3)
    }
}

// MARK: - Usage Tests

@Suite("Usage")
struct UsageTests {

    @Test func roundTrip_basic() throws {
        let usage = Usage(inputTokens: 100, outputTokens: 50)

        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(Usage.self, from: data)

        #expect(decoded == usage)
        #expect(decoded.inputTokens == 100)
        #expect(decoded.outputTokens == 50)
    }

    @Test func totalTokens_computed() {
        let usage = Usage(inputTokens: 100, outputTokens: 50)
        #expect(usage.totalTokens == 150)
    }

    @Test func totalTokens_zero() {
        let usage = Usage(inputTokens: 0, outputTokens: 0)
        #expect(usage.totalTokens == 0)
    }

    @Test func equatable_sameValues() {
        let usage1 = Usage(inputTokens: 100, outputTokens: 50)
        let usage2 = Usage(inputTokens: 100, outputTokens: 50)

        #expect(usage1 == usage2)
    }

    @Test func equatable_differentValues() {
        let usage1 = Usage(inputTokens: 100, outputTokens: 50)
        let usage2 = Usage(inputTokens: 100, outputTokens: 51)

        #expect(usage1 != usage2)
    }

    @Test func hashable_inSet() {
        let usages: Set<Usage> = [
            Usage(inputTokens: 100, outputTokens: 50),
            Usage(inputTokens: 100, outputTokens: 50),  // duplicate
            Usage(inputTokens: 200, outputTokens: 100)
        ]

        #expect(usages.count == 2)
    }
}

// MARK: - CompletionResponse Tests

@Suite("CompletionResponse")
struct CompletionResponseTests {

    // MARK: - Codable Round-Trip

    @Test func roundTrip_textOnly() throws {
        let response = CompletionResponse(
            content: "Hello, world!",
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 5)
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(CompletionResponse.self, from: data)

        #expect(decoded == response)
        #expect(decoded.content == "Hello, world!")
        #expect(decoded.toolCalls.isEmpty)
    }

    @Test func roundTrip_toolCallsOnly() throws {
        let response = CompletionResponse(
            content: nil,
            toolCalls: [
                ToolCall(id: "1", name: "search", arguments: "{}")
            ],
            stopReason: .toolUse,
            usage: Usage(inputTokens: 20, outputTokens: 15)
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(CompletionResponse.self, from: data)

        #expect(decoded == response)
        #expect(decoded.content == nil)
        #expect(decoded.toolCalls.count == 1)
    }

    @Test func roundTrip_mixed() throws {
        let response = CompletionResponse(
            content: "Let me search for that.",
            toolCalls: [
                ToolCall(id: "1", name: "search", arguments: #"{"query":"swift"}"#)
            ],
            stopReason: .toolUse,
            usage: Usage(inputTokens: 50, outputTokens: 30)
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(CompletionResponse.self, from: data)

        #expect(decoded == response)
    }

    @Test func roundTrip_multipleToolCalls() throws {
        let response = CompletionResponse(
            content: "",
            toolCalls: [
                ToolCall(id: "1", name: "search", arguments: "{}"),
                ToolCall(id: "2", name: "calculate", arguments: "{}"),
                ToolCall(id: "3", name: "fetch", arguments: "{}")
            ],
            stopReason: .toolUse,
            usage: Usage(inputTokens: 100, outputTokens: 80)
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(CompletionResponse.self, from: data)

        #expect(decoded == response)
        #expect(decoded.toolCalls.count == 3)
    }

    @Test func roundTrip_maxTokens() throws {
        let response = CompletionResponse(
            content: "This response was truncated because...",
            toolCalls: [],
            stopReason: .maxTokens,
            usage: Usage(inputTokens: 1000, outputTokens: 4096)
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(CompletionResponse.self, from: data)

        #expect(decoded == response)
        #expect(decoded.stopReason == .maxTokens)
    }

    // MARK: - Equatable

    @Test func equatable_sameValues() {
        let response1 = CompletionResponse(
            content: "Hi",
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 1, outputTokens: 1)
        )
        let response2 = CompletionResponse(
            content: "Hi",
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 1, outputTokens: 1)
        )

        #expect(response1 == response2)
    }

    @Test func equatable_differentContent() {
        let response1 = CompletionResponse(
            content: "Hi",
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 1, outputTokens: 1)
        )
        let response2 = CompletionResponse(
            content: "Hello",
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 1, outputTokens: 1)
        )

        #expect(response1 != response2)
    }

    // MARK: - Hashable

    @Test func hashable_inSet() {
        let response1 = CompletionResponse(
            content: "A",
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 1, outputTokens: 1)
        )
        let response2 = CompletionResponse(
            content: "A",
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 1, outputTokens: 1)
        )  // duplicate
        let response3 = CompletionResponse(
            content: "B",
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 1, outputTokens: 1)
        )

        let set: Set<CompletionResponse> = [response1, response2, response3]
        #expect(set.count == 2)
    }
}
