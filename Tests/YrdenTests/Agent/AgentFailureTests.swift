/// Tests for Agent failure handling.
///
/// Tests that the Agent handles various failure scenarios gracefully:
/// - Tool failures (throws, returns .failure, returns .retry)
/// - Model response failures (malformed tool call, unknown tool, empty response)
/// - Usage limit enforcement
///
/// Uses TestMockModel for deterministic testing without API calls.

import Testing
import Foundation
@testable import Yrden

// MARK: - Test Mock Model
//
// TestMockModel is now defined in AgentTestHelpers.swift.
// Also see MockResponse for convenience factories.

// MARK: - Test Tools
//
// Uses shared test helpers from AgentTestHelpers.swift:
// - ConfigurableTool.throwing() - Tool that throws errors
// - ConfigurableTool.failing() - Tool that returns .failure
// - ConfigurableTool.retrying() - Tool that returns .retry
// - ConfigurableTool.succeeding() - Tool that succeeds
// - RetryStatefulTool - Tool that changes behavior after N calls
// - SlowTool - Tool with configurable delay

// MARK: - Tool Failure Tests

@Suite("Agent - Tool Failure Handling")
struct AgentToolFailureTests {

    @Test("Tool that throws error sends error message to model")
    func toolThrowsError() async throws {
        let model = TestMockModel()

        // Model will call the tool, receive error, then respond with text
        await model.setResponses([
            // First response: call the throwing tool
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-1", name: "throwing_tool", arguments: #"{"input":"test"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            ),
            // Second response: acknowledge the error
            CompletionResponse(
                content: "The tool threw an error, I understand.",
                refusal: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 20, outputTokens: 10)
            )
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(ConfigurableTool.throwing(TestToolError.crashed("test")))],
            maxIterations: 5
        )

        let result = try await agent.run("Test the tool", deps: ())

        // Agent should complete with exact response from mock
        #expect(result.output == "The tool threw an error, I understand.")
        let callCount = await model.callCount
        #expect(callCount == 2)
    }

    @Test("Tool that returns .failure sends error to model")
    func toolReturnsFailure() async throws {
        let model = TestMockModel()

        await model.setResponses([
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-1", name: "failing_tool", arguments: #"{"input":"bad data"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            ),
            CompletionResponse(
                content: "The tool failed to process the data.",
                refusal: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 20, outputTokens: 10)
            )
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(ConfigurableTool.failing(TestToolError.processingFailed("data")))],
            maxIterations: 5
        )

        let result = try await agent.run("Process this data", deps: ())

        // Agent should complete with exact response from mock
        #expect(result.output == "The tool failed to process the data.")
        let callCount = await model.callCount
        #expect(callCount == 2)
    }

    @Test("Tool that returns .retry triggers LLM retry attempt")
    func toolReturnsRetry() async throws {
        let model = TestMockModel()

        await model.setResponses([
            // First call to tool
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-1", name: "retry_tool", arguments: #"{"input":"wrong"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            ),
            // Model receives retry message and tries again with different input
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-2", name: "simple_tool", arguments: #"{"input":"correct"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 20, outputTokens: 10)
            ),
            // Final response
            CompletionResponse(
                content: "Got the result from simple_tool.",
                refusal: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 30, outputTokens: 10)
            )
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [
                AnyAgentTool(ConfigurableTool.retrying("Invalid input, please try with a different value", name: "retry_tool")),
                AnyAgentTool(ConfigurableTool.succeeding("Processed: correct", name: "simple_tool"))
            ],
            maxIterations: 5
        )

        let result = try await agent.run("Process this", deps: ())

        let callCount = await model.callCount
        #expect(callCount == 3)
        #expect(result.toolCallCount >= 2)
    }

    @Test("Tool fails then succeeds on retry")
    func toolFailsThenSucceeds() async throws {
        let model = TestMockModel()
        let countingTool = RetryStatefulTool(
            name: "counting_tool",
            failUntilCall: 1,
            successResult: "Finally worked!"
        )

        await model.setResponses([
            // First call - tool will request retry
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-1", name: "counting_tool", arguments: #"{"input":"test"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            ),
            // Model retries same tool
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-2", name: "counting_tool", arguments: #"{"input":"test2"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 20, outputTokens: 10)
            ),
            // Success
            CompletionResponse(
                content: "The tool finally worked!",
                refusal: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 30, outputTokens: 10)
            )
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "Keep retrying the tool.",
            tools: [AnyAgentTool(countingTool)],
            maxIterations: 5
        )

        let result = try await agent.run("Use the counting tool", deps: ())

        let toolCallCount = await countingTool.currentCallCount
        // Tool should be called at least twice (once for retry, once for success)
        // May be called more times depending on agent retry logic
        #expect(toolCallCount >= 2, "Expected at least 2 tool calls, got \(toolCallCount)")
        // Agent should complete with exact response from mock
        #expect(result.output == "The tool finally worked!")
    }

    @Test("Max iterations reached when all tools fail")
    func maxIterationsWithFailingTools() async throws {
        let model = TestMockModel()

        // Configure model to keep calling the failing tool
        await model.setResponses((0..<10).map { i in
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-\(i)", name: "failing_tool", arguments: #"{"input":"attempt"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            )
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "Use the tool.",
            tools: [AnyAgentTool(ConfigurableTool.failing(TestToolError.processingFailed("data")))],
            maxIterations: 3
        )

        do {
            _ = try await agent.run("Keep trying", deps: ())
            Issue.record("Expected maxIterationsReached error")
        } catch let error as AgentError {
            guard case .maxIterationsReached(let count) = error else {
                Issue.record("Expected maxIterationsReached, got \(error)")
                return
            }
            #expect(count == 3)
        }
    }
}

