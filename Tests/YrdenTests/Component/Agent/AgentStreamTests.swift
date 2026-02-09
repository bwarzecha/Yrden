/// Tests for Agent streaming via runStream().
///
/// Covers: content delta streaming, thinking/reasoning delta streaming,
/// tool call event streaming, tool error during streaming, and provider
/// error during streaming.
///
/// Uses FakeModel's stream path (onStream / streamEventSequences).

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Agent - Streaming")
struct AgentStreamTests {

    @Test("runStream yields content deltas and finished event with output")
    func runStreamYieldsContentDeltasAndFinished() async throws {
        let response = MockResponse.text("Hello world")
        let model = FakeModel(
            streamEventSequences: [[
                .contentDelta("Hello"),
                .contentDelta(" world"),
                .done(response)
            ]]
        )

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        var deltas: [String] = []
        var finishedRun: AgentRun<String>?

        for try await event in agent.runStream("Hi") {
            switch event {
            case .contentDelta(let text, _):
                deltas.append(text)
            case .finished(let run):
                finishedRun = run
            default:
                break
            }
        }

        #expect(deltas == ["Hello", " world"])
        #expect(finishedRun != nil)
        #expect(finishedRun?.output == "Hello world")
        #expect(finishedRun?.isCompleted == true)
    }

