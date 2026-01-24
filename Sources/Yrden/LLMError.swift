/// Error types for LLM operations.
///
/// `LLMError` provides typed errors for common failure modes when
/// interacting with LLM providers. This enables:
/// - Specific error handling (e.g., retry on rate limit)
/// - Clear error messages for debugging
/// - Type-safe error propagation
///
/// ## Error Handling Example
/// ```swift
/// do {
///     let response = try await model.complete(request)
/// } catch let error as LLMError {
///     switch error {
///     case .rateLimited(let retryAfter):
///         // Wait and retry
///         if let delay = retryAfter {
///             try await Task.sleep(for: .seconds(delay))
///         }
///         // retry...
///     case .contextLengthExceeded(let maxTokens):
///         // Truncate messages and retry
///         print("Context too long, max tokens: \(maxTokens)")
///     case .invalidAPIKey:
///         // Prompt user to check credentials
///         print("Invalid API key")
///     default:
///         print("LLM error: \(error)")
///     }
/// }
/// ```

import Foundation

// MARK: - LLMError

/// Errors that can occur during LLM operations.
public enum LLMError: Error, Sendable, Equatable, Hashable {
    /// Request was rate limited by the provider.
    /// - Parameter retryAfter: Suggested wait time before retrying, if provided.
    case rateLimited(retryAfter: TimeInterval?)

    /// API key is invalid or missing.
    case invalidAPIKey

    /// Response was filtered due to content policy.
    /// - Parameter reason: Explanation of why content was filtered.
    case contentFiltered(reason: String)

    /// Requested model does not exist or is not available.
    /// - Parameter model: The model identifier that was not found.
    case modelNotFound(String)

    /// Request parameters were invalid.
    /// - Parameter details: Description of what was invalid.
    case invalidRequest(String)

    /// Input exceeded the model's context window.
    /// - Parameter maxTokens: The model's maximum context length.
    case contextLengthExceeded(maxTokens: Int)

    /// Requested capability is not supported by this model.
    /// - Parameter capability: Description of the unsupported capability.
    ///
    /// Example: "temperature not supported by o1"
    case capabilityNotSupported(String)

    /// Network error during request.
    /// - Parameter message: Description of the network failure.
    ///
    /// Note: Uses String instead of Error for Equatable compliance.
    case networkError(String)

    /// Failed to decode the response.
    /// - Parameter message: Description of the decoding failure.
    ///
    /// Note: Uses String instead of Error for Equatable compliance.
    case decodingError(String)

    /// Server-side error from the provider.
    /// - Parameter message: Description of the server error.
    case serverError(String)
}

// MARK: - LocalizedError

extension LLMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .rateLimited(let retryAfter):
            if let delay = retryAfter {
                return "Rate limited. Retry after \(Int(delay)) seconds."
            }
            return "Rate limited. Please retry later."

        case .invalidAPIKey:
            return "Invalid or missing API key."

        case .contentFiltered(let reason):
            return "Content filtered: \(reason)"

        case .modelNotFound(let model):
            return "Model not found: \(model)"

        case .invalidRequest(let details):
            return "Invalid request: \(details)"

        case .contextLengthExceeded(let maxTokens):
            return "Context length exceeded. Maximum tokens: \(maxTokens)"

        case .capabilityNotSupported(let capability):
            return "Capability not supported: \(capability)"

        case .networkError(let message):
            return "Network error: \(message)"

        case .decodingError(let message):
            return "Decoding error: \(message)"

        case .serverError(let message):
            return "Server error: \(message)"
        }
    }
}
