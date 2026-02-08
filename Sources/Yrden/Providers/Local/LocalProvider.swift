/// Provider for local OpenAI-compatible servers.
///
/// Works with any server that implements the OpenAI Chat Completions API:
/// - **Ollama** (`http://localhost:11434/v1`)
/// - **LM Studio** (`http://localhost:1234/v1`)
/// - **vLLM** (`http://localhost:8000/v1`)
///
/// No authentication is required. Model listing returns all models
/// without filtering (unlike `OpenAIProvider` which filters to GPT/o-series).
///
/// ## Usage
/// ```swift
/// let provider = LocalProvider.ollama()
/// let model = LocalModel(name: "llama3.2", provider: provider)
///
/// let response = try await model.complete("Hello!")
/// ```

import Foundation

// MARK: - LocalProvider

/// Provider for local OpenAI-compatible LLM servers.
public struct LocalProvider: Provider, OpenAICompatibleProvider, Sendable {
    /// Base URL for the local server.
    public let baseURL: URL

    /// Request timeout in seconds. Local models can be slow (thinking, tool calling).
    public let requestTimeout: TimeInterval

    /// Creates a provider with a custom base URL.
    ///
    /// - Parameters:
    ///   - baseURL: The server's base URL (must include `/v1`)
    ///   - requestTimeout: Timeout per request in seconds (default: 300 = 5 minutes)
    public init(baseURL: URL, requestTimeout: TimeInterval = 300) {
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
    }

    /// Sets content type and timeout for local servers. No authentication needed.
    public func authenticate(_ request: inout URLRequest) async throws {
        request.setValue(
            HTTPHeaderValue.applicationJSON,
            forHTTPHeaderField: HTTPHeaderField.contentType
        )
        request.timeoutInterval = requestTimeout
    }

    /// Lists all models from the local server without filtering.
    ///
    /// Unlike `OpenAIProvider`, this returns every model the server reports.
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

                    guard (200..<300).contains(http.statusCode) else {
                        throw LLMError.networkError("HTTP \(http.statusCode)")
                    }

                    let apiResponse = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
                    let sortedModels = apiResponse.data.sorted {
                        ($0.created ?? 0) > ($1.created ?? 0)
                    }

                    for model in sortedModels {
                        continuation.yield(ModelInfo(
                            id: model.id,
                            displayName: model.id,
                            createdAt: model.created.map {
                                Date(timeIntervalSince1970: TimeInterval($0))
                            }
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Presets

extension LocalProvider {
    /// Provider for Ollama (default: `http://localhost:11434/v1`).
    public static func ollama(port: Int = 11434) -> LocalProvider {
        LocalProvider(baseURL: URL(string: "http://localhost:\(port)/v1")!)
    }

    /// Provider for LM Studio (default: `http://localhost:1234/v1`).
    public static func lmStudio(port: Int = 1234) -> LocalProvider {
        LocalProvider(baseURL: URL(string: "http://localhost:\(port)/v1")!)
    }

    /// Provider for vLLM (default: `http://localhost:8000/v1`).
    public static func vllm(port: Int = 8000) -> LocalProvider {
        LocalProvider(baseURL: URL(string: "http://localhost:\(port)/v1")!)
    }
}
