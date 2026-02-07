/// Tests for Agent output validators through the run() API.
///
/// Iterator-level validation retry is thoroughly tested in
/// IteratorValidationRetryTests.swift (10 tests). These tests verify
/// validators work correctly through the high-level run() API path,
/// with assertions on what the model actually receives.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Agent - Output Validators")
struct AgentOutputValidatorTests {

    @Test("output validator transforms output before returning")
    func outputValidatorTransformsOutput() async throws {
        let model = FakeModel(responses: [MockResponse.text("hello world")])

        let uppercaseValidator = OutputValidator<String> { _, output in
            output.uppercased()
        }

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            outputValidators: [uppercaseValidator]
        )

        let run = try await agent.run("Say hello")
        #expect(run.output == "HELLO WORLD")
        #expect(await model.completeCallCount == 1)
    }

    @Test("output validator retry sends feedback message to model")
    func outputValidatorRetrySendsFeedbackToModel() async throws {
        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.text("hi")
            case 2:
                // Verify the retry feedback was appended as a user message
                let lastMessage = request.messages.last
                guard case .user(let parts) = lastMessage else {
                    Issue.record("Expected user message with retry feedback, got \(String(describing: lastMessage))")
                    return MockResponse.text("fallback")
                }
                let text = parts.compactMap { part -> String? in
                    if case .text(let t) = part { return t }
                    return nil
                }.joined()
                #expect(text.contains("longer than 10"))
                return MockResponse.text("hello, this is a longer response")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let validator = OutputValidator<String> { _, output in
            guard output.count > 10 else {
                throw ValidationRetry("Response must be longer than 10 characters.")
            }
            return output
        }

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            outputValidators: [validator]
        )

        let run = try await agent.run("Say hello")
        #expect(run.output == "hello, this is a longer response")
        #expect(await model.completeCallCount == 2)
    }
}
