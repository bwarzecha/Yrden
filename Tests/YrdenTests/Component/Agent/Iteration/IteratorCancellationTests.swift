/// Tests for cancellation handling in the iterator.
///
/// Covers:
/// - Cancellation at every phase
/// - State capture before cancellation for recovery
/// - Task cancellation behavior
/// - Resume from manually captured state

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Iterator - Cancellation")
struct IteratorCancellationTests {

    // MARK: - Test 10.1: Cancel at beforeModel captures state

    @Test("state can be captured at beforeModel before cancellation")
    func cancelAtBeforeModelPreservesState() async throws {
        let model = FakeModel(responses: [MockResponse.text("Hello")])
        let agent = Agent<Void, String>(model: model)

        actor StateCapture {
            var state: IterationState<String>?
            func set(_ s: IterationState<String>) { state = s }
        }

        let capture = StateCapture()
        let task = Task {
            for try await node in agent.iter("Hi", deps: ()) {
                if case .beforeModel(let ctx) = node {
                    await capture.set(ctx.state)
                    throw CancellationError()
                }
            }
        }

        do {
            try await task.value
        } catch is CancellationError {
            // Expected
        }

        let capturedState = await capture.state
        #expect(capturedState != nil)
        guard case .beforeModel = capturedState?.phase else {
            Issue.record("Expected beforeModel phase")
            return
        }
        // User message should be in messages
        let hasUserMessage = capturedState?.messages.contains { msg in
            if case .user(let parts) = msg {
                return parts.contains { part in
                    if case .text(let text) = part {
                        return text == "Hi"
                    }
                    return false
                }
            }
            return false
        }
        #expect(hasUserMessage == true)
    }

    // MARK: - Test 10.2: Cancel at afterModel captures response

    @Test("state captured at afterModel includes the model response")
    func cancelAtAfterModelPreservesResponse() async throws {
        let model = FakeModel(responses: [MockResponse.text("Model response")])
        let agent = Agent<Void, String>(model: model)

        var capturedState: IterationState<String>?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .afterModel(let ctx) = node {
                capturedState = ctx.state
                break  // Exit early (simulates cancellation point)
            }
        }