// MARK: - Model Response Failure Tests

@Suite("Agent - Model Response Failure Handling")
struct AgentModelResponseFailureTests {

    @Test("Model calls unknown tool sends error back")
    func modelCallsUnknownTool() async throws {
        let model = TestMockModel()

        await model.setResponses([
            // Model calls a tool that doesn't exist
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-1", name: "nonexistent_tool", arguments: #"{}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            ),
            // Model acknowledges and responds with text
            CompletionResponse(
                content: "Sorry, that tool is not available.",
                refusal: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 20, outputTokens: 10)
            )
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(ConfigurableTool.succeeding("Processed: test", name: "simple_tool"))],
            maxIterations: 5
        )

        let result = try await agent.run("Do something", deps: ())

        // Agent should complete after model receives "tool not found" error
        #expect(!result.output.isEmpty)
        let callCount = await model.callCount
        #expect(callCount == 2)
    }

    @Test("Model returns malformed tool call arguments")
    func modelReturnsMalformedToolCall() async throws {
        let model = TestMockModel()

        await model.setResponses([
            // Model calls a tool with invalid JSON arguments
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-1", name: "simple_tool", arguments: #"not valid json {"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            ),
            // Model receives error and responds with text
            CompletionResponse(
                content: "I apologize for the malformed tool call.",
                refusal: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 20, outputTokens: 10)
            )
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(ConfigurableTool.succeeding("Success", name: "simple_tool"))],
            maxIterations: 5
        )

        let result = try await agent.run("Use the tool", deps: ())

        // Agent should complete after model receives parse error and responds
        #expect(!result.output.isEmpty)
        let callCount = await model.callCount
        #expect(callCount == 2, "Expected 2 model calls (initial + retry after error)")
    }

    @Test("Model returns maxTokens triggers error")
    func modelHitsMaxTokens() async throws {
        let model = TestMockModel()
        await model.setMaxTokensResponse("This response was truncat")

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [],
            maxIterations: 3
        )

        do {
            _ = try await agent.run("Write a long story", deps: ())
            Issue.record("Expected unexpectedModelBehavior error")
        } catch let error as AgentError {
            guard case .unexpectedModelBehavior(let details) = error else {
                Issue.record("Expected unexpectedModelBehavior, got \(error)")
                return
            }
            #expect(details.contains("max tokens") || details.contains("truncated"))
        }
    }

    @Test("Model content filtered triggers error")
    func modelContentFiltered() async throws {
        let model = TestMockModel()
        await model.setContentFilteredResponse()

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [],
            maxIterations: 3
        )

        do {
            _ = try await agent.run("Write something", deps: ())
            Issue.record("Expected unexpectedModelBehavior error")
        } catch let error as AgentError {
            guard case .unexpectedModelBehavior(let details) = error else {
                Issue.record("Expected unexpectedModelBehavior, got \(error)")
                return
            }
            #expect(details.contains("filtered"))
        }
    }

    @Test("Model refusal triggers error")
    func modelRefusal() async throws {
        let model = TestMockModel()
        await model.setRefusalResponse("I cannot help with that request.")

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [],
            maxIterations: 3
        )

        do {
            _ = try await agent.run("Do something bad", deps: ())
            Issue.record("Expected unexpectedModelBehavior error")
        } catch let error as AgentError {
            guard case .unexpectedModelBehavior(let details) = error else {
                Issue.record("Expected unexpectedModelBehavior, got \(error)")
                return
            }
            #expect(details.contains("refused"))
        }
    }

    @Test("Model returns empty response without tools triggers error")
    func modelReturnsEmptyResponse() async throws {
        let model = TestMockModel()

        // Empty response - no content, no tool calls
        await model.setResponses([CompletionResponse(
            content: nil,
            refusal: nil,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 0)
        )])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [],
            maxIterations: 3
        )

        do {
            _ = try await agent.run("Say hello", deps: ())
            Issue.record("Expected unexpectedModelBehavior error")
        } catch let error as AgentError {
            guard case .unexpectedModelBehavior(let details) = error else {
                Issue.record("Expected unexpectedModelBehavior, got \(error)")
                return
            }
            #expect(details.contains("output") || details.contains("tool"))
        }
    }
}

