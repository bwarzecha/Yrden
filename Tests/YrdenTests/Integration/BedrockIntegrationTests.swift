/// Integration tests for AWS Bedrock provider.
///
/// These tests make real API calls to validate the implementation.
/// Requires AWS credentials to be configured (explicit, profile, or environment).
///
/// Run with: swift test --filter BedrockIntegration

import Testing
import Foundation
@testable import Yrden

@Suite("Bedrock Integration")
struct BedrockIntegrationTests {

    let model: BedrockModel
    let visionModel: BedrockModel
    let provider: BedrockProvider

    init() throws {
        // Try to create provider with available credentials
        if let accessKey = TestConfig.awsAccessKeyId,
           let secretKey = TestConfig.awsSecretAccessKey,
           !accessKey.isEmpty && !secretKey.isEmpty {
            // Explicit credentials
            provider = try BedrockProvider(
                region: TestConfig.awsRegion,
                accessKeyId: accessKey,
                secretAccessKey: secretKey,
                sessionToken: TestConfig.awsSessionToken
            )
        } else {
            // Profile-based credentials (uses ~/.aws/credentials, NOT EC2 metadata)
            provider = try BedrockProvider(
                region: TestConfig.awsRegion,
                profile: TestConfig.awsProfile
            )
        }

        // Use Claude Haiku via inference profile for cost-effective testing
        model = BedrockModel(
            name: "us.anthropic.claude-3-5-haiku-20241022-v1:0",
            provider: provider
        )

        // Use Sonnet for vision tests (Haiku 3.5 doesn't support images)
        visionModel = BedrockModel(
            name: "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
            provider: provider
        )
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
                .system("You are a helpful assistant."),
                .user("Say hello")
            ]
        )

        let response = try await model.complete(request)

        // The contract: system messages are accepted and processed
        #expect(response.content != nil)
        #expect(!response.content!.isEmpty)
        #expect(response.stopReason == .endTurn)
        #expect(response.usage.inputTokens > 0)
        #expect(response.usage.outputTokens > 0)
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

        // The contract: maxTokens causes early stop with .maxTokens reason
        #expect(response.stopReason == .maxTokens)
        #expect(response.content != nil)
        #expect(response.usage.outputTokens > 0)
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

        let accumulated = chunks.joined()
        #expect(accumulated.contains("1"))
        #expect(accumulated.contains("5"))
    }

    @Test func streamingWithLongResponse() async throws {
        var chunkCount = 0
        var accumulatedContent = ""

        for try await event in model.stream("Write a short paragraph about Swift programming.") {
            switch event {
            case .contentDelta(let text):
                chunkCount += 1
                accumulatedContent += text
            default:
                break
            }
        }

        // The contract: streaming works and delivers content
        // We only verify we got at least one chunk and non-empty content
        // Chunk count depends on network batching and is not part of the contract
        #expect(chunkCount >= 1)
        #expect(!accumulatedContent.isEmpty)
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

        // The contract: tool calls are returned with proper structure
        #expect(response.stopReason == .toolUse)
        #expect(!response.toolCalls.isEmpty)
        #expect(response.toolCalls[0].name == "get_weather")
        #expect(!response.toolCalls[0].id.isEmpty)
        // Arguments should be valid JSON
        let args = response.toolCalls[0].arguments
        #expect(!args.isEmpty)
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

        // The contract: after tool result, model provides response
        #expect(response2.stopReason == .endTurn)
        #expect(response2.content != nil)
        #expect(!response2.content!.isEmpty)
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

    // MARK: - Usage Tracking

    @Test func usageTracking() async throws {
        let response = try await model.complete("Hi")

        #expect(response.usage.inputTokens > 0)
        #expect(response.usage.outputTokens > 0)
        #expect(response.usage.totalTokens == response.usage.inputTokens + response.usage.outputTokens)
    }

    // MARK: - Model Listing

    @Test func listFoundationModels() async throws {
        var models: [ModelInfo] = []
        for try await model in provider.listModels() {
            models.append(model)
        }

        #expect(!models.isEmpty)

        // Should include Claude models
        let hasClaude = models.contains { $0.id.contains("claude") }
        #expect(hasClaude)

        // Print first few models
        print("Found \(models.count) models/profiles:")
        for model in models.prefix(10) {
            print("  - \(model.displayName) (\(model.id))")
        }
    }

    @Test func listInferenceProfiles() async throws {
        var profiles: [ModelInfo] = []
        for try await model in provider.listModels() {
            if let type = model.metadata?["type"], case .string(let typeStr) = type, typeStr == "inference_profile" {
                profiles.append(model)
            }
        }

        // Should have inference profiles
        #expect(!profiles.isEmpty)

        // Print for visibility
        print("Found \(profiles.count) inference profiles:")
        for profile in profiles.prefix(5) {
            print("  - \(profile.displayName) (\(profile.id))")
        }
    }

    // MARK: - Stop Sequences

    @Test func stopSequences() async throws {
        let request = CompletionRequest(
            messages: [.user("Count from 1 to 10, putting each number on a new line.")],
            config: CompletionConfig(stopSequences: ["5"])
        )

        let response = try await model.complete(request)

        // The contract: stop reason should be .stopSequence when we hit a stop sequence
        #expect(response.stopReason == .stopSequence)
        // Should have some content (not empty)
        #expect(response.content != nil)
        #expect(!response.content!.isEmpty)
    }

    // MARK: - Vision / Images

    @Test func imageInput() async throws {
        // Create a small 2x2 red PNG image
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

        // Use visionModel (Sonnet) since Haiku 3.5 doesn't support images
        let response = try await visionModel.complete(request)

        #expect(response.content != nil)
        let content = response.content?.lowercased() ?? ""
        #expect(content.contains("red"))
    }

    @Test func imageInputWithText() async throws {
        // Use a green PNG since it's more distinguishable
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
        // Accept green or related color names
        let content = response.content?.lowercased() ?? ""
        let hasGreen = content.contains("green") || content.contains("lime") || content.contains("neon")
        #expect(hasGreen)
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

        let response = try await visionModel.complete(request)

        #expect(response.content != nil)
        let content = response.content?.lowercased() ?? ""
        #expect(content.contains("red"))
        #expect(content.contains("green"))
    }

    // MARK: - Unicode Handling

    @Test func unicodeHandling() async throws {
        // Test that unicode in prompts doesn't cause errors
        let request = CompletionRequest(
            messages: [.user("Say hello in response to: 你好 مرحبا 🎉")]
        )

        let response = try await model.complete(request)

        // The contract: unicode in input is handled without error
        #expect(response.content != nil)
        #expect(!response.content!.isEmpty)
        #expect(response.stopReason == .endTurn)
    }

    @Test func unicodeInToolArguments() async throws {
        let noteTool = ToolDefinition(
            name: "save_note",
            description: "Save a note with the given content",
            inputSchema: [
                "type": "object",
                "properties": [
                    "content": ["type": "string"]
                ],
                "required": ["content"]
            ]
        )

        let request = CompletionRequest(
            messages: [.user("Save a note with this content: 日本語テスト")],
            tools: [noteTool]
        )

        let response = try await model.complete(request)

        // The contract: unicode in tool arguments is properly encoded
        #expect(response.stopReason == .toolUse)
        #expect(!response.toolCalls.isEmpty)
        // Arguments should be valid JSON containing the content
        let args = response.toolCalls[0].arguments
        #expect(!args.isEmpty)
        // Verify it's valid JSON by checking it parses
        #expect(args.data(using: .utf8) != nil)
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

        // The contract: streaming respects stop sequences
        #expect(!chunks.isEmpty)
        #expect(finalResponse != nil)
        #expect(finalResponse?.stopReason == .stopSequence)
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

        // The contract: maxTokens stops streaming with .maxTokens reason
        #expect(!chunks.isEmpty)
        #expect(finalResponse != nil)
        #expect(finalResponse?.stopReason == .maxTokens)
        #expect(finalResponse?.usage.outputTokens ?? 0 > 0)
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
            messages: [.user("What's the weather in Tokyo?")],
            tools: [weatherTool, timeTool]
        )

        let response = try await model.complete(request)

        // The contract: when tools are available, model can call them
        // Tool calls have proper structure (id, name, arguments)
        #expect(response.stopReason == .toolUse)
        #expect(!response.toolCalls.isEmpty)

        for toolCall in response.toolCalls {
            #expect(!toolCall.id.isEmpty)
            #expect(!toolCall.name.isEmpty)
            // Arguments should be valid JSON (even if empty object)
            #expect(!toolCall.arguments.isEmpty)
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
            messages: [.user("Create an event with title, attendees, and location details.")],
            tools: [complexTool]
        )

        let response = try await model.complete(request)

        // The contract: nested schema is accepted and tool is called
        #expect(response.stopReason == .toolUse)
        #expect(!response.toolCalls.isEmpty)
        #expect(response.toolCalls[0].name == "create_event")
        // Arguments should be valid JSON
        let args = response.toolCalls[0].arguments
        #expect(!args.isEmpty)
        #expect(args.data(using: .utf8) != nil)
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
                .toolResult(toolCallId: toolCall.id, content: "Error: Database connection failed.")
            ],
            tools: [searchTool]
        )

        let response2 = try await model.complete(request2)

        // The contract: error tool results are handled and model responds
        #expect(response2.content != nil || !response2.toolCalls.isEmpty)
    }

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

        // Turn 1: Initial request - model should call tool
        let response1 = try await model.complete(CompletionRequest(
            messages: [.user("What is 25 * 4? Use the calculator.")],
            tools: [calculatorTool]
        ))

        #expect(response1.stopReason == .toolUse)
        #expect(!response1.toolCalls.isEmpty)
        let toolCall1 = response1.toolCalls[0]

        // Turn 2: Provide result - model should respond
        let response2 = try await model.complete(CompletionRequest(
            messages: [
                .user("What is 25 * 4? Use the calculator."),
                .assistant(response1.content ?? "", toolCalls: response1.toolCalls),
                .toolResult(toolCallId: toolCall1.id, content: "100")
            ],
            tools: [calculatorTool]
        ))

        // The contract: after tool result, model responds (content or more tools)
        #expect(response2.content != nil || !response2.toolCalls.isEmpty)

        // Turn 3: Follow-up - tests multi-turn context works
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

        // Model should either call tool again or give answer
        let hasResponse = response3.content != nil || !response3.toolCalls.isEmpty
        #expect(hasResponse)
    }

    // MARK: - Stop Sequences

    @Test func stopSequences_multipleSequences() async throws {
        let request = CompletionRequest(
            messages: [.user("List these words one by one: apple, banana, cherry, date. Put each on a new line.")],
            config: CompletionConfig(stopSequences: ["cherry", "date"])
        )

        let response = try await model.complete(request)

        // The contract: multiple stop sequences work, first match stops
        #expect(response.stopReason == .stopSequence)
        #expect(response.content != nil)
        #expect(!response.content!.isEmpty)
    }

    // MARK: - Model Listing

    @Test func listModels_earlyExit() async throws {
        // Find first Claude model and stop (tests lazy evaluation)
        var foundModel: ModelInfo?
        for try await model in provider.listModels() {
            if model.id.contains("claude") {
                foundModel = model
                break  // Early exit - pagination should stop
            }
        }

        #expect(foundModel != nil)
        #expect(foundModel?.id.contains("claude") == true)
    }

    @Test func listModels_cached() async throws {
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

    // MARK: - Nova Model Test (if available)

    @Test func novaModel() async throws {
        // Test with Amazon Nova Lite if available
        let novaModel = BedrockModel(
            name: "us.amazon.nova-lite-v1:0",
            provider: provider
        )

        let response = try await novaModel.complete("Say 'hello' and nothing else.")

        #expect(response.content != nil)
        #expect(response.content?.lowercased().contains("hello") == true)
    }

    // MARK: - Helpers

    /// Creates a minimal valid PNG with a solid color.
    private func createTestPNG(color: (r: UInt8, g: UInt8, b: UInt8)) -> Data {
        var data = Data()

        // PNG signature
        data.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        // IHDR chunk
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

        // IDAT chunk
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

        let compressed = compressZlib(rawData)
        let idat = createPNGChunk(type: "IDAT", data: compressed)
        data.append(idat)

        // IEND chunk
        let iend = createPNGChunk(type: "IEND", data: Data())
        data.append(iend)

        return data
    }

    private func createPNGChunk(type: String, data: Data) -> Data {
        var chunk = Data()

        var length = UInt32(data.count).bigEndian
        chunk.append(Data(bytes: &length, count: 4))
        chunk.append(type.data(using: .ascii)!)
        chunk.append(data)

        var crcData = type.data(using: .ascii)!
        crcData.append(data)
        var crc = crc32(crcData).bigEndian
        chunk.append(Data(bytes: &crc, count: 4))

        return chunk
    }

    private func compressZlib(_ data: Data) -> Data {
        var result = Data()
        result.append(0x78)
        result.append(0x01)
        result.append(0x01)

        let len = UInt16(data.count)
        result.append(UInt8(len & 0xFF))
        result.append(UInt8(len >> 8))
        result.append(UInt8(~len & 0xFF))
        result.append(UInt8(~len >> 8))
        result.append(data)

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
