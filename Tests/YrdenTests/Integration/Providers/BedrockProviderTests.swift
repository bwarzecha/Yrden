/// Bedrock-specific integration tests.
///
/// Tests unique to AWS Bedrock that aren't covered by cross-provider tests.
/// Gated via ProviderFixture — only runs when BEDROCK_TESTS=1 or INTEGRATION=1.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Bedrock Provider", .enabled(if: ProviderFixture.bedrock != nil))
struct BedrockProviderTests {

    private var provider: BedrockProvider {
        if let accessKey = TestConfig.awsAccessKeyId,
           let secretKey = TestConfig.awsSecretAccessKey,
           !accessKey.isEmpty && !secretKey.isEmpty {
            return try! BedrockProvider(
                region: TestConfig.awsRegion,
                accessKeyId: accessKey,
                secretAccessKey: secretKey,
                sessionToken: TestConfig.awsSessionToken
            )
        } else {
            return try! BedrockProvider(
                region: TestConfig.awsRegion,
                profile: TestConfig.awsProfile
            )
        }
    }

    private var model: BedrockModel {
        BedrockModel(
            name: "us.anthropic.claude-haiku-4-5-20251001-v1:0",
            provider: provider
        )
    }

    private var visionModel: BedrockModel {
        BedrockModel(
            name: "us.anthropic.claude-haiku-4-5-20251001-v1:0",
            provider: provider
        )
    }

    // MARK: - Model Listing

    @Test("list foundation models includes Claude")
    func listFoundationModels() async throws {
        var models: [ModelInfo] = []
        for try await model in provider.listModels() {
            models.append(model)
        }

        #expect(!models.isEmpty)

        let hasClaude = models.contains { $0.id.contains("claude") }
        #expect(hasClaude)
    }

    @Test("list inference profiles")
    func listInferenceProfiles() async throws {
        var profiles: [ModelInfo] = []
        for try await model in provider.listModels() {
            if let type = model.metadata?["type"], case .string(let typeStr) = type, typeStr == "inference_profile" {
                profiles.append(model)
            }
        }

        #expect(!profiles.isEmpty)
    }

    @Test("list models supports early exit")
    func listModels_earlyExit() async throws {
        var foundModel: ModelInfo?
        for try await model in provider.listModels() {
            if model.id.contains("claude") {
                foundModel = model
                break
            }
        }

        #expect(foundModel != nil)
        #expect(foundModel?.id.contains("claude") == true)
    }

    @Test("cached model list returns consistent results")
    func listModels_cached() async throws {
        let cache = CachedModelList(ttl: 3600)

        let models1 = try await cache.models(from: provider)
        #expect(!models1.isEmpty)

        let models2 = try await cache.models(from: provider)
        #expect(models1.count == models2.count)
        #expect(models1[0].id == models2[0].id)

        let models3 = try await cache.models(from: provider, forceRefresh: true)
        #expect(models3.count == models1.count)
    }

    // MARK: - Vision (Advanced)

    @Test("image input with system message and text")
    func imageInputWithText() async throws {
        let greenPNG = createTestPNG(color: (0, 255, 0))

        let request = CompletionRequest(
            messages: [
                .system("You are a helpful assistant. Answer concisely."),
                .user([
                    .text("What is the main color of this solid-colored image? Reply with just the color name."),
                    .image(greenPNG, mimeType: "image/png")
                ])
            ],
            config: CompletionConfig(temperature: 0.0)
        )

        let response = try await visionModel.complete(request)

        #expect(response.content != nil)
        let content = response.content?.lowercased() ?? ""
        let hasGreen = content.contains("green") || content.contains("lime") || content.contains("neon")
        #expect(hasGreen)
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

        let response = try await visionModel.complete(request)

        #expect(response.content != nil)
        let content = response.content?.lowercased() ?? ""
        #expect(content.contains("red"))
        #expect(content.contains("green"))
    }

    // MARK: - Streaming Edge Cases

