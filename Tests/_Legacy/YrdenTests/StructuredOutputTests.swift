/// Tests for Structured Output types and extraction logic.
///
/// Test coverage:
/// - StructuredOutputError cases and LocalizedError
/// - TypedResponse structure and metadata
/// - extractAndDecode logic for native and tool-based paths
/// - Edge cases: refusal, empty, truncation, wrong response type

import Testing
import Foundation
@testable import Yrden

// MARK: - Test Schema Types

@Schema
struct TestPerson: Equatable, Hashable {
    let name: String
    let age: Int
}

@Schema
struct TestAddress: Equatable {
    let street: String
    let city: String
    let zip: String?
}

// MARK: - Mock Model for Testing

/// A mock model that returns pre-configured responses for testing extraction logic.
struct StructuredOutputMockModel: Model {
    let name = "mock-model"
    let capabilities = ModelCapabilities.gpt4o

    /// The response to return from complete()
    var mockResponse: CompletionResponse

    func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        mockResponse
    }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.done(mockResponse))
            continuation.finish()
        }
    }
}

// MARK: - StructuredOutputError Tests

@Suite("StructuredOutputError")
struct StructuredOutputErrorTests {

    @Test func modelRefused_localizedDescription() {
        let error = StructuredOutputError.modelRefused(reason: "Content policy violation")
        let description = error.localizedDescription

        #expect(description.contains("refused"))
        #expect(description.contains("Content policy violation"))
    }

    @Test func emptyResponse_localizedDescription() {
        let error = StructuredOutputError.emptyResponse
        let description = error.localizedDescription

        #expect(description.contains("empty"))
    }

    @Test func unexpectedTextResponse_localizedDescription() {
        let error = StructuredOutputError.unexpectedTextResponse(content: "Some unexpected text here")
        let description = error.localizedDescription

        #expect(description.contains("Expected tool call"))
        #expect(description.contains("text"))
    }

    @Test func unexpectedTextResponse_truncatesLongContent() {
        let longContent = String(repeating: "a", count: 200)
        let error = StructuredOutputError.unexpectedTextResponse(content: longContent)
        let description = error.localizedDescription

        #expect(description.contains("..."))
    }

    @Test func unexpectedToolCall_localizedDescription() {
        let error = StructuredOutputError.unexpectedToolCall(toolName: "search_tool")
        let description = error.localizedDescription

        #expect(description.contains("Expected native"))
        #expect(description.contains("search_tool"))
    }

    @Test func decodingFailed_localizedDescription() {
        let json = #"{"invalid": "json"}"#
        let underlyingError = DecodingError.keyNotFound(
            CodingKeys.name,
            DecodingError.Context(codingPath: [], debugDescription: "Key not found")
        )
        let error = StructuredOutputError.decodingFailed(json: json, underlyingError: underlyingError)
        let description = error.localizedDescription

        #expect(description.contains("Failed to decode"))
        #expect(description.contains("invalid"))
    }

    @Test func decodingFailed_truncatesLongJSON() {
        let longJSON = String(repeating: "{}", count: 150)
        let underlyingError = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "Test")
        )
        let error = StructuredOutputError.decodingFailed(json: longJSON, underlyingError: underlyingError)
        let description = error.localizedDescription

        #expect(description.contains("..."))
    }

    @Test func incompleteResponse_localizedDescription() {
        let partialJSON = #"{"name": "John", "age"#
        let error = StructuredOutputError.incompleteResponse(partialJSON: partialJSON)
        let description = error.localizedDescription

        #expect(description.contains("truncated"))
        #expect(description.contains("max tokens"))
    }

    // MARK: - Equatable

    @Test func equatable_modelRefused() {
        let e1 = StructuredOutputError.modelRefused(reason: "test")
        let e2 = StructuredOutputError.modelRefused(reason: "test")
        let e3 = StructuredOutputError.modelRefused(reason: "different")

        #expect(e1 == e2)
        #expect(e1 != e3)
    }

    @Test func equatable_emptyResponse() {
        let e1 = StructuredOutputError.emptyResponse
        let e2 = StructuredOutputError.emptyResponse

        #expect(e1 == e2)
    }

    @Test func equatable_decodingFailed_comparesOnlyJSON() {
        let err1 = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "Error 1")
        )
        let err2 = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "Error 2")
        )

        let e1 = StructuredOutputError.decodingFailed(json: "{}", underlyingError: err1)
        let e2 = StructuredOutputError.decodingFailed(json: "{}", underlyingError: err2)

        // Should be equal because JSON is the same (underlying error ignored)
        #expect(e1 == e2)
    }

    private enum CodingKeys: CodingKey {
        case name
    }
}

