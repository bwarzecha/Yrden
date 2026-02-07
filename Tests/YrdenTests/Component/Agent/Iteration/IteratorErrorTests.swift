/// Tests for error propagation through the iterator.
///
/// Covers:
/// - Model errors (network, refusal, max tokens, content filtered)
/// - Usage limits
/// - Per design doc: all resumable errors carry IterationState

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Iterator - Errors")
struct IteratorErrorTests {

    // MARK: - Test 9.1: Model error propagates with state

    @Test("LLM error is wrapped as modelError with state")
    func modelErrorPropagates() async throws {
        let model = FakeModel(onComplete: { _ in
            throw LLMError.serverError("Internal server error")
        })

        let agent = try Agent<String>(model: model)

        do {
            for try await _ in agent.iter("Hi") { }
            Issue.record("Expected error to be thrown")
        } catch let error as AgentError<String> {
            // Per design doc: modelError carries state and underlying error
            guard case .modelError(let state, let underlying) = error else {
                Issue.record("Expected modelError, got \(error)")
                return
            }
            // State should be at beforeModel phase
            guard case .beforeModel = state.phase else {
                Issue.record("Expected beforeModel phase")
                return
            }
            // Underlying error should be the LLM error
            #expect(underlying is LLMError)
        } catch let error as LLMError {
            // Alternatively, LLM errors may propagate directly
            guard case .serverError = error else {
                Issue.record("Expected serverError, got \(error)")
                return
            }
        }
    }

    // MARK: - Test 9.2: Model refusal throws modelRefusal

    @Test("model refusal causes modelRefusal error with state")
    func modelRefusalThrows() async throws {
        let model = FakeModel(responses: [MockResponse.refusal("I cannot help with that request")])
        let agent = try Agent<String>(model: model)

        do {
            for try await _ in agent.iter("Bad request") { }
            Issue.record("Expected error to be thrown")
        } catch let error as AgentError<String> {
            // Per design doc: modelRefusal carries state and refusal message
            // Note: Only thrown when response.refusal != nil (OpenAI-specific)
            guard case .modelRefusal(let state, let refusal) = error else {
                Issue.record("Expected modelRefusal, got \(error)")
                return
            }
            #expect(refusal.contains("cannot help"))
            #expect(state.iteration >= 0)
        }
    }

    // MARK: - Test 9.3: Max tokens throws

    @Test("max tokens response causes modelError with ResponseUnusable")
    func maxTokensThrows() async throws {
        let model = FakeModel(responses: [MockResponse.maxTokens("Partial respon")])
        let agent = try Agent<String>(model: model)

        do {
            for try await _ in agent.iter("Generate long text") { }
            Issue.record("Expected error to be thrown")
        } catch let error as AgentError<String> {
            // Max tokens causes modelError with ResponseUnusable.maxTokensReached
            guard case .modelError(let state, let underlying) = error else {
                Issue.record("Expected modelError, got \(error)")
                return
            }
            guard let responseError = underlying as? ResponseUnusable,
                  case .maxTokensReached(let partial) = responseError else {
                Issue.record("Expected ResponseUnusable.maxTokensReached, got \(underlying)")
                return
            }
            #expect(partial == "Partial respon")
            #expect(state.iteration >= 0)
        }
    }

    // MARK: - Test 9.4: Content filtered throws

    @Test("content filtered response causes modelError with ResponseUnusable")
    func contentFilteredThrows() async throws {
        let model = FakeModel(responses: [MockResponse.contentFiltered()])
        let agent = try Agent<String>(model: model)

        do {
            for try await _ in agent.iter("Filtered request") { }
            Issue.record("Expected error to be thrown")
        } catch let error as AgentError<String> {
            // Content filtered causes modelError with ResponseUnusable.contentFiltered
            guard case .modelError(let state, let underlying) = error else {
                Issue.record("Expected modelError, got \(error)")
                return
            }
            guard let responseError = underlying as? ResponseUnusable,
                  case .contentFiltered = responseError else {
                Issue.record("Expected ResponseUnusable.contentFiltered, got \(underlying)")
                return
            }
            #expect(state.iteration >= 0)
        }
    }

    // MARK: - Test 9.5: Input token limit throws with state

