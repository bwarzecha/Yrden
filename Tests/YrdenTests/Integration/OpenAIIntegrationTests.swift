/// Integration tests for OpenAI provider.
///
/// These tests make real API calls to validate the implementation.
/// Requires OPENAI_API_KEY to be set.
///
/// Run with: swift test --filter OpenAIIntegration
///
/// Tests cover:
/// - Standard models (gpt-4o-mini) with full capabilities
/// - Reasoning models (o1-mini) with limited capabilities

import Testing
import Foundation
@testable import Yrden

@Suite("OpenAI Integration")
struct OpenAIIntegrationTests {

    let provider: OpenAIProvider
    let model: OpenAIModel

    init() {
        let apiKey = TestConfig.openAIAPIKey
        provider = OpenAIProvider(apiKey: apiKey)
        // Use gpt-4o-mini for cost-effective testing
        model = OpenAIModel(name: "gpt-4o-mini", provider: provider)
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
                            content.contains("ye") ||
                            content.contains("avast")
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
            config: CompletionConfig(maxTokens: 20)  // Responses API requires min 16
        )

        let response = try await model.complete(request)

        // Should be truncated
        #expect(response.stopReason == .maxTokens)
        #expect(response.usage.outputTokens <= 25)  // Some margin
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

        var toolCallStarted = false
        var toolCallDeltas: [String] = []
        var toolCallEnded = false
        var finalResponse: CompletionResponse?

        let request = CompletionRequest(
            messages: [.user("Search for 'swift concurrency'")],
            tools: [searchTool]
        )

        for try await event in model.stream(request) {
            switch event {
            case .toolCallStart(_, let name):
                toolCallStarted = true
                #expect(name == "search")
            case .toolCallDelta(let delta):
                toolCallDeltas.append(delta)
            case .toolCallEnd:
                toolCallEnded = true
            case .done(let response):
                finalResponse = response
            default:
                break
            }
        }

