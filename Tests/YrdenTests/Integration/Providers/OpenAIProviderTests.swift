/// OpenAI-specific integration tests.
///
/// Tests unique to OpenAI that aren't covered by cross-provider tests.
/// Gated via ProviderFixture — only runs when OPENAI_TESTS=1 or INTEGRATION=1.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("OpenAI Provider", .enabled(if: ProviderFixture.openAI != nil))
struct OpenAIProviderTests {

    private var provider: OpenAIProvider {
        OpenAIProvider(apiKey: TestConfig.openAIAPIKey)
    }

    private var model: OpenAIModel {
        OpenAIModel(name: "gpt-5-mini", provider: provider)
    }

    // MARK: - Error Handling

    @Test("invalid API key returns invalidAPIKey error")
    func invalidAPIKey() async throws {
        let badProvider = OpenAIProvider(apiKey: "sk-invalid-key")
        let badModel = OpenAIModel(name: "gpt-4o-mini", provider: badProvider)

        do {
            _ = try await badModel.complete("Hello")
            Issue.record("Expected error to be thrown")
        } catch let error as LLMError {
            #expect(error == .invalidAPIKey)
        }
    }

    @Test("invalid model name returns appropriate error")
    func invalidModel() async throws {
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

    @Test("list models returns GPT models")
    func listModels() async throws {
        var models: [ModelInfo] = []

        for try await model in provider.listModels() {
            models.append(model)
            if models.count >= 5 {
                break
            }
        }

        #expect(!models.isEmpty)
        let hasGPT = models.contains { $0.id.hasPrefix("gpt-") }
        #expect(hasGPT)
    }

    // MARK: - Structured Output

    @Test("structured output - sentiment analysis with JSON schema")
    func structuredOutput_sentimentAnalysis() async throws {
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
            config: CompletionConfig(maxTokens: 2000)
        )

        let response = try await model.complete(request)

        #expect(response.content != nil)

        let jsonData = Data(response.content!.utf8)
        let result = try JSONDecoder().decode(JSONValue.self, from: jsonData)

        guard case .object(let obj) = result else {
            Issue.record("Expected object response")
            return
        }

        guard let sentimentValue = obj["sentiment"],
              case .string(let sentiment) = sentimentValue else {
            Issue.record("Missing sentiment field")
            return
        }
        #expect(["positive", "negative", "neutral"].contains(sentiment))
        #expect(sentiment == "positive")

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

        guard let keywordsValue = obj["keywords"],
              case .array(let keywords) = keywordsValue else {
            Issue.record("Missing keywords field")
            return
        }
        #expect(!keywords.isEmpty)
    }

    @Test("structured output - data extraction")
    func structuredOutput_dataExtraction() async throws {
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
            config: CompletionConfig(maxTokens: 2000)
        )

        let response = try await model.complete(request)

        #expect(response.content != nil)

        let jsonData = Data(response.content!.utf8)
        let result = try JSONDecoder().decode(JSONValue.self, from: jsonData)

        guard case .object(let obj) = result else {
            Issue.record("Expected object response")
            return
        }

        guard let nameValue = obj["name"], case .string(let name) = nameValue else {
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

        guard let emailValue = obj["email"], case .string(let email) = emailValue else {
            Issue.record("Missing email field")
            return
        }
        #expect(email.contains("john.smith"))
    }

    @Test("structured output with streaming")
    func structuredOutput_streaming() async throws {
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
            config: CompletionConfig(maxTokens: 2000)
        )

        var accumulatedContent = ""
        var gotDone = false

        for try await event in model.stream(request) {
            switch event {
            case .contentDelta(let delta, _):
                accumulatedContent += delta
            case .done(let response):
                gotDone = true
                #expect(response.content != nil)
            default:
                break
            }
        }

        #expect(gotDone)

        let jsonData = Data(accumulatedContent.utf8)
        let result = try JSONDecoder().decode(JSONValue.self, from: jsonData)

        guard case .object(let obj) = result else {
            Issue.record("Expected object response")
            return
        }

        guard let answerValue = obj["answer"], case .string(let answer) = answerValue else {
            Issue.record("Missing answer field")
            return
        }
        #expect(answer.contains("4"))

        guard let explanationValue = obj["explanation"], case .string(_) = explanationValue else {
            Issue.record("Missing explanation field")
            return
        }
    }

    // MARK: - Multiple Tool Calls (Responses API)

    /// Note: The Responses API has a known limitation where it doesn't reliably
    /// produce multiple parallel tool calls in a single response.
    @Test("multiple tool calls with Responses API")
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

        let request = CompletionRequest(
            messages: [
                .system("When asked about multiple cities, make separate tool calls for each city."),
                .user("What's the weather in NYC and LA? Call the get_weather function for each city separately.")
            ],
            tools: [weatherTool]
        )

        let response = try await model.complete(request)

        #expect(response.stopReason == .toolUse)
        #expect(response.toolCalls.count >= 1)
    }

    // MARK: - o1 Reasoning Model Tests

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_EXPENSIVE_TESTS"] != nil))
    func o1_simpleCompletion() async throws {
        let o1Model = OpenAIModel(name: "o1-mini", provider: provider)

        let response = try await o1Model.complete("What is 2+2? Reply with just the number.")

        #expect(response.content?.contains("4") == true)
        #expect(response.stopReason == .endTurn)
    }

    @Test("o1 rejects temperature parameter")
    func o1_noTemperature_validation() async throws {
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

    @Test("o1 rejects tools")
    func o1_noTools_validation() async throws {
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

    @Test("o1 rejects system messages")
    func o1_noSystemMessage_validation() async throws {
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

    // MARK: - GPT-5 Model Tests

    @Test("GPT-5.2 simple completion")
    func gpt5_simpleCompletion() async throws {
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

    @Test("GPT-5.2 streaming")
    func gpt5_streaming() async throws {
        let gpt5Model = OpenAIModel(name: "gpt-5.2", provider: provider)

        let request = CompletionRequest(
            messages: [.user("Count from 1 to 5, one number per line.")],
            config: CompletionConfig(temperature: 0.0, maxTokens: 100)
        )

        var accumulatedContent = ""
        var gotDone = false

        for try await event in gpt5Model.stream(request) {
            switch event {
            case .contentDelta(let delta, _):
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

    // MARK: - o3 Reasoning Model Tests

    @Test("o3-mini simple completion")
    func o3_simpleCompletion() async throws {
        let o3Model = OpenAIModel(name: "o3-mini", provider: provider)

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
        #expect(response.usage.outputTokens > 10)
    }

    @Test("o3-mini rejects temperature parameter")
    func o3_capabilityValidation() async throws {
        let o3Model = OpenAIModel(name: "o3-mini", provider: provider)

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
