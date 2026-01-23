/// Tests for Model types: ModelCapabilities, Model protocol validation.
///
/// Test coverage:
/// - ModelCapabilities Codable round-trip
/// - Predefined capability constants
/// - Request validation logic

import Testing
import Foundation
@testable import Yrden

// MARK: - ModelCapabilities Tests

@Suite("ModelCapabilities")
struct ModelCapabilitiesTests {

    // MARK: - Codable Round-Trip

    @Test func roundTrip_allTrue() throws {
        let caps = ModelCapabilities(
            supportsTemperature: true,
            supportsTools: true,
            supportsVision: true,
            supportsStructuredOutput: true,
            supportsSystemMessage: true,
            maxContextTokens: 200_000
        )

        let data = try JSONEncoder().encode(caps)
        let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: data)

        #expect(decoded == caps)
    }

    @Test func roundTrip_allFalse() throws {
        let caps = ModelCapabilities(
            supportsTemperature: false,
            supportsTools: false,
            supportsVision: false,
            supportsStructuredOutput: false,
            supportsSystemMessage: false,
            maxContextTokens: nil
        )

        let data = try JSONEncoder().encode(caps)
        let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: data)

        #expect(decoded == caps)
    }

    @Test func roundTrip_mixed() throws {
        let caps = ModelCapabilities(
            supportsTemperature: false,
            supportsTools: true,
            supportsVision: true,
            supportsStructuredOutput: true,
            supportsSystemMessage: false,
            maxContextTokens: 128_000
        )

        let data = try JSONEncoder().encode(caps)
        let decoded = try JSONDecoder().decode(ModelCapabilities.self, from: data)

        #expect(decoded == caps)
    }

    // MARK: - Equatable

    @Test func equatable_same() {
        let caps1 = ModelCapabilities(
            supportsTemperature: true,
            supportsTools: true,
            supportsVision: false,
            supportsStructuredOutput: true,
            supportsSystemMessage: true,
            maxContextTokens: 100_000
        )
        let caps2 = ModelCapabilities(
            supportsTemperature: true,
            supportsTools: true,
            supportsVision: false,
            supportsStructuredOutput: true,
            supportsSystemMessage: true,
            maxContextTokens: 100_000
        )

        #expect(caps1 == caps2)
    }

    @Test func equatable_differentTokens() {
        let caps1 = ModelCapabilities(
            supportsTemperature: true,
            supportsTools: true,
            supportsVision: true,
            supportsStructuredOutput: true,
            supportsSystemMessage: true,
            maxContextTokens: 100_000
        )
        let caps2 = ModelCapabilities(
            supportsTemperature: true,
            supportsTools: true,
            supportsVision: true,
            supportsStructuredOutput: true,
            supportsSystemMessage: true,
            maxContextTokens: 200_000
        )

        #expect(caps1 != caps2)
    }

    // MARK: - Hashable

    @Test func hashable_inSet() {
        let caps1 = ModelCapabilities.claude35
        let caps2 = ModelCapabilities.claude35  // same
        let caps3 = ModelCapabilities.o1

        let set: Set<ModelCapabilities> = [caps1, caps2, caps3]
        #expect(set.count == 2)
    }

    // MARK: - Predefined Capabilities

    @Test func predefined_claude35() {
        let caps = ModelCapabilities.claude35

        #expect(caps.supportsTemperature == true)
        #expect(caps.supportsTools == true)
        #expect(caps.supportsVision == true)
        #expect(caps.supportsStructuredOutput == true)
        #expect(caps.supportsSystemMessage == true)
        #expect(caps.maxContextTokens == 200_000)
    }

    @Test func predefined_claude3Haiku() {
        let caps = ModelCapabilities.claude3Haiku

        #expect(caps.supportsTemperature == true)
        #expect(caps.supportsTools == true)
        #expect(caps.supportsVision == true)
        #expect(caps.maxContextTokens == 200_000)
    }

    @Test func predefined_gpt4o() {
        let caps = ModelCapabilities.gpt4o

        #expect(caps.supportsTemperature == true)
        #expect(caps.supportsTools == true)
        #expect(caps.supportsVision == true)
        #expect(caps.supportsStructuredOutput == true)
        #expect(caps.supportsSystemMessage == true)
        #expect(caps.maxContextTokens == 128_000)
    }

    @Test func predefined_o1() {
        let caps = ModelCapabilities.o1

        #expect(caps.supportsTemperature == false)
        #expect(caps.supportsTools == false)
        #expect(caps.supportsVision == false)
        #expect(caps.supportsStructuredOutput == false)
        #expect(caps.supportsSystemMessage == false)
        #expect(caps.maxContextTokens == 128_000)
    }

    @Test func predefined_o3() {
        let caps = ModelCapabilities.o3

        #expect(caps.supportsTemperature == false)
        #expect(caps.supportsTools == true)  // o3 supports tools
        #expect(caps.supportsVision == true)
        #expect(caps.supportsStructuredOutput == true)
        #expect(caps.supportsSystemMessage == false)
        #expect(caps.maxContextTokens == 200_000)
    }
}

// MARK: - Mock Model for Validation Testing

/// Mock model for testing validation logic.
private struct MockModel: Model {
    let name: String
    let capabilities: ModelCapabilities

    func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        // Not implemented for validation tests
        fatalError("Not implemented")
    }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        // Not implemented for validation tests
        fatalError("Not implemented")
    }
}

// MARK: - Request Validation Tests

@Suite("Model Request Validation")
struct ModelValidationTests {

    // MARK: - Temperature Validation

