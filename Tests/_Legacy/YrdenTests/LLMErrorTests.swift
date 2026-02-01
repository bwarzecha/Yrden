/// Tests for LLMError.
///
/// Test coverage:
/// - All error cases
/// - Equatable/Hashable behavior
/// - LocalizedError descriptions

import Testing
import Foundation
@testable import Yrden

@Suite("LLMError")
struct LLMErrorTests {

    // MARK: - Equatable

    @Test func equatable_rateLimitedWithDelay() {
        let err1 = LLMError.rateLimited(retryAfter: 30.0)
        let err2 = LLMError.rateLimited(retryAfter: 30.0)

        #expect(err1 == err2)
    }

    @Test func equatable_rateLimitedDifferentDelay() {
        let err1 = LLMError.rateLimited(retryAfter: 30.0)
        let err2 = LLMError.rateLimited(retryAfter: 60.0)

        #expect(err1 != err2)
    }

    @Test func equatable_rateLimitedNil() {
        let err1 = LLMError.rateLimited(retryAfter: nil)
        let err2 = LLMError.rateLimited(retryAfter: nil)

        #expect(err1 == err2)
    }

    @Test func equatable_invalidAPIKey() {
        let err1 = LLMError.invalidAPIKey
        let err2 = LLMError.invalidAPIKey

        #expect(err1 == err2)
    }

    @Test func equatable_contentFiltered() {
        let err1 = LLMError.contentFiltered(reason: "violence")
        let err2 = LLMError.contentFiltered(reason: "violence")

        #expect(err1 == err2)
    }

    @Test func equatable_contentFilteredDifferent() {
        let err1 = LLMError.contentFiltered(reason: "violence")
        let err2 = LLMError.contentFiltered(reason: "hate speech")

        #expect(err1 != err2)
    }

    @Test func equatable_modelNotFound() {
        let err1 = LLMError.modelNotFound("gpt-5")
        let err2 = LLMError.modelNotFound("gpt-5")

        #expect(err1 == err2)
    }

    @Test func equatable_invalidRequest() {
        let err1 = LLMError.invalidRequest("missing messages")
        let err2 = LLMError.invalidRequest("missing messages")

        #expect(err1 == err2)
    }

    @Test func equatable_contextLengthExceeded() {
        let err1 = LLMError.contextLengthExceeded(maxTokens: 128000)
        let err2 = LLMError.contextLengthExceeded(maxTokens: 128000)

        #expect(err1 == err2)
    }

    @Test func equatable_capabilityNotSupported() {
        let err1 = LLMError.capabilityNotSupported("temperature")
        let err2 = LLMError.capabilityNotSupported("temperature")

        #expect(err1 == err2)
    }

    @Test func equatable_networkError() {
        let err1 = LLMError.networkError("timeout")
        let err2 = LLMError.networkError("timeout")

        #expect(err1 == err2)
    }

    @Test func equatable_decodingError() {
        let err1 = LLMError.decodingError("invalid JSON")
        let err2 = LLMError.decodingError("invalid JSON")

        #expect(err1 == err2)
    }

    @Test func equatable_differentCases() {
        let err1 = LLMError.invalidAPIKey
        let err2 = LLMError.networkError("invalid key")

        #expect(err1 != err2)
    }

    // MARK: - Hashable

    @Test func hashable_inSet() {
        let errors: Set<LLMError> = [
            .invalidAPIKey,
            .invalidAPIKey,  // duplicate
            .rateLimited(retryAfter: 30),
            .modelNotFound("gpt-5"),
            .networkError("timeout")
        ]

        #expect(errors.count == 4)
    }

    @Test func hashable_asDictionaryKey() {
        var dict: [LLMError: String] = [:]
        dict[.invalidAPIKey] = "Check your API key"
        dict[.rateLimited(retryAfter: 30)] = "Wait and retry"

        #expect(dict[.invalidAPIKey] == "Check your API key")
        #expect(dict[.rateLimited(retryAfter: 30)] == "Wait and retry")
    }

    // MARK: - LocalizedError

    @Test func errorDescription_rateLimitedWithDelay() {
        let error = LLMError.rateLimited(retryAfter: 30.0)
        #expect(error.errorDescription == "Rate limited. Retry after 30 seconds.")
    }

    @Test func errorDescription_rateLimitedNoDelay() {
        let error = LLMError.rateLimited(retryAfter: nil)
        #expect(error.errorDescription == "Rate limited. Please retry later.")
    }

    @Test func errorDescription_invalidAPIKey() {
        let error = LLMError.invalidAPIKey
        #expect(error.errorDescription == "Invalid or missing API key.")
    }

    @Test func errorDescription_contentFiltered() {
        let error = LLMError.contentFiltered(reason: "violence")
        #expect(error.errorDescription == "Content filtered: violence")
    }

    @Test func errorDescription_modelNotFound() {
        let error = LLMError.modelNotFound("gpt-5-turbo")
        #expect(error.errorDescription == "Model not found: gpt-5-turbo")
    }

    @Test func errorDescription_invalidRequest() {
        let error = LLMError.invalidRequest("messages array is empty")
        #expect(error.errorDescription == "Invalid request: messages array is empty")
    }

    @Test func errorDescription_contextLengthExceeded() {
        let error = LLMError.contextLengthExceeded(maxTokens: 128000)
        #expect(error.errorDescription == "Context length exceeded. Maximum tokens: 128000")
    }

    @Test func errorDescription_capabilityNotSupported() {
        let error = LLMError.capabilityNotSupported("temperature not supported by o1")
        #expect(error.errorDescription == "Capability not supported: temperature not supported by o1")
    }

    @Test func errorDescription_networkError() {
        let error = LLMError.networkError("Connection timed out")
        #expect(error.errorDescription == "Network error: Connection timed out")
    }

    @Test func errorDescription_decodingError() {
        let error = LLMError.decodingError("Expected object, got array")
        #expect(error.errorDescription == "Decoding error: Expected object, got array")
    }

    // MARK: - Error Protocol

    @Test func errorProtocol_throwAndCatch() throws {
        func throwingFunction() throws {
            throw LLMError.invalidAPIKey
        }

        do {
            try throwingFunction()
            Issue.record("Should have thrown")
        } catch let error as LLMError {
            #expect(error == .invalidAPIKey)
        }
    }

    @Test func errorProtocol_catchAsError() throws {
        func throwingFunction() throws {
            throw LLMError.rateLimited(retryAfter: 10)
        }

        do {
            try throwingFunction()
            Issue.record("Should have thrown")
        } catch {
            #expect(error is LLMError)
            #expect(error.localizedDescription.contains("Rate limited"))
        }
    }
}
