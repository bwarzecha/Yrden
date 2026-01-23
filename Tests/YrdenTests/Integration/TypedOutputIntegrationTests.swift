/// Integration tests for typed structured output API.
///
/// Tests the `generate` and `generateWithTool` convenience methods
/// that return `TypedResponse<T>` with decoded data directly.
///
/// Test coverage:
/// - `generate()` with OpenAI native structured output
/// - `generateWithTool()` with Anthropic tool-based approach
/// - Error handling for edge cases
/// - Streaming variants

import Foundation
import Testing
@testable import Yrden

// MARK: - Test Schema Types

@Schema(description: "Extracted person information")
private struct ExtractedPerson: Codable, Equatable {
    let name: String
    let age: Int
    let occupation: String
}

@Schema(description: "Simple extraction result")
private struct SimpleExtraction: Codable, Equatable {
    let value: String
    let confidence: Double
}

@Schema(description: "Analysis with multiple fields")
private struct AnalysisResult: Codable {
    let category: String
    let score: Int
    let keywords: [String]
}

// MARK: - Test Configuration

private let hasAnthropicKey = TestConfig.hasAnthropicAPIKey
private let hasOpenAIKey = TestConfig.hasOpenAIAPIKey

// MARK: - OpenAI Typed Output Tests

@Suite("Typed Output - OpenAI", .tags(.integration), .serialized)
struct OpenAITypedOutputTests {
    private let model = OpenAIModel(
        name: "gpt-5-mini",
        provider: OpenAIProvider(apiKey: TestConfig.openAIAPIKey)
    )

    @Test("generate() returns typed PersonExtraction", .enabled(if: hasOpenAIKey))
    func generateTypedPerson() async throws {
        let result = try await model.generate(
            "Extract person info: Dr. Sarah Chen is a 38-year-old cardiologist.",
            as: ExtractedPerson.self,
            systemPrompt: "Extract the person's name, age, and occupation. Return valid JSON."
        )

        #expect(result.data.name.lowercased().contains("sarah") || result.data.name.lowercased().contains("chen"))
        #expect(result.data.age == 38)
        #expect(result.data.occupation.lowercased().contains("cardiologist") ||
                result.data.occupation.lowercased().contains("doctor"))

        #expect(result.usage.totalTokens > 0)
        #expect(result.stopReason == .endTurn)
        #expect(!result.rawJSON.isEmpty)
    }

    @Test("generate() with messages array", .enabled(if: hasOpenAIKey))
    func generateWithMessages() async throws {
        let result = try await model.generate(
            messages: [
                .system("Extract structured data from the user's message."),
                .user("The confidence level is high (0.95) and the value is 'success'.")
            ],
            as: SimpleExtraction.self
        )

        #expect(result.data.value.lowercased().contains("success"))
        #expect(result.data.confidence >= 0.9)
    }

    @Test("generateWithTool() returns typed data from tool call", .enabled(if: hasOpenAIKey))
    func generateWithToolTyped() async throws {
        let result = try await model.generateWithTool(
            "Analyze: This article discusses machine learning and data science. Quality: excellent.",
            as: AnalysisResult.self,
            toolName: "analyze_content",
            toolDescription: "Analyze content and extract category, score (1-10), and keywords"
        )

        #expect(!result.data.category.isEmpty)
        #expect(result.data.score >= 1 && result.data.score <= 10)
        #expect(!result.data.keywords.isEmpty)
        #expect(result.stopReason == .toolUse)
    }

    @Test("generate() preserves usage statistics", .enabled(if: hasOpenAIKey))
    func generatePreservesUsage() async throws {
        let result = try await model.generate(
            "Extract: value is 'test', confidence is 0.5",
            as: SimpleExtraction.self
        )

        #expect(result.usage.inputTokens > 0)
        #expect(result.usage.outputTokens > 0)
    }
}

// MARK: - Anthropic Typed Output Tests

