/// OpenAI API provider for authentication and connection.
///
/// Handles:
/// - API key authentication via Bearer token
/// - Content-Type header
/// - Base URL for OpenAI Chat Completions API
///
/// ## Usage
/// ```swift
/// let provider = OpenAIProvider(apiKey: "sk-...")
/// let model = OpenAIModel(name: "gpt-4o", provider: provider)
///
/// let response = try await model.complete("Hello!")
/// ```

import Foundation

// MARK: - OpenAIProvider

/// Provider for the OpenAI Chat Completions API.
///
/// Configures authentication and connection details for OpenAI:
/// - API key via `Authorization: Bearer` header
/// - Base URL: `https://api.openai.com/v1`
///
/// Also works as a base for OpenAI-compatible APIs via `OpenAICompatibleProvider`.
public struct OpenAIProvider: Provider, OpenAICompatibleProvider, Sendable {
    /// OpenAI API key (starts with `sk-`).
    public let apiKey: String

    /// Base URL for the OpenAI API.
    public var baseURL: URL {
        URL(string: "https://api.openai.com/v1")!
    }

    /// Creates a provider with the given API key.
    ///
    /// - Parameter apiKey: Your OpenAI API key
    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Adds authentication headers to the request.
    ///
    /// Sets:
    /// - `Authorization`: Bearer token authentication
    /// - `Content-Type`: application/json
    public func authenticate(_ request: inout URLRequest) async throws {
        request.setValue(HTTPHeaderValue.bearerPrefix + apiKey, forHTTPHeaderField: HTTPHeaderField.authorization)
        request.setValue(HTTPHeaderValue.applicationJSON, forHTTPHeaderField: HTTPHeaderField.contentType)
    }

    /// Lists available models from OpenAI.
    ///
    /// Returns a stream of chat completion models (gpt-*, o1-*, o3-*).
    /// Unlike Anthropic, OpenAI returns all models in a single response.
    ///
    /// ## Usage
    /// ```swift
    /// // Collect all models
    /// let models = try await Array(provider.listModels())
    ///
    /// // Find GPT-4o models
    /// for try await model in provider.listModels() {
    ///     if model.id.hasPrefix("gpt-4o") {
    ///         print(model.id)
    ///     }
    /// }
    /// ```
    ///
    /// - Returns: Stream of available models
    public func listModels() -> AsyncThrowingStream<ModelInfo, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent(OpenAIEndpoint.models))
                    request.httpMethod = HTTPMethod.get
                    try await authenticate(&request)

                    let (data, response) = try await URLSession.shared.data(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.networkError("Invalid response type")
                    }

                    switch http.statusCode {
                    case 200..<300:
                        break
                    case 401:
                        throw LLMError.invalidAPIKey
                    case 429:
                        let retryAfter = http.value(forHTTPHeaderField: HTTPHeaderField.retryAfter)
                            .flatMap { Double($0) }
                        throw LLMError.rateLimited(retryAfter: retryAfter)
                    default:
                        throw LLMError.networkError("HTTP \(http.statusCode)")
                    }

                    let apiResponse = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)

                    // Filter to chat completion models only
                    let chatModels = apiResponse.data.filter { model in
                        model.id.hasPrefix("gpt-") ||
                        model.id.hasPrefix("o1") ||
                        model.id.hasPrefix("o3")
                    }

                    // Sort by creation date (newest first)
                    let sortedModels = chatModels.sorted { $0.created > $1.created }

                    for model in sortedModels {
                        let info = ModelInfo(
                            id: model.id,
                            displayName: model.id,  // OpenAI doesn't provide display names
                            createdAt: Date(timeIntervalSince1970: TimeInterval(model.created)),
                            metadata: nil
                        )
                        continuation.yield(info)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
