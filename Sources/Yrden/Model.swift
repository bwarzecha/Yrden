/// Model protocol and capabilities for LLM providers.
///
/// This module defines:
/// - `ModelCapabilities`: What features a model supports
/// - `Model`: Protocol for LLM implementations
///
/// ## Architecture
///
/// Following PydanticAI's approach, we separate:
/// - **Model**: Knows API format, capabilities, encodes requests, decodes responses
/// - **Provider**: Knows connection details, authentication
///
/// This avoids N×M type explosion (models × backends) and enables:
/// - Azure OpenAI (OpenAI format + Azure auth)
/// - Ollama (OpenAI format + local connection)
/// - Bedrock Claude (Claude capabilities + AWS auth)

import Foundation

// MARK: - ModelCapabilities

/// Capabilities supported by a model.
///
/// Not all models support all features. This struct declares what
/// a specific model can do, enabling:
/// - Validation before sending requests
/// - Capability-based feature selection
/// - Clear error messages for unsupported operations
///
/// ## Example
/// ```swift
/// let model: Model = ...
/// if model.capabilities.supportsTools {
///     // Can use tools
/// }
///
/// if !model.capabilities.supportsTemperature {
///     // Don't set temperature parameter
/// }
/// ```
public struct ModelCapabilities: Sendable, Codable, Equatable, Hashable {
    /// Whether the model supports temperature parameter.
    /// o1/o3 models do NOT support temperature.
    public let supportsTemperature: Bool

    /// Whether the model supports tool/function calling.
    /// o1/o3 models do NOT support tools.
    public let supportsTools: Bool

    /// Whether the model supports image inputs (vision).
    public let supportsVision: Bool

    /// Whether the model supports structured JSON output.
    public let supportsStructuredOutput: Bool

    /// Whether the model supports system messages.
    /// o1 has limited/no system message support.
    public let supportsSystemMessage: Bool

    /// Maximum context window size in tokens.
    /// nil means unknown or unlimited.
    public let maxContextTokens: Int?

    public init(
        supportsTemperature: Bool,
        supportsTools: Bool,
        supportsVision: Bool,
        supportsStructuredOutput: Bool,
        supportsSystemMessage: Bool,
        maxContextTokens: Int?
    ) {
        self.supportsTemperature = supportsTemperature
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.supportsStructuredOutput = supportsStructuredOutput
        self.supportsSystemMessage = supportsSystemMessage
        self.maxContextTokens = maxContextTokens
    }
}

// MARK: - Predefined Capabilities

extension ModelCapabilities {
    /// Capabilities for Claude 3.5 Sonnet/Opus models.
    public static let claude35 = ModelCapabilities(
        supportsTemperature: true,
        supportsTools: true,
        supportsVision: true,
        supportsStructuredOutput: true,
        supportsSystemMessage: true,
        maxContextTokens: 200_000
    )

    /// Capabilities for Claude 3 Haiku.
    public static let claude3Haiku = ModelCapabilities(
        supportsTemperature: true,
        supportsTools: true,
        supportsVision: true,
        supportsStructuredOutput: true,
        supportsSystemMessage: true,
        maxContextTokens: 200_000
    )

    /// Capabilities for GPT-4o and GPT-4o-mini.
    public static let gpt4o = ModelCapabilities(
        supportsTemperature: true,
        supportsTools: true,
        supportsVision: true,
        supportsStructuredOutput: true,
        supportsSystemMessage: true,
        maxContextTokens: 128_000
    )

    /// Capabilities for GPT-4 Turbo.
    public static let gpt4Turbo = ModelCapabilities(
        supportsTemperature: true,
        supportsTools: true,
        supportsVision: true,
        supportsStructuredOutput: true,
        supportsSystemMessage: true,
        maxContextTokens: 128_000
    )

    /// Capabilities for o1/o1-mini/o3-mini reasoning models.
    /// These models have significant limitations.
    public static let o1 = ModelCapabilities(
        supportsTemperature: false,
        supportsTools: false,
        supportsVision: false,
        supportsStructuredOutput: false,
        supportsSystemMessage: false,
        maxContextTokens: 128_000
    )

    /// Capabilities for o3 reasoning model.
    /// Has more capabilities than o1 but still limited.
    public static let o3 = ModelCapabilities(
        supportsTemperature: false,
        supportsTools: true,  // o3 supports tools
        supportsVision: true,
        supportsStructuredOutput: true,
        supportsSystemMessage: false,
        maxContextTokens: 200_000
    )
}

// MARK: - Model Protocol

