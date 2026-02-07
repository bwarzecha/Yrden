/// Tests for tool approval flow in the iterator.
///
/// Covers approve/deny/replace decisions in beforeTools phase:
/// - Default behavior (pending = execute)
/// - Explicit approval
/// - Denial with message
/// - Replacement with synthetic result
/// - requiresApproval flag behavior

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Iterator - Tool Approval")
struct IteratorToolApprovalTests {

    // MARK: - Test 4.1: Pending decision executes by default

    @Test("without any action, pending tools execute")
    func pendingDecisionExecutesByDefault() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "my_tool",
            onCall: { _ in .success("executed") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(model: model, tools: [tool])

        for try await _ in agent.iter("Use tool") {
            // Don't call approve(), deny(), or replace()
            // Just let iteration continue
        }

        let calls = await tool.calls
        #expect(calls.count == 1)  // Tool WAS executed
    }

    // MARK: - Test 4.2: Approve executes tool

    @Test("explicit approve executes tool")
    func approveExecutesTool() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "my_tool",
            onCall: { _ in .success("executed") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(model: model, tools: [tool])

        for try await node in agent.iter("Use tool") {
            if case .beforeTools(let ctx) = node {
                ctx.approve(ctx.pendingCalls[0].call)
            }
        }

        let calls = await tool.calls
        #expect(calls.count == 1)
    }

    // MARK: - Test 4.3: Deny skips execution with message

    @Test("deny prevents execution and sends message to model")
    func denySkipsExecutionWithMessage() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "my_tool",
            onCall: { _ in .success("executed") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(model: model, tools: [tool])

        var deniedResultOutput: String?
        for try await node in agent.iter("Use tool") {
            if case .beforeTools(let ctx) = node {
                ctx.deny(ctx.pendingCalls[0].call, message: "Not allowed today")
            }
            if case .afterTools(let ctx) = node {
                // Per design doc: use .denied case or .output property
                if case .denied(let message) = ctx.results.first?.result {
                    deniedResultOutput = "Tool denied: \(message)"
                } else {
                    // Fallback: use output property which formats correctly
                    deniedResultOutput = ctx.results.first?.output
                }
            }
        }

        let calls = await tool.calls
        #expect(calls.isEmpty)  // Tool was NOT executed
        // Per design doc: denied tools produce "Tool denied: {message}" format
        #expect(deniedResultOutput == "Tool denied: Not allowed today")
    }

    // MARK: - Test 4.4: Replace skips execution with result

    @Test("replace skips execution and uses synthetic result")
    func replaceSkipsExecutionWithResult() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "my_tool",
            onCall: { _ in .success("executed") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(model: model, tools: [tool])

        var replacedResultContent: String?
        for try await node in agent.iter("Use tool") {
            if case .beforeTools(let ctx) = node {
                ctx.replace(ctx.pendingCalls[0].call, withResult: "cached value from yesterday")
            }
            if case .afterTools(let ctx) = node {
                // Per design doc: replaced tools use .replaced case
                if case .replaced(let value) = ctx.results.first?.result {
                    replacedResultContent = value
                } else {
                    // Fallback: use output property
                    replacedResultContent = ctx.results.first?.output
                }
            }
        }

        let calls = await tool.calls
        #expect(calls.isEmpty)  // Tool was NOT executed
        // Per design doc: replaced result is the exact string, no formatting
        #expect(replacedResultContent == "cached value from yesterday")
    }

    // MARK: - Test 4.5: Mixed decisions respected

