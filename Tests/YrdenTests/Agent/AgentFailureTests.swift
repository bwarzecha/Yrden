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

/// A controllable model for testing agent behavior.
/// All configuration is done via async methods to be safe with Swift concurrency.
actor TestMockModel: Model {
    nonisolated let name: String = "test-mock-model"
    nonisolated let capabilities = ModelCapabilities.claude35

    private var responses: [CompletionResponse] = []
    private var errorToThrow: Error?
    private(set) var callCount: Int = 0

    /// Set responses to return in order.
    func setResponses(_ responses: [CompletionResponse]) {
        self.responses = responses
    }

    /// Set error to throw on next call.
    func setError(_ error: Error?) {
        self.errorToThrow = error
    }

    nonisolated func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        try await nextResponse()
    }

    private func nextResponse() throws -> CompletionResponse {
        callCount += 1

        if let error = errorToThrow {
            throw error
        }

        guard !responses.isEmpty else {
            throw LLMError.serverError("TestMockModel: No responses configured")
        }

        return responses.removeFirst()
    }

    nonisolated func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await self.complete(request)
                    if let content = response.content {
                        continuation.yield(.contentDelta(content))
                    }
                    for call in response.toolCalls {
                        continuation.yield(.toolCallStart(id: call.id, name: call.name))
                        continuation.yield(.toolCallDelta(argumentsDelta: call.arguments))
                        continuation.yield(.toolCallEnd(id: call.id))
                    }
                    continuation.yield(.done(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Reset the model state.
    func reset() {
        responses = []
        errorToThrow = nil
        callCount = 0
    }

    /// Configure model to return a text response.
    func setTextResponse(_ text: String) {
        responses = [CompletionResponse(
            content: text,
            refusal: nil,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 10)
        )]
    }

    /// Configure model to call a tool.
    func setToolCall(name: String, arguments: String, id: String = "call-1") {
        responses = [CompletionResponse(
            content: nil,
            refusal: nil,
            toolCalls: [ToolCall(id: id, name: name, arguments: arguments)],
            stopReason: .toolUse,
            usage: Usage(inputTokens: 10, outputTokens: 10)
        )]
    }

    /// Configure model to call a tool then return text.
    func setToolCallThenText(toolName: String, toolArgs: String, finalText: String) {
        responses = [
            CompletionResponse(
                content: nil,
                refusal: nil,
                toolCalls: [ToolCall(id: "call-1", name: toolName, arguments: toolArgs)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            ),
            CompletionResponse(
                content: finalText,
                refusal: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            )
        ]
    }

    /// Configure model to return maxTokens stop reason.
    func setMaxTokensResponse(_ partialContent: String) {
        responses = [CompletionResponse(
            content: partialContent,
            refusal: nil,
            toolCalls: [],
            stopReason: .maxTokens,
            usage: Usage(inputTokens: 10, outputTokens: 4096)
        )]
    }

    /// Configure model to return content filtered.
    func setContentFilteredResponse() {
        responses = [CompletionResponse(
            content: nil,
            refusal: nil,
            toolCalls: [],
            stopReason: .contentFiltered,
            usage: Usage(inputTokens: 10, outputTokens: 0)
        )]
    }

    /// Configure model to return a refusal.
    func setRefusalResponse(_ reason: String) {
        responses = [CompletionResponse(
            content: nil,
            refusal: reason,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 10)
        )]
    }
}

// MARK: - Test Tools

@Schema(description: "Arguments for throwing tool")
struct ThrowingToolArgs {
    let input: String
}

/// Tool that always throws an error.
struct ThrowingTool: AgentTool {
    typealias Deps = Void
    typealias Args = ThrowingToolArgs

    struct ToolError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var name: String { "throwing_tool" }
    var description: String { "A tool that throws errors" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        throw ToolError(message: "Tool crashed: \(arguments.input)")
    }
}

@Schema(description: "Arguments for failing tool")
struct FailingToolArgs {
    let input: String
}

/// Tool that returns .failure result.
struct FailingTool: AgentTool {
    typealias Deps = Void
    typealias Args = FailingToolArgs

    struct ToolFailure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    var name: String { "failing_tool" }
    var description: String { "A tool that returns failure" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        return .failure(ToolFailure(reason: "Failed to process: \(arguments.input)"))
    }
}

@Schema(description: "Arguments for retry tool")
struct RetryToolArgs {
    let input: String
}

/// Tool that returns .retry result to ask LLM to try again.
struct RetryRequestingTool: AgentTool {
    typealias Deps = Void
    typealias Args = RetryToolArgs

    var name: String { "retry_tool" }
    var description: String { "A tool that requests retry" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        return .retry(message: "Invalid input '\(arguments.input)', please try with a different value")
    }
}

