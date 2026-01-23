/// Provider protocol for LLM connection and authentication.
///
/// A Provider handles the transport layer:
/// - Base URL for API requests
/// - Authentication (API keys, tokens, AWS signatures)
/// - Model discovery (listing available models)
///
/// Providers are separate from Models to enable:
/// - Same model format with different backends (Azure OpenAI, Ollama)
/// - Different auth methods for same API format
/// - Easy testing with mock providers

import Foundation

// MARK: - ModelInfo

/// Information about an available model from a provider.
///
/// Returned by `Provider.listModels()` for model discovery.
/// The `id` is the string to use when creating a Model instance.
///
/// ## Example
/// ```swift
/// let models = try await provider.listModels()
/// for model in models {
///     print("\(model.displayName): \(model.id)")
/// }
/// // Create a model using the id
/// let model = AnthropicModel(name: models[0].id, provider: provider)
/// ```
public struct ModelInfo: Sendable, Codable, Equatable, Hashable {
    /// API identifier for the model.
    /// This is the string to pass when creating a Model instance.
    public let id: String

    /// Human-readable display name.
    /// Example: "Claude 3.5 Sonnet"
    public let displayName: String

    /// When the model was created/released.
    /// May be nil if unknown.
    public let createdAt: Date?

    /// Provider-specific metadata.
    /// For Bedrock: geography, routing regions, etc.
    /// For OpenRouter: pricing, context length, etc.
    public let metadata: JSONValue?

    public init(
        id: String,
        displayName: String,
        createdAt: Date? = nil,
        metadata: JSONValue? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

// MARK: - Provider Protocol

/// Protocol for LLM API providers.
///
/// A Provider knows:
/// - Where to send requests (baseURL)
/// - How to authenticate requests
///
/// Providers are `Sendable` and can be shared across tasks.
///
/// ## Example Implementations
///
/// ```swift
/// // Direct API access
/// struct OpenAIProvider: Provider {
///     let apiKey: String
///     var baseURL: URL { URL(string: "https://api.openai.com/v1")! }
///
///     func authenticate(_ request: inout URLRequest) async throws {
///         request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
///     }
/// }
///
/// // Azure OpenAI
/// struct AzureOpenAIProvider: Provider {
///     let endpoint: URL
///     let apiKey: String
///     var baseURL: URL { endpoint }
///
///     func authenticate(_ request: inout URLRequest) async throws {
///         request.setValue(apiKey, forHTTPHeaderField: "api-key")
///     }
/// }
///
/// // Local (Ollama)
/// struct LocalProvider: Provider {
///     var baseURL: URL { URL(string: "http://localhost:11434/v1")! }
///
///     func authenticate(_ request: inout URLRequest) async throws {
///         // No auth needed for local
///     }
/// }
/// ```
public protocol Provider: Sendable {
    /// Base URL for API requests.
    ///
    /// Model implementations append paths to this URL:
    /// - `/chat/completions` for OpenAI format
    /// - `/messages` for Anthropic format
    var baseURL: URL { get }

    /// Add authentication to a request.
    ///
    /// Called before each API request. Implementations should add
    /// appropriate headers, query parameters, or signatures.
    ///
    /// - Parameter request: The request to authenticate (modified in place)
    /// - Throws: If authentication fails (e.g., token refresh failure)
    func authenticate(_ request: inout URLRequest) async throws

    /// List available models from this provider.
    ///
    /// Returns a lazy stream of model information. Models are fetched
    /// page by page as the stream is consumed, enabling efficient handling
    /// of large model catalogs (e.g., OpenRouter with 200+ models).
    ///
    /// ## Usage
    /// ```swift
    /// // Collect all models
    /// let allModels = try await Array(provider.listModels())
    ///
    /// // Find first matching model (stops early)
    /// for try await model in provider.listModels() {
    ///     if model.id.contains("claude") {
    ///         return model
    ///     }
    /// }
    /// ```
    ///
    /// - Returns: Stream of available models, most recent first
    func listModels() -> AsyncThrowingStream<ModelInfo, Error>
}

// MARK: - OpenAI-Compatible Provider

/// Marker protocol for providers that use OpenAI-compatible API format.
///
/// Used to identify providers that can work with `OpenAIChatModel`:
/// - OpenAI direct
/// - Azure OpenAI
/// - Ollama
/// - vLLM
/// - LM Studio
/// - OpenRouter (partial)
public protocol OpenAICompatibleProvider: Provider {}

// MARK: - Model List Caching

/// Actor for caching model lists from providers.
///
/// Model lists rarely change, so caching avoids repeated API calls.
/// Use this when you need to access the model list multiple times.
///
/// ## Usage
/// ```swift
/// let cache = CachedModelList(ttl: 3600)  // 1 hour TTL
///
/// // First call fetches from API
/// let models = try await cache.models(from: provider)
///
/// // Subsequent calls return cached data
/// let models2 = try await cache.models(from: provider)
///
/// // Force refresh
/// let fresh = try await cache.models(from: provider, forceRefresh: true)
/// ```
public actor CachedModelList {
    private var cache: [String: CacheEntry] = [:]
    private let ttl: TimeInterval

    /// Cache entry with models and expiry time.
    private struct CacheEntry {
        let models: [ModelInfo]
        let expiry: Date
    }

    /// Creates a cached model list with the specified TTL.
    ///
    /// - Parameter ttl: Time-to-live in seconds (default: 1 hour)
    public init(ttl: TimeInterval = 3600) {
        self.ttl = ttl
    }

    /// Gets models from a provider, using cache if valid.
    ///
    /// - Parameters:
    ///   - provider: The provider to fetch models from
    ///   - forceRefresh: If true, bypasses cache and fetches fresh data
    /// - Returns: Array of available models
    /// - Throws: `LLMError` for network or authentication failures
    public func models<P: Provider>(from provider: P, forceRefresh: Bool = false) async throws -> [ModelInfo] {
        let key = cacheKey(for: provider)

        // Check cache
        if !forceRefresh, let entry = cache[key], entry.expiry > Date() {
            return entry.models
        }

        // Fetch all models from stream
        var models: [ModelInfo] = []
        for try await model in provider.listModels() {
            models.append(model)
        }

        // Update cache
        cache[key] = CacheEntry(
            models: models,
            expiry: Date().addingTimeInterval(ttl)
        )

        return models
    }

    /// Clears all cached entries.
    public func clearAll() {
        cache.removeAll()
    }

    /// Clears cached entry for a specific provider.
    public func clear<P: Provider>(for provider: P) {
        let key = cacheKey(for: provider)
        cache.removeValue(forKey: key)
    }

    /// Generates a cache key for a provider.
    private func cacheKey<P: Provider>(for provider: P) -> String {
        // Use type name + baseURL as key
        "\(type(of: provider)):\(provider.baseURL.absoluteString)"
    }
}
