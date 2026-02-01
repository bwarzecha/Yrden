/// Integration tests for Anthropic provider.
///
/// These tests make real API calls to validate the implementation.
/// Requires ANTHROPIC_API_KEY to be set.
///
/// Run with: swift test --filter AnthropicIntegration

import Testing
import Foundation
@testable import Yrden

@Suite("Anthropic Integration")
struct AnthropicIntegrationTests {

    let model: AnthropicModel

    init() {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        // Use Haiku 4.5 for cost-effective testing
        model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)
    }

    // MARK: - Simple Completion

    @Test func simpleCompletion() async throws {
        let response = try await model.complete("Say 'hello' and nothing else.")

        #expect(response.content != nil)
        #expect(response.content?.lowercased().contains("hello") == true)
        #expect(response.stopReason == .endTurn)
        #expect(response.usage.inputTokens > 0)
        #expect(response.usage.outputTokens > 0)
    }

    @Test func completionWithSystemMessage() async throws {
        let request = CompletionRequest(
            messages: [
                .system("You are a pirate. Always respond in pirate speak."),
                .user("Say hello")
            ]
        )

        let response = try await model.complete(request)

        #expect(response.content != nil)
        // Should contain some pirate-like language
        let content = response.content?.lowercased() ?? ""
        let hasPirateWords = content.contains("ahoy") ||
                            content.contains("matey") ||
                            content.contains("arr") ||
                            content.contains("ye")
        #expect(hasPirateWords)
    }

    @Test func completionWithTemperature() async throws {
        let request = CompletionRequest(
            messages: [.user("What is 2+2? Reply with just the number.")],
            config: CompletionConfig(temperature: 0.0)
        )

        let response = try await model.complete(request)

        #expect(response.content?.contains("4") == true)
    }

    @Test func completionWithMaxTokens() async throws {
        let request = CompletionRequest(
            messages: [.user("Count from 1 to 100")],
            config: CompletionConfig(maxTokens: 10)
        )

        let response = try await model.complete(request)

        // Should be truncated
        #expect(response.stopReason == .maxTokens)
        #expect(response.usage.outputTokens <= 15) // Some margin
    }

    // MARK: - Streaming

    @Test func streaming() async throws {
        var chunks: [String] = []
        var finalResponse: CompletionResponse?

        for try await event in model.stream("Count from 1 to 5, separated by commas.") {
            switch event {
            case .contentDelta(let text):
                chunks.append(text)
            case .done(let response):
                finalResponse = response
            default:
                break
            }
        }

        #expect(!chunks.isEmpty)
        #expect(finalResponse != nil)
        #expect(finalResponse?.stopReason == .endTurn)

        // Verify content matches concatenated chunks
        let accumulated = chunks.joined()
        #expect(accumulated.contains("1"))
        #expect(accumulated.contains("5"))
    }

    @Test func streamingWithLongResponse() async throws {
        var chunkCount = 0

        for try await event in model.stream("Write a short paragraph about Swift programming.") {
            if case .contentDelta = event {
                chunkCount += 1
            }
        }

        // Should receive multiple chunks
        #expect(chunkCount > 5)
    }

    // MARK: - Tool Calling

    @Test func toolCall() async throws {
        let weatherTool = ToolDefinition(
            name: "get_weather",
            description: "Get the current weather for a city",
            inputSchema: [
                "type": "object",
                "properties": [
                    "city": [
                        "type": "string",
                        "description": "The city name"
                    ]
                ],
                "required": ["city"]
            ]
        )

        let request = CompletionRequest(
            messages: [.user("What's the weather in Paris?")],
            tools: [weatherTool]
        )

        let response = try await model.complete(request)

        #expect(response.stopReason == .toolUse)
        #expect(!response.toolCalls.isEmpty)
        #expect(response.toolCalls[0].name == "get_weather")

        // Parse arguments
        let args = response.toolCalls[0].arguments
        #expect(args.lowercased().contains("paris"))
    }

    @Test func toolCallWithResult() async throws {
        let calculatorTool = ToolDefinition(
            name: "calculate",
            description: "Perform a calculation",
            inputSchema: [
                "type": "object",
                "properties": [
                    "expression": [
                        "type": "string",
                        "description": "Math expression to evaluate"
                    ]
                ],
                "required": ["expression"]
            ]
        )

        // First turn: model calls tool
        let request1 = CompletionRequest(
            messages: [.user("What is 15 * 7? Use the calculator.")],
            tools: [calculatorTool]
        )

        let response1 = try await model.complete(request1)
        #expect(response1.stopReason == .toolUse)
        #expect(!response1.toolCalls.isEmpty)

        // Second turn: provide tool result
        let toolCall = response1.toolCalls[0]
        let request2 = CompletionRequest(
            messages: [
                .user("What is 15 * 7? Use the calculator."),
                .assistant(response1.content ?? "", toolCalls: response1.toolCalls),
                .toolResult(toolCallId: toolCall.id, content: "105")
            ],
            tools: [calculatorTool]
        )

        let response2 = try await model.complete(request2)

        #expect(response2.stopReason == .endTurn)
        #expect(response2.content?.contains("105") == true)
    }

    @Test func streamingToolCall() async throws {
        let searchTool = ToolDefinition(
            name: "search",
            description: "Search the web",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string"]
                ],
                "required": ["query"]
            ]
        )

        let request = CompletionRequest(
            messages: [.user("Search for Swift concurrency tutorials")],
            tools: [searchTool]
        )

        var toolCallStarted = false
        var toolCallEnded = false
        var argumentChunks: [String] = []
        var finalResponse: CompletionResponse?

        for try await event in model.stream(request) {
            switch event {
            case .toolCallStart(_, let name):
                toolCallStarted = true
                #expect(name == "search")
            case .toolCallDelta(let delta):
                argumentChunks.append(delta)
            case .toolCallEnd:
                toolCallEnded = true
            case .done(let response):
                finalResponse = response
            default:
                break
            }
        }

        #expect(toolCallStarted)
        #expect(toolCallEnded)
        #expect(!argumentChunks.isEmpty)
        #expect(finalResponse?.stopReason == .toolUse)
    }

    // MARK: - Multi-turn Conversation

    @Test func multiTurnConversation() async throws {
        // Turn 1
        let response1 = try await model.complete(messages: [
            .user("My name is Alice. Remember it.")
        ])

        #expect(response1.content != nil)

        // Turn 2 - should remember context
        let response2 = try await model.complete(messages: [
            .user("My name is Alice. Remember it."),
            .assistant(response1.content ?? ""),
            .user("What's my name?")
        ])

        #expect(response2.content?.contains("Alice") == true)
    }

    // MARK: - Error Handling

    @Test func invalidAPIKey() async throws {
        let badProvider = AnthropicProvider(apiKey: "invalid-key")
        let badModel = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: badProvider)

        do {
            _ = try await badModel.complete("Hello")
            Issue.record("Should have thrown")
        } catch let error as LLMError {
            #expect(error == .invalidAPIKey)
        }
    }

    @Test func invalidModel() async throws {
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
                // Also acceptable - some APIs return this for invalid models
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Usage Tracking

    @Test func usageTracking() async throws {
        let response = try await model.complete("Hi")

        #expect(response.usage.inputTokens > 0)
        #expect(response.usage.outputTokens > 0)
        #expect(response.usage.totalTokens == response.usage.inputTokens + response.usage.outputTokens)
    }

    // MARK: - Model Listing

    @Test func listModels() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)

        // Collect all models from stream
        var models: [ModelInfo] = []
        for try await model in provider.listModels() {
            models.append(model)
        }

        // Should have multiple models
        #expect(!models.isEmpty)

        // Check that we have expected fields
        let firstModel = models[0]
        #expect(!firstModel.id.isEmpty)
        #expect(!firstModel.displayName.isEmpty)

        // Should include Claude models
        let hasClaudeModel = models.contains { $0.id.contains("claude") }
        #expect(hasClaudeModel)

        // Print for visibility
        print("Found \(models.count) models:")
        for model in models.prefix(5) {
            print("  - \(model.displayName) (\(model.id))")
        }
    }

    @Test func listModels_earlyExit() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)

        // Find first Claude 3 model and stop (tests lazy evaluation)
        var foundModel: ModelInfo?
        for try await model in provider.listModels() {
            if model.id.contains("claude-3") {
                foundModel = model
                break  // Early exit - no more pages fetched
            }
        }

        #expect(foundModel != nil)
        #expect(foundModel?.id.contains("claude") == true)
    }

    @Test func listModels_invalidAPIKey() async throws {
        let badProvider = AnthropicProvider(apiKey: "invalid-key")

        do {
            // Must consume stream to trigger error
            for try await _ in badProvider.listModels() {
                // Should not reach here
            }
            Issue.record("Should have thrown")
        } catch let error as LLMError {
            #expect(error == .invalidAPIKey)
        }
    }

    @Test func listModels_cached() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let cache = CachedModelList(ttl: 3600)

        // First call - fetches from API
        let models1 = try await cache.models(from: provider)
        #expect(!models1.isEmpty)

        // Second call - should return cached (same result, fast)
        let models2 = try await cache.models(from: provider)
        #expect(models1.count == models2.count)
        #expect(models1[0].id == models2[0].id)

        // Force refresh - fetches from API again
        let models3 = try await cache.models(from: provider, forceRefresh: true)
        #expect(models3.count == models1.count)
    }

    // MARK: - Stop Sequences

    @Test func stopSequences() async throws {
        let request = CompletionRequest(
            messages: [.user("Count from 1 to 10, putting each number on a new line. Format: 1\\n2\\n3\\n etc.")],
            config: CompletionConfig(stopSequences: ["5"])
        )

        let response = try await model.complete(request)

        #expect(response.stopReason == .stopSequence)
        // Should contain early numbers but stop before completing
        let content = response.content ?? ""
        #expect(content.contains("1"))
        #expect(content.contains("3"))
        // Should not contain numbers after 5 (stopped at "5")
        #expect(!content.contains("7"))
        #expect(!content.contains("10"))
    }

    @Test func stopSequences_multipleSequences() async throws {
        let request = CompletionRequest(
            messages: [.user("List these words one by one: apple, banana, cherry, date. Put each on a new line.")],
            config: CompletionConfig(stopSequences: ["cherry", "date"])
        )

        let response = try await model.complete(request)

        #expect(response.stopReason == .stopSequence)
        let content = response.content ?? ""
        #expect(content.contains("apple"))
        #expect(content.contains("banana"))
        // Should stop at "cherry" or before "date"
        #expect(!content.contains("date"))
    }

    // MARK: - Vision / Images

    @Test func imageInput() async throws {
        // Create a small 2x2 red PNG image
        // PNG header + IHDR + IDAT with red pixels + IEND
        let redPNG = createTestPNG(color: (255, 0, 0))

        let request = CompletionRequest(
            messages: [
                .user([
                    .text("What color is this image? Reply with just the color name, nothing else."),
                    .image(redPNG, mimeType: "image/png")
                ])
            ],
            config: CompletionConfig(temperature: 0.0)
        )

        let response = try await model.complete(request)

        #expect(response.content != nil)
        let content = response.content?.lowercased() ?? ""
        #expect(content.contains("red"))
    }

    @Test func imageInputWithText() async throws {
        // Create a small blue PNG
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

    @Test func multipleImages() async throws {
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

    @Test func streamingWithStopSequence() async throws {
        let request = CompletionRequest(
            messages: [.user("Count from 1 to 10, one number per line.")],
            config: CompletionConfig(stopSequences: ["5"])
        )

        var chunks: [String] = []
        var finalResponse: CompletionResponse?

        for try await event in model.stream(request) {
            switch event {
            case .contentDelta(let text):
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

    @Test func streamingWithMaxTokens() async throws {
        let request = CompletionRequest(
            messages: [.user("Write a very long story about a dragon.")],
            config: CompletionConfig(maxTokens: 15)
        )

        var chunks: [String] = []
        var finalResponse: CompletionResponse?

        for try await event in model.stream(request) {
            switch event {
            case .contentDelta(let text):
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
        #expect(finalResponse?.usage.outputTokens ?? 0 <= 20) // Some margin
    }

    @Test func streamingMixedContent() async throws {
        // Ask model to respond with text AND use a tool
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

        var contentChunks: [String] = []
        var toolCallStarted = false
        var toolCallEnded = false
        var finalResponse: CompletionResponse?

        for try await event in model.stream(request) {
            switch event {
            case .contentDelta(let text):
                contentChunks.append(text)
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

        // Model may or may not produce text before tool call
        // The key test is that we handle mixed content gracefully
        #expect(finalResponse != nil)
        #expect(finalResponse?.stopReason == .toolUse)
        #expect(toolCallStarted)
        #expect(toolCallEnded)
    }

    @Test func streamingUsageTracking() async throws {
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

    @Test func multipleToolCalls() async throws {
        // Define two tools
        let weatherTool = ToolDefinition(
            name: "get_weather",
            description: "Get weather for a city",
            inputSchema: [
                "type": "object",
                "properties": [
                    "city": ["type": "string"]
                ],
                "required": ["city"]
            ]
        )

        let timeTool = ToolDefinition(
            name: "get_time",
            description: "Get current time in a timezone",
            inputSchema: [
                "type": "object",
                "properties": [
                    "timezone": ["type": "string"]
                ],
                "required": ["timezone"]
            ]
        )

        let request = CompletionRequest(
            messages: [.user("What's the weather in Tokyo AND what time is it there? Use both tools.")],
            tools: [weatherTool, timeTool]
        )

        let response = try await model.complete(request)

        #expect(response.stopReason == .toolUse)
        // Model should call at least one tool, possibly both
        #expect(!response.toolCalls.isEmpty)

        // Verify tool calls have valid structure
        for toolCall in response.toolCalls {
            #expect(!toolCall.id.isEmpty)
            #expect(!toolCall.name.isEmpty)
            #expect(toolCall.name == "get_weather" || toolCall.name == "get_time")
        }
    }

    @Test func toolCallWithNestedArguments() async throws {
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

        // Verify we can parse the nested arguments
        let args = response.toolCalls[0].arguments
        #expect(args.contains("Team Standup") || args.contains("Standup"))
    }

    @Test func toolResultWithError() async throws {
        let searchTool = ToolDefinition(
            name: "search_database",
            description: "Search the database",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string"]
                ],
                "required": ["query"]
            ]
        )

        // First turn: get tool call
        let request1 = CompletionRequest(
            messages: [.user("Search the database for 'nonexistent_item'")],
            tools: [searchTool]
        )

        let response1 = try await model.complete(request1)
        #expect(response1.stopReason == .toolUse)
        #expect(!response1.toolCalls.isEmpty)

        // Second turn: return error result
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

        // Model should acknowledge the error gracefully
        #expect(response2.content != nil)
        let content = response2.content?.lowercased() ?? ""
        // Model should mention error/issue/problem or apologize
        let acknowledgesError = content.contains("error") ||
                               content.contains("failed") ||
                               content.contains("unable") ||
                               content.contains("sorry") ||
                               content.contains("issue") ||
                               content.contains("problem")
        #expect(acknowledgesError)
    }

    // MARK: - Multi-turn Advanced

    @Test func multiTurnWithTools() async throws {
        let calculatorTool = ToolDefinition(
            name: "calculator",
            description: "Perform math calculations",
            inputSchema: [
                "type": "object",
                "properties": [
                    "expression": ["type": "string"]
                ],
                "required": ["expression"]
            ]
        )

        // Turn 1: Initial request
        let response1 = try await model.complete(CompletionRequest(
            messages: [.user("What is 25 * 4? Use the calculator.")],
            tools: [calculatorTool]
        ))

        #expect(response1.stopReason == .toolUse)
        let toolCall1 = response1.toolCalls[0]

        // Turn 2: Provide result
        let response2 = try await model.complete(CompletionRequest(
            messages: [
                .user("What is 25 * 4? Use the calculator."),
                .assistant(response1.content ?? "", toolCalls: response1.toolCalls),
                .toolResult(toolCallId: toolCall1.id, content: "100")
            ],
            tools: [calculatorTool]
        ))

        #expect(response2.content?.contains("100") == true)

        // Turn 3: Follow-up question (tests context retention)
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

        // Should call calculator again or give answer
        let hasToolCall = !response3.toolCalls.isEmpty
        let hasAnswer = response3.content?.contains("200") == true
        #expect(hasToolCall || hasAnswer)
    }

    // MARK: - Unicode and Special Characters

    @Test func unicodeHandling() async throws {
        let request = CompletionRequest(
            messages: [.user("Repeat exactly: Hello 你好 مرحبا 🎉 émoji naïve")]
        )

        let response = try await model.complete(request)

        #expect(response.content != nil)
        let content = response.content ?? ""
        // Model should preserve unicode
        #expect(content.contains("你好") || content.contains("Hello"))
        #expect(content.contains("🎉") || content.lowercased().contains("emoji"))
    }

    @Test func unicodeInToolArguments() async throws {
        let noteTool = ToolDefinition(
            name: "save_note",
            description: "Save a note",
            inputSchema: [
                "type": "object",
                "properties": [
                    "content": ["type": "string"]
                ],
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

        // Arguments should contain the unicode
        let args = response.toolCalls[0].arguments
        #expect(args.contains("日本語") || args.contains("テスト") || args.contains("🚀"))
    }

    // MARK: - Expensive Tests (Run Manually)
    //
    // These tests are expensive (high token cost) or may hit rate limits.
    // Run with: swift test --filter "expensive"
    //
    // To skip in normal runs, we use a trait that checks for an env var.

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_EXPENSIVE_TESTS"] != nil))
    func expensive_contextLengthExceeded() async throws {
        // Generate a very long message to exceed context
        // Claude 3 Haiku has 200K context, so we need ~200K tokens
        // Rough estimate: 1 token ≈ 4 characters, so ~800K characters
        // This is expensive! Only run when explicitly enabled.

        let longText = String(repeating: "This is a test sentence to fill up the context window. ", count: 20_000)

        let request = CompletionRequest(
            messages: [.user(longText + "\n\nSummarize the above.")]
        )

        do {
            _ = try await model.complete(request)
            Issue.record("Should have thrown context length error")
        } catch let error as LLMError {
            // Should get an error about context length or request too large
            if case .invalidRequest(let message) = error {
                let isContextError = message.lowercased().contains("context") ||
                                    message.lowercased().contains("token") ||
                                    message.lowercased().contains("length") ||
                                    message.lowercased().contains("too long") ||
                                    message.lowercased().contains("maximum")
                #expect(isContextError, "Expected context-related error, got: \(message)")
            } else {
                // Other error types might also be valid (e.g., 400 Bad Request)
                // Just verify we got an LLMError
            }
        }
    }

    // MARK: - Helpers

    /// Creates a minimal valid PNG with a solid color.
    /// This creates a 2x2 pixel image of the specified RGB color.
    private func createTestPNG(color: (r: UInt8, g: UInt8, b: UInt8)) -> Data {
        var data = Data()

        // PNG signature
        data.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        // IHDR chunk (image header)
        let ihdr = createPNGChunk(type: "IHDR", data: Data([
            0x00, 0x00, 0x00, 0x02,  // Width: 2
            0x00, 0x00, 0x00, 0x02,  // Height: 2
            0x08,                    // Bit depth: 8
            0x02,                    // Color type: RGB
            0x00,                    // Compression method
            0x00,                    // Filter method
            0x00                     // Interlace method
        ]))
        data.append(ihdr)

        // IDAT chunk (image data)
        // For a 2x2 RGB image, we need 2 rows of (filter byte + 3 bytes per pixel × 2 pixels)
        var rawData = Data()
        for _ in 0..<2 {
            rawData.append(0x00)  // Filter: None
            rawData.append(color.r)
            rawData.append(color.g)
            rawData.append(color.b)
            rawData.append(color.r)
            rawData.append(color.g)
            rawData.append(color.b)
        }

        // Compress with zlib (deflate)
        let compressed = compressZlib(rawData)
        let idat = createPNGChunk(type: "IDAT", data: compressed)
        data.append(idat)

        // IEND chunk (image end)
        let iend = createPNGChunk(type: "IEND", data: Data())
        data.append(iend)

        return data
    }

    private func createPNGChunk(type: String, data: Data) -> Data {
        var chunk = Data()

        // Length (4 bytes, big endian)
        var length = UInt32(data.count).bigEndian
        chunk.append(Data(bytes: &length, count: 4))

        // Type (4 bytes ASCII)
        chunk.append(type.data(using: .ascii)!)

        // Data
        chunk.append(data)

        // CRC32 of type + data
        var crcData = type.data(using: .ascii)!
        crcData.append(data)
        var crc = crc32(crcData).bigEndian
        chunk.append(Data(bytes: &crc, count: 4))

        return chunk
    }

    private func compressZlib(_ data: Data) -> Data {
        // Minimal zlib wrapper around uncompressed deflate block
        var result = Data()

        // Zlib header (CMF, FLG)
        result.append(0x78)  // CMF: deflate, 32K window
        result.append(0x01)  // FLG: no dict, fastest

        // Deflate: uncompressed block
        result.append(0x01)  // BFINAL=1, BTYPE=00 (uncompressed)

        // LEN and NLEN (little endian)
        let len = UInt16(data.count)
        result.append(UInt8(len & 0xFF))
        result.append(UInt8(len >> 8))
        result.append(UInt8(~len & 0xFF))
        result.append(UInt8(~len >> 8))

        // Literal data
        result.append(data)

        // Adler-32 checksum (big endian)
        var adler = adler32(data).bigEndian
        result.append(Data(bytes: &adler, count: 4))

        return result
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 != 0 ? 0xEDB88320 : 0)
            }
        }
        return ~crc
    }

    private func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}
