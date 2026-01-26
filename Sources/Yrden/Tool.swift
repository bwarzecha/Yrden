/// Tool types for LLM function calling.
///
/// This module provides the core types for tool/function calling:
/// - `ToolDefinition`: Schema sent to the LLM describing available tools
/// - `ToolCall`: The LLM's request to invoke a tool
/// - `ToolOutput`: The result returned from tool execution
///
/// ## Wire Format Compatibility
///
/// These types are designed to work with multiple providers:
/// - Anthropic: `tool_use` content blocks
/// - OpenAI: `tools` array with `function` type
/// - Bedrock: Converse API `toolConfig`
///
/// Provider-specific encoding is handled by Model implementations.

import Foundation

// MARK: - ToolDefinition

/// Definition of a tool that can be called by the LLM.
///
/// Sent to the LLM as part of the completion request. The LLM uses this
/// information to decide when and how to call the tool.
///
/// ## Example
/// ```swift
/// let searchTool = ToolDefinition(
///     name: "search",
///     description: "Search the knowledge base for relevant documents",
///     inputSchema: [
///         "type": "object",
///         "properties": [
///             "query": ["type": "string", "description": "Search query"],
///             "limit": ["type": "integer", "description": "Max results"]
///         ],
///         "required": ["query"]
///     ]
/// )
/// ```
public struct ToolDefinition: Codable, Sendable, Equatable, Hashable {
    /// Unique identifier for the tool. Must match `[a-zA-Z0-9_-]+`.
    public let name: String

    /// Human-readable description of what the tool does.
    /// The LLM uses this to decide when to call the tool.
    public let description: String

    /// JSON Schema describing the tool's input parameters.
    /// Uses JSONValue for Sendable compliance.
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

// MARK: - ToolCall

/// A request from the LLM to invoke a tool.
///
/// When the LLM decides to use a tool, it returns a ToolCall with the
/// tool name and JSON-encoded arguments. The agent loop executes the
/// tool and returns the result.
///
/// ## Argument Contract
///
/// The `arguments` field follows this contract:
///
/// | Input Value      | Meaning                        | Should Parse To    |
/// |------------------|--------------------------------|--------------------|
/// | `"{}"`           | Explicitly empty object        | Empty object `[:]` |
/// | `""` (empty)     | No arguments provided          | Empty object `[:]` |
/// | `"   "` (spaces) | Whitespace-only                | Empty object `[:]` |
/// | Valid JSON       | Arguments provided             | Parsed object      |
/// | Invalid JSON     | Malformed                      | Error              |
///
/// **Important**: Empty and whitespace-only strings are semantically equivalent
/// to `{}`. This is because LLMs may omit arguments entirely when a tool has
/// no required parameters, rather than sending an explicit empty object.
///
/// **Why not `nil`?**: Using empty string instead of optional keeps the type
/// simple and matches how LLM providers serialize tool calls. The empty-to-object
/// conversion happens at parse time in each provider/tool implementation.
///
/// ## Example
/// ```swift
/// let call = ToolCall(
///     id: "call_abc123",
///     name: "search",
///     arguments: #"{"query": "Swift concurrency", "limit": 5}"#
/// )
///
/// // Parse arguments
/// let argsData = call.arguments.data(using: .utf8)!
/// let args = try JSONValue(jsonData: argsData)
/// ```
public struct ToolCall: Codable, Sendable, Equatable, Hashable {
    /// Unique identifier for this tool call.
    /// Used to correlate the call with its result.
    public let id: String

    /// Name of the tool to invoke. Must match a ToolDefinition.name.
    public let name: String

    /// JSON-encoded arguments for the tool.
    ///
    /// **Invariant**: Always valid JSON. Empty/whitespace inputs are
    /// normalized to `"{}"` at construction time.
    ///
    /// This eliminates the need for downstream code to handle empty strings.
    /// All parsing can assume valid JSON (though it may be an empty object).
    public let arguments: String

    /// Creates a tool call, normalizing empty arguments to `"{}"`.
    ///
    /// - Parameters:
    ///   - id: Unique identifier for this call
    ///   - name: Tool name to invoke
    ///   - arguments: JSON arguments (empty/whitespace normalized to `"{}"`)
    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        // Enforce invariant: arguments is always valid JSON
        // Empty/whitespace → "{}" so downstream parsing always succeeds
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        self.arguments = trimmed.isEmpty ? "{}" : arguments
    }
}

// MARK: - ToolOutput

/// Result of executing a tool.
///
/// Returned from tool execution and sent back to the LLM as context
/// for generating the next response.
///
/// ## Cases
/// - `.text`: Plain text result (most common)
/// - `.json`: Structured JSON result
/// - `.error`: Error message to help LLM recover
///
/// ## Example
/// ```swift
/// // Successful text result
/// let output = ToolOutput.text("Found 3 documents matching 'Swift concurrency'")
///
/// // Structured result
/// let output = ToolOutput.json([
///     "results": [
///         ["title": "Swift Concurrency Guide", "score": 0.95],
///         ["title": "Async/Await Tutorial", "score": 0.87]
///     ]
/// ])
///
/// // Error for LLM to handle
/// let output = ToolOutput.error("Database connection timeout. Try again.")
/// ```
public enum ToolOutput: Codable, Sendable, Equatable, Hashable {
    /// Plain text result.
    case text(String)

    /// Structured JSON result.
    case json(JSONValue)

    /// Error message. The LLM can use this to retry or explain the failure.
    case error(String)
}

// MARK: - Codable Implementation

extension ToolOutput {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum OutputType: String, Codable {
        case text
        case json
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(OutputType.self, forKey: .type)

        switch type {
        case .text:
            let value = try container.decode(String.self, forKey: .value)
            self = .text(value)
        case .json:
            let value = try container.decode(JSONValue.self, forKey: .value)
            self = .json(value)
        case .error:
            let value = try container.decode(String.self, forKey: .value)
            self = .error(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let value):
            try container.encode(OutputType.text, forKey: .type)
            try container.encode(value, forKey: .value)
        case .json(let value):
            try container.encode(OutputType.json, forKey: .type)
            try container.encode(value, forKey: .value)
        case .error(let value):
            try container.encode(OutputType.error, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}