// MARK: - TypedResponse Tests

@Suite("TypedResponse")
struct TypedResponseTests {

    @Test func init_setsAllFields() {
        let person = TestPerson(name: "John", age: 30)
        let usage = Usage(inputTokens: 100, outputTokens: 50)

        let response = TypedResponse(
            data: person,
            usage: usage,
            stopReason: .endTurn,
            rawJSON: #"{"name":"John","age":30}"#
        )

        #expect(response.data == person)
        #expect(response.usage == usage)
        #expect(response.stopReason == .endTurn)
        #expect(response.rawJSON == #"{"name":"John","age":30}"#)
    }

    @Test func equatable_sameValues() {
        let person = TestPerson(name: "John", age: 30)
        let usage = Usage(inputTokens: 100, outputTokens: 50)

        let r1 = TypedResponse(data: person, usage: usage, stopReason: .endTurn, rawJSON: "{}")
        let r2 = TypedResponse(data: person, usage: usage, stopReason: .endTurn, rawJSON: "{}")

        #expect(r1 == r2)
    }

    @Test func equatable_differentData() {
        let usage = Usage(inputTokens: 100, outputTokens: 50)

        let r1 = TypedResponse(
            data: TestPerson(name: "John", age: 30),
            usage: usage,
            stopReason: .endTurn,
            rawJSON: "{}"
        )
        let r2 = TypedResponse(
            data: TestPerson(name: "Jane", age: 25),
            usage: usage,
            stopReason: .endTurn,
            rawJSON: "{}"
        )

        #expect(r1 != r2)
    }

    @Test func hashable_inSet() {
        let usage = Usage(inputTokens: 100, outputTokens: 50)
        let person = TestPerson(name: "John", age: 30)

        let responses: Set<TypedResponse<TestPerson>> = [
            TypedResponse(data: person, usage: usage, stopReason: .endTurn, rawJSON: "{}"),
            TypedResponse(data: person, usage: usage, stopReason: .endTurn, rawJSON: "{}"),  // duplicate
            TypedResponse(data: TestPerson(name: "Jane", age: 25), usage: usage, stopReason: .endTurn, rawJSON: "{}")
        ]

        #expect(responses.count == 2)
    }
}

// MARK: - extractAndDecode Tests

@Suite("extractAndDecode")
struct ExtractAndDecodeTests {

    // MARK: - Native Path (expectToolCall: false)

    @Test func native_successfulDecoding() throws {
        let json = #"{"name":"John","age":30}"#
        let response = CompletionResponse(
            content: json,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 100, outputTokens: 50)
        )

        let model = StructuredOutputMockModel(mockResponse: response)
        let result = try model.extractAndDecode(from: response, as: TestPerson.self, expectToolCall: false)