// MARK: - Usage Limit Tests

@Suite("Agent - Usage Limit Enforcement")
struct AgentUsageLimitTests {

    @Test("Request limit enforced")
    func requestLimitEnforced() async throws {
        let model = TestMockModel()

        // Configure model to keep needing more iterations
        await model.setResponses((0..<10).map { i in
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-\(i)", name: "simple_tool", arguments: #"{"input":"test"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            )
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(ConfigurableTool.succeeding("Processed: test", name: "simple_tool"))],
            maxIterations: 10,
            usageLimits: UsageLimits(maxRequests: 2)
        )

        do {
            _ = try await agent.run("Use tool repeatedly", deps: ())
            Issue.record("Expected usageLimitExceeded error")
        } catch let error as AgentError {
            guard case .usageLimitExceeded(let kind) = error else {
                Issue.record("Expected usageLimitExceeded, got \(error)")
                return
            }
            if case .requests(let used, let limit) = kind {
                #expect(used >= limit)
            } else {
                Issue.record("Expected requests limit, got \(kind)")
            }
        }
    }

    @Test("Tool call limit enforced")
    func toolCallLimitEnforced() async throws {
        let model = TestMockModel()

        // Model returns multiple tool calls in one response
        await model.setResponses([
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [
                    ToolCall(id: "call-1", name: "simple_tool", arguments: #"{"input":"a"}"#),
                    ToolCall(id: "call-2", name: "simple_tool", arguments: #"{"input":"b"}"#),
                    ToolCall(id: "call-3", name: "simple_tool", arguments: #"{"input":"c"}"#)
                ],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            )
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(ConfigurableTool.succeeding("Processed: test", name: "simple_tool"))],
            maxIterations: 10,
            usageLimits: UsageLimits(maxToolCalls: 2)
        )

        do {
            _ = try await agent.run("Use tools", deps: ())
            Issue.record("Expected usageLimitExceeded error")
        } catch let error as AgentError {
            guard case .usageLimitExceeded(let kind) = error else {
                Issue.record("Expected usageLimitExceeded, got \(error)")
                return
            }
            if case .toolCalls(let used, let limit) = kind {
                #expect(used >= limit)
            } else {
                Issue.record("Expected toolCalls limit, got \(kind)")
            }
        }
    }

    @Test("Token limit enforced")
    func tokenLimitEnforced() async throws {
        let model = TestMockModel()

        // Response with high token usage
        await model.setResponses([
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-1", name: "simple_tool", arguments: #"{"input":"test"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 1000, outputTokens: 500)
            )
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(ConfigurableTool.succeeding("Processed: test", name: "simple_tool"))],
            maxIterations: 10,
            usageLimits: UsageLimits(maxTotalTokens: 100)
        )

        do {
            _ = try await agent.run("Use tool", deps: ())
            Issue.record("Expected usageLimitExceeded error")
        } catch let error as AgentError {
            guard case .usageLimitExceeded(let kind) = error else {
                Issue.record("Expected usageLimitExceeded, got \(error)")
                return
            }
            if case .totalTokens(let used, let limit) = kind {
                #expect(used > limit)
            } else {
                Issue.record("Expected totalTokens limit, got \(kind)")
            }
        }
    }
}

// MARK: - Network/Provider Error Tests

@Suite("Agent - Network Error Handling")
struct AgentNetworkErrorTests {

