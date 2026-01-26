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

// MARK: - Tool Argument Contract Tests

@Suite("Tool Argument Contract")
struct ToolArgumentContractTests {

    // MARK: - MCP Argument Parsing

    @Test("Empty string parses to empty object")
    func mcpArgs_emptyString() {
        let result = parseMCPArguments("")
        switch result {
        case .success(let args):
            #expect(args != nil, "Should return non-nil empty dict, not nil")
            #expect(args?.isEmpty == true, "Should be empty dictionary")
        case .error(let error):
            Issue.record("Empty string should not error: \(error)")
        }
    }

    @Test("Whitespace-only string parses to empty object")
    func mcpArgs_whitespaceOnly() {
        let result = parseMCPArguments("   \n\t  ")
        switch result {
        case .success(let args):
            #expect(args != nil, "Should return non-nil for whitespace")
            #expect(args?.isEmpty == true, "Should be empty dictionary")
        case .error(let error):
            Issue.record("Whitespace should not error: \(error)")
        }
    }

    @Test("Explicit empty object parses to empty object")
    func mcpArgs_emptyObject() {
        let result = parseMCPArguments("{}")
        switch result {
        case .success(let args):
            #expect(args != nil, "Should return non-nil for {}")
            #expect(args?.isEmpty == true, "Should be empty dictionary")
        case .error(let error):
            Issue.record("Empty object should not error: \(error)")
        }
    }

    @Test("Valid JSON object parses correctly")
    func mcpArgs_validObject() {
        let result = parseMCPArguments(#"{"query": "test", "limit": 10}"#)
        switch result {
        case .success(let args):
            #expect(args != nil)
            #expect(args?.count == 2)
        case .error(let error):
            Issue.record("Valid JSON should not error: \(error)")
        }
    }

    @Test("Array is rejected (must be object)")
    func mcpArgs_arrayRejected() {
        let result = parseMCPArguments("[1, 2, 3]")
        switch result {
        case .success:
            Issue.record("Array should be rejected, MCP requires object")
        case .error(let error):
            #expect(error == .argumentParsing("Arguments must be a JSON object"))
        }
    }

    @Test("Invalid JSON produces parsing error")
    func mcpArgs_invalidJSON() {
        let result = parseMCPArguments("{invalid json}")
        switch result {
        case .success:
            Issue.record("Invalid JSON should produce error")
        case .error(let error):
            if case .argumentParsing = error {
                // Expected - parsing error
            } else {
                Issue.record("Should be argumentParsing error, got: \(error)")
            }
        }
    }

    // MARK: - ToolExecutionError Distinction

    @Test("argumentParsing vs argumentValidation are distinct errors")
    func errorTypes_areDistinct() {
        let parsing = ToolExecutionError.argumentParsing("Invalid JSON")
        let validation = ToolExecutionError.argumentValidation("Value out of range")

        #expect(parsing != validation)

        // Check error descriptions are different
        #expect(parsing.errorDescription?.contains("parse") == true)
        #expect(validation.errorDescription?.contains("validation") == true)
    }

    // MARK: - Contract Documentation Verification

    /// This test documents and verifies the argument contract table from ToolCall.
    @Test("Argument contract table")
    func argumentContract_documentedCases() {
        // | Input Value      | Meaning                        | Should Parse To    |
        // |------------------|--------------------------------|--------------------|
        // | `"{}"`           | Explicitly empty object        | Empty object `[:]` |
        // | `""` (empty)     | No arguments provided          | Empty object `[:]` |
        // | `"   "` (spaces) | Whitespace-only                | Empty object `[:]` |
        // | Valid JSON       | Arguments provided             | Parsed object      |
        // | Invalid JSON     | Malformed                      | Error              |

        // Case 1: "{}"
        if case .success(let args1) = parseMCPArguments("{}") {
            #expect(args1?.isEmpty == true, "Contract: {} → empty object")
        } else {
            Issue.record("Contract violation: {} should parse")
        }

        // Case 2: "" (empty)
        if case .success(let args2) = parseMCPArguments("") {
            #expect(args2?.isEmpty == true, "Contract: empty string → empty object")
        } else {
            Issue.record("Contract violation: empty string should parse")
        }

        // Case 3: "   " (spaces)
        if case .success(let args3) = parseMCPArguments("   ") {
            #expect(args3?.isEmpty == true, "Contract: whitespace → empty object")
        } else {
            Issue.record("Contract violation: whitespace should parse")
        }

        // Case 4: Valid JSON
        if case .success(let args4) = parseMCPArguments(#"{"key": "value"}"#) {
            #expect(args4?.count == 1, "Contract: valid JSON → parsed object")
        } else {
            Issue.record("Contract violation: valid JSON should parse")
        }

        // Case 5: Invalid JSON
        if case .error = parseMCPArguments("not json") {
            // Expected
        } else {
            Issue.record("Contract violation: invalid JSON should error")
        }
    }
}
