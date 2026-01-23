/// Completion request and response types.
///
/// This module provides the core types for LLM completions:
/// - `CompletionConfig`: Model parameters (temperature, max tokens)
/// - `CompletionRequest`: Full request with messages, tools, output schema
/// - `CompletionResponse`: Response with content, tool calls, usage
/// - `StopReason`: Why the model stopped generating
/// - `Usage`: Token counts for billing/limits

import Foundation

// MARK: - CompletionConfig

/// Configuration parameters for completion requests.
///
/// Not all parameters are supported by all models. The Model protocol
/// validates parameters against `ModelCapabilities` before sending.
///
/// ## Example
/// ```swift
/// let config = CompletionConfig(
///     temperature: 0.7,
///     maxTokens: 1000,
///     stopSequences: ["END"]
/// )
///
/// // Or use defaults
/// let defaultConfig = CompletionConfig.default
/// ```
public struct CompletionConfig: Codable, Sendable, Equatable, Hashable {
    /// Sampling temperature (0.0 to 2.0).
    /// Lower values = more deterministic, higher = more creative.
    /// Not supported by o1/o3 models.
    public let temperature: Double?

    /// Maximum tokens to generate in the response.
    /// Provider-specific limits apply.
    public let maxTokens: Int?

    /// Stop sequences that halt generation.
    /// Generation stops when any sequence is encountered.
    public let stopSequences: [String]?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        stopSequences: [String]? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
    }

    /// Default configuration with no overrides.
    /// Models use their default values for all parameters.
    public static let `default` = CompletionConfig()
}

// MARK: - CompletionRequest

/// A request for LLM completion.
///
/// Contains all information needed to generate a response:
/// - Conversation history (messages)
/// - Available tools (optional)
/// - Required output schema (optional)
/// - Generation parameters (config)
///
/// ## Example
/// ```swift
/// let request = CompletionRequest(
///     messages: [
///         .system("You are a helpful assistant."),
///         .user("What's the weather in Paris?")
///     ],
///     tools: [weatherTool],
///     config: CompletionConfig(temperature: 0.5)
/// )
/// ```
public struct CompletionRequest: Codable, Sendable, Equatable, Hashable {
    /// Conversation history. Must contain at least one message.
    public let messages: [Message]

    /// Tools available for the model to call.
    /// nil means no tools available.
    public let tools: [ToolDefinition]?

    /// JSON Schema for structured output.
    /// When set, the model's response must conform to this schema.
    public let outputSchema: JSONValue?

    /// Generation configuration (temperature, max tokens, etc.).
    public let config: CompletionConfig

    public init(
        messages: [Message],
        tools: [ToolDefinition]? = nil,
        outputSchema: JSONValue? = nil,
        config: CompletionConfig = .default
    ) {
        self.messages = messages
        self.tools = tools
        self.outputSchema = outputSchema
        self.config = config
    }
}

// MARK: - StopReason

/// Reason why the model stopped generating.
///
/// Used to determine next steps in the agent loop:
/// - `.endTurn`: Model finished naturally, process response
/// - `.toolUse`: Model wants to call tools, execute them
/// - `.maxTokens`: Response truncated, may need to continue
/// - `.stopSequence`: Hit a stop sequence, response complete
/// - `.contentFiltered`: Response blocked by safety filters
public enum StopReason: String, Codable, Sendable, Equatable, Hashable {
    /// Model finished generating (natural end).
    case endTurn = "end_turn"

    /// Model wants to use a tool.
    case toolUse = "tool_use"

    /// Hit the max tokens limit.
    case maxTokens = "max_tokens"

    /// Hit a stop sequence.
    case stopSequence = "stop_sequence"

    /// Response filtered by content policy.
    case contentFiltered = "content_filtered"
}

// MARK: - Usage

/// Token usage statistics for a completion.
///
/// Used for:
/// - Billing estimation
/// - Context window management
/// - Usage limits in agent loops
///
/// ## Example
/// ```swift
/// let usage = response.usage
/// print("Input: \(usage.inputTokens), Output: \(usage.outputTokens)")
/// print("Total: \(usage.totalTokens)")
/// ```
public struct Usage: Codable, Sendable, Equatable, Hashable {
    /// Number of tokens in the input (messages + tools + schema).
    public let inputTokens: Int

    /// Number of tokens in the output (response).
    public let outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// Total tokens used (input + output).
    public var totalTokens: Int {
        inputTokens + outputTokens
    }
}

// MARK: - CompletionResponse

/// Response from an LLM completion request.
///
/// A response can contain:
/// - Text content (the model's response)
/// - Tool calls (requests to invoke tools)
/// - Both (text + tool calls)
/// - Neither (rare, usually an error)
///
/// ## Example
/// ```swift
/// let response = try await model.complete(request)
///
/// // Check for tool calls
/// if !response.toolCalls.isEmpty {
///     for call in response.toolCalls {
///         let result = try await executeTool(call)
///         // Add result to conversation and continue
///     }
/// }
///
/// // Check for text content
/// if let content = response.content {
///     print(content)
/// }
/// ```
public struct CompletionResponse: Codable, Sendable, Equatable, Hashable {
    /// Text content of the response.
    /// May be nil if the model only made tool calls.
    public let content: String?

    /// Tool calls requested by the model.
    /// Empty array if no tools were called.
    public let toolCalls: [ToolCall]

    /// Reason the model stopped generating.
    public let stopReason: StopReason

    /// Token usage for this request/response.
    public let usage: Usage

    public init(
        content: String?,
        toolCalls: [ToolCall],
        stopReason: StopReason,
        usage: Usage
    ) {
        self.content = content
        self.toolCalls = toolCalls
        self.stopReason = stopReason
        self.usage = usage
    }
}
