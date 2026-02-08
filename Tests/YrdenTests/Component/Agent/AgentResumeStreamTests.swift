/// Tests for Agent.resumeStream() functionality.
///
/// Covers: streaming events during resume after approval, subsequent tool
/// call events, denied resolution events, and subsequent approval deferral
/// during a resume.
///
/// Key invariant: resumeStream emits tool result events for resolved tools,
/// streams model responses, and pauses again if new approval-requiring
/// tools are encountered.
///
/// Implementation detail: agent.run() uses model.complete() while
/// agent.resumeStream() uses model.stream(), so FakeModel needs both
/// onComplete and onStream callbacks configured.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Agent - Resume Stream")
struct AgentResumeStreamTests {

    @Test("resumeStream emits tool result and finished for approved tool")
    func resumeStreamEmitsToolResultAndFinished() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "approvable_tool",
            onCall: { _ in .success("tool executed") }
        )

        let completeCounter = CallCounter()
        let streamCounter = CallCounter()
        let model = FakeModel(
            onComplete: { _ in
                switch await completeCounter.increment() {
                case 1:
                    // Initial run: model calls approvable tool → triggers approval pause
                    return MockResponse.toolCall(
                        name: "approvable_tool",
                        arguments: #"{"input":"go"}"#,
                        id: "tc-1"
                    )
                default:
                    throw LLMError.serverError("Unexpected complete call")
                }
            },
            onStream: { _ in
                switch await streamCounter.increment() {
                case 1:
                    // After resume: model returns final text
                    let response = MockResponse.text("Task completed")
                    return [
                        .contentDelta("Task completed"),
                        .done(response)
                    ]
                default:
                    throw LLMError.serverError("Unexpected stream call")
                }
            }
        )

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [ApprovalRequired(tool)]
        )

        // Initial run should pause for approval
        let initialRun = try await agent.run("Use the tool")
        guard case .needsApproval(let pending) = initialRun.status else {
            Issue.record("Expected .needsApproval, got \(initialRun.status)")
            return
        }
        #expect(pending.count == 1)
        #expect(pending[0].call.name == "approvable_tool")

        // Tool not yet executed
        let callsBefore = await tool.calls
        #expect(callsBefore.isEmpty)

        // Resume with approval via streaming
        let options = ResumeOptions.approve([pending[0].call.id])

        var toolResults: [(id: String, result: String)] = []
        var contentDeltas: [String] = []
        var finishedRun: AgentRun<String>?

        for try await event in agent.resumeStream(from: initialRun, with: options) {
            switch event {
            case .toolResult(let id, let result):
                toolResults.append((id, result))
            case .contentDelta(let text, _):
                contentDeltas.append(text)
            case .finished(let run):
                finishedRun = run
            default:
                break
            }
        }

        // Tool result emitted
        #expect(toolResults.count == 1)
        #expect(toolResults[0].id == "tc-1")
        #expect(toolResults[0].result.contains("tool executed"))

        // Content streamed
        #expect(contentDeltas == ["Task completed"])

        // Finished with output
        guard let run = finishedRun else {
            Issue.record("Expected .finished event")
            return
        }
        #expect(run.output == "Task completed")

        // Tool was executed
        let callsAfter = await tool.calls
        #expect(callsAfter.count == 1)
    }

    @Test("resumeStream emits events for subsequent tool calls from model")
    func resumeStreamEmitsSubsequentToolEvents() async throws {
        let tool1 = FakeTool<ConfigurableToolArgs, String>(
            name: "first_tool",
            onCall: { _ in .success("first result") }
        )
        let tool2 = FakeTool<ConfigurableToolArgs, String>(
            name: "second_tool",
            onCall: { _ in .success("second result") }
        )

        let completeCounter = CallCounter()
        let streamCounter = CallCounter()
        let model = FakeModel(
            onComplete: { _ in
                switch await completeCounter.increment() {
                case 1:
                    // Initial run: model calls approvable tool → triggers approval pause
                    return MockResponse.toolCall(
                        name: "first_tool",
                        arguments: #"{"input":"a"}"#,
                        id: "tc-1"
                    )
                default:
                    throw LLMError.serverError("Unexpected complete call")
                }
            },
            onStream: { _ in
                switch await streamCounter.increment() {
                case 1:
                    // After approval resume: model calls second (non-approval) tool
                    let response = MockResponse.toolCall(
                        name: "second_tool",
                        arguments: #"{"input":"b"}"#,
                        id: "tc-2"
                    )
                    return [
                        .toolCallStart(id: "tc-2", name: "second_tool"),
                        .toolCallDelta(argumentsDelta: #"{"input":"b"}"#),
                        .toolCallEnd(id: "tc-2"),
                        .done(response)
                    ]
                case 2:
                    let response = MockResponse.text("All done")
                    return [
                        .contentDelta("All done"),
                        .done(response)
                    ]
                default:
                    throw LLMError.serverError("Unexpected stream call")
                }
            }
        )

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [ApprovalRequired(tool1), tool2]
        )

        // Initial run defers
        let initialRun = try await agent.run("Use tools")
        guard case .needsApproval(let pending) = initialRun.status else {
            Issue.record("Expected .needsApproval, got \(initialRun.status)")
            return
        }

        // Resume with approval
        let options = ResumeOptions.approve([pending[0].call.id])

        var toolStartNames: [String] = []
        var toolResultIds: [String] = []

        for try await event in agent.resumeStream(from: initialRun, with: options) {
            switch event {
            case .toolCallStart(_, let name):
                toolStartNames.append(name)
            case .toolResult(let id, _):
                toolResultIds.append(id)
            default:
                break
            }
        }

        // Subsequent tool (second_tool) should emit toolCallStart — it's new from model
        #expect(toolStartNames.contains("second_tool"),
                "Should emit start for second tool. Got: \(toolStartNames)")

        // Both tools should have results
        #expect(toolResultIds.contains("tc-1"), "Should have result for first tool")
        #expect(toolResultIds.contains("tc-2"), "Should have result for second tool")

        // Both tools were executed
        let calls1 = await tool1.calls
        let calls2 = await tool2.calls
        #expect(calls1.count == 1, "First tool should be called once")
        #expect(calls2.count == 1, "Second tool should be called once")
    }

    @Test("resumeStream with denied resolution emits error result to model")
    func resumeStreamDeniedEmitsErrorResult() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "denied_tool",
            onCall: { _ in .success("should not reach") }
        )

        let completeCounter = CallCounter()
        let streamCounter = CallCounter()
        let model = FakeModel(
            onComplete: { _ in
                switch await completeCounter.increment() {
                case 1:
                    // Initial run: model calls tool → triggers approval pause
                    return MockResponse.toolCall(
                        name: "denied_tool",
                        arguments: #"{"input":"go"}"#,
                        id: "tc-1"
                    )
                default:
                    throw LLMError.serverError("Unexpected complete call")
                }
            },
            onStream: { _ in
                switch await streamCounter.increment() {
                case 1:
                    // After denial resume: model recovers gracefully
                    let response = MockResponse.text("Understood, tool was denied")
                    return [
                        .contentDelta("Understood, tool was denied"),
                        .done(response)
                    ]
                default:
                    throw LLMError.serverError("Unexpected stream call")
                }
            }
        )

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [ApprovalRequired(tool)]
        )

        // Initial run defers
        let initialRun = try await agent.run("Use the tool")
        guard case .needsApproval(let pending) = initialRun.status else {
            Issue.record("Expected .needsApproval, got \(initialRun.status)")
            return
        }

        // Resume with denial
        let options = ResumeOptions.deny([pending[0].call.id], message: "User rejected")

        var toolResults: [(id: String, result: String)] = []
        var contentDeltas: [String] = []
        var finishedRun: AgentRun<String>?

        for try await event in agent.resumeStream(from: initialRun, with: options) {
            switch event {
            case .toolResult(let id, let result):
                toolResults.append((id, result))
            case .contentDelta(let text, _):
                contentDeltas.append(text)
            case .finished(let run):
                finishedRun = run
            default:
                break
            }
        }

        // Denied tools do NOT emit .toolResult to the public stream
        // (toolDenied events are internal and not forwarded)
        #expect(toolResults.isEmpty,
                "Denied tools should not produce .toolResult events. Got: \(toolResults)")

        // Model received the denial and recovered with text output
        #expect(contentDeltas == ["Understood, tool was denied"])

        guard let run = finishedRun else {
            Issue.record("Expected .finished event")
            return
        }
        #expect(run.output == "Understood, tool was denied")

        // Tool was NOT executed
        let calls = await tool.calls
        #expect(calls.isEmpty, "Denied tool should not be executed")
    }

    @Test("resumeStream pauses again when model calls another approvable tool")
    func resumeStreamPausesOnSubsequentApprovalTool() async throws {
        let tool1 = FakeTool<ConfigurableToolArgs, String>(
            name: "first_approvable",
            onCall: { _ in .success("first done") }
        )
        let tool2 = FakeTool<ConfigurableToolArgs, String>(
            name: "second_approvable",
            onCall: { _ in .success("second done") }
        )

        let completeCounter = CallCounter()
        let streamCounter = CallCounter()
        let model = FakeModel(
            onComplete: { _ in
                switch await completeCounter.increment() {
                case 1:
                    // Initial run: call first tool → triggers approval pause
                    return MockResponse.toolCall(
                        name: "first_approvable",
                        arguments: #"{"input":"a"}"#,
                        id: "tc-1"
                    )
                case 2:
                    // Second resume (for second tool): final text response
                    return MockResponse.text("All approved and done")
                default:
                    throw LLMError.serverError("Unexpected complete call")
                }
            },
            onStream: { _ in
                switch await streamCounter.increment() {
                case 1:
                    // First resume: after first approval, model calls second approvable tool
                    let response = MockResponse.toolCall(
                        name: "second_approvable",
                        arguments: #"{"input":"b"}"#,
                        id: "tc-2"
                    )
                    return [
                        .toolCallStart(id: "tc-2", name: "second_approvable"),
                        .toolCallDelta(argumentsDelta: #"{"input":"b"}"#),
                        .toolCallEnd(id: "tc-2"),
                        .done(response)
                    ]
                default:
                    throw LLMError.serverError("Unexpected stream call")
                }
            }
        )

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [ApprovalRequired(tool1), ApprovalRequired(tool2)]
        )

        // Initial run defers on first tool
        let initialRun = try await agent.run("Use tools")
        guard case .needsApproval(let pending1) = initialRun.status else {
            Issue.record("Expected .needsApproval, got \(initialRun.status)")
            return
        }
        #expect(pending1.count == 1)
        #expect(pending1[0].call.name == "first_approvable")

        // Resume with approval for first tool — should pause on second
        let options1 = ResumeOptions.approve([pending1[0].call.id])

        var secondPausedRun: AgentRun<String>?
        for try await event in agent.resumeStream(from: initialRun, with: options1) {
            if case .finished(let run) = event {
                secondPausedRun = run
            }
        }

        // Should have paused again on second tool
        guard let run2 = secondPausedRun else {
            Issue.record("Expected .finished event with paused run")
            return
        }
        guard case .needsApproval(let pending2) = run2.status else {
            Issue.record("Expected .needsApproval for second tool, got \(run2.status)")
            return
        }
        #expect(pending2.count == 1)
        #expect(pending2[0].call.name == "second_approvable")

        // First tool should have been executed, second should not
        let calls1 = await tool1.calls
        let calls2 = await tool2.calls
        #expect(calls1.count == 1, "First tool should have been executed")
        #expect(calls2.isEmpty, "Second tool should NOT have been executed yet")

        // Resume with approval for second tool (non-streaming)
        let options2 = ResumeOptions.approve([pending2[0].call.id])
        let finalRun = try await agent.resume(from: run2, with: options2)

        guard case .completed(let output) = finalRun.status else {
            Issue.record("Expected .completed, got \(finalRun.status)")
            return
        }
        #expect(output == "All approved and done")

        // Both tools now executed
        let finalCalls2 = await tool2.calls
        #expect(finalCalls2.count == 1)
    }
}
