/// Tests for Agent human-in-the-loop approval, deferral, and resume behavior.
///
/// Covers: approval deferral, batch deferral, resume with approved/denied/
/// replaced/no-decision, and run state preservation.
///
/// Key invariant: tools with requiresApproval are NEVER executed until
/// explicitly approved via resume.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Agent - Tool Approval")
struct AgentToolApprovalTests {

    @Test("tool with approval defers and is not executed")
    func toolWithApprovalDefersAndDoesNotExecute() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "approval_tool",
            onCall: { _ in .success("should not reach") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "approval_tool",
                    arguments: #"{"input":"go"}"#,
                    id: "tc-1"
                )
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [ApprovalRequired(tool)]
        )

        // run() returns AgentRun with status, doesn't throw for approvals
        let run = try await agent.run("Do it")

        // Check status is needsApproval
        guard case .needsApproval(let pending) = run.status else {
            Issue.record("Expected .needsApproval, got \(run.status)")
            return
        }

        #expect(pending.count == 1)
        #expect(pending[0].requiresApproval)
        #expect(pending[0].call.name == "approval_tool")
        #expect(pending[0].call.id == "tc-1")

        // Tool was NOT executed
        let calls = await tool.calls
        #expect(calls.isEmpty)
    }

    @Test("approval tool in batch blocks normal tools from executing")
    func approvalToolInBatchBlocksNormalTools() async throws {
        let normalA = FakeTool<ConfigurableToolArgs, String>(
            name: "normal_a",
            onCall: { _ in .success("a-ok") }
        )
        let approvalB = FakeTool<ConfigurableToolArgs, String>(
            name: "approval_b",
            onCall: { _ in .success("b-ok") }
        )

        let model = FakeModel(onComplete: { _ in
            MockResponse.toolCalls([
                ToolCall(id: "tc-a", name: "normal_a", arguments: #"{"input":"a"}"#),
                ToolCall(id: "tc-b", name: "approval_b", arguments: #"{"input":"b"}"#),
            ])
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [
                normalA,
                ApprovalRequired(approvalB),
            ]
        )

        let run = try await agent.run("Use all tools")

        guard case .needsApproval(let pending) = run.status else {
            Issue.record("Expected .needsApproval, got \(run.status)")
            return
        }

        #expect(pending.count == 1)
        #expect(pending[0].call.name == "approval_b")

        // Normal tool must NOT execute either — entire batch is held
        let aCalls = await normalA.calls
        let bCalls = await approvalB.calls
        #expect(aCalls.isEmpty)
        #expect(bCalls.isEmpty)
    }

    @Test("resume with approved executes tool and continues")
    func resumeWithApprovedExecutesToolAndContinues() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "approval_tool",
            onCall: { _ in .success("tool output") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "approval_tool",
                    arguments: #"{"input":"go"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultSuccess(for: "tc-1"))
                #expect(request.toolResultContent(for: "tc-1") == "tool output")
                return MockResponse.text("Done after approval")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [ApprovalRequired(tool)]
        )

        // Run → deferred
        let initialRun = try await agent.run("Do it")
        guard case .needsApproval(let pending) = initialRun.status else {
            Issue.record("Expected .needsApproval, got \(initialRun.status)")
            return
        }

        // Resume with approval
        let options = ResumeOptions.approve([pending[0].call.id])
        let result = try await agent.resume(from: initialRun, with: options)

        guard case .completed(let output) = result.status else {
            Issue.record("Expected .completed, got \(result.status)")
            return
        }
        #expect(output == "Done after approval")

        // Tool was executed during resume
        let calls = await tool.calls
        #expect(calls.count == 1)
    }

    @Test("resume with denied sends error to model")
    func resumeWithDeniedSendsErrorToModel() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "approval_tool",
            onCall: { _ in .success("should not reach") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "approval_tool",
                    arguments: #"{"input":"go"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultError(for: "tc-1"))
                return MockResponse.text("Handled denial")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [ApprovalRequired(tool)]
        )

        let initialRun = try await agent.run("Do it")
        guard case .needsApproval(let pending) = initialRun.status else {
            Issue.record("Expected .needsApproval")
            return
        }

        let options = ResumeOptions.deny([pending[0].call.id], message: "User rejected")
        let result = try await agent.resume(from: initialRun, with: options)

        guard case .completed(let output) = result.status else {
            Issue.record("Expected .completed, got \(result.status)")
            return
        }
        #expect(output == "Handled denial")

        let calls = await tool.calls
        #expect(calls.isEmpty)
    }

    @Test("resume with replaced uses provided result")
    func resumeWithReplacedUsesProvidedResult() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "approval_tool",
            onCall: { _ in .success("should not reach") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "approval_tool",
                    arguments: #"{"input":"go"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultSuccess(for: "tc-1"))
                #expect(request.toolResultContent(for: "tc-1") == "external data")
                return MockResponse.text("Used external data")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [ApprovalRequired(tool)]
        )

        let initialRun = try await agent.run("Do it")
        guard case .needsApproval(let pending) = initialRun.status else {
            Issue.record("Expected .needsApproval")
            return
        }

        let options = ResumeOptions.replace([pending[0].call.id: "external data"])
        let result = try await agent.resume(from: initialRun, with: options)

        guard case .completed(let output) = result.status else {
            Issue.record("Expected .completed, got \(result.status)")
            return
        }
        #expect(output == "Used external data")

        let calls = await tool.calls
        #expect(calls.isEmpty)
    }

    @Test("resume with deny all sends errors to model")
    func resumeWithDenyAllSendsErrorsToModel() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "approval_tool",
            onCall: { _ in .success("should not reach") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "approval_tool",
                    arguments: #"{"input":"go"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultError(for: "tc-1"))
                return MockResponse.text("Handled failure")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [ApprovalRequired(tool)]
        )

        let initialRun = try await agent.run("Do it")
        guard case .needsApproval = initialRun.status else {
            Issue.record("Expected .needsApproval")
            return
        }

        // Deny all pending tools
        let options = ResumeOptions.denyAll(from: initialRun, message: "Service timeout")
        let result = try await agent.resume(from: initialRun, with: options)

        guard case .completed(let output) = result.status else {
            Issue.record("Expected .completed, got \(result.status)")
            return
        }
        #expect(output == "Handled failure")

        let calls = await tool.calls
        #expect(calls.isEmpty)
    }

    @Test("resume with empty decisions denies all")
    func resumeWithEmptyDecisionsDeniesAll() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "approval_tool",
            onCall: { _ in .success("should not reach") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "approval_tool",
                    arguments: #"{"input":"go"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultError(for: "tc-1"))
                return MockResponse.text("Handled missing resolution")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [ApprovalRequired(tool)]
        )

        let initialRun = try await agent.run("Do it")
        guard case .needsApproval = initialRun.status else {
            Issue.record("Expected .needsApproval")
            return
        }

        // Resume with empty decisions - should deny all by default
        let options = ResumeOptions.decisions([:])
        let result = try await agent.resume(from: initialRun, with: options)

        guard case .completed(let output) = result.status else {
            Issue.record("Expected .completed, got \(result.status)")
            return
        }
        #expect(output == "Handled missing resolution")

        let calls = await tool.calls
        #expect(calls.isEmpty)
    }

    @Test("run state preserves conversation context")
    func runStatePreservesConversationContext() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "approval_tool",
            onCall: { _ in .success("should not reach") }
        )

        let model = FakeModel(onComplete: { _ in
            return MockResponse.toolCall(
                name: "approval_tool",
                arguments: #"{"input":"go"}"#,
                id: "tc-1"
            )
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [ApprovalRequired(tool)]
        )

        let run = try await agent.run("Test prompt")

        guard case .needsApproval(let pending) = run.status else {
            Issue.record("Expected .needsApproval, got \(run.status)")
            return
        }

        // Verify pending tools
        #expect(pending.count == 1)
        #expect(pending[0].call.name == "approval_tool")

        // User prompt preserved
        let hasUserMessage = run.messages.contains { message in
            if case .user(let parts) = message {
                return parts.contains { part in
                    if case .text(let text) = part {
                        return text == "Test prompt"
                    }
                    return false
                }
            }
            return false
        }
        #expect(hasUserMessage)

        // Assistant response with tool call preserved
        let hasAssistantWithToolCall = run.messages.contains { message in
            if case .assistant(let blocks) = message {
                return blocks.compactMap({ $0.toolCall }).contains { $0.name == "approval_tool" }
            }
            return false
        }
        #expect(hasAssistantWithToolCall)

        // Usage tracked
        #expect(run.usage.totalTokens > 0)

        // Request count reflects model call
        #expect(run.requestCount >= 1)

        // Run ID populated
        #expect(!run.runID.isEmpty)

        // Status indicates needs approval
        #expect(run.canResume)
        #expect(!run.isCompleted)
    }

}
