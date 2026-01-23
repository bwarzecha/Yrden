/// Retry configuration and utilities for handling transient errors.
///
/// Implements exponential backoff with jitter for transient HTTP errors,
/// following the same pattern as the official OpenAI Python client.
///
/// ## Retriable Status Codes
/// - 408 Request Timeout
/// - 409 Conflict (lock timeout)
/// - 429 Rate Limited
/// - 500+ Server Errors (500, 502, 503, 504, etc.)
///
/// ## Example
/// ```swift
/// let config = RetryConfig(maxRetries: 3, initialDelay: 0.5, maxDelay: 30)
/// let data = try await config.execute {
///     try await sendRequest(urlRequest)
/// }
/// ```

import Foundation

// MARK: - RetryConfig

/// Configuration for automatic retry of transient errors.
public struct RetryConfig: Sendable, Equatable, Hashable {
    /// Maximum number of retry attempts (0 = no retries, just the initial attempt).
    public let maxRetries: Int

    /// Initial delay before first retry (in seconds).
    public let initialDelay: TimeInterval

    /// Maximum delay between retries (in seconds).
    public let maxDelay: TimeInterval

    /// Jitter factor (0.0-1.0). Adds randomness to prevent thundering herd.
    public let jitterFactor: Double

    /// Creates a retry configuration.
    ///
    /// - Parameters:
    ///   - maxRetries: Maximum retry attempts (default: 2)
    ///   - initialDelay: Initial delay in seconds (default: 0.5)
    ///   - maxDelay: Maximum delay in seconds (default: 30)
    ///   - jitterFactor: Random jitter factor 0-1 (default: 0.25)
    public init(
        maxRetries: Int = 2,
        initialDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 30,
        jitterFactor: Double = 0.25
    ) {
        self.maxRetries = max(0, maxRetries)
        self.initialDelay = max(0, initialDelay)
        self.maxDelay = max(initialDelay, maxDelay)
        self.jitterFactor = min(1.0, max(0.0, jitterFactor))
    }

    /// Default retry configuration (2 retries, 0.5s initial delay).
    public static let `default` = RetryConfig()

    /// No retries - fail on first error.
    public static let none = RetryConfig(maxRetries: 0)

    /// Aggressive retry configuration (5 retries, 1s initial delay).
    public static let aggressive = RetryConfig(maxRetries: 5, initialDelay: 1.0, maxDelay: 60)
}

// MARK: - Retriable Error

/// Errors that can be retried after a delay.
public struct RetriableError: Error {
    /// The underlying error.
    public let underlyingError: Error

    /// Suggested delay before retry (from Retry-After header).
    public let retryAfter: TimeInterval?

    /// HTTP status code that triggered the retry.
    public let statusCode: Int
}

// MARK: - HTTP Retry Execution

extension RetryConfig {
    /// Executes an HTTP operation with automatic retry for transient errors.
    ///
    /// - Parameters:
    ///   - operation: The async operation to execute
    /// - Returns: The result of the operation
    /// - Throws: The last error if all retries are exhausted
    public func execute<T>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var attempt = 0

        while attempt <= maxRetries {
            do {
                return try await operation()
            } catch let error as RetriableError {
                lastError = error.underlyingError
                attempt += 1

                if attempt > maxRetries {
                    throw error.underlyingError
                }

                let delay = calculateDelay(
                    attempt: attempt,
                    retryAfter: error.retryAfter
                )
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                // Non-retriable error, throw immediately
                throw error
            }
        }

        throw lastError ?? LLMError.networkError("Retry exhausted with no error")
    }

    /// Calculates the delay for a retry attempt using exponential backoff with jitter.
    private func calculateDelay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        // Respect Retry-After header if present and reasonable (≤ 60s)
        if let retryAfter = retryAfter, retryAfter > 0, retryAfter <= 60 {
            return retryAfter
        }

        // Exponential backoff: initialDelay * 2^(attempt-1)
        let exponentialDelay = initialDelay * pow(2.0, Double(attempt - 1))

        // Cap at maxDelay
        let cappedDelay = min(exponentialDelay, maxDelay)

        // Add jitter: delay ± (delay * jitterFactor * random)
        let jitter = cappedDelay * jitterFactor * Double.random(in: -1...1)
        let finalDelay = cappedDelay + jitter

        return max(0, finalDelay)
    }
}

// MARK: - HTTP Response Helpers

/// Checks if an HTTP status code should trigger a retry.
///
/// Retriable status codes:
/// - 408: Request Timeout
/// - 409: Conflict (lock timeout)
/// - 429: Rate Limited
/// - 500+: Server Errors
public func isRetriableStatusCode(_ statusCode: Int) -> Bool {
    switch statusCode {
    case 408, 409, 429:
        return true
    case 500...:
        return true
    default:
        return false
    }
}

/// Parses the Retry-After header value.
///
/// Supports:
/// - Integer seconds: "120"
/// - Float seconds: "2.5"
/// - HTTP date: "Wed, 21 Oct 2015 07:28:00 GMT"
///
/// - Parameter value: The Retry-After header value
/// - Returns: Delay in seconds, or nil if unparseable
public func parseRetryAfter(_ value: String?) -> TimeInterval? {
    guard let value = value else { return nil }

    // Try parsing as number (seconds)
    if let seconds = Double(value) {
        return seconds
    }

    // Try parsing as HTTP date
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    formatter.locale = Locale(identifier: "en_US_POSIX")

    if let date = formatter.date(from: value) {
        let delay = date.timeIntervalSinceNow
        return delay > 0 ? delay : nil
    }

    return nil
}