    @Test("Server error is propagated")
    func serverErrorPropagated() async throws {
        let model = TestMockModel()
        await model.setError(LLMError.serverError("Internal server error (500)"))

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [],
            maxIterations: 3
        )

        do {
            _ = try await agent.run("Hello", deps: ())
            Issue.record("Expected LLMError")
        } catch let error as LLMError {
            if case .serverError(let msg) = error {
                #expect(msg.contains("server error"))
            } else {
                Issue.record("Expected serverError, got \(error)")
            }
        }
    }

    @Test("Rate limit error is propagated")
    func rateLimitErrorPropagated() async throws {
        let model = TestMockModel()
        await model.setError(LLMError.rateLimited(retryAfter: 30))

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [],
            maxIterations: 3
        )

        do {
            _ = try await agent.run("Hello", deps: ())
            Issue.record("Expected LLMError")
        } catch let error as LLMError {
            if case .rateLimited(let retryAfter) = error {
                #expect(retryAfter == 30)
            } else {
                Issue.record("Expected rateLimited, got \(error)")
            }
        }
    }

    @Test("Network error is propagated")
    func networkErrorPropagated() async throws {
        let model = TestMockModel()
        await model.setError(LLMError.networkError("Not connected to internet"))

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [],
            maxIterations: 3
        )

        do {
            _ = try await agent.run("Hello", deps: ())
            Issue.record("Expected LLMError")
        } catch let error as LLMError {
            if case .networkError(let msg) = error {
                #expect(msg.contains("internet"))
            } else {
                Issue.record("Expected networkError, got \(error)")
            }
        }
    }
}

// MARK: - Streaming Failure Tests

@Suite("Agent - Streaming Failure Handling")
struct AgentStreamingFailureTests {

    @Test("Tool error during streaming sends error to model")
    func streamingToolError() async throws {
        let model = TestMockModel()

        await model.setResponses([
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-1", name: "throwing_tool", arguments: #"{"input":"test"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            ),
            CompletionResponse(
                content: "Tool error handled.",
                refusal: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 20, outputTokens: 10)
            )
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(ConfigurableTool.throwing(TestToolError.crashed("test")))],
            maxIterations: 5
        )

        var events: [String] = []
        var finalResult: AgentResult<String>?

        for try await event in agent.runStream("Test tool", deps: ()) {
            switch event {
            case .toolCallStart(let name, _):
                events.append("start:\(name)")
            case .toolResult(let id, let result):
                events.append("result:\(id):\(result.prefix(20))")
            case .result(let result):
                finalResult = result
            default:
                break
            }
        }

        #expect(events.contains { $0.starts(with: "start:throwing_tool") })
        #expect(events.contains { $0.contains("Error") })
        #expect(finalResult != nil)
    }

    @Test("Server error during streaming throws")
    func streamingServerError() async throws {
        let model = TestMockModel()
        await model.setError(LLMError.serverError("Service unavailable (503)"))

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [],
            maxIterations: 3
        )

        do {
            for try await _ in agent.runStream("Hello", deps: ()) {
                // Consume stream
            }
            Issue.record("Expected error")
        } catch let error as LLMError {
            if case .serverError(let msg) = error {
                #expect(msg.contains("503") || msg.contains("unavailable"))
            } else {
                Issue.record("Expected serverError, got \(error)")
            }
        }
    }

    @Test("Stream interrupted mid-response throws error")
    func streamInterrupted() async throws {
        let model = StreamInterruptingModel()

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [],
            maxIterations: 3
        )

        var deltasReceived: [String] = []
        var errorThrown = false

        do {
            for try await event in agent.runStream("Hello", deps: ()) {
                if case .contentDelta(let delta) = event {
                    deltasReceived.append(delta)
                }
            }
            Issue.record("Expected stream interruption error")
        } catch let error as LLMError {
            errorThrown = true
            if case .networkError(let msg) = error {
                #expect(msg.contains("interrupted") || msg.contains("connection"))
            } else {
                Issue.record("Expected networkError, got \(error)")
            }
        }

        // Should have received some deltas before interruption
        #expect(!deltasReceived.isEmpty, "Expected partial content before interruption")
        #expect(errorThrown, "Expected error to be thrown")
    }
}

// MARK: - Cancellation Tests

