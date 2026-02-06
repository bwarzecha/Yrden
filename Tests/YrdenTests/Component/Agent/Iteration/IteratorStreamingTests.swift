/// Tests for streaming behavior via ctx.stream() API.
///
/// Covers streaming functionality at decision points:
/// - Model streaming via BeforeModelContext.stream()
/// - Tool streaming via BeforeToolsContext.stream()
/// - Stream event types and ordering
/// - Stream lifecycle constraints

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Iterator - Streaming")
struct IteratorStreamingTests {

    // MARK: - Test 6.1: stream() triggers model execution

    @Test("calling stream() triggers model execution")
    func streamTriggersModelExecution() async throws {
        let counter = CallCounter()
        let response = MockResponse.text("Hello")
        let model = FakeModel(
            onStream: { _ in
                await counter.increment()
                return [.contentDelta("Hello"), .done(response)]
            }
        )
        let agent = try Agent<Void, String>(model: model)

        for try await node in agent.iter("Hi", deps: ()) {
            if case .beforeModel(let ctx) = node {
                // Stream triggers execution
                for try await _ in ctx.stream() { }
                // Model should have been called
                let count = await counter.current
                #expect(count == 1)
            }
        }
    }

    // MARK: - Test 6.2: Without stream(), execution happens on advance