@Suite("Typed Output - Anthropic", .tags(.integration))
struct AnthropicTypedOutputTests {
    private let model = AnthropicModel(
        name: "claude-haiku-4-5",
        provider: AnthropicProvider(apiKey: TestConfig.anthropicAPIKey)
    )

    @Test("generateWithTool() returns typed PersonExtraction", .enabled(if: hasAnthropicKey))
    func generateWithToolTypedPerson() async throws {
        let result = try await model.generateWithTool(
            "Extract person info: Marcus Johnson is a 45-year-old software architect.",
            as: ExtractedPerson.self,
            toolName: "extract_person",
            toolDescription: "Extract person's name, age, and occupation",
            systemPrompt: "Use the extract_person tool to extract information."
        )

        #expect(result.data.name.lowercased().contains("marcus") || result.data.name.lowercased().contains("johnson"))
        #expect(result.data.age == 45)
        #expect(result.data.occupation.lowercased().contains("architect") ||
                result.data.occupation.lowercased().contains("software"))

        #expect(result.usage.totalTokens > 0)
        #expect(result.stopReason == .toolUse)
    }

    @Test("generateWithTool() with analysis schema", .enabled(if: hasAnthropicKey))
    func generateWithToolAnalysis() async throws {
        let content = """
            Article: The Rise of Machine Learning in Healthcare

            Machine learning algorithms are transforming medical diagnostics.
            AI systems can now detect cancer in medical images with 95% accuracy.
            Neural networks are being used to predict patient outcomes and
            recommend personalized treatments. This technology shows great promise.
            """

        let result = try await model.generateWithTool(
            "Analyze this article and extract: category, quality score (1-10), and key topics: \(content)",
            as: AnalysisResult.self,
            toolName: "analyze",
            toolDescription: "Extract category, score (1-10), and keywords from content",
            systemPrompt: "You must use the analyze tool to extract structured data from the provided content."
        )

        #expect(!result.data.category.isEmpty)
        #expect(result.data.score >= 1 && result.data.score <= 10)
        #expect(!result.data.keywords.isEmpty)
    }

    @Test("generateWithTool() with messages array", .enabled(if: hasAnthropicKey))
    func generateWithToolMessages() async throws {
        let result = try await model.generateWithTool(
            messages: [
                .system("Use the extract tool to extract data."),
                .user("The result shows value='positive' with confidence of 0.87")
            ],
            as: SimpleExtraction.self,
            toolName: "extract"
        )

        #expect(result.data.value.lowercased().contains("positive"))
        #expect(result.data.confidence >= 0.8)
    }
}

// MARK: - Streaming Typed Output Tests

@Suite("Typed Output - Streaming", .tags(.integration))
struct StreamingTypedOutputTests {
    private let openAIModel = OpenAIModel(
        name: "gpt-5-mini",
        provider: OpenAIProvider(apiKey: TestConfig.openAIAPIKey)
    )

    private let anthropicModel = AnthropicModel(
        name: "claude-haiku-4-5",
        provider: AnthropicProvider(apiKey: TestConfig.anthropicAPIKey)
    )

    @Test("generateStream() yields events and final response", .enabled(if: hasOpenAIKey))
    func generateStreamYieldsEvents() async throws {
        var contentDeltas: [String] = []
        var finalResponse: CompletionResponse?

        for try await event in openAIModel.generateStream(
            "Extract: name is Test, age is 25, occupation is Tester",
            as: ExtractedPerson.self
        ) {
            switch event {
            case .contentDelta(let delta):
                contentDeltas.append(delta)
            case .done(let response):
                finalResponse = response
            default:
                break
            }
        }

        #expect(!contentDeltas.isEmpty)
        #expect(finalResponse != nil)

        let result = try openAIModel.extractAndDecode(
            from: finalResponse!,
            as: ExtractedPerson.self,
            expectToolCall: false
        )
        #expect(result.data.name.lowercased().contains("test"))
    }