    @Test func validation_temperatureSupported() throws {
        let model = MockModel(
            name: "test",
            capabilities: ModelCapabilities.claude35
        )
        let request = CompletionRequest(
            messages: [.user("Hi")],
            config: CompletionConfig(temperature: 0.7)
        )

        // Should not throw
        try model.validateRequest(request)
    }

    @Test func validation_temperatureNotSupported() throws {
        let model = MockModel(
            name: "o1",
            capabilities: ModelCapabilities.o1
        )
        let request = CompletionRequest(
            messages: [.user("Hi")],
            config: CompletionConfig(temperature: 0.7)
        )

        #expect(throws: LLMError.self) {
            try model.validateRequest(request)
        }
    }

    @Test func validation_noTemperatureOnRestrictedModel() throws {
        let model = MockModel(
            name: "o1",
            capabilities: ModelCapabilities.o1
        )
        let request = CompletionRequest(
            messages: [.user("Hi")]
        )

        // Should not throw - no temperature specified
        try model.validateRequest(request)
    }

    // MARK: - Tools Validation

    @Test func validation_toolsSupported() throws {
        let model = MockModel(
            name: "gpt-4o",
            capabilities: ModelCapabilities.gpt4o
        )
        let request = CompletionRequest(
            messages: [.user("Hi")],
            tools: [ToolDefinition(name: "test", description: "Test", inputSchema: .null)]
        )

        // Should not throw
        try model.validateRequest(request)
    }

    @Test func validation_toolsNotSupported() throws {
        let model = MockModel(
            name: "o1",
            capabilities: ModelCapabilities.o1
        )
        let request = CompletionRequest(
            messages: [.user("Hi")],
            tools: [ToolDefinition(name: "test", description: "Test", inputSchema: .null)]
        )

        #expect(throws: LLMError.self) {
            try model.validateRequest(request)
        }
    }

    @Test func validation_emptyToolsAllowed() throws {
        let model = MockModel(
            name: "o1",
            capabilities: ModelCapabilities.o1
        )
        let request = CompletionRequest(
            messages: [.user("Hi")],
            tools: []  // Empty array is fine
        )

        // Should not throw
        try model.validateRequest(request)
    }

    // MARK: - Structured Output Validation

    @Test func validation_structuredOutputSupported() throws {
        let model = MockModel(
            name: "claude-3-5-sonnet",
            capabilities: ModelCapabilities.claude35
        )
        let request = CompletionRequest(
            messages: [.user("Hi")],
            outputSchema: ["type": "object"]
        )

        // Should not throw
        try model.validateRequest(request)
    }

    @Test func validation_structuredOutputNotSupported() throws {
        let model = MockModel(
            name: "o1",
            capabilities: ModelCapabilities.o1
        )
        let request = CompletionRequest(
            messages: [.user("Hi")],
            outputSchema: ["type": "object"]
        )

        #expect(throws: LLMError.self) {
            try model.validateRequest(request)
        }
    }

    // MARK: - System Message Validation

    @Test func validation_systemMessageSupported() throws {
        let model = MockModel(
            name: "gpt-4o",
            capabilities: ModelCapabilities.gpt4o
        )
        let request = CompletionRequest(
            messages: [
                .system("You are helpful."),
                .user("Hi")
            ]
        )

        // Should not throw
        try model.validateRequest(request)
    }

    @Test func validation_systemMessageNotSupported() throws {
        let model = MockModel(
            name: "o1",
            capabilities: ModelCapabilities.o1
        )
        let request = CompletionRequest(
            messages: [
                .system("You are helpful."),
                .user("Hi")
            ]
        )

        #expect(throws: LLMError.self) {
            try model.validateRequest(request)
        }
    }

    @Test func validation_noSystemMessageOnRestrictedModel() throws {
        let model = MockModel(
            name: "o1",
            capabilities: ModelCapabilities.o1
        )
        let request = CompletionRequest(
            messages: [.user("Hi")]
        )

        // Should not throw - no system message
        try model.validateRequest(request)
    }

    // MARK: - Vision Validation

    @Test func validation_visionSupported() throws {
        let model = MockModel(
            name: "gpt-4o",
            capabilities: ModelCapabilities.gpt4o
        )
        let request = CompletionRequest(
            messages: [
                .user([
                    .text("What's in this image?"),
                    .image(Data([1, 2, 3]), mimeType: "image/png")
                ])
            ]
        )

        // Should not throw
        try model.validateRequest(request)
    }

    @Test func validation_visionNotSupported() throws {
        let model = MockModel(
            name: "o1",
            capabilities: ModelCapabilities.o1
        )
        let request = CompletionRequest(
            messages: [
                .user([
                    .text("What's in this image?"),
                    .image(Data([1, 2, 3]), mimeType: "image/png")
                ])
            ]
        )

        #expect(throws: LLMError.self) {
            try model.validateRequest(request)
        }
    }

    @Test func validation_textOnlyOnVisionRestrictedModel() throws {
        let model = MockModel(
            name: "o1",
            capabilities: ModelCapabilities.o1
        )
        let request = CompletionRequest(
            messages: [
                .user([.text("Hello")])
            ]
        )

        // Should not throw - no images
        try model.validateRequest(request)
    }

    // MARK: - Error Details

    @Test func validation_errorContainsModelName() throws {
        let model = MockModel(
            name: "o1-preview",
            capabilities: ModelCapabilities.o1
        )
        let request = CompletionRequest(
            messages: [.user("Hi")],
            config: CompletionConfig(temperature: 0.7)
        )

        do {
            try model.validateRequest(request)
            Issue.record("Should have thrown")
        } catch let error as LLMError {
            if case .capabilityNotSupported(let message) = error {
                #expect(message.contains("o1-preview"))
                #expect(message.contains("temperature"))
            } else {
                Issue.record("Wrong error type: \(error)")
            }
        }
    }
}