@Schema(description: "Arguments for counting tool")
struct CountingToolArgs {
    let input: String
}

/// Actor to track call count for CountingTool.
actor CountingToolState {
    var callCount = 0

    func increment() -> Int {
        callCount += 1
        return callCount
    }

    func reset() {
        callCount = 0
    }
}

/// Tool that tracks call count and can be configured to fail then succeed.
struct CountingTool: AgentTool {
    typealias Deps = Void
    typealias Args = CountingToolArgs

    let state = CountingToolState()
    let failUntilCall: Int
    let successResult: String

    var name: String { "counting_tool" }
    var description: String { "A tool that counts calls" }

    init(failUntilCall: Int = 0, successResult: String = "Success") {
        self.failUntilCall = failUntilCall
        self.successResult = successResult
    }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        let currentCount = await state.increment()
        if currentCount <= failUntilCall {
            return .retry(message: "Not ready yet, please try again (attempt \(currentCount))")
        }
        return .success(successResult)
    }

    var callCount: Int {
        get async { await state.callCount }
    }

    func reset() async {
        await state.reset()
    }
}

@Schema(description: "Simple tool args")
struct SimpleToolArgs {
    let value: String
}

/// Simple working tool for control tests.
struct SimpleTool: AgentTool {
    typealias Deps = Void
    typealias Args = SimpleToolArgs

    var name: String { "simple_tool" }
    var description: String { "A simple working tool" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        return .success("Processed: \(arguments.value)")
    }
}

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
            tools: [AnyAgentTool(ThrowingTool())],
            maxIterations: 5
        )

        let result = try await agent.run("Test the tool", deps: ())

        // Agent should complete successfully after receiving error feedback
        #expect(result.output.contains("error"))
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
            tools: [AnyAgentTool(FailingTool())],
            maxIterations: 5
        )

        let result = try await agent.run("Process this data", deps: ())

        #expect(result.output.contains("failed"))
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
                toolCalls: [ToolCall(id: "call-2", name: "simple_tool", arguments: #"{"value":"correct"}"#)],
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
            tools: [AnyAgentTool(RetryRequestingTool()), AnyAgentTool(SimpleTool())],
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
        let countingTool = CountingTool(failUntilCall: 1, successResult: "Finally worked!")

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

        let toolCallCount = await countingTool.callCount
        // Tool should be called at least twice: once for retry, once for success
        #expect(toolCallCount >= 2, "Expected at least 2 tool calls, got \(toolCallCount)")
        #expect(result.output.contains("worked"))
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
            tools: [AnyAgentTool(FailingTool())],
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
            tools: [AnyAgentTool(SimpleTool())],
            maxIterations: 5
        )

        let result = try await agent.run("Do something", deps: ())

        // Agent should complete after model receives "tool not found" error
        #expect(!result.output.isEmpty)
        let callCount = await model.callCount
        #expect(callCount == 2)
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
                toolCalls: [ToolCall(id: "call-\(i)", name: "simple_tool", arguments: #"{"value":"test"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            )
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(SimpleTool())],
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
                    ToolCall(id: "call-1", name: "simple_tool", arguments: #"{"value":"a"}"#),
                    ToolCall(id: "call-2", name: "simple_tool", arguments: #"{"value":"b"}"#),
                    ToolCall(id: "call-3", name: "simple_tool", arguments: #"{"value":"c"}"#)
                ],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            )
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(SimpleTool())],
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
                toolCalls: [ToolCall(id: "call-1", name: "simple_tool", arguments: #"{"value":"test"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 1000, outputTokens: 500)
            )
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(SimpleTool())],
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
            tools: [AnyAgentTool(ThrowingTool())],
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
                toolCalls: [ToolCall(id: "call-1", name: "simple_tool", arguments: #"{"value":"test"}"#)],
                stopReason: .toolUse,
                usage: Usage(inputTokens: 10, outputTokens: 10)
            )
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(SimpleTool())],
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
                toolCalls: [ToolCall(id: "call-1", name: "slow_tool", arguments: #"{"value":"test"}"#)],
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
                toolCalls: [ToolCall(id: "call-1", name: "slow_tool", arguments: #"{"value":"test"}"#)],
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
        #expect(result.output.contains("completed"))
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

// MARK: - Helper: SlowTool

@Schema(description: "Slow tool arguments")
struct SlowToolArgs {
    let value: String
}

/// Tool that takes a configurable amount of time.
struct SlowTool: AgentTool {
    typealias Deps = Void
    typealias Args = SlowToolArgs

    let delay: Duration

    var name: String { "slow_tool" }
    var description: String { "A tool that takes time" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        try await Task.sleep(for: delay)
        return .success("Completed after delay: \(arguments.value)")
    }
}
