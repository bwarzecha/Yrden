/// HTTP constants used across providers.
///
/// Centralizes HTTP-related strings to ensure consistency and avoid typos.

import Foundation

// MARK: - HTTP Methods

/// Standard HTTP methods.
enum HTTPMethod {
    static let get = "GET"
    static let post = "POST"
}

// MARK: - HTTP Header Fields

/// Standard HTTP header field names.
enum HTTPHeaderField {
    static let authorization = "Authorization"
    static let contentType = "Content-Type"
    /// Case-insensitive header name for retry delay. Use this consistently.
    static let retryAfter = "Retry-After"
}

// MARK: - HTTP Header Values

/// Common HTTP header values.
enum HTTPHeaderValue {
    static let applicationJSON = "application/json"
    static let bearerPrefix = "Bearer "
}

// MARK: - Anthropic-Specific Headers

/// Header constants specific to the Anthropic API.
enum AnthropicHeader {
    /// Header field for API key authentication.
    static let apiKeyField = "x-api-key"
    /// Header field for API version.
    static let versionField = "anthropic-version"
    /// Current API version value.
    static let versionValue = "2023-06-01"
}
