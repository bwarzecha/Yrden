/// Integration tests specific to LocalModel + LocalProvider (Ollama).
///
/// Tests local-specific behavior that isn't covered by cross-provider tests.
/// Requires Ollama running locally. Gated by `LOCAL_TESTS=1` or `INTEGRATION=1`.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Local Provider", .enabled(if: ProviderFixture.local != nil))
struct LocalProviderTests {

    private var provider: LocalProvider {
        LocalProvider.ollama(port: TestConfig.ollamaPort)
    }

    private var model: LocalModel {
        LocalModel(name: TestConfig.ollamaTestModel, provider: provider)
    }

    // MARK: - Model Listing

    @Test func listModels() async throws {
        var models: [ModelInfo] = []

        for try await model in provider.listModels() {
            models.append(model)
        }

        #expect(!models.isEmpty, "Ollama should have at least one model")

        // The test model should be in the list
        let hasTestModel = models.contains { $0.id.contains(TestConfig.ollamaTestModel) }
        #expect(hasTestModel, "Should find test model '\(TestConfig.ollamaTestModel)' in model list")
    }

    @Test func listModels_returnsUnfiltered() async throws {
        // Unlike OpenAIProvider, LocalProvider returns ALL models without filtering
        var models: [ModelInfo] = []

        for try await model in provider.listModels() {
            models.append(model)
        }

        // Every model from Ollama should be present (no prefix filtering)
        for model in models {
            #expect(!model.id.isEmpty, "Model ID should not be empty")
            #expect(!model.displayName.isEmpty, "Display name should not be empty")
        }
    }

    // MARK: - Error Handling

    @Test func invalidModel_returnsError() async throws {
        let badModel = LocalModel(
            name: "nonexistent-model-that-does-not-exist",
            provider: provider
        )

        do {
            _ = try await badModel.complete("Hello")
            Issue.record("Should have thrown for nonexistent model")
        } catch {
            // Ollama returns 404 for unknown models
            #expect(error is LLMError, "Error should be LLMError, got \(type(of: error))")
        }
    }

    // MARK: - Thinking Mode

    @Test func thinkingMode_enabledByDefault() async throws {
        // Qwen3 uses thinking by default - verify we handle /think tags correctly
        let response = try await model.complete("What is 2+2? Reply with just the number.")

        #expect(response.content != nil, "Should have content")
        #expect(
            response.content?.contains("4") == true,
            "Response should contain '4', got: \(response.content ?? "nil")"
        )
    }

    // MARK: - Tool Calling

    @Test func toolCall_multiTurn() async throws {
        let tool = ToolDefinition(
            name: "get_time",
            description: "Get the current time in a timezone",
            inputSchema: [
                "type": "object",
                "properties": [
                    "timezone": [
                        "type": "string",
                        "description": "Timezone name like UTC, US/Eastern"
                    ]
                ],
                "required": ["timezone"]
            ]
        )

        // First turn: ask model to use the tool
        let request1 = CompletionRequest(
            messages: [.user("What time is it in UTC? Use the get_time tool.")],
            tools: [tool]
        )

        let response1 = try await model.complete(request1)
        #expect(response1.stopReason == .toolUse, "Should request tool use")
        #expect(!response1.toolCalls.isEmpty, "Should have tool calls")
        #expect(response1.toolCalls[0].name == "get_time", "Should call get_time")

        // Second turn: provide tool result
        let toolCall = response1.toolCalls[0]
        let request2 = CompletionRequest(
            messages: [
                .user("What time is it in UTC? Use the get_time tool."),
                .assistant(response1.content ?? "", toolCalls: response1.toolCalls),
                .toolResult(toolCallId: toolCall.id, content: "14:30 UTC")
            ],
            tools: [tool]
        )

        let response2 = try await model.complete(request2)
        #expect(response2.stopReason == .endTurn, "Should complete after tool result")
        #expect(
            response2.content?.contains("14:30") == true || response2.content?.contains("2:30") == true,
            "Response should reference the time"
        )
    }

    // MARK: - Streaming

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

    // MARK: - Provider Presets

    @Test func presets_haveCorrectURLs() {
        let ollama = LocalProvider.ollama()
        #expect(ollama.baseURL.absoluteString == "http://localhost:11434/v1")

        let lmStudio = LocalProvider.lmStudio()
        #expect(lmStudio.baseURL.absoluteString == "http://localhost:1234/v1")

        let vllm = LocalProvider.vllm()
        #expect(vllm.baseURL.absoluteString == "http://localhost:8000/v1")
    }

    @Test func presets_customPort() {
        let custom = LocalProvider.ollama(port: 9999)
        #expect(custom.baseURL.absoluteString == "http://localhost:9999/v1")
    }
}