        #expect(toolCallStarted)
        #expect(!toolCallDeltas.isEmpty)
        #expect(toolCallEnded)
        #expect(finalResponse?.stopReason == .toolUse)
    }

    /// Tests tool calling with multiple cities.
    ///
    /// Note: The Responses API has a known limitation where it doesn't reliably
    /// produce multiple parallel tool calls in a single response, even with
    /// `parallel_tool_calls: true`. This is an OpenAI API limitation.
    /// See: https://community.openai.com/t/chatcompletions-vs-responses-api-difference-in-parallel-tool-call-behaviour-observed/1369663
    ///
    /// This test verifies at least one tool call is made. Parallel calls may
    /// or may not occur depending on the model's behavior.
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

        let request = CompletionRequest(
            messages: [
                .system("When asked about multiple cities, make separate tool calls for each city."),
                .user("What's the weather in NYC and LA? Call the get_weather function for each city separately.")
            ],
            tools: [weatherTool]
        )

        let response = try await model.complete(request)

        #expect(response.stopReason == .toolUse)
        // Note: Responses API may return 1 or 2 tool calls due to known limitation
        #expect(response.toolCalls.count >= 1)
    }

    // MARK: - Multi-turn Conversation

    @Test func multiTurnConversation() async throws {
        let messages1: [Message] = [
            .system("You are a helpful assistant."),
            .user("My name is Alice.")
        ]

        let response1 = try await model.complete(messages: messages1)

        let messages2: [Message] = [
            .system("You are a helpful assistant."),
            .user("My name is Alice."),
            .assistant(response1.content ?? "", toolCalls: []),
            .user("What is my name?")
        ]

        let response2 = try await model.complete(messages: messages2)

        #expect(response2.content?.contains("Alice") == true)
    }

    // MARK: - Error Handling

    @Test func invalidAPIKey() async throws {
        let badProvider = OpenAIProvider(apiKey: "sk-invalid-key")
        let badModel = OpenAIModel(name: "gpt-4o-mini", provider: badProvider)

        do {
            _ = try await badModel.complete("Hello")
            Issue.record("Expected error to be thrown")
        } catch let error as LLMError {
            #expect(error == .invalidAPIKey)
        }
    }

    @Test func invalidModel() async throws {
        let badModel = OpenAIModel(name: "not-a-real-model", provider: provider)

        do {
            _ = try await badModel.complete("Hello")
            Issue.record("Expected error to be thrown")
        } catch let error as LLMError {
            if case .modelNotFound(let name) = error {
                #expect(name == "not-a-real-model")
            } else if case .invalidRequest = error {
                // OpenAI may return this instead
            } else {
                Issue.record("Expected modelNotFound or invalidRequest error, got \(error)")
            }
        }
    }

    // MARK: - Model Listing

    @Test func listModels() async throws {
        var models: [ModelInfo] = []

        for try await model in provider.listModels() {
            models.append(model)
            // Early exit after finding some models
            if models.count >= 5 {
                break
            }
        }

        #expect(!models.isEmpty)

        // Should contain GPT models
        let hasGPT = models.contains { $0.id.hasPrefix("gpt-") }
        #expect(hasGPT)
    }

    // MARK: - Vision

    @Test func imageInput() async throws {
        // Create a minimal red PNG (2x2 pixels)
        let redPNG = createTestPNG(color: .red)

        let request = CompletionRequest(
            messages: [
                .user([
                    .text("What color is this image? Answer with just the color name."),
                    .image(redPNG, mimeType: "image/png")
                ])
            ]
        )

        let response = try await model.complete(request)

        #expect(response.content?.lowercased().contains("red") == true)
    }

    // MARK: - Structured Output

    @Test func structuredOutput_sentimentAnalysis() async throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "sentiment": [
                    "type": "string",
                    "enum": ["positive", "negative", "neutral"]
                ],
                "confidence": [
                    "type": "number",
                    "minimum": 0,
                    "maximum": 1
                ],
                "keywords": [
                    "type": "array",
                    "items": ["type": "string"]
                ]
            ],
            "required": ["sentiment", "confidence", "keywords"],
            "additionalProperties": false
        ]

        let request = CompletionRequest(
            messages: [
                .system("You are a sentiment analyzer. Analyze the sentiment of the given text."),
                .user("I absolutely love this product! It's amazing and works perfectly.")
            ],
            outputSchema: schema,
            config: CompletionConfig(temperature: 0.0, maxTokens: 2000)
        )

        let response = try await model.complete(request)

        #expect(response.content != nil)

        // Parse the JSON response
        let jsonData = Data(response.content!.utf8)
        let result = try JSONDecoder().decode(JSONValue.self, from: jsonData)

        // Verify structure
        guard case .object(let obj) = result else {
            Issue.record("Expected object response")
            return
        }

        // Check sentiment is one of the enum values
        guard let sentimentValue = obj["sentiment"],
              case .string(let sentiment) = sentimentValue else {
            Issue.record("Missing sentiment field")
            return
        }
        #expect(["positive", "negative", "neutral"].contains(sentiment))
        #expect(sentiment == "positive") // Should be positive for this input

        // Check confidence is a number between 0 and 1
        guard let confidenceValue = obj["confidence"] else {
            Issue.record("Missing confidence field")
            return
        }
        let confidence: Double
        switch confidenceValue {
        case .double(let d): confidence = d
        case .int(let i): confidence = Double(i)
        default:
            Issue.record("Confidence is not a number")
            return
        }
        #expect(confidence >= 0 && confidence <= 1)

        // Check keywords is an array
        guard let keywordsValue = obj["keywords"],
              case .array(let keywords) = keywordsValue else {
            Issue.record("Missing keywords field")
            return
        }
        #expect(!keywords.isEmpty)
    }

    @Test func structuredOutput_dataExtraction() async throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "age": ["type": "integer"],
                "email": ["type": "string"]
            ],
            "required": ["name", "age", "email"],
            "additionalProperties": false
        ]

        let request = CompletionRequest(
            messages: [
                .user("Extract the person info: John Smith is 32 years old and can be reached at john.smith@email.com")
            ],
            outputSchema: schema,
            config: CompletionConfig(temperature: 0.0, maxTokens: 2000)
        )

        let response = try await model.complete(request)

        #expect(response.content != nil)

        // Parse and verify
        let jsonData = Data(response.content!.utf8)
        let result = try JSONDecoder().decode(JSONValue.self, from: jsonData)

        guard case .object(let obj) = result else {
            Issue.record("Expected object response")
            return
        }

        guard let nameValue = obj["name"],
              case .string(let name) = nameValue else {
            Issue.record("Missing name field")
            return
        }
        #expect(name.contains("John"))

        guard let ageValue = obj["age"] else {
            Issue.record("Missing age field")
            return
        }
        let age: Int
        switch ageValue {
        case .int(let i): age = i
        case .double(let d): age = Int(d)
        default:
            Issue.record("Age is not a number")
            return
        }
        #expect(age == 32)

        guard let emailValue = obj["email"],
              case .string(let email) = emailValue else {
            Issue.record("Missing email field")
            return
        }
        #expect(email.contains("john.smith"))
    }

    @Test func structuredOutput_streaming() async throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "answer": ["type": "string"],
                "explanation": ["type": "string"]
            ],
            "required": ["answer", "explanation"],
            "additionalProperties": false
        ]

        let request = CompletionRequest(
            messages: [
                .user("What is 2+2? Provide answer and brief explanation.")
            ],
            outputSchema: schema,
            config: CompletionConfig(temperature: 0.0, maxTokens: 2000)
        )

        var accumulatedContent = ""
        var gotDone = false

        for try await event in model.stream(request) {
            switch event {
            case .contentDelta(let delta):
                accumulatedContent += delta
            case .done(let response):
                gotDone = true
                #expect(response.content != nil)
            default:
                break
            }
        }

        #expect(gotDone)

        // Parse the accumulated JSON
        let jsonData = Data(accumulatedContent.utf8)
        let result = try JSONDecoder().decode(JSONValue.self, from: jsonData)

        guard case .object(let obj) = result else {
            Issue.record("Expected object response")
            return
        }

        guard let answerValue = obj["answer"],
              case .string(let answer) = answerValue else {
            Issue.record("Missing answer field")
            return
        }
        #expect(answer.contains("4"))

        guard let explanationValue = obj["explanation"],
              case .string(_) = explanationValue else {
            Issue.record("Missing explanation field")
            return
        }
    }

    // MARK: - o1 Model Tests (Reasoning Models with Limitations)
    //
    // These tests require access to o1 models which may not be available in all accounts.
    // Run with: RUN_EXPENSIVE_TESTS=1 swift test --filter o1_

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_EXPENSIVE_TESTS"] != nil))
    func o1_simpleCompletion() async throws {
        let o1Model = OpenAIModel(name: "o1-mini", provider: provider)

        let response = try await o1Model.complete("What is 2+2? Reply with just the number.")

        #expect(response.content?.contains("4") == true)
        #expect(response.stopReason == .endTurn)
    }

    // Capability validation tests - these don't require actual API calls to o1,
    // they just verify our validation logic catches unsupported features early.

    @Test func o1_noTemperature_validation() async throws {
        let o1Model = OpenAIModel(name: "o1-mini", provider: provider)

        let request = CompletionRequest(
            messages: [.user("Hello")],
            config: CompletionConfig(temperature: 0.5)
        )

        do {
            _ = try await o1Model.complete(request)
            Issue.record("Should have thrown capabilityNotSupported")
        } catch let error as LLMError {
            if case .capabilityNotSupported(let message) = error {
                #expect(message.contains("temperature"))
            } else {
                Issue.record("Expected capabilityNotSupported error, got \(error)")
            }
        }
    }

    @Test func o1_noTools_validation() async throws {
        let o1Model = OpenAIModel(name: "o1-mini", provider: provider)

        let tool = ToolDefinition(
            name: "test",
            description: "Test tool",
            inputSchema: ["type": "object"]
        )

        let request = CompletionRequest(
            messages: [.user("Hello")],
            tools: [tool]
        )

        do {
            _ = try await o1Model.complete(request)
            Issue.record("Should have thrown capabilityNotSupported")
        } catch let error as LLMError {
            if case .capabilityNotSupported(let message) = error {
                #expect(message.contains("tools"))
            } else {
                Issue.record("Expected capabilityNotSupported error, got \(error)")
            }
        }
    }

    @Test func o1_noSystemMessage_validation() async throws {
        let o1Model = OpenAIModel(name: "o1-mini", provider: provider)

        let request = CompletionRequest(
            messages: [
                .system("You are helpful."),
                .user("Hello")
            ]
        )

        do {
            _ = try await o1Model.complete(request)
            Issue.record("Should have thrown capabilityNotSupported")
        } catch let error as LLMError {
            if case .capabilityNotSupported(let message) = error {
                #expect(message.contains("system"))
            } else {
                Issue.record("Expected capabilityNotSupported error, got \(error)")
            }
        }
    }

    // MARK: - Unicode Handling

    @Test func unicodeHandling() async throws {
        let response = try await model.complete("Echo exactly: こんにちは 🎉 مرحبا")

        let content = response.content ?? ""
        #expect(content.contains("こんにちは"))
        #expect(content.contains("🎉"))
        #expect(content.contains("مرحبا"))
    }

    @Test func unicodeInToolArguments() async throws {
        let greetTool = ToolDefinition(
            name: "greet",
            description: "Greet someone by name",
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string"]
                ],
                "required": ["name"]
            ]
        )

        let request = CompletionRequest(
            messages: [.user("Greet 田中さん using the greet tool")],
            tools: [greetTool]
        )

        let response = try await model.complete(request)

        #expect(!response.toolCalls.isEmpty)
        #expect(response.toolCalls[0].arguments.contains("田中"))
    }

    // MARK: - GPT-5 Model Tests (Newest Models)

    @Test func gpt5_simpleCompletion() async throws {
        let gpt5Model = OpenAIModel(name: "gpt-5.2", provider: provider)

        let request = CompletionRequest(
            messages: [
                .system("You are a helpful assistant. Be very concise."),
                .user("What is 2+2? Just the number.")
            ],
            config: CompletionConfig(temperature: 0.0, maxTokens: 50)
        )

        let response = try await gpt5Model.complete(request)

        #expect(response.content != nil)
        #expect(response.content!.contains("4"))
        #expect(response.stopReason == .endTurn)
    }

    @Test func gpt5_streaming() async throws {
        let gpt5Model = OpenAIModel(name: "gpt-5.2", provider: provider)

        let request = CompletionRequest(
            messages: [.user("Count from 1 to 5, one number per line.")],
            config: CompletionConfig(temperature: 0.0, maxTokens: 100)
        )

        var accumulatedContent = ""
        var gotDone = false

        for try await event in gpt5Model.stream(request) {
            switch event {
            case .contentDelta(let delta):
                accumulatedContent += delta
            case .done(let response):
                gotDone = true
                #expect(response.usage.inputTokens > 0)
                #expect(response.usage.outputTokens > 0)
            default:
                break
            }
        }

        #expect(gotDone)
        #expect(accumulatedContent.contains("1"))
        #expect(accumulatedContent.contains("5"))
    }

    @Test func o3_simpleCompletion() async throws {
        let o3Model = OpenAIModel(name: "o3-mini", provider: provider)

        // o3 doesn't support temperature or system messages
        let request = CompletionRequest(
            messages: [
                .user("What is 15 * 17? Think step by step, then give just the final number.")
            ],
            config: CompletionConfig(maxTokens: 4000)
        )

        let response = try await o3Model.complete(request)

        #expect(response.content != nil)
        #expect(response.content!.contains("255"))
        #expect(response.stopReason == .endTurn)
        // o3 models use more tokens due to reasoning
        #expect(response.usage.outputTokens > 10)
    }

    @Test func o3_capabilityValidation() async throws {
        let o3Model = OpenAIModel(name: "o3-mini", provider: provider)

        // Verify temperature is not supported
        let requestWithTemp = CompletionRequest(
            messages: [.user("Hello")],
            config: CompletionConfig(temperature: 0.5)
        )

        do {
            _ = try await o3Model.complete(requestWithTemp)
            Issue.record("Should have thrown capabilityNotSupported for temperature")
        } catch let error as LLMError {
            if case .capabilityNotSupported(let message) = error {
                #expect(message.contains("temperature"))
            } else {
                Issue.record("Expected capabilityNotSupported error, got \(error)")
            }
        }
    }
}