/// Protocol for LLM model implementations.
///
/// A Model knows:
/// - Its name and capabilities
/// - How to format requests for its API
/// - How to parse responses from its API
///
/// Models are `Sendable` and can be shared across tasks.
///
/// ## Implementing a Model
///
/// ```swift
/// struct AnthropicModel: Model {
///     let name: String
///     let capabilities: ModelCapabilities
///     let provider: AnthropicProvider
///
///     func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
///         // 1. Validate request against capabilities
///         // 2. Convert to Anthropic API format
///         // 3. Send request via provider
///         // 4. Parse response
///     }
///
///     func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
///         // Similar, but returns streaming events
///     }
/// }
/// ```
public protocol Model: Sendable {
    /// The model identifier (e.g., "claude-3-5-sonnet-20241022", "gpt-4o").
    var name: String { get }

    /// Capabilities this model supports.
    var capabilities: ModelCapabilities { get }

    /// Execute a completion request and return the full response.
    ///
    /// - Parameter request: The completion request
    /// - Returns: The complete response
    /// - Throws: `LLMError` for provider/model errors
    func complete(_ request: CompletionRequest) async throws -> CompletionResponse

    /// Execute a completion request and stream events.
    ///
    /// - Parameter request: The completion request
    /// - Returns: Stream of events, ending with `.done`
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

// MARK: - Model Convenience Extensions

extension Model {
    /// Execute a simple text prompt.
    ///
    /// ```swift
    /// let response = try await model.complete("What is Swift?")
    /// print(response.content ?? "")
    /// ```
    public func complete(_ prompt: String) async throws -> CompletionResponse {
        try await complete(CompletionRequest(messages: [.user(prompt)]))
    }

    /// Execute a completion with messages only.
    ///
    /// ```swift
    /// let response = try await model.complete(messages: [
    ///     .system("You are helpful."),
    ///     .user("Hello")
    /// ])
    /// ```
    public func complete(messages: [Message]) async throws -> CompletionResponse {
        try await complete(CompletionRequest(messages: messages))
    }

    /// Execute a completion with tools.
    ///
    /// ```swift
    /// let response = try await model.complete(
    ///     "What's the weather?",
    ///     tools: [weatherTool]
    /// )
    /// ```
    public func complete(
        _ prompt: String,
        tools: [ToolDefinition]
    ) async throws -> CompletionResponse {
        try await complete(CompletionRequest(
            messages: [.user(prompt)],
            tools: tools
        ))
    }

    /// Execute a completion with structured output.
    ///
    /// ```swift
    /// let response = try await model.complete(
    ///     "Analyze this text",
    ///     outputSchema: Analysis.jsonSchema
    /// )
    /// ```
    public func complete(
        _ prompt: String,
        outputSchema: JSONValue
    ) async throws -> CompletionResponse {
        try await complete(CompletionRequest(
            messages: [.user(prompt)],
            outputSchema: outputSchema
        ))
    }

    /// Stream a simple text prompt.
    ///
    /// ```swift
    /// for await event in model.stream("Tell me a story") {
    ///     if case .contentDelta(let text) = event {
    ///         print(text, terminator: "")
    ///     }
    /// }
    /// ```
    public func stream(_ prompt: String) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(CompletionRequest(messages: [.user(prompt)]))
    }

    /// Stream with messages only.
    public func stream(messages: [Message]) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(CompletionRequest(messages: messages))
    }
}

// MARK: - Request Validation

extension Model {
    /// Validate a request against model capabilities.
    ///
    /// Call this before sending to catch capability mismatches early.
    ///
    /// - Parameter request: The request to validate
    /// - Throws: `LLMError.capabilityNotSupported` if request uses unsupported features
    public func validateRequest(_ request: CompletionRequest) throws {
        // Check temperature
        if request.config.temperature != nil, !capabilities.supportsTemperature {
            throw LLMError.capabilityNotSupported(
                "temperature not supported by \(name)"
            )
        }

        // Check tools
        if let tools = request.tools, !tools.isEmpty, !capabilities.supportsTools {
            throw LLMError.capabilityNotSupported(
                "tools not supported by \(name)"
            )
        }

        // Check structured output
        if request.outputSchema != nil, !capabilities.supportsStructuredOutput {
            throw LLMError.capabilityNotSupported(
                "structured output not supported by \(name)"
            )
        }

        // Check system message
        if !capabilities.supportsSystemMessage {
            let hasSystemMessage = request.messages.contains { message in
                if case .system = message { return true }
                return false
            }
            if hasSystemMessage {
                throw LLMError.capabilityNotSupported(
                    "system messages not supported by \(name)"
                )
            }
        }

        // Check vision
        if !capabilities.supportsVision {
            let hasImage = request.messages.contains { message in
                if case .user(let parts) = message {
                    return parts.contains { part in
                        if case .image = part { return true }
                        return false
                    }
                }
                return false
            }
            if hasImage {
                throw LLMError.capabilityNotSupported(
                    "vision/images not supported by \(name)"
                )
            }
        }
    }
}