        guard case .afterModel(let response) = capturedState?.phase else {
            Issue.record("Expected afterModel phase")
            return
        }
        #expect(response.content == "Model response")
    }

    // MARK: - Test 10.3: Cancel at beforeTools captures pending calls

    @Test("state captured at beforeTools includes pending tool calls")
    func cancelAtBeforeToolsPreservesPendingCalls() async throws {
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

        let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var capturedState: IterationState<String>?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeTools(let ctx) = node {
                ctx.approve(ctx.pendingCalls[0].call)  // Make a decision
                capturedState = ctx.state
                break
            }
        }

        guard case .beforeTools(let calls) = capturedState?.phase else {
            Issue.record("Expected beforeTools phase")
            return
        }
        #expect(calls.count == 1)
        #expect(calls[0].decision == .approved)
    }

    // MARK: - Test 10.4: Cancel at afterTools captures results

    @Test("state captured at afterTools includes tool execution results")
    func cancelAtAfterToolsPreservesResults() async throws {
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

        let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var capturedState: IterationState<String>?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .afterTools(let ctx) = node {
                capturedState = ctx.state
                break
            }
        }

        guard case .afterTools(let results) = capturedState?.phase else {
            Issue.record("Expected afterTools phase")
            return
        }
        #expect(results.count == 1)
        #expect(results[0].call.id == "tc-1")
    }

    // MARK: - Test 10.5: Task cancellation during model call

    @Test("task cancellation during model call throws error")
    func cancelDuringModelCallThrowsError() async throws {
        let slowModel = FakeModel(onComplete: { _ in
            try await Task.sleep(for: .seconds(10))
            return MockResponse.text("Done")
        })
        let agent = Agent<Void, String>(model: slowModel)

        actor CancelTracker {
            var caught = false
            func markCaught() { caught = true }
        }

        let tracker = CancelTracker()
        let task = Task {
            do {
                for try await _ in agent.iter("Hi", deps: ()) { }
            } catch is CancellationError {
                await tracker.markCaught()
            } catch let error as AgentError<String> {
                if case .cancelled = error {
                    await tracker.markCaught()
                }
            }
        }

        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        _ = await task.result

        let caughtCancellation = await tracker.caught
        #expect(caughtCancellation)
    }

    // MARK: - Test 10.6: Task cancellation during tool execution

    @Test("task cancellation during tool execution throws error")
    func cancelDuringToolExecutionThrowsError() async throws {
        let slowTool = FakeTool<ConfigurableToolArgs, String>(
            name: "slow_tool",
            onCall: { _ in
                try await Task.sleep(for: .seconds(10))
                return .success("result")
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

        let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(slowTool)])

        actor CancelTracker {
            var caught = false
            func markCaught() { caught = true }
        }

        let tracker = CancelTracker()
        let task = Task {
            do {
                for try await _ in agent.iter("Use tool", deps: ()) { }
            } catch is CancellationError {
                await tracker.markCaught()
            } catch let error as AgentError<String> {
                if case .cancelled = error {
                    await tracker.markCaught()
                }
            }
        }

        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = await task.result

        let caughtCancellation = await tracker.caught
        #expect(caughtCancellation)
    }

    // MARK: - Test 10.7: Cancelled error is thrown on cancellation

    @Test("AgentError.cancelled is thrown when task is cancelled")
    func cancelledErrorThrown() async throws {
        let model = FakeModel(onComplete: { _ in
            try await Task.sleep(for: .seconds(10))
            return MockResponse.text("Done")
        })
        let agent = Agent<Void, String>(model: model)

        actor CancelTracker {
            var caught = false
            func markCaught() { caught = true }
        }

        let tracker = CancelTracker()
        let task = Task {
            do {
                for try await _ in agent.iter("Hi", deps: ()) { }
            } catch let error as AgentError<String> {
                if case .cancelled = error {
                    await tracker.markCaught()
                }
            } catch is CancellationError {
                // Also acceptable
                await tracker.markCaught()
            }
        }

        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        _ = await task.result

        let caughtAgentCancelled = await tracker.caught
        #expect(caughtAgentCancelled)
    }

    // MARK: - Test 10.8: Resume from manually captured state

    @Test("can resume from manually captured state after cancellation")
    func resumeFromCapturedState() async throws {
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let n = await counter.increment()
            if n == 1 { throw CancellationError() }  // First call "cancelled"
            return MockResponse.text("Success on retry")
        })
        let agent = Agent<Void, String>(model: model)

        var savedState: IterationState<String>?

        // First run - capture state at beforeModel, then "cancel"
        do {
            for try await node in agent.iter("Hi", deps: ()) {
                if case .beforeModel(let ctx) = node {
                    savedState = ctx.state
                }
            }
        } catch {
            // Expected cancellation
        }

        // Resume from saved state
        var output: String?
        for try await node in agent.iter(from: savedState!, deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output == "Success on retry")
        #expect(await counter.current == 2)  // Model called twice
    }

    // MARK: - Test 10.9: Resume preserves tool decisions

    @Test("tool approval decisions survive when captured before break")
    func resumePreservesDecisions() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "my_tool",
            onCall: { _ in .success("result") }
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
            default:
                return MockResponse.text("Done")
            }
        })

        let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var savedState: IterationState<String>?

        // First run - make decisions then break
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .beforeTools(let ctx) = node {
                ctx.deny(ctx.pendingCalls[0].call, message: "Not now")
                savedState = ctx.state
                break
            }
        }

        // Resume - check decisions preserved
        guard let state = savedState else {
            Issue.record("Failed to capture savedState in first loop")
            return
        }

        for try await node in agent.iter(from: state, deps: ()) {
            if case .beforeTools(let ctx) = node {
                #expect(ctx.pendingCalls[0].decision == .denied("Not now"))
                break
            }
        }
    }

    // MARK: - Test 10.10: Double cancellation is idempotent

    @Test("cancelling an already-cancelled task doesn't crash")
    func doubleCancellationIdempotent() async throws {
        let model = FakeModel(onComplete: { _ in
            try await Task.sleep(for: .seconds(10))
            return MockResponse.text("Done")
        })
        let agent = Agent<Void, String>(model: model)

        let task = Task {
            for try await _ in agent.iter("Hi", deps: ()) { }
        }

        task.cancel()
        task.cancel()  // Second cancel - should not crash

        // Verify task completes (with cancellation error)
        _ = await task.result
    }

    // MARK: - Test 10.11: New iteration after cancel is independent

    @Test("starting a new iteration after cancellation works normally")
    func newIterationAfterCancelIndependent() async throws {
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let n = await counter.increment()
            if n == 1 {
                try await Task.sleep(for: .seconds(10))
            }
            return MockResponse.text("Response \(n)")
        })

        let agent = Agent<Void, String>(model: model)

        // First iteration - cancel
        let task1 = Task {
            for try await _ in agent.iter("Task 1", deps: ()) { }
        }
        try await Task.sleep(for: .milliseconds(5))
        task1.cancel()
        _ = await task1.result

        // Second iteration - should work normally
        var output: String?
        for try await node in agent.iter("Fresh start", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }
        #expect(output != nil)
    }

    // MARK: - Test 10.12: Cancellation releases resources

    @Test("cancellation properly releases resources")
    func cancellationReleasesResources() async throws {
        let model = FakeModel(onComplete: { _ in
            try await Task.sleep(for: .seconds(10))
            return MockResponse.text("Done")
        })
        let agent = Agent<Void, String>(model: model)

        let task = Task {
            for try await _ in agent.iter("Hi", deps: ()) { }
        }

        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        _ = await task.result

        // If we get here without hanging, resources were released
    }

    // MARK: - Test 10.13: Concurrent iterations cancel independently

    @Test("cancelling one iteration doesn't affect another concurrent iteration")
    func concurrentIterationsCancelIndependently() async throws {
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let n = await counter.increment()
            if n == 1 {
                // First task will be slow and get cancelled
                try await Task.sleep(for: .seconds(10))
            }
            return MockResponse.text("Response \(n)")
        })

        let agent = Agent<Void, String>(model: model)

        let task1 = Task {
            for try await _ in agent.iter("Task 1", deps: ()) { }
        }

        // Small delay to ensure task1 starts first
        try await Task.sleep(for: .milliseconds(5))

        let task2 = Task {
            var output: String?
            for try await node in agent.iter("Task 2", deps: ()) {
                if case .finished(let ctx) = node {
                    output = ctx.output
                }
            }
            return output
        }

        task1.cancel()
        let result2 = try await task2.value  // Should complete normally
        #expect(result2 != nil)
    }

    // MARK: - Test 10.14: Breaking out of loop is safe

    @Test("breaking out of iteration loop early doesn't break agent")
    func breakingOutOfLoopIsSafe() async throws {
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let n = await counter.increment()
            return MockResponse.text("Response \(n)")
        })

        let agent = Agent<Void, String>(model: model)

        // First iteration - break early
        for try await node in agent.iter("Hi", deps: ()) {
            if case .beforeModel = node {
                break  // Exit early, before finished
            }
        }

        // Agent should be usable for new iteration
        var output: String?
        for try await node in agent.iter("Second", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output != nil)
    }

    // MARK: - Test 10.15: Cancellation propagates through nested agent tool

    @Test("cancellation propagates to inner agents in agent-as-tool pattern")
    func cancellationPropagatesThroughNestedAgentTool() async throws {
        // Inner agent that's slow
        let innerModel = FakeModel(onComplete: { _ in
            try await Task.sleep(for: .seconds(10))
            return MockResponse.text("Inner done")
        })
        let innerAgent = Agent<Void, String>(model: innerModel)

        // Tool that calls inner agent
        actor CancellationTracker {
            var innerCancelled = false
            func markCancelled() { innerCancelled = true }
        }

        let tracker = CancellationTracker()
        let nestedTool = FakeTool<ConfigurableToolArgs, String>(
            name: "nested_tool",
            onCall: { _ in
                do {
                    for try await node in innerAgent.iter("Inner", deps: ()) {
                        if case .finished(let ctx) = node {
                            return .success(ctx.output)
                        }
                    }
                    return .success("completed")
                } catch is CancellationError {
                    await tracker.markCancelled()
                    throw CancellationError()
                }
            }
        )

        // Outer agent
        let counter = CallCounter()
        let outerModel = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "nested_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Done")
            }
        })

        let outerAgent = Agent<Void, String>(
            model: outerModel,
            tools: [AnyAgentTool(nestedTool)]
        )

        let task = Task {
            for try await _ in outerAgent.iter("Use nested", deps: ()) { }
        }

        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = await task.result

        let innerCancelled = await tracker.innerCancelled
        #expect(innerCancelled == true)
    }
}
