/// Anthropic-specific integration tests.
///
/// Tests unique to Anthropic that aren't covered by cross-provider tests.
/// Gated via ProviderFixture — only runs when ANTHROPIC_TESTS=1 or INTEGRATION=1.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Anthropic Provider", .enabled(if: ProviderFixture.anthropic != nil))
struct AnthropicProviderTests {

    private var model: AnthropicModel {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        return AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)
    }

    // MARK: - Error Handling

    @Test("invalid API key returns invalidAPIKey error")
    func invalidAPIKey() async throws {
        let badProvider = AnthropicProvider(apiKey: "invalid-key")
        let badModel = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: badProvider)

        do {
            _ = try await badModel.complete("Hello")
            Issue.record("Should have thrown")
        } catch let error as LLMError {
            #expect(error == .invalidAPIKey)
        }
    }

    @Test("invalid model name returns appropriate error")
    func invalidModel() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let badModel = AnthropicModel(name: "nonexistent-model", provider: provider)

        do {
            _ = try await badModel.complete("Hello")
            Issue.record("Should have thrown")
        } catch let error as LLMError {
            if case .modelNotFound = error {
                // Expected
            } else if case .invalidRequest = error {
                // Also acceptable
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Model Listing

    @Test("list models returns Claude models")
    func listModels() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)

        var models: [ModelInfo] = []
        for try await model in provider.listModels() {
            models.append(model)
        }

        #expect(!models.isEmpty)

        let firstModel = models[0]
        #expect(!firstModel.id.isEmpty)
        #expect(!firstModel.displayName.isEmpty)

        let hasClaudeModel = models.contains { $0.id.contains("claude") }
        #expect(hasClaudeModel)
    }

    @Test("list models supports early exit")
    func listModels_earlyExit() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)

        var foundModel: ModelInfo?
        for try await model in provider.listModels() {
            if model.id.contains("claude-3") {
                foundModel = model
                break
            }
        }

        #expect(foundModel != nil)
        #expect(foundModel?.id.contains("claude") == true)
    }

    @Test("list models with invalid API key returns error")
    func listModels_invalidAPIKey() async throws {
        let badProvider = AnthropicProvider(apiKey: "invalid-key")

        do {
            for try await _ in badProvider.listModels() {}
            Issue.record("Should have thrown")
        } catch let error as LLMError {
            #expect(error == .invalidAPIKey)
        }
    }

    @Test("cached model list returns consistent results")
    func listModels_cached() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let cache = CachedModelList(ttl: 3600)

        let models1 = try await cache.models(from: provider)
        #expect(!models1.isEmpty)

        let models2 = try await cache.models(from: provider)
        #expect(models1.count == models2.count)
        #expect(models1[0].id == models2[0].id)

        let models3 = try await cache.models(from: provider, forceRefresh: true)
        #expect(models3.count == models1.count)
    }

    // MARK: - Stop Sequences (Advanced)

    @Test("multiple stop sequences - first match stops")
    func stopSequences_multipleSequences() async throws {
        let request = CompletionRequest(
            messages: [.user("List these words one by one: apple, banana, cherry, date. Put each on a new line.")],
            config: CompletionConfig(stopSequences: ["cherry", "date"])
        )

        let response = try await model.complete(request)

        #expect(response.stopReason == .stopSequence)
        let content = response.content ?? ""
        #expect(content.contains("apple"))
        #expect(content.contains("banana"))
        #expect(!content.contains("date"))
    }

    // MARK: - Vision (Advanced)

    @Test("image input with system message and text")
    func imageInputWithText() async throws {
        let bluePNG = createTestPNG(color: (0, 0, 255))

        let request = CompletionRequest(
            messages: [
                .system("You are a helpful assistant. Answer concisely."),
                .user([
                    .text("Describe the color of this image in one word."),
                    .image(bluePNG, mimeType: "image/png")
                ])
            ]
        )

        let response = try await model.complete(request)

        #expect(response.content != nil)
        let content = response.content?.lowercased() ?? ""
        #expect(content.contains("blue"))
    }

    @Test("multiple images in single message")
    func multipleImages() async throws {
        let redPNG = createTestPNG(color: (255, 0, 0))
        let greenPNG = createTestPNG(color: (0, 255, 0))

        let request = CompletionRequest(
            messages: [
                .user([
                    .text("I'm showing you two images. What colors are they? List both colors."),
                    .image(redPNG, mimeType: "image/png"),
                    .image(greenPNG, mimeType: "image/png")
                ])
            ]
        )

        let response = try await model.complete(request)

        #expect(response.content != nil)
        let content = response.content?.lowercased() ?? ""
        #expect(content.contains("red"))
        #expect(content.contains("green"))
    }

    // MARK: - Streaming Edge Cases

    @Test("streaming respects stop sequences")
    func streamingWithStopSequence() async throws {
        let request = CompletionRequest(
            messages: [.user("Count from 1 to 10, one number per line.")],
            config: CompletionConfig(stopSequences: ["5"])
        )

        var chunks: [String] = []
        var finalResponse: CompletionResponse?

        for try await event in model.stream(request) {
            switch event {
            case .contentDelta(let text, _):
                chunks.append(text)
            case .done(let response):
                finalResponse = response
            default:
                break
            }
        }

        #expect(!chunks.isEmpty)
        #expect(finalResponse != nil)
        #expect(finalResponse?.stopReason == .stopSequence)

        let accumulated = chunks.joined()
        #expect(accumulated.contains("1"))
        #expect(!accumulated.contains("7"))
    }

    @Test("streaming respects maxTokens")
    func streamingWithMaxTokens() async throws {
        let request = CompletionRequest(
            messages: [.user("Write a very long story about a dragon.")],
            config: CompletionConfig(maxTokens: 15)
        )

        var chunks: [String] = []
        var finalResponse: CompletionResponse?

        for try await event in model.stream(request) {
            switch event {
            case .contentDelta(let text, _):
                chunks.append(text)
            case .done(let response):
                finalResponse = response
            default:
                break
            }
        }

        #expect(!chunks.isEmpty)
        #expect(finalResponse != nil)
        #expect(finalResponse?.stopReason == .maxTokens)
        #expect(finalResponse?.usage.outputTokens ?? 0 <= 20)
    }

    @Test("streaming handles mixed content and tool calls")
    func streamingMixedContent() async throws {
        let noteTool = ToolDefinition(
            name: "take_note",
            description: "Save a note for later",
            inputSchema: [
                "type": "object",
                "properties": [
                    "note": ["type": "string", "description": "The note to save"]
                ],
                "required": ["note"]
            ]
        )

        let request = CompletionRequest(
            messages: [.user("First say 'I will help you' then use the take_note tool to save 'test note'.")],
            tools: [noteTool]
        )

        var toolCallStarted = false
        var toolCallEnded = false
        var finalResponse: CompletionResponse?

        for try await event in model.stream(request) {
            switch event {
            case .toolCallStart(_, _):
                toolCallStarted = true
            case .toolCallEnd(_):
                toolCallEnded = true
            case .done(let response):
                finalResponse = response
            default:
                break
            }
        }

        #expect(finalResponse != nil)
        #expect(finalResponse?.stopReason == .toolUse)
        #expect(toolCallStarted)
        #expect(toolCallEnded)
    }

    @Test("streaming tracks usage")
    func streamingUsageTracking() async throws {
        var finalResponse: CompletionResponse?

        for try await event in model.stream("Say hello") {
            if case .done(let response) = event {
                finalResponse = response
            }
        }

        #expect(finalResponse != nil)
        #expect(finalResponse?.usage.inputTokens ?? 0 > 0)
        #expect(finalResponse?.usage.outputTokens ?? 0 > 0)
        #expect(finalResponse?.usage.totalTokens ?? 0 > 0)
    }

    // MARK: - Advanced Tool Calling

    @Test("multiple tool definitions - model selects correct one")
    func multipleToolCalls() async throws {
        let weatherTool = ToolDefinition(
            name: "get_weather",
            description: "Get weather for a city",
            inputSchema: [
                "type": "object",
                "properties": ["city": ["type": "string"]],
                "required": ["city"]
            ]
        )

        let timeTool = ToolDefinition(
            name: "get_time",
            description: "Get current time in a timezone",
            inputSchema: [
                "type": "object",
                "properties": ["timezone": ["type": "string"]],
                "required": ["timezone"]
            ]
        )

        let request = CompletionRequest(
            messages: [.user("What's the weather in Tokyo AND what time is it there? Use both tools.")],
            tools: [weatherTool, timeTool]
        )

        let response = try await model.complete(request)

        #expect(response.stopReason == .toolUse)
        #expect(!response.toolCalls.isEmpty)

        for toolCall in response.toolCalls {
            #expect(!toolCall.id.isEmpty)
            #expect(!toolCall.name.isEmpty)
            #expect(toolCall.name == "get_weather" || toolCall.name == "get_time")
        }
    }

    @Test("tool call with nested JSON arguments")
    func toolCallWithNestedArguments() async throws {
        let complexTool = ToolDefinition(
            name: "create_event",
            description: "Create a calendar event",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "attendees": [
                        "type": "array",
                        "items": ["type": "string"]
                    ],
                    "details": [
                        "type": "object",
                        "properties": [
                            "location": ["type": "string"],
                            "duration_minutes": ["type": "integer"]
                        ]
                    ]
                ],
                "required": ["title"]
            ]
        )

        let request = CompletionRequest(
            messages: [.user("Create an event called 'Team Standup' with attendees Alice and Bob, location 'Room 101', duration 30 minutes.")],
            tools: [complexTool]
        )

        let response = try await model.complete(request)

        #expect(response.stopReason == .toolUse)
        #expect(!response.toolCalls.isEmpty)
        #expect(response.toolCalls[0].name == "create_event")

        let args = response.toolCalls[0].arguments
        #expect(args.contains("Team Standup") || args.contains("Standup"))
    }

    @Test("tool result with error is handled gracefully")
    func toolResultWithError() async throws {
        let searchTool = ToolDefinition(
            name: "search_database",
            description: "Search the database",
            inputSchema: [
                "type": "object",
                "properties": ["query": ["type": "string"]],
                "required": ["query"]
            ]
        )

        let request1 = CompletionRequest(
            messages: [.user("Search the database for 'nonexistent_item'")],
            tools: [searchTool]
        )

        let response1 = try await model.complete(request1)
        #expect(response1.stopReason == .toolUse)
        #expect(!response1.toolCalls.isEmpty)

        let toolCall = response1.toolCalls[0]
        let request2 = CompletionRequest(
            messages: [
                .user("Search the database for 'nonexistent_item'"),
                .assistant(response1.content ?? "", toolCalls: response1.toolCalls),
                .toolResult(toolCallId: toolCall.id, content: "Error: Database connection failed. Please try again later.")
            ],
            tools: [searchTool]
        )

        let response2 = try await model.complete(request2)

        #expect(response2.content != nil)
        let content = response2.content?.lowercased() ?? ""
        let acknowledgesError = content.contains("error") ||
                               content.contains("failed") ||
                               content.contains("unable") ||
                               content.contains("sorry") ||
                               content.contains("issue") ||
                               content.contains("problem")
        #expect(acknowledgesError)
    }

    // MARK: - Multi-turn with Tools

    @Test("multi-turn conversation with tool use preserves context")
    func multiTurnWithTools() async throws {
        let calculatorTool = ToolDefinition(
            name: "calculator",
            description: "Perform math calculations",
            inputSchema: [
                "type": "object",
                "properties": ["expression": ["type": "string"]],
                "required": ["expression"]
            ]
        )

        let response1 = try await model.complete(CompletionRequest(
            messages: [.user("What is 25 * 4? Use the calculator.")],
            tools: [calculatorTool]
        ))

        #expect(response1.stopReason == .toolUse)
        let toolCall1 = response1.toolCalls[0]

        let response2 = try await model.complete(CompletionRequest(
            messages: [
                .user("What is 25 * 4? Use the calculator."),
                .assistant(response1.content ?? "", toolCalls: response1.toolCalls),
                .toolResult(toolCallId: toolCall1.id, content: "100")
            ],
            tools: [calculatorTool]
        ))

        #expect(response2.content?.contains("100") == true)

        let response3 = try await model.complete(CompletionRequest(
            messages: [
                .user("What is 25 * 4? Use the calculator."),
                .assistant(response1.content ?? "", toolCalls: response1.toolCalls),
                .toolResult(toolCallId: toolCall1.id, content: "100"),
                .assistant(response2.content ?? ""),
                .user("Now double that result. Use the calculator.")
            ],
            tools: [calculatorTool]
        ))

        let hasToolCall = !response3.toolCalls.isEmpty
        let hasAnswer = response3.content?.contains("200") == true
        #expect(hasToolCall || hasAnswer)
    }

    // MARK: - Unicode in Tools

    @Test("unicode in tool arguments is preserved")
    func unicodeInToolArguments() async throws {
        let noteTool = ToolDefinition(
            name: "save_note",
            description: "Save a note",
            inputSchema: [
                "type": "object",
                "properties": ["content": ["type": "string"]],
                "required": ["content"]
            ]
        )

        let request = CompletionRequest(
            messages: [.user("Save a note with this content: 日本語テスト 🚀")],
            tools: [noteTool]
        )

        let response = try await model.complete(request)

        #expect(response.stopReason == .toolUse)
        #expect(!response.toolCalls.isEmpty)

        let args = response.toolCalls[0].arguments
        #expect(args.contains("日本語") || args.contains("テスト") || args.contains("🚀"))
    }

    // MARK: - Expensive Tests

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_EXPENSIVE_TESTS"] != nil))
    func expensive_contextLengthExceeded() async throws {
        let longText = String(repeating: "This is a test sentence to fill up the context window. ", count: 20_000)

        let request = CompletionRequest(
            messages: [.user(longText + "\n\nSummarize the above.")]
        )

        do {
            _ = try await model.complete(request)
            Issue.record("Should have thrown context length error")
        } catch let error as LLMError {
            if case .invalidRequest(let message) = error {
                let isContextError = message.lowercased().contains("context") ||
                                    message.lowercased().contains("token") ||
                                    message.lowercased().contains("length") ||
                                    message.lowercased().contains("too long") ||
                                    message.lowercased().contains("maximum")
                #expect(isContextError, "Expected context-related error, got: \(message)")
            }
        }
    }
}