// MARK: - Test Helpers

/// Creates a minimal valid PNG image for testing.
private func createTestPNG(color: TestColor) -> Data {
    // Minimal PNG structure:
    // - PNG signature
    // - IHDR chunk (width=2, height=2, 8-bit RGB)
    // - IDAT chunk (compressed pixel data)
    // - IEND chunk

    var data = Data()

    // PNG signature
    data.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    // IHDR chunk
    let ihdr = createIHDRChunk(width: 2, height: 2)
    data.append(ihdr)

    // IDAT chunk with pixel data
    let idat = createIDATChunk(color: color, width: 2, height: 2)
    data.append(idat)

    // IEND chunk
    let iend = createIENDChunk()
    data.append(iend)

    return data
}

private enum TestColor {
    case red
    case green
    case blue

    var rgb: (UInt8, UInt8, UInt8) {
        switch self {
        case .red: return (255, 0, 0)
        case .green: return (0, 255, 0)
        case .blue: return (0, 0, 255)
        }
    }
}

private func createIHDRChunk(width: UInt32, height: UInt32) -> Data {
    var chunk = Data()

    // Chunk data
    var ihdrData = Data()
    ihdrData.append(contentsOf: withUnsafeBytes(of: width.bigEndian) { Array($0) })
    ihdrData.append(contentsOf: withUnsafeBytes(of: height.bigEndian) { Array($0) })
    ihdrData.append(8)   // Bit depth
    ihdrData.append(2)   // Color type (RGB)
    ihdrData.append(0)   // Compression method
    ihdrData.append(0)   // Filter method
    ihdrData.append(0)   // Interlace method

    // Length
    let length = UInt32(ihdrData.count)
    chunk.append(contentsOf: withUnsafeBytes(of: length.bigEndian) { Array($0) })

    // Type
    chunk.append(contentsOf: [0x49, 0x48, 0x44, 0x52])  // "IHDR"

    // Data
    chunk.append(ihdrData)

    // CRC
    var crcData = Data([0x49, 0x48, 0x44, 0x52])
    crcData.append(ihdrData)
    let crc = crc32(crcData)
    chunk.append(contentsOf: withUnsafeBytes(of: crc.bigEndian) { Array($0) })

    return chunk
}