    @Test("streaming tool call events")
    func streamingToolCall() async throws {
        let searchTool = ToolDefinition(
            name: "search",
            description: "Search the web",
            inputSchema: [
                "type": "object",
                "properties": ["query": ["type": "string"]],
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
        #expect(finalResponse?.usage.outputTokens ?? 0 > 0)
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

    @Test("multiple tool definitions")
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
            messages: [.user("What's the weather in Tokyo?")],
            tools: [weatherTool, timeTool]
        )

        let response = try await model.complete(request)

        #expect(response.stopReason == .toolUse)
        #expect(!response.toolCalls.isEmpty)

        for toolCall in response.toolCalls {
            #expect(!toolCall.id.isEmpty)
            #expect(!toolCall.name.isEmpty)
            #expect(!toolCall.arguments.isEmpty)
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
            messages: [.user("Create an event with title, attendees, and location details.")],
            tools: [complexTool]
        )

        let response = try await model.complete(request)

        #expect(response.stopReason == .toolUse)
        #expect(!response.toolCalls.isEmpty)
        guard let firstCall = response.toolCalls.first else { return }
        #expect(firstCall.name == "create_event")
        let args = firstCall.arguments
        #expect(!args.isEmpty)
        #expect(args.data(using: .utf8) != nil)
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
                .toolResult(toolCallId: toolCall.id, content: "Error: Database connection failed.")
            ],
            tools: [searchTool]
        )

        let response2 = try await model.complete(request2)

        #expect(response2.content != nil || !response2.toolCalls.isEmpty)
    }

    // MARK: - Multi-turn with Tools

    @Test("multi-turn conversation with tool use")
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
        #expect(!response1.toolCalls.isEmpty)
        let toolCall1 = response1.toolCalls[0]

        let response2 = try await model.complete(CompletionRequest(
            messages: [
                .user("What is 25 * 4? Use the calculator."),
                .assistant(response1.content ?? "", toolCalls: response1.toolCalls),
                .toolResult(toolCallId: toolCall1.id, content: "100")
            ],
            tools: [calculatorTool]
        ))

        #expect(response2.content != nil || !response2.toolCalls.isEmpty)

        let response3 = try await model.complete(CompletionRequest(
            messages: [
                .user("What is 25 * 4? Use the calculator."),
                .assistant(response1.content ?? "", toolCalls: response1.toolCalls),
                .toolResult(toolCallId: toolCall1.id, content: "100"),
                .assistant(response2.content ?? ""),
                .user("Now double that result.")
            ],
            tools: [calculatorTool]
        ))

        let hasResponse = response3.content != nil || !response3.toolCalls.isEmpty
        #expect(hasResponse)
    }

    // MARK: - Stop Sequences (Advanced)

    @Test("multiple stop sequences")
    func stopSequences_multipleSequences() async throws {
        let request = CompletionRequest(
            messages: [.user("List these words one by one: apple, banana, cherry, date. Put each on a new line.")],
            config: CompletionConfig(stopSequences: ["cherry", "date"])
        )

        let response = try await model.complete(request)

        #expect(response.stopReason == .stopSequence)
        #expect(response.content != nil)
        #expect(!response.content!.isEmpty)
    }

    // MARK: - Unicode in Tools

    @Test("unicode in tool arguments is preserved")
    func unicodeInToolArguments() async throws {
        let noteTool = ToolDefinition(
            name: "save_note",
            description: "Save a note with the given content",
            inputSchema: [
                "type": "object",
                "properties": ["content": ["type": "string"]],
                "required": ["content"]
            ]
        )

        let request = CompletionRequest(
            messages: [.user("Save a note with this content: 日本語テスト")],
            tools: [noteTool]
        )

        let response = try await model.complete(request)

        #expect(response.stopReason == .toolUse)
        #expect(!response.toolCalls.isEmpty)
        let args = response.toolCalls[0].arguments
        #expect(!args.isEmpty)
        #expect(args.data(using: .utf8) != nil)
    }

    // MARK: - Nova Model

    @Test("Amazon Nova Lite model works")
    func novaModel() async throws {
        let novaModel = BedrockModel(
            name: "us.amazon.nova-lite-v1:0",
            provider: provider
        )

        let response = try await novaModel.complete("Say 'hello' and nothing else.")

        #expect(response.content != nil)
        #expect(response.content?.lowercased().contains("hello") == true)
    }
}
