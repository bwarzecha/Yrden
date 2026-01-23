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

    /// Nucleus sampling parameter (0.0 to 1.0).
    /// Model considers tokens with top_p probability mass.
    /// 0.1 means only top 10% probability tokens are considered.
    /// Generally recommend altering temperature OR top_p, not both.
    public let topP: Double?

    /// Maximum tokens to generate in the response.
    /// Provider-specific limits apply.
    public let maxTokens: Int?

    /// Stop sequences that halt generation.
    /// Generation stops when any sequence is encountered.
    public let stopSequences: [String]?

    /// Whether to store the generated response for later retrieval via API.
    /// Set to false for privacy/compliance when you don't want OpenAI to store responses.
    /// Default is true (responses are stored).
    public let store: Bool?

    /// Cache key for prompt caching to optimize costs.
    /// Similar requests with the same key can reuse cached prefixes.
    /// See: https://platform.openai.com/docs/guides/prompt-caching
    public let promptCacheKey: String?

    /// Retention policy for prompt cache.
    /// - `inMemory`: Default, shorter retention
    /// - `extended`: 24-hour extended caching for longer retention
    public let promptCacheRetention: PromptCacheRetention?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        stopSequences: [String]? = nil,
        store: Bool? = nil,
        promptCacheKey: String? = nil,
        promptCacheRetention: PromptCacheRetention? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
        self.store = store
        self.promptCacheKey = promptCacheKey
        self.promptCacheRetention = promptCacheRetention
    }

    /// Default configuration with no overrides.
    /// Models use their default values for all parameters.
    public static let `default` = CompletionConfig()
}

/// Prompt cache retention policy.
public enum PromptCacheRetention: String, Codable, Sendable, Equatable, Hashable {
    /// Default in-memory caching with shorter retention.
    case inMemory = "in-memory"
    /// Extended 24-hour caching for longer retention.
    case extended = "24h"
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
/// - Tracking prompt cache hits
/// - Monitoring reasoning token usage
///
/// ## Example
/// ```swift
/// let usage = response.usage
/// print("Input: \(usage.inputTokens), Output: \(usage.outputTokens)")
/// print("Total: \(usage.totalTokens)")
///
/// // Check prompt cache effectiveness
/// if let cached = usage.cachedTokens, cached > 0 {
///     print("Cache hit: \(cached) tokens from cache")
/// }
///
/// // Check reasoning token usage (o-series/gpt-5)
/// if let reasoning = usage.reasoningTokens, reasoning > 0 {
///     print("Reasoning: \(reasoning) tokens")
/// }
/// ```
public struct Usage: Codable, Sendable, Equatable, Hashable {
    /// Number of tokens in the input (messages + tools + schema).
    public let inputTokens: Int

    /// Number of tokens in the output (response).
    public let outputTokens: Int

    /// Number of input tokens retrieved from prompt cache.
    /// Cached tokens reduce costs. nil if not available.
    /// See: https://platform.openai.com/docs/guides/prompt-caching
    public let cachedTokens: Int?

    /// Number of reasoning tokens used (o-series and gpt-5 models).
    /// These are internal tokens used for chain-of-thought reasoning.
    /// nil if not available or model doesn't use reasoning.
    public let reasoningTokens: Int?

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cachedTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
    }

    /// Total tokens used (input + output).
    public var totalTokens: Int {
        inputTokens + outputTokens
    }

    /// Effective input tokens after subtracting cached tokens.
    /// This represents the actual new tokens processed (billed at full rate).
    public var effectiveInputTokens: Int {
        inputTokens - (cachedTokens ?? 0)
    }
}

// MARK: - CompletionResponse

/// Response from an LLM completion request.
///
/// A response can contain:
/// - Text content (the model's response)
/// - Tool calls (requests to invoke tools)
/// - Refusal (the model declined to respond)
/// - Both text + tool calls
/// - Neither (rare, usually an error)
///
/// ## Example
/// ```swift
/// let response = try await model.complete(request)
///
/// // Check for refusal first
/// if let refusal = response.refusal {
///     print("Model declined: \(refusal)")
///     return
/// }
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
    /// May be nil if the model only made tool calls or refused.
    public let content: String?

    /// Refusal explanation from the model.
    /// When set, the model declined to fulfill the request.
    /// This is different from content filtering (stopReason = .contentFiltered).
    public let refusal: String?

    /// Tool calls requested by the model.
    /// Empty array if no tools were called.
    public let toolCalls: [ToolCall]

    /// Reason the model stopped generating.
    public let stopReason: StopReason

    /// Token usage for this request/response.
    public let usage: Usage

    public init(
        content: String?,
        refusal: String? = nil,
        toolCalls: [ToolCall],
        stopReason: StopReason,
        usage: Usage
    ) {
        self.content = content
        self.refusal = refusal
        self.toolCalls = toolCalls
        self.stopReason = stopReason
        self.usage = usage
    }
}