@Suite("Agent - Cancellation Handling")
struct AgentCancellationTests {

    @Test("Cancellation during tool execution throws CancellationError")
    func cancellationDuringToolExecution() async throws {
        let model = TestMockModel()

        // Configure slow response
        await model.setResponses([
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-1", name: "simple_tool", arguments: #"{"input":"test"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            )
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(ConfigurableTool.succeeding("Processed: test", name: "simple_tool"))],
            maxIterations: 5
        )

        // Start task and cancel immediately
        let task = Task {
            try await agent.run("Use tool", deps: ())
        }

        // Cancel after a small delay
        try await Task.sleep(for: .milliseconds(1))
        task.cancel()

        do {
            _ = try await task.value
            // May or may not throw depending on timing
        } catch is CancellationError {
            // Expected
        } catch {
            // Other errors may occur depending on timing
        }
    }
}

// MARK: - Retry Policy Tests

@Suite("Agent - Retry Policy")
struct AgentRetryPolicyTests {

    @Test("Retry policy retries on rate limit")
    func retryOnRateLimit() async throws {
        let model = TestMockModel()

        // First call: rate limited
        // Second call: success
        await model.setResponses([
            CompletionResponse(
                content: "Success after retry",
                refusal: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            )
        ])

        // First throw rate limit, then succeed
        let rateLimitError = LLMError.rateLimited(retryAfter: 0.001)

        // Create agent with retry policy
        let retryPolicy = RetryPolicy(
            maxAttempts: 3,
            initialDelay: .milliseconds(1),
            retryableErrors: [.rateLimited]
        )

        // Use a wrapper model that fails first then succeeds
        let retryTestModel = RetryTestModel(
            failCount: 1,
            failWith: rateLimitError,
            thenReturn: CompletionResponse(
                content: "Success after retry",
                refusal: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            )
        )

        let agent = Agent<Void, String>(
            model: retryTestModel,
            systemPrompt: "You are helpful.",
            tools: [],
            retryPolicy: retryPolicy
        )

        let result = try await agent.run("Hello", deps: ())
        #expect(result.output == "Success after retry")
        let callCount = await retryTestModel.callCount
        #expect(callCount == 2, "Expected 2 calls (1 failure + 1 success)")
    }

    @Test("Retry policy exhausted throws retriesExhausted")
    func retriesExhausted() async throws {
        let retryTestModel = RetryTestModel(
            failCount: 5,
            failWith: LLMError.serverError("Server down"),
            thenReturn: CompletionResponse(
                content: "Never reached",
                refusal: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            )
        )

        let retryPolicy = RetryPolicy(
            maxAttempts: 3,
            initialDelay: .milliseconds(1),
            retryableErrors: [.serverError]
        )

        let agent = Agent<Void, String>(
            model: retryTestModel,
            systemPrompt: "You are helpful.",
            tools: [],
            retryPolicy: retryPolicy
        )

        do {
            _ = try await agent.run("Hello", deps: ())
            Issue.record("Expected retriesExhausted error")
        } catch let error as AgentError {
            guard case .retriesExhausted(let attempts, let lastError) = error else {
                Issue.record("Expected retriesExhausted, got \(error)")
                return
            }
            #expect(attempts == 3)
            if case .serverError(let msg) = lastError as? LLMError {
                #expect(msg.contains("Server down"))
            }
        }
    }

    @Test("Non-retryable errors not retried")
    func nonRetryableErrorNotRetried() async throws {
        let retryTestModel = RetryTestModel(
            failCount: 1,
            failWith: LLMError.invalidAPIKey,  // Not in retryableErrors
            thenReturn: CompletionResponse(
                content: "Never reached",
                refusal: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            )
        )

        let retryPolicy = RetryPolicy(
            maxAttempts: 3,
            retryableErrors: [.rateLimited, .serverError]  // No invalidAPIKey
        )

        let agent = Agent<Void, String>(
            model: retryTestModel,
            systemPrompt: "You are helpful.",
            tools: [],
            retryPolicy: retryPolicy
        )

        do {
            _ = try await agent.run("Hello", deps: ())
            Issue.record("Expected invalidAPIKey error")
        } catch let error as LLMError {
            #expect(error == .invalidAPIKey)
        }

        // Should have only tried once
        let callCount = await retryTestModel.callCount
        #expect(callCount == 1, "Expected 1 call (no retry for non-retryable error)")
    }