private func createIDATChunk(color: TestColor, width: Int, height: Int) -> Data {
    let (r, g, b) = color.rgb

    // Raw scanlines with filter byte (0 = no filter)
    var raw = Data()
    for _ in 0..<height {
        raw.append(0)  // Filter byte
        for _ in 0..<width {
            raw.append(r)
            raw.append(g)
            raw.append(b)
        }
    }

    // Compress with zlib (deflate)
    let compressed = deflateCompress(raw)

    var chunk = Data()

    // Length
    let length = UInt32(compressed.count)
    chunk.append(contentsOf: withUnsafeBytes(of: length.bigEndian) { Array($0) })

    // Type
    chunk.append(contentsOf: [0x49, 0x44, 0x41, 0x54])  // "IDAT"

    // Data
    chunk.append(compressed)

    // CRC
    var crcData = Data([0x49, 0x44, 0x41, 0x54])
    crcData.append(compressed)
    let crc = crc32(crcData)
    chunk.append(contentsOf: withUnsafeBytes(of: crc.bigEndian) { Array($0) })

    return chunk
}

private func createIENDChunk() -> Data {
    var chunk = Data()

    // Length (0)
    chunk.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

    // Type
    chunk.append(contentsOf: [0x49, 0x45, 0x4E, 0x44])  // "IEND"

    // CRC of "IEND"
    let crc = crc32(Data([0x49, 0x45, 0x4E, 0x44]))
    chunk.append(contentsOf: withUnsafeBytes(of: crc.bigEndian) { Array($0) })

    return chunk
}

