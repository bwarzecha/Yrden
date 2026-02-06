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

    /// Override foreign thinking behavior for this request.
    /// When nil, uses the model's default behavior.
    /// See `ForeignThinkingBehavior` for options.
    public let foreignThinkingBehavior: ForeignThinkingBehavior?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        stopSequences: [String]? = nil,
        store: Bool? = nil,
        promptCacheKey: String? = nil,
        promptCacheRetention: PromptCacheRetention? = nil,
        foreignThinkingBehavior: ForeignThinkingBehavior? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
        self.store = store
        self.promptCacheKey = promptCacheKey
        self.promptCacheRetention = promptCacheRetention
        self.foreignThinkingBehavior = foreignThinkingBehavior
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

// MARK: - ForeignThinkingBehavior

/// How to handle thinking blocks from other providers.
///
/// When resuming a conversation with a different provider than the one that
/// generated the thinking blocks, this determines what happens to those blocks.
///
/// ## Example
/// ```swift
/// // Drop foreign thinking blocks (default for most models)
/// let model = AnthropicModel(foreignThinkingBehavior: .drop)
///
/// // Convert visible thinking to text, useful for debugging
/// let model = OpenAIModel(foreignThinkingBehavior: .convertToText)
///
/// // Override per-request
/// let config = CompletionConfig(foreignThinkingBehavior: .convertToText)
/// ```
public enum ForeignThinkingBehavior: String, Sendable, Codable, Equatable, Hashable {
    /// Drop all foreign thinking blocks entirely.
    /// This is the safest option for production use.
    case drop

    /// Convert visible thinking content to text blocks, drop filtered blocks.
    /// Useful for debugging or when you want to preserve reasoning context.
    case convertToText
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

// MARK: - Provider Stop Reason Mapping

extension StopReason {
    /// Create StopReason from Anthropic API `stop_reason` value.
    ///
    /// Maps Anthropic-specific strings to the common StopReason enum:
    /// - "end_turn" → .endTurn
    /// - "tool_use" → .toolUse
    /// - "max_tokens" → .maxTokens
    /// - "stop_sequence" → .stopSequence
    /// - Unknown values default to .endTurn
    public static func from(anthropicReason reason: String?) -> StopReason {
        switch reason {
        case "end_turn": return .endTurn
        case "tool_use": return .toolUse
        case "max_tokens": return .maxTokens
        case "stop_sequence": return .stopSequence
        default: return .endTurn
        }
    }

    /// Create StopReason from OpenAI API `finish_reason` value.
    ///
    /// Maps OpenAI-specific strings to the common StopReason enum:
    /// - "stop" → .endTurn (or .stopSequence if stop sequences were provided)
    /// - "tool_calls" → .toolUse
    /// - "length" → .maxTokens
    /// - "content_filter" → .contentFiltered
    /// - Unknown values default to .endTurn
    ///
    /// - Parameters:
    ///   - reason: The finish_reason string from OpenAI API
    ///   - hasStopSequences: Whether stop sequences were provided in the request.
    ///     OpenAI returns "stop" for both natural end and stop sequence hits,
    ///     so we use this flag to disambiguate.
    public static func from(openAIReason reason: String?, hasStopSequences: Bool = false) -> StopReason {
        switch reason {
        case "stop":
            // OpenAI returns "stop" for both natural end and stop sequence
            // If stop sequences were provided, assume it stopped due to one of them
            return hasStopSequences ? .stopSequence : .endTurn
        case "tool_calls": return .toolUse
        case "length": return .maxTokens
        case "content_filter": return .contentFiltered
        default: return .endTurn
        }
    }
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
/// A response contains ordered content blocks that preserve the exact structure
/// from the provider, enabling cache compatibility on subsequent requests.
///
/// Content blocks can include:
/// - Text content (the model's visible response)
/// - Thinking blocks (reasoning/chain-of-thought, may be filtered)
/// - Tool calls (requests to invoke tools)
///
/// Blocks can be interleaved in any order. For example, a model might:
/// 1. Think about the problem
/// 2. Output some text
/// 3. Call a tool
/// 4. Think more
/// 5. Output final text
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
/// // Process all content blocks in order
/// for block in response.contentBlocks {
///     switch block {
///     case .text(let text):
///         print(text)
///     case .thinking(let thinking):
///         if let content = thinking.content {
///             print("[Thinking] \(content)")
///         }
///     case .toolUse(let call):
///         let result = try await executeTool(call)
///     }
/// }
///
/// // Or use convenience properties
/// if let content = response.content {
///     print(content)
/// }
/// for call in response.toolCalls {
///     // Execute tools...
/// }
/// ```
public struct CompletionResponse: Codable, Sendable, Equatable, Hashable {
    /// Ordered content blocks from the model.
    /// Preserves exact structure for cache compatibility.
    public let contentBlocks: [AssistantContentBlock]

    /// Refusal explanation from the model.
    /// When set, the model declined to fulfill the request.
    /// This is different from content filtering (stopReason = .contentFiltered).
    public let refusal: String?

    /// Reason the model stopped generating.
    public let stopReason: StopReason

    /// Token usage for this request/response.
    public let usage: Usage

    public init(
        contentBlocks: [AssistantContentBlock],
        refusal: String? = nil,
        stopReason: StopReason,
        usage: Usage
    ) {
        self.contentBlocks = contentBlocks
        self.refusal = refusal
        self.stopReason = stopReason
        self.usage = usage
    }

    /// Convenience initializer for simple text responses.
    public init(
        content: String?,
        refusal: String? = nil,
        toolCalls: [ToolCall] = [],
        stopReason: StopReason,
        usage: Usage
    ) {
        var blocks: [AssistantContentBlock] = []
        if let text = content, !text.isEmpty {
            blocks.append(.text(text))
        }
        blocks.append(contentsOf: toolCalls.map { .toolUse($0) })
        self.contentBlocks = blocks
        self.refusal = refusal
        self.stopReason = stopReason
        self.usage = usage
    }
}

// MARK: - CompletionResponse Computed Properties

extension CompletionResponse {
    /// Combined text content from the response (excludes thinking).
    /// Returns nil if no text blocks are present.
    public var content: String? {
        let texts = contentBlocks.compactMap { $0.textContent }
        return texts.isEmpty ? nil : texts.joined()
    }

    /// Combined thinking content from the response.
    /// Returns nil if no thinking blocks with visible content are present.
    public var thinking: String? {
        let thoughts = contentBlocks.compactMap { $0.thinkingContent }
        return thoughts.isEmpty ? nil : thoughts.joined()
    }

    /// All tool calls from the response.
    /// Returns empty array if no tool calls are present.
    public var toolCalls: [ToolCall] {
        contentBlocks.compactMap { $0.toolCall }
    }

    /// All thinking blocks from the response (including filtered ones).
    public var thinkingBlocks: [ThinkingBlock] {
        contentBlocks.compactMap { $0.thinkingBlock }
    }
}
