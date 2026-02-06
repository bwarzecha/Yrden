/// Tests for tool execution mechanics through the iterator.
///
/// Covers:
/// - Arguments parsing and passing
/// - Results flowing back to messages
/// - Failure handling (as results, not exceptions)
/// - Timeouts

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Iterator - Tool Execution")
struct IteratorToolExecutionTests {

    // MARK: - Test 3.1: Tool receives correct arguments

    @Test("tool receives correctly parsed arguments from model")
    func toolReceivesCorrectArguments() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "my_tool",
            onCall: { args in .success("got: \(args.input)") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"hello world"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        for try await _ in agent.iter("Use tool", deps: ()) { }
        let calls = await tool.calls

        #expect(calls.count == 1)
        #expect(calls[0].input == "hello world")
    }

    // MARK: - Test 3.2: Tool result added to messages after afterTools

    @Test("tool result is in message history after afterTools phase")
    func toolResultAddedToMessagesAfterAfterTools() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "my_tool",
            onCall: { args in .success("got: \(args.input)") }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"test"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var messagesAfterTools: [Message]?
        var iterationAfterTools: Int = -1
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeModel(let ctx) = node {
                if ctx.state.iteration > 0 {
                    messagesAfterTools = ctx.state.messages
                    iterationAfterTools = ctx.state.iteration
                }
            }
        }

        #expect(iterationAfterTools == 1)
        // Check that tool result is in the messages
        let hasToolResult = messagesAfterTools?.contains { message in
            if case .toolResults(let results) = message {
                return results.contains { $0.id == "tc-1" }
            }
            return false
        }
        #expect(hasToolResult == true)
    }

    // MARK: - Test 3.3: Tool result ID matches call ID

    @Test("tool result message uses exact same ID as tool call")
    func toolResultIDMatchesCallID() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "call-xyz-123"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var resultId: String?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeModel(let ctx) = node, ctx.state.iteration > 0 {
                for message in ctx.state.messages {
                    if case .toolResults(let results) = message {
                        resultId = results.first?.id
                    }
                }
            }
        }

        #expect(resultId == "call-xyz-123")
    }

    // MARK: - Test 3.4: Multiple tools all executed

    @Test("all tools in a batch are executed")
    func multipleToolsAllExecuted() async throws {
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

        let agent = try Agent<Void, String>(
            model: model,
            tools: [AnyAgentTool(toolA), AnyAgentTool(toolB), AnyAgentTool(toolC)]
        )

        for try await _ in agent.iter("Use all", deps: ()) { }

        let aCalls = await toolA.calls
        let bCalls = await toolB.calls
        let cCalls = await toolC.calls

        #expect(aCalls.count == 1)
        #expect(bCalls.count == 1)
        #expect(cCalls.count == 1)
    }

    // MARK: - Test 3.5: Tools execute in original order

    @Test("tool results maintain the original call order")
    func toolsExecuteInOriginalOrder() async throws {
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

        let agent = try Agent<Void, String>(
            model: model,
            tools: [AnyAgentTool(toolA), AnyAgentTool(toolB), AnyAgentTool(toolC)]
        )

        var resultOrder: [String] = []
        for try await node in agent.iter("Use all", deps: ()) {
            if case .afterTools(let ctx) = node {
                resultOrder = ctx.results.map { $0.call.name }
            }
        }

        #expect(resultOrder == ["tool_a", "tool_b", "tool_c"])
    }

    // MARK: - Test 3.6: Tool context has correct deps
    // NOTE: Requires custom tool that captures deps. Deferred for now as
    // the test infrastructure would need enhancement.

    // MARK: - Test 3.7: Tool exception becomes failure result

    @Test("tool exception becomes failure result, not thrown error")
    func toolExceptionBecomesFailureResult() async throws {
        struct MyToolError: Error {}

        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "failing_tool",
            onCall: { _ in throw MyToolError() }
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
                // Model should receive error in tool result
                return MockResponse.text("Acknowledged error")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        // Should NOT throw - tool errors are results, not exceptions
        var output: String?
        for try await node in agent.iter("Use failing tool", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }
        #expect(output == "Acknowledged error")
    }

    // MARK: - Test 3.8: Tool not found becomes failure result

    @Test("calling unknown tool returns failure result")
    func toolNotFoundBecomesFailureResult() async throws {
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "nonexistent_tool",
                    arguments: "{}",
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Tool not found acknowledged")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        // No tools registered!
        let agent = try Agent<Void, String>(model: model, tools: [])

        var output: String?
        for try await node in agent.iter("Use unknown tool", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output == "Tool not found acknowledged")
    }

    // MARK: - Test 3.9: Argument parsing error becomes failure result

    @Test("invalid JSON arguments become failure result")
    func argumentParsingErrorBecomesFailureResult() async throws {
        let tool = ConfigurableTool.succeeding("ok", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: "not valid json {{{",  // Invalid!
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Parse error acknowledged")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        // Should complete without throwing
        var output: String?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }
        #expect(output == "Parse error acknowledged")
    }

    // MARK: - Test 3.10: Tool timeout becomes failure result

    @Test("tool timeout becomes failure result")
    func toolTimeoutBecomesFailureResult() async throws {
        let slowTool = SlowTool(delay: .seconds(10), result: "finally")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "slow_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Timeout acknowledged")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<Void, String>(
            model: model,
            tools: [AnyAgentTool(slowTool)],
            toolTimeout: .milliseconds(10)  // 10ms timeout
        )

        var toolResult: ToolCallResult?
        for try await node in agent.iter("Use slow tool", deps: ()) {
            if case .afterTools(let ctx) = node {
                toolResult = ctx.results.first
            }
        }

        // Check that the result is a failure
        if case .failed = toolResult?.result {
            // Success - tool timed out
        } else {
            Issue.record("Expected failure result from timeout, got \(String(describing: toolResult?.result))")
        }
    }

    // MARK: - Test 3.11: Failure result sent to model as content

    @Test("failure result error message appears in tool_result content")
    func failureResultSentToModelAsContent() async throws {
        struct MyToolError: Error, LocalizedError {
            var errorDescription: String? { "Something went wrong" }
        }

        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "failing_tool",
            onCall: { _ in throw MyToolError() }
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
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var toolResultContent: String?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeModel(let ctx) = node, ctx.state.iteration > 0 {
                for message in ctx.state.messages {
                    if case .toolResults(let results) = message {
                        if let result = results.first(where: { $0.id == "tc-1" }) {
                            if case .error(let error) = result.output {
                                toolResultContent = error
                            }
                        }
                    }
                }
            }
        }

        // The error message should contain error information
        #expect(toolResultContent?.contains("wrong") == true || toolResultContent?.contains("Error") == true)
    }

    // MARK: - Test 3.12: Per-tool timeout respected
    // NOTE: Per-tool timeout configuration not yet implemented in AnyAgentTool

    // MARK: - Test 3.13: Engine default timeout used when no per-tool

    @Test("engine default timeout applies when tool has none")
    func engineDefaultTimeoutUsedWhenNoPerTool() async throws {
        let slowTool = SlowTool(delay: .seconds(10), result: "finally")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "slow_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<Void, String>(
            model: model,
            tools: [AnyAgentTool(slowTool)],  // No per-tool timeout
            toolTimeout: .milliseconds(10)  // Engine default
        )

        var toolResult: ToolCallResult?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .afterTools(let ctx) = node {
                toolResult = ctx.results.first
            }
        }

        // Should have timed out
        if case .failed = toolResult?.result {
            // Success
        } else {
            Issue.record("Expected timeout failure, got \(String(describing: toolResult?.result))")
        }
    }

    // MARK: - Test 3.14: No timeout allows long execution

    @Test("without timeout, long-running tools complete")
    func noTimeoutAllowsLongExecution() async throws {
        // Use a short delay that won't time out the test but completes quickly
        let slowTool = SlowTool(delay: .milliseconds(20), result: "completed")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "slow_tool",
                    arguments: #"{"input":"test"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<Void, String>(
            model: model,
            tools: [AnyAgentTool(slowTool)],
            toolTimeout: nil  // No timeout
        )

        var toolResult: ToolCallResult?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .afterTools(let ctx) = node {
                toolResult = ctx.results.first
            }
        }

        // Should have succeeded
        if case .success(let value) = toolResult?.result {
            #expect(value.contains("completed"))
        } else {
            Issue.record("Expected success result")
        }
    }

    // MARK: - Test 3.15: Tool receives correct call ID in context
    // NOTE: Requires checking AgentContext.toolCallID, need custom tool

    // MARK: - Test 3.16: Batch tools execute concurrently
    // NOTE: Testing concurrency is tricky, would need timing checks
}