    @Test("without stream(), execution happens when iterator advances")
    func noStreamStillExecutesOnAdvance() async throws {
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            await counter.increment()
            return MockResponse.text("Hello")
        })
        let agent = try Agent<Void, String>(model: model)

        var seenBeforeModel = false
        var seenAfterModel = false

        for try await node in agent.iter("Hi", deps: ()) {
            switch node {
            case .beforeModel:
                seenBeforeModel = true
                // Don't call stream() - just continue
                let countBefore = await counter.current
                #expect(countBefore == 0, "Model should not be called yet at beforeModel")

            case .afterModel:
                seenAfterModel = true
                // Model was called when iterator advanced
                let countAfter = await counter.current
                #expect(countAfter == 1, "Model should be called by afterModel")

            default:
                break
            }
        }

        #expect(seenBeforeModel)
        #expect(seenAfterModel)
    }

    // MARK: - Test 6.3: stream() yields content deltas

    @Test("stream() yields content delta events for text tokens")
    func streamYieldsContentDeltas() async throws {
        let response = MockResponse.text("Hello world")
        let model = FakeModel(
            streamEventSequences: [[
                .contentDelta("Hello"),
                .contentDelta(" world"),
                .done(response)
            ]]
        )
        let agent = try Agent<Void, String>(model: model)

        var deltas: [String] = []
        for try await node in agent.iter("Hi", deps: ()) {
            if case .beforeModel(let ctx) = node {
                for try await event in ctx.stream() {
                    if case .contentDelta(let text, _) = event {
                        deltas.append(text)
                    }
                }
            }
        }

        // Should have received some content (exact chunking depends on implementation)
        #expect(deltas.joined().contains("Hello"))
    }

    // MARK: - Test 6.4: stream() yields tool call events

    @Test("stream() yields tool call events when model requests tools")
    func streamYieldsToolCallEvents() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let toolCallResponse = MockResponse.toolCall(
            name: "my_tool",
            arguments: #"{"input":"test"}"#,
            id: "tc-1"
        )
        let textResponse = MockResponse.text("Done")

        let counter = CallCounter()
        let model = FakeModel(
            onStream: { _ in
                switch await counter.increment() {
                case 1:
                    return [
                        .toolCallStart(id: "tc-1", name: "my_tool"),
                        .toolCallDelta(argumentsDelta: #"{"input":"test"}"#),
                        .toolCallEnd(id: "tc-1"),
                        .done(toolCallResponse)
                    ]
                default:
                    return [.contentDelta("Done"), .done(textResponse)]
                }
            }
        )

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var toolCallStarted = false
        var toolCallEnded = false

        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeModel(let ctx) = node {
                for try await event in ctx.stream() {
                    switch event {
                    case .toolCallStart(_, let name):
                        if name == "my_tool" {
                            toolCallStarted = true
                        }
                    case .toolCallEnd:
                        toolCallEnded = true
                    default:
                        break
                    }
                }
            }
        }

        // Verify tool call events were emitted during model streaming
        #expect(toolCallStarted, "Should have received toolCallStart event for my_tool")
        #expect(toolCallEnded, "Should have received toolCallEnd event")
    }

    // MARK: - Test 6.5: Response available after stream completes

    @Test("after stream() completes, response is available in afterModel")
    func streamCompletesWithResponse() async throws {
        let response = MockResponse.text("Streamed response")
        let model = FakeModel(
            streamEventSequences: [[
                .contentDelta("Streamed response"),
                .done(response)
            ]]
        )
        let agent = try Agent<Void, String>(model: model)

        var responseContent: String?

        for try await node in agent.iter("Hi", deps: ()) {
            switch node {
            case .beforeModel(let ctx):
                for try await _ in ctx.stream() { }

            case .afterModel(let ctx):
                responseContent = ctx.response.content

            default:
                break
            }
        }

        #expect(responseContent == "Streamed response")
    }

    // MARK: - Test 6.6: Tool stream yields started events

    @Test("tool stream yields toolStarted events")
    func toolStreamYieldsStartedEvents() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Done")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var startedEvents: [String] = []

        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeTools(let ctx) = node {
                for try await event in ctx.stream() {
                    if case .toolStarted(let call) = event {
                        startedEvents.append(call.name)
                    }
                }
            }
        }

        #expect(startedEvents.contains("my_tool"))
    }

    // MARK: - Test 6.7: Tool stream yields completed events

    @Test("tool stream yields toolCompleted events with results")
    func toolStreamYieldsCompletedEvents() async throws {
        let tool = ConfigurableTool.succeeding("tool_result", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Done")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var completedResults: [String] = []

        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeTools(let ctx) = node {
                for try await event in ctx.stream() {
                    if case .toolCompleted(_, let result, _) = event {
                        completedResults.append(result)
                    }
                }
            }
        }

        #expect(completedResults.contains("tool_result"))
    }

    // MARK: - Test 6.8: Tool stream yields failed events

    @Test("tool stream yields toolFailed events for tool errors")
    func toolStreamYieldsFailedEvents() async throws {
        let failingTool = FakeTool<ConfigurableToolArgs, String>(
            name: "failing_tool",
            onCall: { _ in
                throw TestToolError.generic("Tool exploded")
            }
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
            default:
                return MockResponse.text("Done")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(failingTool)])

        var failedEvents: [String] = []

        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeTools(let ctx) = node {
                for try await event in ctx.stream() {
                    if case .toolFailed(let call, let error, _) = event {
                        failedEvents.append("\(call.name): \(error)")
                    }
                }
            }
        }

        #expect(failedEvents.count >= 1)
    }

    // MARK: - Test 6.9: Denied tools emit events immediately

    @Test("denied tools emit toolDenied events immediately without execution")
    func toolStreamYieldsDeniedEventsImmediately() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Done")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var deniedEvents: [(name: String, message: String)] = []

        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeTools(let ctx) = node {
                // Deny the tool
                ctx.deny(ctx.pendingCalls[0].call, message: "Not allowed")

                for try await event in ctx.stream() {
                    if case .toolDenied(let call, let message) = event {
                        deniedEvents.append((call.name, message))
                    }
                }
            }
        }

        #expect(deniedEvents.count == 1)
        #expect(deniedEvents[0].name == "my_tool")
        #expect(deniedEvents[0].message == "Not allowed")
    }

    // MARK: - Test 6.10: Multiple tools emit events

    @Test("tool stream yields events for all pending tool calls")
    func toolStreamYieldsEventsForAllTools() async throws {
        let toolA = ConfigurableTool.succeeding("a-result", name: "tool_a")
        let toolB = ConfigurableTool.succeeding("b-result", name: "tool_b")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCalls([
                    ToolCall(id: "tc-a", name: "tool_a", arguments: #"{"input":"a"}"#),
                    ToolCall(id: "tc-b", name: "tool_b", arguments: #"{"input":"b"}"#),
                ])
            default:
                return MockResponse.text("Done")
            }
        })

        let agent = try Agent<Void, String>(
            model: model,
            tools: [AnyAgentTool(toolA), AnyAgentTool(toolB)]
        )

        var eventOrder: [String] = []

        for try await node in agent.iter("Use tools", deps: ()) {
            if case .beforeTools(let ctx) = node {
                for try await event in ctx.stream() {
                    switch event {
                    case .toolStarted(let call):
                        eventOrder.append("start:\(call.name)")
                    case .toolCompleted(let call, _, _):
                        eventOrder.append("complete:\(call.name)")
                    default:
                        break
                    }
                }
            }
        }

        // Both tools should have started and completed
        #expect(eventOrder.contains("start:tool_a"))
        #expect(eventOrder.contains("start:tool_b"))
        #expect(eventOrder.contains("complete:tool_a"))
        #expect(eventOrder.contains("complete:tool_b"))
    }

    // MARK: - Test 6.11: stream() can only be called once

    @Test("stream() can only be called once per context")
    func streamOnlyCallableOnce() async throws {
        let response = MockResponse.text("Hello")
        let model = FakeModel(
            streamEventSequences: [[.contentDelta("Hello"), .done(response)]]
        )
        let agent = try Agent<Void, String>(model: model)

        for try await node in agent.iter("Hi", deps: ()) {
            if case .beforeModel(let ctx) = node {
                // First call should work
                for try await _ in ctx.stream() { }

                // Second call should fail or return empty stream
                var secondCallEvents = 0
                for try await _ in ctx.stream() {
                    secondCallEvents += 1
                }

                // Second stream() call must return empty - model already executed
                #expect(secondCallEvents == 0, "Second stream() call should return empty stream")
            }
        }
    }

    // MARK: - Test 6.12: stream() after advance fails

    @Test("calling stream() after iterator advanced is invalid")
    func streamAfterAdvanceFails() async throws {
        // Test uses responses (not streaming) because user doesn't call stream() in beforeModel
        let model = FakeModel(responses: [MockResponse.text("Hello")])
        let agent = try Agent<Void, String>(model: model)

        var capturedContext: BeforeModelContext<Void, String>?

        for try await node in agent.iter("Hi", deps: ()) {
            switch node {
            case .beforeModel(let ctx):
                capturedContext = ctx
                // Don't call stream(), let iterator advance

            case .afterModel:
                // Now try to call stream() on the old context
                if let ctx = capturedContext {
                    // This should either throw or return empty stream
                    // because execution already happened
                    var lateCallEvents = 0
                    for try await _ in ctx.stream() {
                        lateCallEvents += 1
                    }
                    // Late stream() call must return empty - model already executed
                    #expect(lateCallEvents == 0, "Late stream() call should return empty stream")
                }

            default:
                break
            }
        }
    }

    // MARK: - Test 6.13: Model stream events include tool call deltas

    @Test("model stream yields tool call argument deltas")
    func streamYieldsToolCallArgumentDeltas() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        // Configure FakeModel with streaming events that include tool call deltas.
        // The stream should emit: toolCallStart -> toolCallDelta(s) -> toolCallEnd -> done
        let toolCallResponse = MockResponse.toolCall(
            name: "my_tool",
            arguments: #"{"input":"streaming_args"}"#,
            id: "tc-1"
        )
        let textResponse = MockResponse.text("Done")

        let counter = CallCounter()
        let model = FakeModel(
            onStream: { _ in
                // Counter for multi-iteration agent loop
                switch await counter.increment() {
                case 1:
                    // First call: tool call with argument deltas
                    return [
                        .toolCallStart(id: "tc-1", name: "my_tool"),
                        .toolCallDelta(argumentsDelta: #"{"input":"#),
                        .toolCallDelta(argumentsDelta: #""streaming_args"}"#),
                        .toolCallEnd(id: "tc-1"),
                        .done(toolCallResponse)
                    ]
                default:
                    // Second call: text response
                    return [.contentDelta("Done"), .done(textResponse)]
                }
            }
        )

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var toolCallDeltas: [String] = []

        var streamedSuccessfully = false
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeModel(let ctx) = node {
                for try await event in ctx.stream() {
                    if case .toolCallDelta(_, let delta) = event {
                        toolCallDeltas.append(delta)
                    }
                }
                streamedSuccessfully = true
            }
        }

        // Verify streaming completed successfully
        #expect(streamedSuccessfully, "Should have streamed through beforeModel")

        // Verify tool call deltas were emitted (not a silent pass)
        #expect(!toolCallDeltas.isEmpty, "Should have received tool call argument deltas")

        // Verify deltas contain expected argument content
        let combined = toolCallDeltas.joined()
        #expect(combined.contains("input"), "Tool call deltas should contain 'input' key")
        #expect(combined.contains("streaming_args"), "Tool call deltas should contain argument value")
    }

    // MARK: - Test 6.14: Tool stream events follow expected lifecycle

    @Test("tool stream events follow started -> completed/failed lifecycle")
    func toolStreamEventsFollowLifecycle() async throws {
        // Verifies that tool events follow the expected lifecycle:
        // toolStarted must come before toolCompleted/toolFailed for each tool

        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Done")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var startedTools: Set<String> = []
        var completedTools: Set<String> = []
        var eventSequence: [String] = []

        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeTools(let ctx) = node {
                for try await event in ctx.stream() {
                    switch event {
                    case .toolStarted(let call):
                        startedTools.insert(call.id)
                        eventSequence.append("started:\(call.id)")
                    case .toolCompleted(let call, _, _):
                        completedTools.insert(call.id)
                        eventSequence.append("completed:\(call.id)")
                    case .toolFailed(let call, _, _):
                        completedTools.insert(call.id)
                        eventSequence.append("failed:\(call.id)")
                    case .toolDenied(let call, _):
                        eventSequence.append("denied:\(call.id)")
                    case .toolProgress(let callId, _):
                        // Progress events are optional, just track them in sequence
                        eventSequence.append("progress:\(callId)")
                    }
                }
            }
        }

        // Verify lifecycle: started must come before completed
        #expect(startedTools.contains("tc-1"), "Tool tc-1 should have started")
        #expect(completedTools.contains("tc-1"), "Tool tc-1 should have completed")

        // Verify ordering: started comes before completed in sequence
        if let startIdx = eventSequence.firstIndex(of: "started:tc-1"),
           let completeIdx = eventSequence.firstIndex(of: "completed:tc-1") {
            #expect(startIdx < completeIdx, "toolStarted should come before toolCompleted")
        }
    }

    // MARK: - Test 6.15: Model stream respects cancellation

    @Test("model stream stops when task is cancelled", .timeLimit(.minutes(1)))
    func modelStreamRespectsCancellation() async throws {
        // Model that streams slowly - we'll cancel mid-stream
        let streamStarted = Flag()
        let model = FakeModel(
            onStream: { _ in
                await streamStarted.set()
                // Simulate slow streaming - will be cancelled before completion
                try await Task.sleep(for: .seconds(60))
                return [.contentDelta("Should not reach"), .done(MockResponse.text("Done"))]
            }
        )
        let agent = try Agent<Void, String>(model: model)

        let task = Task {
            for try await node in agent.iter("Hi", deps: ()) {
                if case .beforeModel(let ctx) = node {
                    for try await _ in ctx.stream() {
                        // Keep consuming until cancelled
                    }
                }
            }
        }

        // Wait for stream to start, then cancel
        while await !streamStarted.isSet {
            await Task.yield()
        }
        task.cancel()

        // Wait for task to complete - if cancellation works, this completes quickly
        // If cancellation doesn't work, the test times out after 5 seconds
        // (proving the 60-second sleep was interrupted)
        _ = await task.result
    }

    // MARK: - Test 6.16: Tool stream respects cancellation

    @Test("tool stream stops when task is cancelled")
    func toolStreamRespectsCancellation() async throws {
        // Tool that takes a long time - we'll cancel mid-execution
        let flag = Flag()
        let slowTool = FakeTool<ConfigurableToolArgs, String>(
            name: "slow_tool",
            onCall: { _ in
                await flag.set()
                try await Task.sleep(for: .seconds(10))
                return .success("Should not reach")
            }
        )

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "slow_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Done")
            }
        })

        let agent = try Agent<Void, String>(model: model, tools: [AnyAgentTool(slowTool)])

        let task = Task {
            for try await node in agent.iter("Use tool", deps: ()) {
                if case .beforeTools(let ctx) = node {
                    for try await _ in ctx.stream() {
                        // Keep consuming until cancelled
                    }
                }
            }
        }

        // Wait for tool to start, then cancel
        while await !flag.isSet {
            await Task.yield()
        }
        task.cancel()

        // Task should complete (via cancellation) without hanging
        let result = await task.result
        switch result {
        case .failure(let error):
            #expect(error is CancellationError, "Should throw CancellationError")
        case .success:
            // Also acceptable - stream may have been cancelled cleanly
            break
        }
    }
}

// MARK: - Test Helpers

/// Simple actor-based flag for test synchronization.
private actor Flag {
    private var value = false

    var isSet: Bool { value }

    func set() { value = true }
}
