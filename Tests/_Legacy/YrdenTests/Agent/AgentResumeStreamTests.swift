/// Tests for Agent.resumeStream() functionality.
///
/// Tests the streaming resume behavior after tool approval:
/// - Events are emitted for approved tool execution
/// - Subsequent tool calls from model also emit events
/// - Deferred tools during resume throw hasDeferredTools

import Testing
import Foundation
@testable import Yrden

// MARK: - Test Mock Model for Resume Stream

/// Mock model that returns configurable responses for testing resumeStream.
private actor ResumeStreamTestModel: Model {
    nonisolated let name: String = "resume-stream-test-model"
    nonisolated let capabilities = ModelCapabilities.claude35

    private var responses: [CompletionResponse] = []
    private(set) var callCount: Int = 0

    init(responses: [CompletionResponse]) {
        self.responses = responses
    }

    func setResponses(_ responses: [CompletionResponse]) {
        self.responses = responses
        callCount = 0
    }

    nonisolated func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        try await nextResponse()
    }

    private func nextResponse() throws -> CompletionResponse {
        callCount += 1
        guard !responses.isEmpty else {
            throw LLMError.serverError("No responses configured")
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
}

// MARK: - Test Tool Counter

/// Thread-safe counter for tracking tool calls.
private actor ResumeTestCounter {
    private(set) var count = 0

    func increment() { count += 1 }
    func reset() { count = 0 }
}

// MARK: - Test Tool

/// A test tool that can require approval and tracks calls.
private func makeApprovableTool(
    name: String,
    requiresApproval: Bool,
    counter: ResumeTestCounter
) -> AnyAgentTool<Void> {
    AnyAgentTool<Void>(
        name: name,
        description: "Test tool: \(name)",
        definition: ToolDefinition(
            name: name,
            description: "Test tool for resume stream tests",
            inputSchema: ["type": "object", "properties": [:], "required": []]
        ),
        requiresApproval: requiresApproval,
        call: { _, _ in
            await counter.increment()
            return .success("\(name) executed successfully")
        }
    )
}

// MARK: - Helper

private let defaultUsage = Usage(inputTokens: 100, outputTokens: 50)

private func makeToolCallResponse(name: String, id: String = "call-1") -> CompletionResponse {
    CompletionResponse(
        content: nil,
        refusal: nil,
        toolCalls: [ToolCall(id: id, name: name, arguments: "{}")],
        stopReason: .toolUse,
        usage: defaultUsage
    )
}

private func makeTextResponse(_ text: String) -> CompletionResponse {
    CompletionResponse(
        content: text,
        refusal: nil,
        toolCalls: [],
        stopReason: .endTurn,
        usage: defaultUsage
    )
}

// MARK: - Tests

@Suite("Agent.resumeStream - Streaming Events")
struct AgentResumeStreamTests {

    @Test("resumeStream emits toolCallStart and toolResult for approved tools")
    func resumeStreamEmitsToolEvents() async throws {
        let counter = ResumeTestCounter()
        let tool = makeApprovableTool(name: "approvable_tool", requiresApproval: true, counter: counter)

        // Model returns tool call, then text response after tool result
        let model = ResumeStreamTestModel(responses: [
            makeToolCallResponse(name: "approvable_tool", id: "tool-1"),
            makeTextResponse("Task completed")
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are a test assistant.",
            tools: [tool],
            maxIterations: 5
        )

        // First run should throw hasDeferredTools
        var paused: PausedAgentRun?
        do {
            _ = try await agent.run("Use the tool", deps: ())
            Issue.record("Expected hasDeferredTools error")
        } catch let error as AgentError {
            guard case .hasDeferredTools(let p) = error else {
                Issue.record("Expected hasDeferredTools, got \(error)")
                return
            }
            paused = p
        }

        guard let pausedState = paused else {
            Issue.record("Failed to get paused state")
            return
        }

        // Verify initial state
        #expect(pausedState.pendingCalls.count == 1)
        #expect(pausedState.pendingCalls[0].toolCall.name == "approvable_tool")
        let initialCount = await counter.count
        #expect(initialCount == 0, "Tool should not have been called yet")

        // Resume with approval and collect streaming events
        let resolutions = [ResolvedTool(id: "tool-1", resolution: .approved)]

        var events: [String] = []
        for try await event in agent.resumeStream(paused: pausedState, resolutions: resolutions, deps: ()) {
            switch event {
            case .toolCallStart(let name, let id):
                events.append("toolCallStart:\(name):\(id)")
            case .toolResult(let id, _):
                events.append("toolResult:\(id)")
            case .contentDelta(let text):
                events.append("contentDelta:\(text)")
            case .result:
                events.append("result")
            default:
                break
            }
        }

        // Verify events were emitted
        // Note: toolCallStart is NOT emitted for resumed pending tools - they were
        // already announced during the initial stream. Only toolResult is emitted.
        #expect(!events.contains("toolCallStart:approvable_tool:tool-1"),
                "Should NOT emit toolCallStart for resumed pending tool (already announced). Events: \(events)")
        #expect(events.contains("toolResult:tool-1"),
                "Should emit toolResult after execution. Events: \(events)")
        #expect(events.contains("result"),
                "Should emit final result. Events: \(events)")

        // Verify tool was executed
        let finalCount = await counter.count
        #expect(finalCount == 1, "Tool should have been called once after approval")
    }

    @Test("resumeStream emits events for subsequent tool calls from model")
    func resumeStreamEmitsSubsequentToolEvents() async throws {
        let counter1 = ResumeTestCounter()
        let counter2 = ResumeTestCounter()
        let tool1 = makeApprovableTool(name: "first_tool", requiresApproval: true, counter: counter1)
        let tool2 = makeApprovableTool(name: "second_tool", requiresApproval: false, counter: counter2)

        // Model flow:
        // 1. Initial run -> calls first_tool (deferred)
        // 2. After approval -> model calls second_tool
        // 3. After second_tool -> model returns final text
        let model = ResumeStreamTestModel(responses: [
            makeToolCallResponse(name: "first_tool", id: "tool-1"),
            makeToolCallResponse(name: "second_tool", id: "tool-2"),
            makeTextResponse("All done")
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are a test assistant.",
            tools: [tool1, tool2],
            maxIterations: 5
        )

        // First run defers
        var paused: PausedAgentRun?
        do {
            _ = try await agent.run("Use tools", deps: ())
        } catch let error as AgentError {
            if case .hasDeferredTools(let p) = error {
                paused = p
            }
        }

        guard let pausedState = paused else {
            Issue.record("Failed to get paused state")
            return
        }

        // Resume with approval
        let resolutions = [ResolvedTool(id: "tool-1", resolution: .approved)]

        var toolStartEvents: [String] = []
        var toolResultEvents: [String] = []

        for try await event in agent.resumeStream(paused: pausedState, resolutions: resolutions, deps: ()) {
            switch event {
            case .toolCallStart(let name, let id):
                toolStartEvents.append("\(name):\(id)")
            case .toolResult(let id, _):
                toolResultEvents.append(id)
            default:
                break
            }
        }

        // Resumed pending tool (first_tool) should NOT emit toolCallStart - already announced
        // Subsequent tool (second_tool) called by model SHOULD emit toolCallStart - it's new
        #expect(!toolStartEvents.contains("first_tool:tool-1"),
                "Should NOT emit start for resumed pending tool. Got: \(toolStartEvents)")
        #expect(toolStartEvents.contains("second_tool:tool-2"),
                "Should emit start for second tool (new from model). Got: \(toolStartEvents)")
        #expect(toolResultEvents.contains("tool-1"),
                "Should emit result for first tool. Got: \(toolResultEvents)")
        #expect(toolResultEvents.contains("tool-2"),
                "Should emit result for second tool. Got: \(toolResultEvents)")

        // Both tools should have been executed
        let count1 = await counter1.count
        let count2 = await counter2.count
        #expect(count1 == 1, "First tool should be called once")
        #expect(count2 == 1, "Second tool should be called once")
    }

    @Test("resumeStream with denied resolution emits error result")
    func resumeStreamDeniedEmitsError() async throws {
        let counter = ResumeTestCounter()
        let tool = makeApprovableTool(name: "denied_tool", requiresApproval: true, counter: counter)

        let model = ResumeStreamTestModel(responses: [
            makeToolCallResponse(name: "denied_tool", id: "tool-1"),
            makeTextResponse("Understood, tool was denied")
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are a test assistant.",
            tools: [tool],
            maxIterations: 5
        )

        // First run defers
        var paused: PausedAgentRun?
        do {
            _ = try await agent.run("Use the tool", deps: ())
        } catch let error as AgentError {
            if case .hasDeferredTools(let p) = error {
                paused = p
            }
        }

        guard let pausedState = paused else {
            Issue.record("Failed to get paused state")
            return
        }

        // Resume with denial
        let resolutions = [ResolvedTool(id: "tool-1", resolution: .denied(reason: "User rejected"))]

        var toolResults: [(id: String, result: String)] = []
        for try await event in agent.resumeStream(paused: pausedState, resolutions: resolutions, deps: ()) {
            if case .toolResult(let id, let result) = event {
                toolResults.append((id, result))
            }
        }

        // Should have a result with denial message
        #expect(toolResults.count >= 1, "Should emit tool result for denied tool")
        #expect(toolResults[0].result.contains("denied") || toolResults[0].result.contains("rejected"),
                "Result should indicate denial. Got: \(toolResults[0].result)")

        // Tool should NOT have been called
        let count = await counter.count
        #expect(count == 0, "Denied tool should not be executed")
    }
}

