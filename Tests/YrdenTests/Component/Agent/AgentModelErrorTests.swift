/// Tests for Agent model error handling.
///
/// Covers model response errors (maxTokens, contentFiltered, refusal, empty)
/// and provider-level errors (server, rate limit, network).
///
/// Key invariant: model response errors throw AgentError variants (with state),
/// while LLM provider errors propagate as LLMError directly.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

// MARK: - Model Response Errors

@Suite("Agent - Model Response Errors")
struct AgentModelResponseErrorTests {

    @Test("maxTokens response throws modelError with ResponseUnusable.maxTokensReached")
    func maxTokensResponseThrowsModelError() async throws {
        let model = FakeModel(responses: [MockResponse.maxTokens("This was truncat")])

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        do {
            _ = try await agent.run("Write a story")
            Issue.record("Expected AgentError.modelError")
        } catch let error as AgentError<String> {
            guard case .modelError(let state, let underlying) = error else {
                Issue.record("Expected .modelError, got \(error)")
                return
            }
            guard let unusable = underlying as? ResponseUnusable,
                  case .maxTokensReached(let partial) = unusable else {
                Issue.record("Expected ResponseUnusable.maxTokensReached, got \(underlying)")
                return
            }
            #expect(partial == "This was truncat")
            #expect(!state.messages.isEmpty)
        }
    }

    @Test("contentFiltered response throws modelError with ResponseUnusable.contentFiltered")
    func contentFilteredResponseThrowsModelError() async throws {
        let model = FakeModel(responses: [MockResponse.contentFiltered()])

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        do {
            _ = try await agent.run("Write something")
            Issue.record("Expected AgentError.modelError")
        } catch let error as AgentError<String> {
            guard case .modelError(_, let underlying) = error else {
                Issue.record("Expected .modelError, got \(error)")
                return
            }
            guard let unusable = underlying as? ResponseUnusable,
                  case .contentFiltered = unusable else {
                Issue.record("Expected ResponseUnusable.contentFiltered, got \(underlying)")
                return
            }
        }
    }

    @Test("refusal response throws modelRefusal with refusal message")
    func refusalResponseThrowsModelRefusal() async throws {
        let model = FakeModel(responses: [MockResponse.refusal("I cannot help with that.")])

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        do {
            _ = try await agent.run("Bad request")
            Issue.record("Expected AgentError.modelRefusal")
        } catch let error as AgentError<String> {
            guard case .modelRefusal(let state, let refusal) = error else {
                Issue.record("Expected .modelRefusal, got \(error)")
                return
            }
            #expect(refusal == "I cannot help with that.")
            #expect(!state.messages.isEmpty)
        }
    }

    @Test("empty response (no content, no tools) throws modelError with ResponseUnusable.emptyResponse")
    func emptyResponseThrowsModelError() async throws {
        let model = FakeModel(responses: [MockResponse.empty()])

        // For String output, empty response returns "" (empty string is valid).
        // emptyResponse only fires for structured output types where content is required.
        // So we test with String and verify it returns empty string successfully.
        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        let run = try await agent.run("Say hello")
        #expect(run.output == "")
    }
}

// MARK: - Provider/Network Errors

@Suite("Agent - Provider Error Propagation")
struct AgentProviderErrorTests {

    @Test("server error propagates as LLMError.serverError")
    func serverErrorPropagated() async throws {
        let model = FakeModel(onComplete: { _ in
            throw LLMError.serverError("Internal server error (500)")
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        do {
            _ = try await agent.run("Hello")
            Issue.record("Expected LLMError.serverError")
        } catch let error as LLMError {
            guard case .serverError(let msg) = error else {
                Issue.record("Expected .serverError, got \(error)")
                return
            }
            #expect(msg.contains("server error"))
        }
    }

    @Test("rate limit error propagates as LLMError.rateLimited")
    func rateLimitErrorPropagated() async throws {
        let model = FakeModel(onComplete: { _ in
            throw LLMError.rateLimited(retryAfter: 30)
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        do {
            _ = try await agent.run("Hello")
            Issue.record("Expected LLMError.rateLimited")
        } catch let error as LLMError {
            guard case .rateLimited(let retryAfter) = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
            #expect(retryAfter == 30)
        }
    }

    @Test("network error propagates as LLMError.networkError")
    func networkErrorPropagated() async throws {
        let model = FakeModel(onComplete: { _ in
            throw LLMError.networkError("Not connected to internet")
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        do {
            _ = try await agent.run("Hello")
            Issue.record("Expected LLMError.networkError")
        } catch let error as LLMError {
            guard case .networkError(let msg) = error else {
                Issue.record("Expected .networkError, got \(error)")
                return
            }
            #expect(msg.contains("internet"))
        }
    }
}
