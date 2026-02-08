/// Integration tests specific to LocalModel + LocalProvider (LM Studio).
///
/// Tests LM Studio-specific behavior that isn't covered by cross-provider tests.
/// Requires LM Studio running locally. Gated by `LM_STUDIO_TESTS=1` or `INTEGRATION=1`.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("LM Studio Provider", .enabled(if: ProviderFixture.lmStudio != nil))
struct LMStudioProviderTests {

    private var provider: LocalProvider {
        LocalProvider.lmStudio(port: TestConfig.lmStudioPort)
    }

    private var model: LocalModel {
        LocalModel(name: TestConfig.lmStudioTestModel, provider: provider)
    }

    // MARK: - Model Listing

    @Test func listModels() async throws {
        var models: [ModelInfo] = []

        for try await model in provider.listModels() {
            models.append(model)
        }

        #expect(!models.isEmpty, "LM Studio should have at least one model")

        let hasTestModel = models.contains { $0.id.contains(TestConfig.lmStudioTestModel) }
        #expect(hasTestModel, "Should find test model '\(TestConfig.lmStudioTestModel)' in model list")
    }

    @Test func listModels_returnsUnfiltered() async throws {
        var models: [ModelInfo] = []

        for try await model in provider.listModels() {
            models.append(model)
        }

        for model in models {
            #expect(!model.id.isEmpty, "Model ID should not be empty")
            #expect(!model.displayName.isEmpty, "Display name should not be empty")
        }
    }

    // MARK: - Basic Completion

    @Test func simpleCompletion() async throws {
        let response = try await model.complete("What is 2+2? Reply with just the number.")

        #expect(response.content != nil, "Should have content")
        #expect(
            response.content?.contains("4") == true,
            "Response should contain '4', got: \(response.content ?? "nil")"
        )
    }

    // MARK: - Tool Calling

    @Test func toolCall_singleTurn() async throws {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "Get the current weather for a city",
            inputSchema: [
                "type": "object",
                "properties": [
                    "city": [
                        "type": "string",
                        "description": "City name"
                    ]
                ],
                "required": ["city"]
            ]
        )

        let request = CompletionRequest(
            messages: [.user("What's the weather in Paris? Use the get_weather tool.")],
            tools: [tool]
        )

        let response = try await model.complete(request)
        #expect(response.stopReason == .toolUse, "Should request tool use")
        #expect(!response.toolCalls.isEmpty, "Should have tool calls")
        #expect(response.toolCalls[0].name == "get_weather", "Should call get_weather")
    }

    // MARK: - Streaming

    @Test func streaming_basicContent() async throws {
        var accumulated = ""
        var finalResponse: CompletionResponse?

        for try await event in model.stream("Say exactly: Hello World") {
            switch event {
            case .contentDelta(let text, _):
                accumulated += text
            case .done(let response):
                finalResponse = response
            default:
                break
            }
        }

        #expect(finalResponse != nil, "Should have final response")
        #expect(accumulated.contains("Hello"), "Should contain 'Hello', got: '\(accumulated)'")
        #expect(accumulated.contains("World"), "Should contain 'World', got: '\(accumulated)'")
    }

    @Test func streaming_toolCalls() async throws {
        let tool = ToolDefinition(
            name: "lookup",
            description: "Look up information",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to look up"]
                ],
                "required": ["query"]
            ]
        )

        let request = CompletionRequest(
            messages: [.user("Look up the population of France. Use the lookup tool.")],
            tools: [tool]
        )

        var toolCallStarted = false
        var toolName: String?
        var argumentsAccumulated = ""
        var finalResponse: CompletionResponse?

        for try await event in model.stream(request) {
            switch event {
            case .toolCallStart(_, let name):
                toolCallStarted = true
                toolName = name
            case .toolCallDelta(let delta):
                argumentsAccumulated += delta
            case .done(let response):
                finalResponse = response
            default:
                break
            }
        }

        #expect(toolCallStarted, "Should receive toolCallStart")
        #expect(toolName == "lookup", "Tool name should be 'lookup'")
        #expect(!argumentsAccumulated.isEmpty, "Should accumulate arguments")
        #expect(finalResponse?.stopReason == .toolUse, "Should stop for tool use")
    }

    // MARK: - LM Studio Behavior

    @Test func unknownModel_fallsBackToActive() async throws {
        // LM Studio silently falls back to the active model for unknown model names
        // (unlike Ollama which returns 404). Verify it still produces a response.
        let fallbackModel = LocalModel(
            name: "nonexistent-model-that-does-not-exist",
            provider: provider
        )

        let response = try await fallbackModel.complete("Say hi")
        #expect(response.content != nil, "Should produce content via fallback model")
    }
}