@Suite("Agent.resumeStream - Deferred During Resume")
struct AgentResumeStreamDeferralTests {

    @Test("resumeStream throws hasDeferredTools when model calls another approvable tool")
    func resumeStreamThrowsOnSubsequentDeferral() async throws {
        let counter1 = ResumeTestCounter()
        let counter2 = ResumeTestCounter()
        let tool1 = makeApprovableTool(name: "approved_tool", requiresApproval: true, counter: counter1)
        let tool2 = makeApprovableTool(name: "also_approvable", requiresApproval: true, counter: counter2)

        // Model calls first tool, then after approval calls second tool (also needs approval)
        let model = ResumeStreamTestModel(responses: [
            makeToolCallResponse(name: "approved_tool", id: "tool-1"),
            makeToolCallResponse(name: "also_approvable", id: "tool-2"),
            makeTextResponse("Done")
        ])

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are a test assistant.",
            tools: [tool1, tool2],
            maxIterations: 5
        )

        // First run defers on tool1
        var paused: PausedAgentRun?
        do {
            _ = try await agent.run("Use tools", deps: ())
        } catch let error as AgentError {
            if case .hasDeferredTools(let p) = error {
                paused = p
            }
        }

        guard let pausedState = paused else {
            Issue.record("Failed to get paused state")
            return
        }

        // Resume with approval for tool1, should defer on tool2
        let resolutions = [ResolvedTool(id: "tool-1", resolution: .approved)]

        var secondPaused: PausedAgentRun?
        do {
            for try await _ in agent.resumeStream(paused: pausedState, resolutions: resolutions, deps: ()) {
                // Consume events
            }
            Issue.record("Expected hasDeferredTools when model calls second approvable tool")
        } catch let error as AgentError {
            if case .hasDeferredTools(let p) = error {
                secondPaused = p
            } else {
                Issue.record("Expected hasDeferredTools, got \(error)")
            }
        }

        // Should have paused on second tool
        guard let secondPausedState = secondPaused else {
            Issue.record("Should have paused on second tool")
            return
        }

        #expect(secondPausedState.pendingCalls.count == 1)
        #expect(secondPausedState.pendingCalls[0].toolCall.name == "also_approvable")

        // First tool should have been called, second should not
        let count1 = await counter1.count
        let count2 = await counter2.count
        #expect(count1 == 1, "First tool should have been executed")
        #expect(count2 == 0, "Second tool should NOT have been executed (needs approval)")
    }
}