    @Test("runStream yields tool call events and tool result events")
    func runStreamYieldsToolCallAndResultEvents() async throws {
        let toolCallResponse = CompletionResponse(
            content: nil,
            refusal: nil,
            toolCalls: [ToolCall(id: "tc-1", name: "search", arguments: #"{"input":"swift"}"#)],
            stopReason: .toolUse,
            usage: MockResponse.defaultUsage
        )

        let finalResponse = MockResponse.text("Found results")

        let model = FakeModel(
            streamEventSequences: [
                // First stream: model calls a tool
                [
                    .toolCallStart(id: "tc-1", name: "search"),
                    .toolCallDelta(argumentsDelta:#"{"input":"swift"}"#),
                    .toolCallEnd(id: "tc-1"),
                    .done(toolCallResponse)
                ],
                // Second stream: model responds with text
                [
                    .contentDelta("Found results"),
                    .done(finalResponse)
                ]
            ]
        )

        let tool = ConfigurableTool.succeeding("3 results for swift", name: "search")

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool]
        )

        var toolStarts: [(id: String, name: String)] = []
        var toolDeltas: [(id: String, delta: String)] = []
        var toolEnds: [String] = []
        var toolResults: [(id: String, result: String)] = []
        var contentDeltas: [String] = []
        var finishedRun: AgentRun<String>?

        for try await event in agent.runStream("Search for swift") {
            switch event {
            case .contentDelta(let text, _):
                contentDeltas.append(text)
            case .toolCallStart(let id, let name):
                toolStarts.append((id: id, name: name))
            case .toolCallDelta(let id, let delta):
                toolDeltas.append((id: id, delta: delta))
            case .toolCallEnd(let id):
                toolEnds.append(id)
            case .toolResult(let id, let result):
                toolResults.append((id: id, result: result))
            case .backgroundTaskCompleted:
                break
            case .finished(let run):
                finishedRun = run
            case .usage:
                break
            }
        }

        // Tool call lifecycle events
        #expect(toolStarts.count == 1)
        #expect(toolStarts[0].name == "search")
        #expect(toolStarts[0].id == "tc-1")
        #expect(toolEnds == ["tc-1"])

        // Tool execution result flowed back
        #expect(toolResults.count == 1)
        #expect(toolResults[0].id == "tc-1")
        #expect(toolResults[0].result.contains("3 results"))

        // Final content
        #expect(contentDeltas == ["Found results"])
        #expect(finishedRun?.output == "Found results")
    }

    @Test("runStream with tool error sends error result and model recovers")
    func runStreamToolErrorSendsErrorResultToModel() async throws {
        let toolCallResponse = CompletionResponse(
            content: nil,
            refusal: nil,
            toolCalls: [ToolCall(id: "tc-1", name: "crashy", arguments: #"{"input":"go"}"#)],
            stopReason: .toolUse,
            usage: MockResponse.defaultUsage
        )
        let recoveryResponse = MockResponse.text("Recovered from error")

        let model = FakeModel(
            streamEventSequences: [
                [
                    .toolCallStart(id: "tc-1", name: "crashy"),
                    .toolCallDelta(argumentsDelta:#"{"input":"go"}"#),
                    .toolCallEnd(id: "tc-1"),
                    .done(toolCallResponse)
                ],
                [
                    .contentDelta("Recovered from error"),
                    .done(recoveryResponse)
                ]
            ]
        )

        let tool = ConfigurableTool.throwing(
            TestToolError.crashed("boom"),
            name: "crashy"
        )

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool]
        )

        var toolResults: [(id: String, result: String)] = []
        var finishedRun: AgentRun<String>?

        for try await event in agent.runStream("Do it") {
            switch event {
            case .toolResult(let id, let result):
                toolResults.append((id: id, result: result))
            case .finished(let run):
                finishedRun = run
            default:
                break
            }
        }

        // Tool error was sent as result (not propagated)
        #expect(toolResults.count == 1)
        #expect(toolResults[0].id == "tc-1")

        // Agent recovered
        #expect(finishedRun?.output == "Recovered from error")
    }

    // MARK: - Thinking/Reasoning Streaming

    @Test("runStream yields thinking deltas with kind: .thinking before text deltas")
    func runStreamYieldsThinkingDeltas() async throws {
        let response = MockResponse.withThinking(
            thinking: "Let me analyze this step by step",
            text: "The answer is 42"
        )
        let model = FakeModel(
            streamEventSequences: [[
                .contentDelta("Let me analyze", kind: .thinking),
                .contentDelta(" this step by step", kind: .thinking),
                .contentDelta("The answer"),
                .contentDelta(" is 42"),
                .done(response)
            ]]
        )

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        var thinkingDeltas: [String] = []
        var textDeltas: [String] = []
        var finishedRun: AgentRun<String>?

        for try await event in agent.runStream("What is the meaning?") {
            switch event {
            case .contentDelta(let text, let kind):
                switch kind {
                case .thinking: thinkingDeltas.append(text)
                case .text: textDeltas.append(text)
                }
            case .finished(let run):
                finishedRun = run
            default:
                break
            }
        }

        #expect(thinkingDeltas == ["Let me analyze", " this step by step"])
        #expect(textDeltas == ["The answer", " is 42"])
        #expect(finishedRun?.output == "The answer is 42")
    }

    @Test("runStream thinking blocks preserved in messages for cache compatibility")
    func runStreamPreservesThinkingBlocksInMessages() async throws {
        let thinkingToolCallResponse = MockResponse.withThinkingAndToolCall(
            thinking: "I need to search for this",
            toolName: "search",
            toolArguments: #"{"input":"swift"}"#,
            toolId: "tc-1"
        )
        let finalResponse = MockResponse.withThinking(
            thinking: "Found the results",
            text: "Here are the results"
        )

        let counter = CallCounter()
        let model = FakeModel(
            onStream: { request in
                switch await counter.increment() {
                case 1:
                    return [
                        .contentDelta("I need to search for this", kind: .thinking),
                        .toolCallStart(id: "tc-1", name: "search"),
                        .toolCallDelta(argumentsDelta: #"{"input":"swift"}"#),
                        .toolCallEnd(id: "tc-1"),
                        .done(thinkingToolCallResponse)
                    ]
                default:
                    // Verify thinking blocks were preserved in the request
                    let assistantMessages = request.messages.filter {
                        if case .assistant = $0 { return true }
                        return false
                    }
                    // The assistant message from turn 1 should contain thinking
                    if let firstAssistant = assistantMessages.first,
                       let blocks = firstAssistant.assistantBlocks {
                        let hasThinking = blocks.contains { $0.isThinking }
                        if !hasThinking {
                            throw LLMError.serverError("Thinking blocks not preserved in messages")
                        }
                    }
                    return [
                        .contentDelta("Found the results", kind: .thinking),
                        .contentDelta("Here are the results"),
                        .done(finalResponse)
                    ]
                }
            }
        )

        let tool = ConfigurableTool.succeeding("3 results", name: "search")
        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool]
        )

        var finishedRun: AgentRun<String>?
        for try await event in agent.runStream("Find swift info") {
            if case .finished(let run) = event {
                finishedRun = run
            }
        }

        #expect(finishedRun?.output == "Here are the results")
    }

    @Test("runStream with filtered thinking passes through opaquely")
    func runStreamFilteredThinkingPassesThrough() async throws {
        let response = MockResponse.withFilteredThinking(text: "I can help with that")
        let model = FakeModel(
            streamEventSequences: [[
                .contentDelta("I can help with that"),
                .done(response)
            ]]
        )

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        var finishedRun: AgentRun<String>?
        for try await event in agent.runStream("Hello") {
            if case .finished(let run) = event {
                finishedRun = run
            }
        }

        #expect(finishedRun?.output == "I can help with that")

        // Verify the last assistant message contains a filtered thinking block
        let assistantBlocks = finishedRun?.messages.last(where: {
            if case .assistant = $0 { return true }
            return false
        })?.assistantBlocks ?? []
        let thinkingBlocks = assistantBlocks.compactMap { $0.thinkingBlock }
        #expect(thinkingBlocks.count == 1)
        #expect(thinkingBlocks.first?.isFiltered == true)
    }

    @Test("runStream thinking-only deltas still produce output from text blocks")
    func runStreamThinkingOnlyDeltasDoNotContaminateOutput() async throws {
        let response = MockResponse.withThinking(
            thinking: "Deep analysis here",
            text: "Final answer"
        )
        let model = FakeModel(
            streamEventSequences: [[
                .contentDelta("Deep analysis here", kind: .thinking),
                .contentDelta("Final answer", kind: .text),
                .done(response)
            ]]
        )

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        var allDeltas: [(text: String, kind: ContentKind)] = []
        var finishedRun: AgentRun<String>?

        for try await event in agent.runStream("Analyze") {
            switch event {
            case .contentDelta(let text, let kind):
                allDeltas.append((text, kind))
            case .finished(let run):
                finishedRun = run
            default:
                break
            }
        }

        // Thinking and text are both emitted
        #expect(allDeltas.count == 2)
        #expect(allDeltas[0].kind == .thinking)
        #expect(allDeltas[1].kind == .text)

        // Output is derived from text content only (not thinking)
        #expect(finishedRun?.output == "Final answer")

        // But thinking is accessible via the assistant message blocks
        let assistantBlocks = finishedRun?.messages.last(where: {
            if case .assistant = $0 { return true }
            return false
        })?.assistantBlocks ?? []
        let thinking = assistantBlocks.compactMap { $0.thinkingContent }.joined()
        #expect(thinking == "Deep analysis here")
    }

    @Test("runStream with redacted thinking preserves encrypted data through tool use round-trip")
    func runStreamRedactedThinkingPreservedThroughToolUse() async throws {
        let redactedProviderData = "encrypted-opaque-blob-abc123"
        let toolCallResponse = MockResponse.withFilteredThinkingAndToolCall(
            toolName: "search",
            toolArguments: #"{"input":"swift"}"#,
            toolId: "tc-1",
            providerData: redactedProviderData
        )
        let finalResponse = MockResponse.withFilteredThinking(
            text: "Here are the results",
            providerData: "encrypted-opaque-blob-def456"
        )

        let counter = CallCounter()
        let model = FakeModel(
            onStream: { request in
                switch await counter.increment() {
                case 1:
                    return [
                        .toolCallStart(id: "tc-1", name: "search"),
                        .toolCallDelta(argumentsDelta: #"{"input":"swift"}"#),
                        .toolCallEnd(id: "tc-1"),
                        .done(toolCallResponse)
                    ]
                default:
                    // Verify redacted thinking block was preserved in the request
                    let assistantMessages = request.messages.filter {
                        if case .assistant = $0 { return true }
                        return false
                    }
                    if let firstAssistant = assistantMessages.first,
                       let blocks = firstAssistant.assistantBlocks {
                        let thinkingBlocks = blocks.compactMap { $0.thinkingBlock }
                        // Must have a filtered thinking block with exact providerData
                        guard let thinking = thinkingBlocks.first,
                              thinking.isFiltered,
                              thinking.providerData == redactedProviderData else {
                            throw LLMError.serverError(
                                "Redacted thinking not preserved: \(thinkingBlocks)"
                            )
                        }
                    }
                    return [
                        .contentDelta("Here are the results"),
                        .done(finalResponse)
                    ]
                }
            }
        )

        let tool = ConfigurableTool.succeeding("3 results", name: "search")
        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool]
        )

        var finishedRun: AgentRun<String>?
        for try await event in agent.runStream("Find swift info") {
            if case .finished(let run) = event {
                finishedRun = run
            }
        }

        #expect(finishedRun?.output == "Here are the results")

        // Verify the final message also has filtered thinking
        let lastAssistantBlocks = finishedRun?.messages.last(where: {
            if case .assistant = $0 { return true }
            return false
        })?.assistantBlocks ?? []
        let filteredBlocks = lastAssistantBlocks.compactMap { $0.thinkingBlock }.filter { $0.isFiltered }
        #expect(filteredBlocks.count == 1)
        #expect(filteredBlocks.first?.providerData == "encrypted-opaque-blob-def456")
    }

    @Test("runStream with provider error throws through the stream")
    func runStreamProviderErrorThrowsThroughStream() async throws {
        let model = FakeModel(onStream: { _ in
            throw LLMError.serverError("Service unavailable (503)")
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        do {
            for try await _ in agent.runStream("Hello") {
                // consume stream
            }
            Issue.record("Expected LLMError.serverError")
        } catch let error as LLMError {
            guard case .serverError(let msg) = error else {
                Issue.record("Expected .serverError, got \(error)")
                return
            }
            #expect(msg.contains("503"))
        }
    }
}
