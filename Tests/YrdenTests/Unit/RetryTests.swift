/// Tests for retry configuration and retriable error handling.
///
/// Test coverage:
/// - isRetriableStatusCode() identifies correct status codes
/// - RetryConfig.execute retries on RetriableError
/// - RetryConfig.execute does not retry on non-retriable errors
/// - RetryConfig respects maxRetries limit

import Testing
import Foundation
@testable import Yrden

/// Thread-safe counter for tracking retry attempts in Sendable closures.
private actor AttemptCounter {
    var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

@Suite("Retry")
struct RetryTests {

    // MARK: - isRetriableStatusCode

    @Test("429, 408, 409 are retriable")
    func clientRetriableStatusCodes() {
        #expect(isRetriableStatusCode(408))
        #expect(isRetriableStatusCode(409))
        #expect(isRetriableStatusCode(429))
    }

    @Test("500+ are retriable")
    func serverRetriableStatusCodes() {
        #expect(isRetriableStatusCode(500))
        #expect(isRetriableStatusCode(502))
        #expect(isRetriableStatusCode(503))
        #expect(isRetriableStatusCode(504))
    }

    @Test("200, 400, 401, 404 are not retriable")
    func nonRetriableStatusCodes() {
        #expect(!isRetriableStatusCode(200))
        #expect(!isRetriableStatusCode(400))
        #expect(!isRetriableStatusCode(401))
        #expect(!isRetriableStatusCode(404))
    }

    // MARK: - RetryConfig.execute

    @Test("execute retries on RetriableError then succeeds")
    func executeRetriesThenSucceeds() async throws {
        let config = RetryConfig(maxRetries: 2, initialDelay: 0.01, maxDelay: 0.1)
        let counter = AttemptCounter()

        let result = try await config.execute {
            let attempt = await counter.increment()
            if attempt < 2 {
                throw RetriableError(
                    underlyingError: LLMError.networkError("HTTP 429"),
                    retryAfter: nil,
                    statusCode: 429
                )
            }
            return "success"
        }

        #expect(result == "success")
        #expect(await counter.count == 2)
    }

    @Test("execute does not retry non-retriable errors")
    func executeDoesNotRetryNonRetriable() async {
        let config = RetryConfig(maxRetries: 3, initialDelay: 0.01, maxDelay: 0.1)
        let counter = AttemptCounter()

        do {
            _ = try await config.execute { () -> String in
                _ = await counter.increment()
                throw LLMError.invalidAPIKey
            }
            Issue.record("Should have thrown")
        } catch {
            let attempts = await counter.count
            #expect(attempts == 1)
            if case LLMError.invalidAPIKey = error {
                // Expected
            } else {
                Issue.record("Expected invalidAPIKey, got \(error)")
            }
        }
    }

    @Test("execute exhausts retries then throws underlying error")
    func executeExhaustsRetries() async {
        let config = RetryConfig(maxRetries: 2, initialDelay: 0.01, maxDelay: 0.1)
        let counter = AttemptCounter()

        do {
            _ = try await config.execute { () -> String in
                _ = await counter.increment()
                throw RetriableError(
                    underlyingError: LLMError.networkError("HTTP 500"),
                    retryAfter: nil,
                    statusCode: 500
                )
            }
            Issue.record("Should have thrown")
        } catch {
            let attempts = await counter.count
            #expect(attempts == 3) // 1 initial + 2 retries
            if case LLMError.networkError(let msg) = error {
                #expect(msg == "HTTP 500")
            } else {
                Issue.record("Expected networkError, got \(error)")
            }
        }
    }

    @Test("no retries when maxRetries is zero")
    func noRetriesWhenZero() async {
        let config = RetryConfig.none
        let counter = AttemptCounter()

        do {
            _ = try await config.execute { () -> String in
                _ = await counter.increment()
                throw RetriableError(
                    underlyingError: LLMError.networkError("HTTP 429"),
                    retryAfter: nil,
                    statusCode: 429
                )
            }
            Issue.record("Should have thrown")
        } catch {
            let attempts = await counter.count
            #expect(attempts == 1)
        }
    }

    // MARK: - parseRetryAfter

    @Test("parseRetryAfter parses integer seconds")
    func parseRetryAfterInteger() {
        #expect(parseRetryAfter("5") == 5.0)
        #expect(parseRetryAfter("120") == 120.0)
    }

    @Test("parseRetryAfter parses float seconds")
    func parseRetryAfterFloat() {
        #expect(parseRetryAfter("2.5") == 2.5)
    }

    @Test("parseRetryAfter returns nil for invalid input")
    func parseRetryAfterInvalid() {
        #expect(parseRetryAfter(nil) == nil)
        #expect(parseRetryAfter("not-a-number") == nil)
    }
}