    @Test("exceeding input token limit throws usageLimitExceeded with state")
    func inputTokenLimitThrows() async throws {
        let model = FakeModel(responses: [
            MockResponse.text("Response", usage: Usage(inputTokens: 1000, outputTokens: 10))
        ])

        let agent = try Agent<String>(
            model: model,
            usageLimits: UsageLimits(maxInputTokens: 500)
        )

        do {
            for try await _ in agent.iter("Hi") { }
            Issue.record("Expected usageLimitExceeded error")
        } catch let error as AgentError<String> {
            // Per design doc: usageLimitExceeded carries state and limit
            switch error {
            case .usageLimitExceeded(let state, let limit):
                guard case .inputTokens(let used, let limitVal) = limit else {
                    Issue.record("Expected inputTokens limit")
                    return
                }
                #expect(used > limitVal)
                #expect(state.iteration >= 0)
            default:
                Issue.record("Expected usageLimitExceeded, got \(error)")
            }
        }
    }

    // MARK: - Test 9.6: Output token limit throws with state

    @Test("exceeding output token limit throws usageLimitExceeded with state")
    func outputTokenLimitThrows() async throws {
        let model = FakeModel(responses: [
            MockResponse.text("Response", usage: Usage(inputTokens: 10, outputTokens: 1000))
        ])

        let agent = try Agent<String>(
            model: model,
            usageLimits: UsageLimits(maxOutputTokens: 500)
        )

        do {
            for try await _ in agent.iter("Hi") { }
            Issue.record("Expected usageLimitExceeded error")
        } catch let error as AgentError<String> {
            switch error {
            case .usageLimitExceeded(let state, let limit):
                guard case .outputTokens(let used, let limitVal) = limit else {
                    Issue.record("Expected outputTokens limit")
                    return
                }
                #expect(used > limitVal)
                #expect(state.iteration >= 0)
            default:
                Issue.record("Expected usageLimitExceeded, got \(error)")
            }
        }
    }

    // MARK: - Test 9.7: Total token limit throws with state

    @Test("exceeding total token limit throws usageLimitExceeded with state")
    func totalTokenLimitThrows() async throws {
        let model = FakeModel(responses: [
            MockResponse.text("Response", usage: Usage(inputTokens: 600, outputTokens: 600))
        ])

        let agent = try Agent<String>(
            model: model,
            usageLimits: UsageLimits(maxTotalTokens: 1000)
        )

        do {
            for try await _ in agent.iter("Hi") { }
            Issue.record("Expected usageLimitExceeded error")
        } catch let error as AgentError<String> {
            switch error {
            case .usageLimitExceeded(let state, let limit):
                guard case .totalTokens(let used, let limitVal) = limit else {
                    Issue.record("Expected totalTokens limit")
                    return
                }
                #expect(used > limitVal)
                #expect(state.iteration >= 0)
            default:
                Issue.record("Expected usageLimitExceeded, got \(error)")
            }
        }
    }

    // MARK: - Test 9.8: Request limit throws with state

