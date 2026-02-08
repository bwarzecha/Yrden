/// Model implementation for local OpenAI-compatible servers.
///
/// Uses `ChatCompletionsHandler` with conservative defaults suitable for
/// Ollama, LM Studio, vLLM, and other local servers:
/// - `max_tokens` (legacy) instead of `max_completion_tokens`
/// - `tool_choice: "auto"` instead of `"required"` (safer for local models)
/// - No retries by default (local servers don't rate-limit)
///
/// ## Usage
/// ```swift
/// let provider = LocalProvider.ollama()
/// let model = LocalModel(name: "llama3.2", provider: provider)
///
/// // Simple completion
/// let response = try await model.complete("Hello!")
///
/// // With tools
/// let agent = Agent(model: model, tools: [myTool])
/// let result = try await agent.run("Search for X")
/// ```

import Foundation

// MARK: - LocalModel

/// Model for local OpenAI-compatible LLM servers.
public struct LocalModel: Model, Sendable {
    /// Provider identifier for cross-provider thinking block handling.
    public static let providerId = "local"

    /// Model identifier (e.g., "llama3.2", "qwen2.5-coder").
    public let name: String

    /// Capabilities of this model.
    public let capabilities: ModelCapabilities

    /// How to handle thinking blocks from other providers.
    public let foreignThinkingBehavior: ForeignThinkingBehavior

    /// Provider for connection.
    private let provider: LocalProvider

    /// Retry configuration for transient errors.
    private let retryConfig: RetryConfig

    /// Chat Completions wire format handler.
    private let handler: ChatCompletionsHandler

    /// Creates a local model.
    ///
    /// - Parameters:
    ///   - name: Model identifier as reported by the server (e.g., "llama3.2")
    ///   - provider: Local provider for connection
    ///   - capabilities: Model capabilities (default: `.local`)
    ///   - defaultMaxTokens: Default max tokens, nil means omit (let server decide). (default: nil)
    ///   - retryConfig: Retry configuration (default: `.none`)
    ///   - foreignThinkingBehavior: How to handle thinking blocks from other providers (default: `.drop`)
    public init(
        name: String,
        provider: LocalProvider,
        capabilities: ModelCapabilities = .local,
        defaultMaxTokens: Int? = nil,
        retryConfig: RetryConfig = .none,
        foreignThinkingBehavior: ForeignThinkingBehavior = .drop
    ) {
        self.name = name
        self.provider = provider
        self.capabilities = capabilities
        self.retryConfig = retryConfig
        self.foreignThinkingBehavior = foreignThinkingBehavior
        self.handler = ChatCompletionsHandler(
            maxTokensParam: .legacy,
            toolChoiceStrategy: .alwaysAuto,
            foreignThinkingBehavior: foreignThinkingBehavior,
            defaultMaxTokens: defaultMaxTokens,
            providerId: Self.providerId
        )
    }

    // MARK: - Model Protocol

    public func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        try validateRequest(request)

        let openAIRequest = try handler.encodeRequest(request, modelName: name, stream: false)

        return try await retryConfig.execute {
            let data = try await handler.sendRequest(openAIRequest, provider: provider, modelName: name)
            return try handler.decodeResponse(data, stopSequences: request.config.stopSequences)
        }
    }

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try validateRequest(request)

                    let openAIRequest = try handler.encodeRequest(request, modelName: name, stream: true)

                    try await retryConfig.execute {
                        try await handler.streamRequest(
                            openAIRequest,
                            provider: provider,
                            modelName: name,
                            continuation: continuation,
                            stopSequences: request.config.stopSequences
                        )
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
