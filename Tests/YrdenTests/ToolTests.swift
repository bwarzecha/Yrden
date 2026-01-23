/// Tests for Tool types: ToolDefinition, ToolCall, ToolOutput.
///
/// Test coverage:
/// - Codable round-trip for all types
/// - Equatable/Hashable behavior
/// - Edge cases (empty strings, complex schemas)

import Testing
import Foundation
@testable import Yrden

// MARK: - ToolDefinition Tests

@Suite("ToolDefinition")
struct ToolDefinitionTests {

    // MARK: - Codable Round-Trip

    @Test func roundTrip_simpleSchema() throws {
        let tool = ToolDefinition(
            name: "search",
            description: "Search for documents",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string"]
                ],
                "required": ["query"]
            ]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(tool)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ToolDefinition.self, from: data)

        #expect(decoded == tool)
    }

    @Test func roundTrip_complexSchema() throws {
        let tool = ToolDefinition(
            name: "analyze",
            description: "Analyze data with multiple parameters",
            inputSchema: [
                "type": "object",
                "properties": [
                    "data": ["type": "array", "items": ["type": "number"]],
                    "options": [
                        "type": "object",
                        "properties": [
                            "normalize": ["type": "boolean"],
                            "precision": ["type": "integer"]
                        ]
                    ]
                ],
                "required": ["data"]
            ]
        )

        let data = try JSONEncoder().encode(tool)
        let decoded = try JSONDecoder().decode(ToolDefinition.self, from: data)

        #expect(decoded == tool)
    }

    @Test func roundTrip_emptyDescription() throws {
        let tool = ToolDefinition(
            name: "noop",
            description: "",
            inputSchema: ["type": "object"]
        )

        let data = try JSONEncoder().encode(tool)
        let decoded = try JSONDecoder().decode(ToolDefinition.self, from: data)

        #expect(decoded == tool)
        #expect(decoded.description == "")
    }

    // MARK: - Equatable

    @Test func equatable_sameValues() {
        let tool1 = ToolDefinition(
            name: "test",
            description: "Test tool",
            inputSchema: ["type": "object"]
        )
        let tool2 = ToolDefinition(
            name: "test",
            description: "Test tool",
            inputSchema: ["type": "object"]
        )

        #expect(tool1 == tool2)
    }

    @Test func equatable_differentNames() {
        let tool1 = ToolDefinition(name: "a", description: "desc", inputSchema: .null)
        let tool2 = ToolDefinition(name: "b", description: "desc", inputSchema: .null)

        #expect(tool1 != tool2)
    }

    // MARK: - Hashable

    @Test func hashable_inSet() {
        let tool1 = ToolDefinition(name: "search", description: "Search", inputSchema: .null)
        let tool2 = ToolDefinition(name: "search", description: "Search", inputSchema: .null)
        let tool3 = ToolDefinition(name: "analyze", description: "Analyze", inputSchema: .null)

        let set: Set<ToolDefinition> = [tool1, tool2, tool3]
        #expect(set.count == 2)  // tool1 and tool2 are equal
    }
}

// MARK: - ToolCall Tests

@Suite("ToolCall")
struct ToolCallTests {

    // MARK: - Codable Round-Trip

    @Test func roundTrip_basic() throws {
        let call = ToolCall(
            id: "call_abc123",
            name: "search",
            arguments: #"{"query": "Swift concurrency"}"#
        )

        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(ToolCall.self, from: data)

        #expect(decoded == call)
        #expect(decoded.id == "call_abc123")
        #expect(decoded.name == "search")
        #expect(decoded.arguments == #"{"query": "Swift concurrency"}"#)
    }

    @Test func roundTrip_emptyArguments() throws {
        let call = ToolCall(id: "call_1", name: "noop", arguments: "{}")

        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(ToolCall.self, from: data)

        #expect(decoded == call)
        #expect(decoded.arguments == "{}")
    }

    @Test func roundTrip_complexArguments() throws {
        let args = #"{"items": [1, 2, 3], "nested": {"key": "value"}, "unicode": "héllo 🎉"}"#
        let call = ToolCall(id: "call_complex", name: "process", arguments: args)

        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(ToolCall.self, from: data)

        #expect(decoded == call)
    }

    // MARK: - Equatable

    @Test func equatable_sameValues() {
        let call1 = ToolCall(id: "1", name: "test", arguments: "{}")
        let call2 = ToolCall(id: "1", name: "test", arguments: "{}")

        #expect(call1 == call2)
    }

    @Test func equatable_differentIds() {
        let call1 = ToolCall(id: "1", name: "test", arguments: "{}")
        let call2 = ToolCall(id: "2", name: "test", arguments: "{}")

        #expect(call1 != call2)
    }

    // MARK: - Hashable

    @Test func hashable_asDictionaryKey() {
        let call = ToolCall(id: "call_1", name: "search", arguments: "{}")
        var dict: [ToolCall: String] = [:]
        dict[call] = "result"

        #expect(dict[call] == "result")
    }
}

// MARK: - ToolOutput Tests

@Suite("ToolOutput")
struct ToolOutputTests {

    // MARK: - Codable Round-Trip

    @Test func roundTrip_text() throws {
        let output = ToolOutput.text("Search found 5 results")

        let data = try JSONEncoder().encode(output)
        let decoded = try JSONDecoder().decode(ToolOutput.self, from: data)

        #expect(decoded == output)
    }

    @Test func roundTrip_json() throws {
        let output = ToolOutput.json([
            "results": [
                ["title": "Doc 1", "score": 0.95],
                ["title": "Doc 2", "score": 0.87]
            ],
            "total": 2
        ])

        let data = try JSONEncoder().encode(output)
        let decoded = try JSONDecoder().decode(ToolOutput.self, from: data)

        #expect(decoded == output)
    }

    @Test func roundTrip_error() throws {
        let output = ToolOutput.error("Connection timeout")

        let data = try JSONEncoder().encode(output)
        let decoded = try JSONDecoder().decode(ToolOutput.self, from: data)

        #expect(decoded == output)
    }

    @Test func roundTrip_emptyText() throws {
        let output = ToolOutput.text("")

        let data = try JSONEncoder().encode(output)
        let decoded = try JSONDecoder().decode(ToolOutput.self, from: data)

        #expect(decoded == output)
    }

    @Test func roundTrip_complexJson() throws {
        let output = ToolOutput.json([
            "nested": [
                "array": [1, 2, 3],
                "object": ["a": true, "b": false]
            ],
            "unicode": "🎉 héllo",
            "null_value": .null
        ])

        let data = try JSONEncoder().encode(output)
        let decoded = try JSONDecoder().decode(ToolOutput.self, from: data)

        #expect(decoded == output)
    }

    // MARK: - Equatable

    @Test func equatable_sameText() {
        let output1 = ToolOutput.text("result")
        let output2 = ToolOutput.text("result")

        #expect(output1 == output2)
    }

    @Test func equatable_differentCases() {
        let text = ToolOutput.text("error message")
        let error = ToolOutput.error("error message")

        #expect(text != error)
    }

    @Test func equatable_sameJson() {
        let output1 = ToolOutput.json(["key": "value"])
        let output2 = ToolOutput.json(["key": "value"])

        #expect(output1 == output2)
    }

    // MARK: - Hashable

    @Test func hashable_inSet() {
        let outputs: Set<ToolOutput> = [
            .text("a"),
            .text("a"),  // duplicate
            .text("b"),
            .error("e")
        ]

        #expect(outputs.count == 3)
    }
}
