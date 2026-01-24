/// Cross-provider streaming tests.
///
/// Tests streaming functionality across all providers.

import Testing
import Foundation
@testable import Yrden

@Suite("Cross-Provider Streaming")
struct CrossProviderStreamingTests {

    // MARK: - Basic Streaming

    @Test(arguments: ProviderFixture.all)
    func streaming(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsStreaming else { return }

        var chunks: [String] = []
        var finalResponse: CompletionResponse?

        for try await event in subject.model.stream("Count from 1 to 5, separated by commas.") {
            switch event {
            case .contentDelta(let text):
                chunks.append(text)
            case .done(let response):
                finalResponse = response
            default:
                break
            }
        }

        #expect(!chunks.isEmpty, "Should receive content chunks")
        #expect(finalResponse != nil, "Should receive final response")
        #expect(finalResponse?.stopReason == .endTurn, "Should stop with endTurn")

        let accumulated = chunks.joined()
        #expect(accumulated.contains("1"), "Content should contain '1'")
        #expect(accumulated.contains("5"), "Content should contain '5'")
    }

    @Test(arguments: ProviderFixture.all)
    func streamingWithLongResponse(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsStreaming else { return }

        var chunkCount = 0

        for try await event in subject.model.stream("Write a short paragraph about Swift programming.") {
            if case .contentDelta = event {
                chunkCount += 1
            }
        }

        #expect(chunkCount > 5, "Should receive multiple chunks, got \(chunkCount)")
    }

    // MARK: - Content Accumulation

    @Test(arguments: ProviderFixture.all)
    func streamingContentMatchesFinal(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsStreaming else { return }

        var accumulated = ""
        var finalResponse: CompletionResponse?

        for try await event in subject.model.stream("Say exactly: Hello World") {
            switch event {
            case .contentDelta(let text):
                accumulated += text
            case .done(let response):
                finalResponse = response
            default:
                break
            }
        }

        #expect(finalResponse != nil, "Should have final response")
        #expect(
            accumulated == finalResponse?.content,
            "Accumulated '\(accumulated)' should match final '\(finalResponse?.content ?? "nil")'"
        )
    }

    // MARK: - Usage Tracking

    @Test(arguments: ProviderFixture.all)
    func streamingUsageTracking(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsStreaming else { return }

        var finalResponse: CompletionResponse?

        for try await event in subject.model.stream("Hi") {
            if case .done(let response) = event {
                finalResponse = response
            }
        }

        #expect(finalResponse != nil, "Should have final response")
        #expect(finalResponse!.usage.inputTokens > 0, "Should have input tokens")
        #expect(finalResponse!.usage.outputTokens > 0, "Should have output tokens")
    }

    // MARK: - Max Tokens

    @Test(arguments: ProviderFixture.all)
    func streamingWithMaxTokens(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsStreaming else { return }

        let maxTokens = max(subject.constraints.minMaxTokens, 20)

        let request = CompletionRequest(
            messages: [.user("Count from 1 to 100, each number on a new line.")],
            config: CompletionConfig(maxTokens: maxTokens)
        )

        var accumulated = ""
        var finalResponse: CompletionResponse?

        for try await event in subject.model.stream(request) {
            switch event {
            case .contentDelta(let text):
                accumulated += text
            case .done(let response):
                finalResponse = response
            default:
                break
            }
        }

        #expect(finalResponse != nil, "Should have final response")

        // Verify truncation - response should not contain high numbers
        // Note: Some providers (OpenAI Responses API streaming) don't report maxTokens stop reason correctly
        let outputTokens = finalResponse?.usage.outputTokens ?? 0
        let stoppedEarly = finalResponse?.stopReason == .maxTokens ||
                          !accumulated.contains("50")  // Behavioral check - shouldn't reach 50

        #expect(
            stoppedEarly,
            "Should stop early due to maxTokens. Stop reason: \(String(describing: finalResponse?.stopReason)), tokens: \(outputTokens), content: \(accumulated.prefix(100))..."
        )
        #expect(
            outputTokens <= maxTokens + 10,
            "Output tokens (\(outputTokens)) should be near maxTokens (\(maxTokens))"
        )
    }

    // MARK: - Stop Sequences

    @Test(arguments: ProviderFixture.all)
    func streamingWithStopSequences(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsStreaming else { return }
        guard subject.constraints.supportsStopSequences else { return }

        let request = CompletionRequest(
            messages: [.user("Output only numbers 1 through 20, one per line, no other text.")],
            config: CompletionConfig(stopSequences: ["8"])
        )

        var accumulated = ""
        var finalResponse: CompletionResponse?

        for try await event in subject.model.stream(request) {
            switch event {
            case .contentDelta(let text):
                accumulated += text
            case .done(let response):
                finalResponse = response
            default:
                break
            }
        }

        #expect(finalResponse?.stopReason == .stopSequence, "Should stop at sequence")
        #expect(accumulated.contains("1"), "Should contain '1'")
        #expect(!accumulated.contains("12"), "Should NOT contain '12'")
    }

    // MARK: - Tool Streaming

    @Test(arguments: ProviderFixture.all)
    func streamingWithTools(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsStreaming else { return }
        guard subject.constraints.supportsTools else { return }

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
            messages: [.user("What's the weather in Tokyo?")],
            tools: [weatherTool]
        )

        var toolCallStarted = false
        var toolCallEnded = false
        var toolName: String?
        var argumentsAccumulated = ""
        var finalResponse: CompletionResponse?

        for try await event in subject.model.stream(request) {
            switch event {
            case .toolCallStart(_, let name):
                toolCallStarted = true
                toolName = name
            case .toolCallDelta(let delta):
                argumentsAccumulated += delta
            case .toolCallEnd:
                toolCallEnded = true
            case .done(let response):
                finalResponse = response
            default:
                break
            }
        }

        #expect(toolCallStarted, "Should receive toolCallStart event")
        #expect(toolCallEnded, "Should receive toolCallEnd event")
        #expect(toolName == "get_weather", "Tool name should be 'get_weather'")
        #expect(argumentsAccumulated.lowercased().contains("tokyo"), "Arguments should contain 'tokyo'")
        #expect(finalResponse?.stopReason == .toolUse, "Should stop for tool use")
        #expect(!finalResponse!.toolCalls.isEmpty, "Final response should have tool calls")
    }
}