/// Minimal deflate compression (uncompressed block for simplicity).
private func deflateCompress(_ data: Data) -> Data {
    var result = Data()

    // Zlib header (no compression)
    result.append(0x78)  // CMF
    result.append(0x01)  // FLG

    // Deflate block (uncompressed)
    let len = UInt16(data.count)
    let nlen = ~len

    result.append(0x01)  // BFINAL=1, BTYPE=00 (uncompressed)
    result.append(UInt8(len & 0xFF))
    result.append(UInt8(len >> 8))
    result.append(UInt8(nlen & 0xFF))
    result.append(UInt8(nlen >> 8))
    result.append(data)

    // Adler-32 checksum
    let adler = adler32(data)
    result.append(contentsOf: withUnsafeBytes(of: adler.bigEndian) { Array($0) })

    return result
}

/// CRC-32 checksum for PNG chunks.
private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF

    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xEDB88320
            } else {
                crc >>= 1
            }
        }
    }

    return ~crc
}

/// Adler-32 checksum for zlib.
private func adler32(_ data: Data) -> UInt32 {
    var a: UInt32 = 1
    var b: UInt32 = 0

    for byte in data {
        a = (a + UInt32(byte)) % 65521
        b = (b + a) % 65521
    }

    return (b << 16) | a
}