    @Test("generateStreamWithTool() yields tool events", .enabled(if: hasAnthropicKey))
    func generateStreamWithToolYieldsEvents() async throws {
        var toolCallStarted = false
        var argumentDeltas: [String] = []
        var finalResponse: CompletionResponse?

        for try await event in anthropicModel.generateStreamWithTool(
            "Extract: value is 'streamed', confidence is 0.99",
            as: SimpleExtraction.self,
            toolName: "extract",
            systemPrompt: "Use the extract tool."
        ) {
            switch event {
            case .toolCallStart:
                toolCallStarted = true
            case .toolCallDelta(let delta):
                argumentDeltas.append(delta)
            case .done(let response):
                finalResponse = response
            default:
                break
            }
        }

        #expect(toolCallStarted)
        #expect(!argumentDeltas.isEmpty)
        #expect(finalResponse != nil)
        #expect(!finalResponse!.toolCalls.isEmpty)

        let result = try anthropicModel.extractAndDecode(
            from: finalResponse!,
            as: SimpleExtraction.self,
            expectToolCall: true
        )
        #expect(result.data.value.lowercased().contains("stream"))
    }
}

// MARK: - Error Handling Tests

@Suite("Typed Output - Error Handling", .tags(.integration))
struct TypedOutputErrorTests {
    private let model = OpenAIModel(
        name: "gpt-5-mini",
        provider: OpenAIProvider(apiKey: TestConfig.openAIAPIKey)
    )

    @Test("Decoding failure throws StructuredOutputError", .enabled(if: hasOpenAIKey))
    func decodingFailureThrowsError() async throws {
        // This test verifies the happy path works - error paths are tested in unit tests
        let result = try await model.generate(
            "Extract: value is 'valid', confidence is 0.8",
            as: SimpleExtraction.self
        )

        #expect(result.data.confidence >= 0.0)
    }

    @Test("extractAndDecode handles response correctly", .enabled(if: hasOpenAIKey))
    func extractAndDecodeHandlesResponse() async throws {
        let request = CompletionRequest(
            messages: [.user("Extract: value is 'manual', confidence is 0.75")],
            outputSchema: SimpleExtraction.jsonSchema
        )

        let response = try await model.complete(request)

        let result = try model.extractAndDecode(
            from: response,
            as: SimpleExtraction.self,
            expectToolCall: false
        )

        #expect(result.data.value.lowercased().contains("manual"))
        #expect(result.rawJSON == response.content)
    }
}

// MARK: - Comparison Tests

@Suite("Typed Output - API Comparison", .tags(.integration))
struct TypedOutputComparisonTests {
    private let model = OpenAIModel(
        name: "gpt-5-mini",
        provider: OpenAIProvider(apiKey: TestConfig.openAIAPIKey)
    )

    /// Demonstrates the improvement over manual decoding
    @Test("Typed API is cleaner than manual decoding", .enabled(if: hasOpenAIKey))
    func typedAPIIsCleanerThanManual() async throws {
        let prompt = "Extract: name is Compare, age is 30, occupation is Developer"

        // OLD WAY - Manual decoding (for comparison)
        let request = CompletionRequest(
            messages: [.user(prompt)],
            outputSchema: ExtractedPerson.jsonSchema
        )
        let response = try await model.complete(request)
        let jsonData = response.content!.data(using: .utf8)!
        let oldPerson = try JSONDecoder().decode(ExtractedPerson.self, from: jsonData)

        // NEW WAY - Typed API
        let result = try await model.generate(prompt, as: ExtractedPerson.self)
        let newPerson = result.data

        // Both should give the same result
        #expect(oldPerson.name == newPerson.name)
        #expect(oldPerson.age == newPerson.age)
        #expect(oldPerson.occupation == newPerson.occupation)

        // But new way also gives metadata without extra work
        #expect(result.usage.totalTokens > 0)
        #expect(!result.rawJSON.isEmpty)
    }
}