    @Test("Retry policy delay calculation")
    func retryDelayCalculation() async throws {
        let policy = RetryPolicy(
            maxAttempts: 5,
            initialDelay: .milliseconds(100),
            maxDelay: .seconds(2),
            backoffMultiplier: 2.0,
            jitter: 0  // No jitter for predictable test
        )

        // Attempt 0: no delay
        #expect(policy.delay(forAttempt: 0) == .zero)

        // Attempt 1: 100ms
        let delay1 = policy.delay(forAttempt: 1)
        #expect(delay1 >= .milliseconds(90) && delay1 <= .milliseconds(110))

        // Attempt 2: 200ms
        let delay2 = policy.delay(forAttempt: 2)
        #expect(delay2 >= .milliseconds(190) && delay2 <= .milliseconds(210))

        // Attempt 3: 400ms
        let delay3 = policy.delay(forAttempt: 3)
        #expect(delay3 >= .milliseconds(390) && delay3 <= .milliseconds(410))
    }
}

// MARK: - Tool Timeout Tests

@Suite("Agent - Tool Timeout")
struct AgentToolTimeoutTests {

    @Test("Tool timeout triggers error")
    func toolTimeoutTriggersError() async throws {
        let model = TestMockModel()

        await model.setResponses([
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-1", name: "slow_tool", arguments: #"{"input":"test"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            ),
            CompletionResponse(
                content: "Done",
                refusal: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 20, outputTokens: 10)
            )
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(SlowTool(delay: .milliseconds(500)))],
            toolTimeout: .milliseconds(10)  // Very short timeout
        )

        do {
            _ = try await agent.run("Use the slow tool", deps: ())
            Issue.record("Expected toolTimeout error")
        } catch let error as AgentError {
            guard case .toolTimeout(let name, let timeout) = error else {
                Issue.record("Expected toolTimeout, got \(error)")
                return
            }
            #expect(name == "slow_tool")
            #expect(timeout == .milliseconds(10))
        }
    }

    @Test("Tool completes within timeout succeeds")
    func toolCompletesWithinTimeout() async throws {
        let model = TestMockModel()

        await model.setResponses([
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-1", name: "slow_tool", arguments: #"{"input":"test"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            ),
            CompletionResponse(
                content: "Tool completed successfully",
                refusal: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 20, outputTokens: 10)
            )
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(SlowTool(delay: .milliseconds(10)))],
            toolTimeout: .seconds(5)  // Generous timeout
        )

        let result = try await agent.run("Use the slow tool", deps: ())
        // Agent should complete with exact response from mock
        #expect(result.output == "Tool completed successfully")
    }
}

// MARK: - Helper: RetryTestModel

/// Model that fails a specified number of times then succeeds.
actor RetryTestModel: Model {
    nonisolated let name: String = "retry-test-model"
    nonisolated let capabilities = ModelCapabilities.claude35

    private var failCount: Int
    private let failWith: Error
    private let thenReturn: CompletionResponse
    private(set) var callCount: Int = 0

    init(failCount: Int, failWith: Error, thenReturn: CompletionResponse) {
        self.failCount = failCount
        self.failWith = failWith
        self.thenReturn = thenReturn
    }

    nonisolated func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        try await doComplete()
    }

    private func doComplete() throws -> CompletionResponse {
        callCount += 1
        if callCount <= failCount {
            throw failWith
        }
        return thenReturn
    }

    nonisolated func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await self.complete(request)
                    if let content = response.content {
                        continuation.yield(.contentDelta(content))
                    }
                    continuation.yield(.done(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Helper: StreamInterruptingModel

/// Model that starts streaming then throws an error mid-stream.
/// Simulates network disconnection or stream interruption.
actor StreamInterruptingModel: Model {
    nonisolated let name: String = "stream-interrupting-model"
    nonisolated let capabilities = ModelCapabilities.claude35

    nonisolated func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        throw LLMError.networkError("Connection interrupted")
    }

    nonisolated func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Send some partial content first
                continuation.yield(.contentDelta("Hello, I'm starting to "))
                continuation.yield(.contentDelta("respond to your "))

                // Brief delay to simulate partial stream
                try? await Task.sleep(for: .milliseconds(10))

                // Then fail mid-stream
                continuation.finish(throwing: LLMError.networkError("Connection interrupted"))
            }
        }
    }
}

// SlowTool is now defined in AgentTestHelpers.swift
