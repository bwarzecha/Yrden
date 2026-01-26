/// HTTP request utilities for LLM provider implementations.
///
/// Provides common patterns for building and sending HTTP requests,
/// reducing boilerplate in provider model implementations.

import Foundation

// MARK: - HTTP Request Helpers

/// Helper for building and sending HTTP requests to LLM providers.
enum HTTPClient {
    /// Sends a POST request with JSON body.
    ///
    /// - Parameters:
    ///   - url: The endpoint URL
    ///   - body: Request body to encode as JSON
    ///   - configure: Closure to configure the request (add auth headers, etc.)
    /// - Returns: Response data and HTTP response
    /// - Throws: `LLMError.networkError` if response is not HTTPURLResponse
    static func sendJSONPOST<Body: Encodable>(
        url: URL,
        body: Body,
        configure: (inout URLRequest) async throws -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = HTTPMethod.post
        try await configure(&request)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError("Invalid response type")
        }

        return (data, http)
    }

    /// Starts a streaming POST request with JSON body.
    ///
    /// - Parameters:
    ///   - url: The endpoint URL
    ///   - body: Request body to encode as JSON
    ///   - configure: Closure to configure the request (add auth headers, etc.)
    /// - Returns: Async byte stream and HTTP response
    /// - Throws: `LLMError.networkError` if response is not HTTPURLResponse
    static func streamJSONPOST<Body: Encodable>(
        url: URL,
        body: Body,
        configure: (inout URLRequest) async throws -> Void
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = HTTPMethod.post
        try await configure(&request)
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError("Invalid response type")
        }

        return (bytes, http)
    }

    /// Collects error data from a streaming response.
    ///
    /// When a streaming request returns a non-success status code,
    /// use this to collect the error response body.
    ///
    /// - Parameter bytes: The async byte stream
    /// - Returns: Collected error data
    static func collectErrorData(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var errorData = Data()
        for try await byte in bytes {
            errorData.append(byte)
        }
        return errorData
    }
}

// MARK: - HTTP Status Code Helpers

extension HTTPClient {
    /// Common HTTP status code handling for LLM APIs.
    ///
    /// Handles status codes that are consistently treated the same across providers:
    /// - 200-299: Success
    /// - 401: Invalid API key
    /// - 404: Model not found
    ///
    /// Other status codes should be handled by the provider for custom logic
    /// (e.g., OpenAI's retry handling, context length detection).
    ///
    /// - Parameters:
    ///   - statusCode: HTTP status code
    ///   - modelName: Model name for error messages
    ///   - data: Response data for error parsing
    ///   - parseError: Closure to parse provider-specific error format
    /// - Returns: `nil` if status handled, throws if error, or status code if provider should handle
    static func handleCommonStatus(
        _ statusCode: Int,
        modelName: String,
        data: Data,
        parseError: (Data) -> String
    ) throws -> Int? {
        switch statusCode {
        case 200..<300:
            return nil  // Success, no error

        case 401:
            throw LLMError.invalidAPIKey

        case 404:
            throw LLMError.modelNotFound(modelName)

        default:
            return statusCode  // Provider should handle
        }
    }

    /// Parses Retry-After header value.
    ///
    /// - Parameter headerValue: The Retry-After header value
    /// - Returns: Retry interval in seconds, or nil if not parseable
    static func parseRetryAfter(_ headerValue: String?) -> TimeInterval? {
        guard let value = headerValue, let seconds = Double(value) else {
            return nil
        }
        return seconds
    }
}