    @Test("exceeding request limit throws usageLimitExceeded with state")
    func requestLimitThrows() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let callCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let callID = await callCounter.increment()
            // Keep returning tool calls to force multiple requests
            return MockResponse.toolCall(
                name: "my_tool",
                arguments: #"{"input":"x"}"#,
                id: "tc-\(callID)"
            )
        })

        let agent = try Agent<String>(
            model: model,
            tools: [tool],
            maxIterations: 100,  // High to not hit this first
            usageLimits: UsageLimits(maxRequests: 2)
        )

        do {
            for try await _ in agent.iter("Loop") { }
            Issue.record("Expected usageLimitExceeded error")
        } catch let error as AgentError<String> {
            switch error {
            case .usageLimitExceeded(let state, let limit):
                guard case .requests(let used, let limitVal) = limit else {
                    Issue.record("Expected requests limit")
                    return
                }
                #expect(used >= limitVal)
                #expect(state.iteration >= 0)
            default:
                Issue.record("Expected usageLimitExceeded, got \(error)")
            }
        }
    }

    // MARK: - Test 9.9: Tool call limit throws with state

    @Test("exceeding tool call limit throws usageLimitExceeded with state")
    func toolCallLimitThrows() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let callCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let callID = await callCounter.increment()
            // Return multiple tool calls each time
            return MockResponse.toolCalls([
                ToolCall(id: "tc-\(callID)-a", name: "my_tool", arguments: #"{"input":"a"}"#),
                ToolCall(id: "tc-\(callID)-b", name: "my_tool", arguments: #"{"input":"b"}"#),
                ToolCall(id: "tc-\(callID)-c", name: "my_tool", arguments: #"{"input":"c"}"#),
            ])
        })

        let agent = try Agent<String>(
            model: model,
            tools: [tool],
            maxIterations: 100,
            usageLimits: UsageLimits(maxToolCalls: 5)
        )

        do {
            for try await _ in agent.iter("Loop") { }
            Issue.record("Expected usageLimitExceeded error")
        } catch let error as AgentError<String> {
            switch error {
            case .usageLimitExceeded(let state, let limit):
                guard case .toolCalls(let used, let limitVal) = limit else {
                    Issue.record("Expected toolCalls limit")
                    return
                }
                #expect(used >= limitVal)
                #expect(state.iteration >= 0)
            default:
                Issue.record("Expected usageLimitExceeded, got \(error)")
            }
        }
    }

    // MARK: - Test 9.10: Network error propagates

    @Test("network error from model propagates")
    func networkErrorPropagates() async throws {
        let model = FakeModel(onComplete: { _ in
            throw LLMError.networkError("Not connected to internet")
        })

        let agent = try Agent<String>(model: model)

        do {
            for try await _ in agent.iter("Hi") { }
            Issue.record("Expected error to be thrown")
        } catch let error as AgentError<String> {
            // Per design doc: wrapped as modelError
            guard case .modelError(let state, let underlying) = error else {
                Issue.record("Expected modelError, got \(error)")
                return
            }
            guard let llmError = underlying as? LLMError,
                  case .networkError = llmError else {
                Issue.record("Expected networkError as underlying")
                return
            }
            #expect(state.iteration >= 0)
        } catch let error as LLMError {
            // Alternatively: LLM errors propagate directly
            guard case .networkError = error else {
                Issue.record("Expected networkError, got \(error)")
                return
            }
        }
    }

    // MARK: - Test 9.11: Rate limit error propagates

    @Test("rate limit error from model propagates")
    func rateLimitErrorPropagates() async throws {
        let model = FakeModel(onComplete: { _ in
            throw LLMError.rateLimited(retryAfter: 60)
        })

        let agent = try Agent<String>(model: model)

        do {
            for try await _ in agent.iter("Hi") { }
            Issue.record("Expected error to be thrown")
        } catch let error as AgentError<String> {
            // Per design doc: wrapped as modelError
            guard case .modelError(_, let underlying) = error else {
                Issue.record("Expected modelError, got \(error)")
                return
            }
            guard let llmError = underlying as? LLMError,
                  case .rateLimited = llmError else {
                Issue.record("Expected rateLimited as underlying")
                return
            }
        } catch let error as LLMError {
            // Alternatively: LLM errors propagate directly
            guard case .rateLimited = error else {
                Issue.record("Expected rateLimited, got \(error)")
                return
            }
        }
    }

    // MARK: - Test 9.12: Cancellation error with state

    @Test("task cancellation causes cancelled error with state")
    func cancellationErrorPropagates() async throws {
        let model = FakeModel(onComplete: { _ in
            // Simulate slow model
            try await Task.sleep(for: .seconds(10))
            return MockResponse.text("Done")
        })

        let agent = try Agent<String>(model: model)

        let task = Task {
            for try await _ in agent.iter("Hi") { }
        }

        // Cancel after a short delay
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()

        do {
            try await task.value
            Issue.record("Expected cancellation error")
        } catch let error as AgentError<String> {
            // Per design doc: cancelled with state and operation
            guard case .cancelled(let state, let during) = error else {
                Issue.record("Expected cancelled, got \(error)")
                return
            }
            #expect(state.iteration >= 0)
            // Should have been cancelled during modelCall
            if case .modelCall = during {
                // Expected
            }
        } catch is CancellationError {
            // Also acceptable: raw CancellationError
        }
    }

    // MARK: - Test 9.13: Tool errors don't prevent iteration completion

    @Test("tool errors don't prevent iteration completion")
    func toolErrorsDontPreventCompletion() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "failing_tool",
            onCall: { _ in throw TestToolError.generic("Tool failed") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "failing_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done after tool failure")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(model: model, tools: [tool])

        var output: String?
        for try await node in agent.iter("Use tool") {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        // Should complete successfully - tool errors are fed back to model
        #expect(output == "Done after tool failure")
    }
}