        #expect(result.data.name == "John")
        #expect(result.data.age == 30)
        #expect(result.rawJSON == json)
        #expect(result.usage.totalTokens == 150)
        #expect(result.stopReason == .endTurn)
    }

    @Test func native_refusalThrowsError() throws {
        let response = CompletionResponse(
            content: nil,
            refusal: "I cannot help with that",
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 5)
        )

        let model = StructuredOutputMockModel(mockResponse: response)

        #expect(throws: StructuredOutputError.self) {
            try model.extractAndDecode(from: response, as: TestPerson.self, expectToolCall: false)
        }
    }

    @Test func native_refusalHasCorrectMessage() throws {
        let response = CompletionResponse(
            content: nil,
            refusal: "Content policy violation",
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 5)
        )

        let model = StructuredOutputMockModel(mockResponse: response)

        do {
            _ = try model.extractAndDecode(from: response, as: TestPerson.self, expectToolCall: false)
            Issue.record("Expected error to be thrown")
        } catch let error as StructuredOutputError {
            if case .modelRefused(let reason) = error {
                #expect(reason == "Content policy violation")
            } else {
                Issue.record("Expected modelRefused error")
            }
        }
    }

    @Test func native_emptyContentThrowsEmptyResponse() throws {
        let response = CompletionResponse(
            content: "",
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 0)
        )

        let model = StructuredOutputMockModel(mockResponse: response)

        do {
            _ = try model.extractAndDecode(from: response, as: TestPerson.self, expectToolCall: false)
            Issue.record("Expected error to be thrown")
        } catch let error as StructuredOutputError {
            #expect(error == .emptyResponse)
        }
    }

    @Test func native_nilContentThrowsEmptyResponse() throws {
        let response = CompletionResponse(
            content: nil,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 0)
        )

        let model = StructuredOutputMockModel(mockResponse: response)

        do {
            _ = try model.extractAndDecode(from: response, as: TestPerson.self, expectToolCall: false)
            Issue.record("Expected error to be thrown")
        } catch let error as StructuredOutputError {
            #expect(error == .emptyResponse)
        }
    }

    @Test func native_unexpectedToolCallThrowsError() throws {
        let response = CompletionResponse(
            content: nil,
            toolCalls: [
                ToolCall(id: "1", name: "search", arguments: "{}")
            ],
            stopReason: .toolUse,
            usage: Usage(inputTokens: 10, outputTokens: 5)
        )

        let model = StructuredOutputMockModel(mockResponse: response)

        do {
            _ = try model.extractAndDecode(from: response, as: TestPerson.self, expectToolCall: false)
            Issue.record("Expected error to be thrown")
        } catch let error as StructuredOutputError {
            if case .unexpectedToolCall(let toolName) = error {
                #expect(toolName == "search")
            } else {
                Issue.record("Expected unexpectedToolCall error")
            }
        }
    }

    @Test func native_maxTokensThrowsIncompleteResponse() throws {
        let partialJSON = #"{"name":"John","age"#
        let response = CompletionResponse(
            content: partialJSON,
            toolCalls: [],
            stopReason: .maxTokens,
            usage: Usage(inputTokens: 100, outputTokens: 4096)
        )

        let model = StructuredOutputMockModel(mockResponse: response)

        do {
            _ = try model.extractAndDecode(from: response, as: TestPerson.self, expectToolCall: false)
            Issue.record("Expected error to be thrown")
        } catch let error as StructuredOutputError {
            if case .incompleteResponse(let partial) = error {
                #expect(partial == partialJSON)
            } else {
                Issue.record("Expected incompleteResponse error")
            }
        }
    }

    @Test func native_invalidJSONThrowsDecodingFailed() throws {
        let invalidJSON = #"{"name":"John"}"#  // Missing required "age"
        let response = CompletionResponse(
            content: invalidJSON,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 100, outputTokens: 50)
        )

        let model = StructuredOutputMockModel(mockResponse: response)

        do {
            _ = try model.extractAndDecode(from: response, as: TestPerson.self, expectToolCall: false)
            Issue.record("Expected error to be thrown")
        } catch let error as StructuredOutputError {
            if case .decodingFailed(let json, _) = error {
                #expect(json == invalidJSON)
            } else {
                Issue.record("Expected decodingFailed error")
            }
        }
    }

    // MARK: - Tool Path (expectToolCall: true)

    @Test func tool_successfulDecoding() throws {
        let json = #"{"name":"Jane","age":25}"#
        let response = CompletionResponse(
            content: nil,
            toolCalls: [
                ToolCall(id: "call_123", name: "extract", arguments: json)
            ],
            stopReason: .toolUse,
            usage: Usage(inputTokens: 50, outputTokens: 30)
        )

        let model = StructuredOutputMockModel(mockResponse: response)
        let result = try model.extractAndDecode(from: response, as: TestPerson.self, expectToolCall: true)

        #expect(result.data.name == "Jane")
        #expect(result.data.age == 25)
        #expect(result.rawJSON == json)
    }

    @Test func tool_noToolCallThrowsEmptyResponse() throws {
        let response = CompletionResponse(
            content: nil,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 50, outputTokens: 0)
        )

        let model = StructuredOutputMockModel(mockResponse: response)

        do {
            _ = try model.extractAndDecode(from: response, as: TestPerson.self, expectToolCall: true)
            Issue.record("Expected error to be thrown")
        } catch let error as StructuredOutputError {
            #expect(error == .emptyResponse)
        }
    }

    @Test func tool_unexpectedTextThrowsError() throws {
        let response = CompletionResponse(
            content: "I can't extract that information",
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 50, outputTokens: 20)
        )

        let model = StructuredOutputMockModel(mockResponse: response)

        do {
            _ = try model.extractAndDecode(from: response, as: TestPerson.self, expectToolCall: true)
            Issue.record("Expected error to be thrown")
        } catch let error as StructuredOutputError {
            if case .unexpectedTextResponse(let content) = error {
                #expect(content.contains("can't extract"))
            } else {
                Issue.record("Expected unexpectedTextResponse error")
            }
        }
    }

    @Test func tool_invalidToolArgumentsThrowsDecodingFailed() throws {
        let invalidJSON = #"{"wrong_field":"value"}"#
        let response = CompletionResponse(
            content: nil,
            toolCalls: [
                ToolCall(id: "call_123", name: "extract", arguments: invalidJSON)
            ],
            stopReason: .toolUse,
            usage: Usage(inputTokens: 50, outputTokens: 30)
        )

        let model = StructuredOutputMockModel(mockResponse: response)

        do {
            _ = try model.extractAndDecode(from: response, as: TestPerson.self, expectToolCall: true)
            Issue.record("Expected error to be thrown")
        } catch let error as StructuredOutputError {
            if case .decodingFailed(let json, _) = error {
                #expect(json == invalidJSON)
            } else {
                Issue.record("Expected decodingFailed error")
            }
        }
    }

    @Test func tool_maxTokensThrowsIncompleteResponse() throws {
        let partialJSON = #"{"name":"Jane"#
        let response = CompletionResponse(
            content: nil,
            toolCalls: [
                ToolCall(id: "call_123", name: "extract", arguments: partialJSON)
            ],
            stopReason: .maxTokens,
            usage: Usage(inputTokens: 50, outputTokens: 4096)
        )

        let model = StructuredOutputMockModel(mockResponse: response)

        do {
            _ = try model.extractAndDecode(from: response, as: TestPerson.self, expectToolCall: true)
            Issue.record("Expected error to be thrown")
        } catch let error as StructuredOutputError {
            if case .incompleteResponse(let partial) = error {
                #expect(partial == partialJSON)
            } else {
                Issue.record("Expected incompleteResponse error")
            }
        }
    }

    // MARK: - Complex Types

    @Test func decodesNestedOptional() throws {
        let json = #"{"street":"123 Main St","city":"NYC","zip":null}"#
        let response = CompletionResponse(
            content: json,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 100, outputTokens: 50)
        )

        let model = StructuredOutputMockModel(mockResponse: response)
        let result = try model.extractAndDecode(from: response, as: TestAddress.self, expectToolCall: false)

        #expect(result.data.street == "123 Main St")
        #expect(result.data.city == "NYC")
        #expect(result.data.zip == nil)
    }

    @Test func decodesWithOptionalPresent() throws {
        let json = #"{"street":"123 Main St","city":"NYC","zip":"10001"}"#
        let response = CompletionResponse(
            content: json,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 100, outputTokens: 50)
        )

        let model = StructuredOutputMockModel(mockResponse: response)
        let result = try model.extractAndDecode(from: response, as: TestAddress.self, expectToolCall: false)

        #expect(result.data.zip == "10001")
    }
}

