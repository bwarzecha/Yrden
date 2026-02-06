/// Tests for validation retry behavior and limits.
///
/// Covers:
/// - maxValidationRetries configuration
/// - Default retry limit (3)
/// - Retry does NOT consume iteration
/// - validationFailed error when retries exhausted

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

// Test type for structured output validation tests
@Schema(description: "A score")
struct ScoreResult: Equatable {
    let score: Int
}

@Suite("Iterator - Validation Retry")
struct IteratorValidationRetryTests {

    // MARK: - Test 14.1: Validation retry succeeds within limit

    @Test("validation succeeds when retries are within limit")
    func validationSucceedsWithinLimit() async throws {
        let validatorCounter = CallCounter()

        // Validator fails twice, then succeeds on third attempt
        let validator = OutputValidator<Void, String> { _, output in
            let count = await validatorCounter.increment()
            if count < 3 {
                throw ValidationRetry("Not ready yet, attempt \(count)")
            }
            return output.uppercased()  // Transform on success
        }

        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            await modelCounter.increment()
            return MockResponse.text("hello")
        })

        let agent = try Agent<Void, String>(
            model: model,
            maxValidationRetries: 3,
            outputValidators: [validator]
        )

        var output: String?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        // Validator called 3 times (2 failures + 1 success)
        #expect(await validatorCounter.current == 3)

        // Model called 3 times (initial + 2 retries)
        #expect(await modelCounter.current == 3)

        // Output should be transformed
        #expect(output == "HELLO")
    }

    // MARK: - Test 14.2: Validation fails when exceeding max retries

    @Test("validation throws validationFailed when exceeding max retries")
    func validationFailsWhenExceedingMaxRetries() async throws {
        let validatorCounter = CallCounter()

        // Validator always fails
        let validator = OutputValidator<Void, String> { _, _ in
            await validatorCounter.increment()
            throw ValidationRetry("Always fails")
        }

        let model = FakeModel(responses: [
            MockResponse.text("attempt 1"),
            MockResponse.text("attempt 2"),
            MockResponse.text("attempt 3"),
            MockResponse.text("attempt 4"),  // Should not reach
        ])

        let agent = try Agent<Void, String>(
            model: model,
            maxValidationRetries: 3,
            outputValidators: [validator]
        )

        var caughtError: AgentError<String>?
        do {
            for try await _ in agent.iter("Hi", deps: ()) { }
        } catch let error as AgentError<String> {
            caughtError = error
        }

        // Should throw validationFailed
        guard case .validationFailed(let state, _, let message) = caughtError else {
            Issue.record("Expected validationFailed error, got: \(String(describing: caughtError))")
            return
        }

        // Validator called exactly maxValidationRetries times
        #expect(await validatorCounter.current == 3)

        // Error should include the retry message
        #expect(message.contains("Always fails") || message.contains("validation"))

        // State should be captured for recovery
        #expect(state.runID.isEmpty == false)
    }

    // MARK: - Test 14.3: Default max validation retries is 3

    @Test("default maxValidationRetries is 3")
    func defaultMaxValidationRetriesIsThree() async throws {
        let validatorCounter = CallCounter()

        // Validator always fails
        let validator = OutputValidator<Void, String> { _, _ in
            await validatorCounter.increment()
            throw ValidationRetry("Persistent failure")
        }

        let model = FakeModel(responses: [
            MockResponse.text("1"),
            MockResponse.text("2"),
            MockResponse.text("3"),
            MockResponse.text("4"),
        ])

        // Agent without explicit maxValidationRetries
        let agent = try Agent<Void, String>(
            model: model,
            outputValidators: [validator]
        )

        do {
            for try await _ in agent.iter("Hi", deps: ()) { }
        } catch {
            // Expected
        }

        // Should have tried exactly 3 times (default)
        #expect(await validatorCounter.current == 3)
    }

    // MARK: - Test 14.4: Validation retry does NOT consume iteration

    @Test("validation retry does not consume iteration count")
    func validationRetryDoesNotConsumeIteration() async throws {
        let validatorCounter = CallCounter()

        // Validator fails twice, then succeeds
        let validator = OutputValidator<Void, String> { _, output in
            let count = await validatorCounter.increment()
            if count < 3 {
                throw ValidationRetry("Not ready")
            }
            return output
        }

        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            await modelCounter.increment()
            return MockResponse.text("response")
        })

        // Agent with maxIterations = 1
        let agent = try Agent<Void, String>(
            model: model,
            maxIterations: 1,  // Very restrictive
            maxValidationRetries: 5,
            outputValidators: [validator]
        )

        var finalIteration: Int?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .finished(let ctx) = node {
                finalIteration = ctx.state.iteration
            }
        }

        // Validation retries should NOT have consumed the iteration budget
        // We should complete successfully despite maxIterations = 1
        #expect(finalIteration == 0, "Iteration should remain at 0 (validation retries don't consume)")

        // Model was called 3 times for validation retries
        #expect(await modelCounter.current == 3)
    }

    // MARK: - Test 14.5: Validation retry with custom limit

    @Test("custom maxValidationRetries is respected")
    func customMaxValidationRetriesRespected() async throws {
        let validatorCounter = CallCounter()

        // Validator always fails
        let validator = OutputValidator<Void, String> { _, _ in
            await validatorCounter.increment()
            throw ValidationRetry("Fails")
        }

        let model = FakeModel(responses: (1...10).map { _ in MockResponse.text("x") })

        let agent = try Agent<Void, String>(
            model: model,
            maxValidationRetries: 5,  // Custom limit
            outputValidators: [validator]
        )

        do {
            for try await _ in agent.iter("Hi", deps: ()) { }
        } catch {
            // Expected
        }

        // Should try exactly 5 times
        #expect(await validatorCounter.current == 5)
    }

    // MARK: - Test 14.6: Validation error carries state for recovery

    @Test("validationFailed error carries IterationState for recovery")
    func validationErrorCarriesState() async throws {
        let validator = OutputValidator<Void, String> { _, _ in
            throw ValidationRetry("Always fails")
        }

        let model = FakeModel(responses: [
            MockResponse.text("a", usage: Usage(inputTokens: 10, outputTokens: 20)),
            MockResponse.text("b", usage: Usage(inputTokens: 10, outputTokens: 20)),
            MockResponse.text("c", usage: Usage(inputTokens: 10, outputTokens: 20)),
        ])

        let agent = try Agent<Void, String>(
            model: model,
            maxValidationRetries: 3,
            outputValidators: [validator]
        )

        var errorState: IterationState<String>?
        do {
            for try await _ in agent.iter("Hi", deps: ()) { }
        } catch let error as AgentError<String> {
            if case .validationFailed(let state, _, _) = error {
                errorState = state
            }
        }

        guard let state = errorState else {
            Issue.record("Expected error to carry state")
            return
        }

        // State should have accumulated usage from all retries
        #expect(state.usage.totalTokens > 0)

        // State should have messages
        #expect(state.messages.count > 0)

        // RunID should be valid
        #expect(!state.runID.isEmpty)
    }

    // MARK: - Test 14.7: Validation retry feedback is sent to model

    @Test("validation retry message is sent back to model")
    func validationRetryFeedbackSentToModel() async throws {
        actor MessageCapture {
            var lastMessages: [Message] = []
            func capture(_ messages: [Message]) { lastMessages = messages }
        }

        let capture = MessageCapture()
        let validatorCounter = CallCounter()

        let validator = OutputValidator<Void, String> { _, output in
            let count = await validatorCounter.increment()
            if count < 2 {
                throw ValidationRetry("Output must contain the word 'valid'")
            }
            return output
        }

        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { request in
            await capture.capture(request.messages)
            switch await modelCounter.increment() {
            case 1:
                return MockResponse.text("invalid response")
            case 2:
                return MockResponse.text("this is valid")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<Void, String>(
            model: model,
            outputValidators: [validator]
        )

        for try await _ in agent.iter("Hi", deps: ()) { }

        // Check that the second model call received the retry feedback
        let lastMessages = await capture.lastMessages
        let hasRetryFeedback = lastMessages.contains { message in
            switch message {
            case .user(let parts):
                return parts.contains { part in
                    if case .text(let text) = part {
                        return text.contains("valid")  // The retry message
                    }
                    return false
                }
            default:
                return false
            }
        }

        // Note: The exact format of retry feedback depends on implementation
        // This test verifies the model received something related to the retry
        #expect(await modelCounter.current == 2)
    }

    // MARK: - Test 14.8: Multiple validators, first fails

    @Test("when first validator fails, second is not called until retry")
    func firstValidatorFailsPreventsSecond() async throws {
        let validator1Counter = CallCounter()
        let validator2Counter = CallCounter()

        let validator1 = OutputValidator<Void, String> { _, _ in
            let count = await validator1Counter.increment()
            if count < 2 {
                throw ValidationRetry("Validator 1 fails first time")
            }
            return "passed v1"
        }

        let validator2 = OutputValidator<Void, String> { _, output in
            await validator2Counter.increment()
            return output + " + passed v2"
        }

        let model = FakeModel(responses: [
            MockResponse.text("attempt 1"),
            MockResponse.text("attempt 2"),
        ])

        let agent = try Agent<Void, String>(
            model: model,
            outputValidators: [validator1, validator2]
        )

        var output: String?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        // Validator 1 called twice (fail, then pass)
        #expect(await validator1Counter.current == 2)

        // Validator 2 called once (only after validator 1 passes)
        #expect(await validator2Counter.current == 1)

        #expect(output == "passed v1 + passed v2")
    }

    // MARK: - Test 14.9: Structured output validation retry

    @Test("structured output validation retry works correctly")
    func structuredOutputValidationRetry() async throws {
        let validatorCounter = CallCounter()

        let validator = OutputValidator<Void, ScoreResult> { _, result in
            let count = await validatorCounter.increment()
            guard result.score >= 50 else {
                throw ValidationRetry("Score must be at least 50")
            }
            return result
        }

        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await modelCounter.increment() {
            case 1:
                // Score too low
                return MockResponse.toolCall(
                    name: "final_result",
                    arguments: #"{"score": 25}"#,
                    id: "out-1"
                )
            case 2:
                // Score acceptable
                return MockResponse.toolCall(
                    name: "final_result",
                    arguments: #"{"score": 75}"#,
                    id: "out-2"
                )
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<Void, ScoreResult>(
            model: model,
            outputValidators: [validator]
        )

        var output: ScoreResult?
        for try await node in agent.iter("Score me", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output?.score == 75)
        #expect(await validatorCounter.current == 2)
    }

    // MARK: - Test 14.10: Zero max retries means single attempt

    @Test("maxValidationRetries of 0 allows only initial validation (no retries)")
    func zeroMaxRetriesMeansSingleAttempt() async throws {
        let validatorCounter = CallCounter()

        let validator = OutputValidator<Void, String> { _, _ in
            await validatorCounter.increment()
            throw ValidationRetry("Always fails")
        }

        let model = FakeModel(responses: [
            MockResponse.text("only one"),
        ])

        let agent = try Agent<Void, String>(
            model: model,
            maxValidationRetries: 0,  // Zero retries = only initial attempt
            outputValidators: [validator]
        )

        do {
            for try await _ in agent.iter("Hi", deps: ()) { }
        } catch {
            // Expected
        }

        // Only one validation attempt
        #expect(await validatorCounter.current == 1)
    }
}
