/// Anthropic API provider for authentication and connection.
///
/// Handles:
/// - API key authentication
/// - Required headers (anthropic-version, Content-Type)
/// - Base URL for Anthropic Messages API
///
/// ## Usage
/// ```swift
/// let provider = AnthropicProvider(apiKey: "sk-ant-...")
/// let model = AnthropicModel(name: "claude-3-5-sonnet-20241022", provider: provider)
///
/// let response = try await model.complete("Hello!")
/// ```

import Foundation

// MARK: - AnthropicProvider

/// Provider for the Anthropic Messages API.
///
/// Configures authentication and connection details for Anthropic:
/// - API key via `x-api-key` header
/// - Required `anthropic-version` header
/// - Base URL: `https://api.anthropic.com/v1`
public struct AnthropicProvider: Provider, Sendable {
    /// Anthropic API key (starts with `sk-ant-`).
    public let apiKey: String

    /// Base URL for the Anthropic API.
    public var baseURL: URL {
        URL(string: "https://api.anthropic.com/v1")!
    }

    /// Creates a provider with the given API key.
    ///
    /// - Parameter apiKey: Your Anthropic API key
    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Adds authentication headers to the request.
    ///
    /// Sets:
    /// - `x-api-key`: API key authentication
    /// - `anthropic-version`: API version (2023-06-01)
    /// - `Content-Type`: application/json
    public func authenticate(_ request: inout URLRequest) async throws {
        request.setValue(apiKey, forHTTPHeaderField: AnthropicHeader.apiKeyField)
        request.setValue(AnthropicHeader.versionValue, forHTTPHeaderField: AnthropicHeader.versionField)
        request.setValue(HTTPHeaderValue.applicationJSON, forHTTPHeaderField: HTTPHeaderField.contentType)
    }

    /// Lists available models from Anthropic.
    ///
    /// Returns a lazy stream of models, fetching pages on demand.
    /// Models are returned with most recently released first.
    ///
    /// ## Usage
    /// ```swift
    /// // Collect all models
    /// let models = try await Array(provider.listModels())
    ///
    /// // Find first Claude 3.5 model
    /// for try await model in provider.listModels() {
    ///     if model.id.contains("claude-3-5") {
    ///         return model
    ///     }
    /// }
    /// ```
    ///
    /// - Returns: Stream of available Claude models
    public func listModels() -> AsyncThrowingStream<ModelInfo, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var afterCursor: String? = nil

                    while true {
                        let page = try await self.fetchModelsPage(after: afterCursor)

                        for model in page.models {
                            continuation.yield(model)
                        }

                        if page.hasMore, let lastId = page.lastId {
                            afterCursor = lastId
                        } else {
                            break
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Fetches a single page of models from the API.
    private func fetchModelsPage(after cursor: String?) async throws -> ModelsPage {
        var urlComponents = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!

        if let cursor = cursor {
            urlComponents.queryItems = [URLQueryItem(name: "after_id", value: cursor)]
        }

        var request = URLRequest(url: urlComponents.url!)
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
            throw LLMError.rateLimited(retryAfter: nil)
        default:
            throw LLMError.networkError("HTTP \(http.statusCode)")
        }

        let apiResponse = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)

        let models = apiResponse.data.map { model in
            ModelInfo(
                id: model.id,
                displayName: model.display_name,
                createdAt: ISO8601DateFormatter().date(from: model.created_at),
                metadata: nil
            )
        }

        return ModelsPage(
            models: models,
            hasMore: apiResponse.has_more,
            lastId: apiResponse.last_id
        )
    }
}

// MARK: - Pagination Helper

/// Internal type for paginated model results.
private struct ModelsPage {
    let models: [ModelInfo]
    let hasMore: Bool
    let lastId: String?
}

// MARK: - Internal Response Types

/// Response from Anthropic Models API.
private struct AnthropicModelsResponse: Decodable {
    let data: [AnthropicModelInfo]
    let has_more: Bool
    let first_id: String?
    let last_id: String?
}

/// Model info from Anthropic API.
private struct AnthropicModelInfo: Decodable {
    let id: String
    let display_name: String
    let created_at: String
    let type: String
}