// MARK: - Generate Method Tests

@Suite("Model.generate")
struct ModelGenerateTests {

    @Test func generate_buildsCorrectRequest() async throws {
        let json = #"{"name":"Test","age":20}"#
        let mockResponse = CompletionResponse(
            content: json,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 50, outputTokens: 25)
        )

        let model = StructuredOutputMockModel(mockResponse: mockResponse)
        let result = try await model.generate(
            "Extract person info",
            as: TestPerson.self,
            systemPrompt: "You are helpful"
        )

        #expect(result.data.name == "Test")
        #expect(result.data.age == 20)
    }

    @Test func generateWithTool_buildsCorrectRequest() async throws {
        let json = #"{"name":"ToolTest","age":35}"#
        let mockResponse = CompletionResponse(
            content: nil,
            toolCalls: [
                ToolCall(id: "1", name: "extract_person", arguments: json)
            ],
            stopReason: .toolUse,
            usage: Usage(inputTokens: 50, outputTokens: 25)
        )

        let model = StructuredOutputMockModel(mockResponse: mockResponse)
        let result = try await model.generateWithTool(
            "Extract person info",
            as: TestPerson.self,
            toolName: "extract_person"
        )

        #expect(result.data.name == "ToolTest")
        #expect(result.data.age == 35)
    }

    @Test func generate_withMessages() async throws {
        let json = #"{"name":"Multi","age":40}"#
        let mockResponse = CompletionResponse(
            content: json,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 100, outputTokens: 50)
        )

        let model = StructuredOutputMockModel(mockResponse: mockResponse)
        let result = try await model.generate(
            messages: [
                .system("You extract data"),
                .user("Extract: Multi is 40")
            ],
            as: TestPerson.self
        )

        #expect(result.data.name == "Multi")
        #expect(result.data.age == 40)
    }
}