    @Test("different decisions for different tools are respected")
    func mixedDecisionsRespected() async throws {
        let toolA = FakeTool<ConfigurableToolArgs, String>(name: "tool_a", onCall: { _ in .success("a") })
        let toolB = FakeTool<ConfigurableToolArgs, String>(name: "tool_b", onCall: { _ in .success("b") })
        let toolC = FakeTool<ConfigurableToolArgs, String>(name: "tool_c", onCall: { _ in .success("c") })

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCalls([
                    ToolCall(id: "tc-a", name: "tool_a", arguments: #"{"input":"a"}"#),
                    ToolCall(id: "tc-b", name: "tool_b", arguments: #"{"input":"b"}"#),
                    ToolCall(id: "tc-c", name: "tool_c", arguments: #"{"input":"c"}"#),
                ])
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(
            model: model,
            tools: [toolA, toolB, toolC]
        )

        for try await node in agent.iter("Use all") {
            if case .beforeTools(let ctx) = node {
                for pending in ctx.pendingCalls {
                    switch pending.call.name {
                    case "tool_a":
                        ctx.approve(pending.call)
                    case "tool_b":
                        ctx.deny(pending.call, message: "denied")
                    case "tool_c":
                        ctx.replace(pending.call, withResult: "replaced")
                    default:
                        break
                    }
                }
            }
        }

        let aCalls = await toolA.calls
        let bCalls = await toolB.calls
        let cCalls = await toolC.calls

        #expect(aCalls.count == 1)  // Approved - executed
        #expect(bCalls.isEmpty)     // Denied - not executed
        #expect(cCalls.isEmpty)     // Replaced - not executed
    }

    // MARK: - Test 4.6: All tools denied

    @Test("all tools denied sends denial messages to model")
    func allToolsDenied() async throws {
        let toolA = ConfigurableTool.succeeding("a", name: "tool_a")
        let toolB = ConfigurableTool.succeeding("b", name: "tool_b")
        let toolC = ConfigurableTool.succeeding("c", name: "tool_c")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCalls([
                    ToolCall(id: "tc-a", name: "tool_a", arguments: #"{"input":"a"}"#),
                    ToolCall(id: "tc-b", name: "tool_b", arguments: #"{"input":"b"}"#),
                    ToolCall(id: "tc-c", name: "tool_c", arguments: #"{"input":"c"}"#),
                ])
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(
            model: model,
            tools: [toolA, toolB, toolC]
        )

        var afterToolsResultCount: Int?
        for try await node in agent.iter("Use all") {
            if case .beforeTools(let ctx) = node {
                for pending in ctx.pendingCalls {
                    ctx.deny(pending.call, message: "all denied")
                }
            }
            if case .afterTools(let ctx) = node {
                afterToolsResultCount = ctx.results.count
            }
        }

        #expect(afterToolsResultCount == 3)
    }

    // MARK: - Test 4.7: All tools replaced

    @Test("all tools replaced uses synthetic results")
    func allToolsReplaced() async throws {
        let toolA = ConfigurableTool.succeeding("a", name: "tool_a")
        let toolB = ConfigurableTool.succeeding("b", name: "tool_b")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCalls([
                    ToolCall(id: "tc-a", name: "tool_a", arguments: #"{"input":"a"}"#),
                    ToolCall(id: "tc-b", name: "tool_b", arguments: #"{"input":"b"}"#),
                ])
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(
            model: model,
            tools: [toolA, toolB]
        )

        var results: [ToolCallResult] = []
        for try await node in agent.iter("Use all") {
            if case .beforeTools(let ctx) = node {
                for pending in ctx.pendingCalls {
                    ctx.replace(pending.call, withResult: "replaced_\(pending.call.name)")
                }
            }
            if case .afterTools(let ctx) = node {
                results = ctx.results
            }
        }

        #expect(results.count == 2)

        // Build expected values map: tool name -> expected replacement value
        let expectedValues = [
            "tool_a": "replaced_tool_a",
            "tool_b": "replaced_tool_b"
        ]

        for result in results {
            let toolName = result.call.name
            let expectedValue = expectedValues[toolName]!

            // Per design doc: replaced tools use .replaced case
            if case .replaced(let value) = result.result {
                #expect(value == expectedValue, "Expected exact replacement value for \(toolName)")
            } else {
                // Fallback: check output property (handles any result type)
                let output = result.output
                #expect(output == expectedValue, "Expected replaced result '\(expectedValue)', got: \(result.result)")
            }
        }
    }

    // MARK: - Test 4.8: Pending calls shows requiresApproval flag

    @Test("pendingCalls exposes requiresApproval flag from tool definition")
    func pendingCallsShowsRequiresApprovalFlag() async throws {
        let normalTool = ConfigurableTool.succeeding("ok", name: "normal")
        let sensitiveTool = ConfigurableTool.succeeding("ok", name: "sensitive")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCalls([
                    ToolCall(id: "tc-normal", name: "normal", arguments: #"{"input":"a"}"#),
                    ToolCall(id: "tc-sensitive", name: "sensitive", arguments: #"{"input":"b"}"#),
                ])
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(
            model: model,
            tools: [
                normalTool,
                ApprovalRequired(sensitiveTool),
            ]
        )

        var normalRequiresApproval: Bool?
        var sensitiveRequiresApproval: Bool?

        for try await node in agent.iter("Use both") {
            if case .beforeTools(let ctx) = node {
                for pending in ctx.pendingCalls {
                    switch pending.call.name {
                    case "normal":
                        normalRequiresApproval = pending.requiresApproval
                    case "sensitive":
                        sensitiveRequiresApproval = pending.requiresApproval
                    default:
                        break
                    }
                }
            }
        }

        #expect(normalRequiresApproval == false)
        #expect(sensitiveRequiresApproval == true)
    }

    // MARK: - Test 4.9: requiresApproval flag is informational only in iter()

    @Test("requiresApproval flag doesn't auto-deny in iter()")
    func requiresApprovalFlagIsInformationalOnly() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "sensitive",
            onCall: { _ in .success("executed") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "sensitive",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(
            model: model,
            tools: [ApprovalRequired(tool)]
        )

        for try await _ in agent.iter("Use tool") {
            // Don't call deny() - just let it execute
        }

        let calls = await tool.calls
        #expect(calls.count == 1)  // Tool executed despite requiresApproval=true
    }

    // MARK: - Test 4.10: Decision persists in state.phase

    @Test("decisions are stored in state.phase for serialization")
    func decisionPersistsInStatePhase() async throws {
        let tool = ConfigurableTool.succeeding("ok", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(model: model, tools: [tool])

        var capturedDecision: PendingToolDecision.Decision?
        for try await node in agent.iter("Use tool") {
            if case .beforeTools(let ctx) = node {
                ctx.deny(ctx.pendingCalls[0].call, message: "denied")

                // Check state reflects decision
                guard case .beforeTools(let calls) = ctx.state.phase else {
                    Issue.record("Expected beforeTools phase")
                    return
                }
                capturedDecision = calls[0].decision
            }
        }

        #expect(capturedDecision == .denied("denied"))
    }

    // MARK: - Test 4.11: Denied tool message format

    @Test("denied tool has consistent message format")
    func deniedToolMessageFormat() async throws {
        let tool = ConfigurableTool.succeeding("ok", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(model: model, tools: [tool])

        var resultOutput: String?
        for try await node in agent.iter("Use tool") {
            if case .beforeTools(let ctx) = node {
                ctx.deny(ctx.pendingCalls[0].call, message: "User said no")
            }
            if case .afterTools(let ctx) = node {
                // Per design doc: use the output property for consistent formatting
                resultOutput = ctx.results.first?.output
            }
        }

        // Per design doc (line 1878): Format is "Tool denied: {message}"
        #expect(resultOutput == "Tool denied: User said no")
    }

    // MARK: - Test 4.12: Replaced tool uses exact result

    @Test("replacement uses exact string without modification")
    func replacedToolUsesExactResult() async throws {
        let tool = ConfigurableTool.succeeding("ok", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(model: model, tools: [tool])

        let specialChars = "Custom result with special chars: <>&\"'"
        var resultOutput: String?
        for try await node in agent.iter("Use tool") {
            if case .beforeTools(let ctx) = node {
                ctx.replace(ctx.pendingCalls[0].call, withResult: specialChars)
            }
            if case .afterTools(let ctx) = node {
                // Per design doc: use output property for consistent access
                resultOutput = ctx.results.first?.output
            }
        }

        // Per design doc: replaced results are returned as-is without formatting
        #expect(resultOutput == specialChars)
    }

    // MARK: - Test 4.13: Multiple approvals on same call are idempotent

    @Test("calling approve multiple times on same call is idempotent")
    func multipleApprovalsIdempotent() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "my_tool",
            onCall: { _ in .success("executed") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(model: model, tools: [tool])

        for try await node in agent.iter("Use tool") {
            if case .beforeTools(let ctx) = node {
                // Call approve multiple times
                ctx.approve(ctx.pendingCalls[0].call)
                ctx.approve(ctx.pendingCalls[0].call)
                ctx.approve(ctx.pendingCalls[0].call)
            }
        }

        let calls = await tool.calls
        #expect(calls.count == 1)  // Tool executed only once
    }
}
