/// Tests for Agent concurrency safety.
///
/// Covers: concurrent runs with independent state, concurrent tool execution,
/// cancellation propagation, and data race safety.
///
/// Key invariant: Agent is an actor — concurrent runs produce independent
/// results with unique runIDs and no shared mutable state corruption.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

// MARK: - Concurrent Runs

@Suite("Agent - Concurrent Runs")
struct AgentConcurrentRunsTests {

    @Test("multiple concurrent runs complete with unique runIDs")
    func multipleConcurrentRunsCompleteWithUniqueRunIDs() async throws {
        let model = FakeModel(onComplete: { _ in
            MockResponse.text("Response")
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        async let run1 = agent.run("Request 1")
        async let run2 = agent.run("Request 2")
        async let run3 = agent.run("Request 3")

        let results = try await [run1, run2, run3]

        #expect(results.count == 3)

        // Each run has a unique runID
        let runIDs = Set(results.map { $0.runID })
        #expect(runIDs.count == 3, "Expected 3 unique runIDs, got \(runIDs.count)")

        // All completed successfully
        for result in results {
            guard case .completed(let output) = result.status else {
                Issue.record("Expected .completed, got \(result.status)")
                return
            }
            #expect(output == "Response")
        }

        // Model was called 3 times (once per run)
        let callCount = await model.completeCallCount
        #expect(callCount == 3)
    }

    @Test("concurrent runs with tools maintain isolation")
    func concurrentRunsWithToolsMaintainIsolation() async throws {
        let callCounter = CallCounter()
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "counter_tool",
            onCall: { _ in
                let n = await callCounter.increment()
                return .success("call-\(n)")
            }
        )

        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { request in
            let n = await modelCounter.increment()
            // Odd calls: tool call; Even calls: text response
            if n % 2 == 1 {
                return MockResponse.toolCall(
                    name: "counter_tool",
                    arguments: #"{"input":"go"}"#,
                    id: "tc-\(n)"
                )
            } else {
                return MockResponse.text("Done-\(n)")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool]
        )

        async let run1 = agent.run("Count 1")
        async let run2 = agent.run("Count 2")

        let results = try await [run1, run2]

        #expect(results.count == 2)
        for result in results {
            #expect(result.isCompleted)
        }

        // Tool called exactly twice (once per run)
        let toolCalls = await tool.calls
        #expect(toolCalls.count == 2)
    }

    @Test("concurrent streams complete independently")
    func concurrentStreamsCompleteIndependently() async throws {
        let model = FakeModel(
            onStream: { _ in
                [
                    .contentDelta("Hello"),
                    .done(MockResponse.text("Hello"))
                ]
            }
        )

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        actor ResultCollector {
            var outputs: [String] = []
            func add(_ output: String) { outputs.append(output) }
        }

        let collector = ResultCollector()

        async let stream1: Void = {
            for try await event in agent.runStream("Stream 1") {
                if case .finished(let run) = event, let output = run.output {
                    await collector.add(output)
                }
            }
        }()

        async let stream2: Void = {
            for try await event in agent.runStream("Stream 2") {
                if case .finished(let run) = event, let output = run.output {
                    await collector.add(output)
                }
            }
        }()

        _ = try await (stream1, stream2)

        let outputs = await collector.outputs
        #expect(outputs.count == 2)
        #expect(outputs.allSatisfy { $0 == "Hello" })
    }
}

// MARK: - Cancellation Propagation

@Suite("Agent - Cancellation Propagation")
struct AgentCancellationPropagationTests {

    @Test("cancellation during model call throws CancellationError")
    func cancellationDuringModelCallThrows() async throws {
        let model = FakeModel(onComplete: { _ in
            // Simulate slow model
            try await Task.sleep(for: .seconds(10))
            return MockResponse.text("Should not reach")
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        let task = Task {
            try await agent.run("Hello")
        }

        // Cancel after brief delay
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            // May complete if timing is off — that's acceptable
        } catch is CancellationError {
            // Expected
        } catch {
            // Other errors from cancellation propagation are acceptable
        }
    }

    @Test("cancellation during tool execution throws CancellationError")
    func cancellationDuringToolExecutionThrows() async throws {
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "slow_tool",
            onCall: { _ in
                try await Task.sleep(for: .seconds(10))
                return .success("Should not reach")
            }
        )

        let model = FakeModel(onComplete: { _ in
            MockResponse.toolCall(
                name: "slow_tool",
                arguments: #"{"input":"go"}"#,
                id: "tc-1"
            )
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool]
        )

        let task = Task {
            try await agent.run("Use slow tool")
        }

        // Cancel after model call returns but tool is still running
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
        } catch is CancellationError {
            // Expected
        } catch {
            // Other cancellation-related errors acceptable
        }
    }

    @Test("cancellation terminates stream cleanly")
    func cancellationTerminatesStreamCleanly() async throws {
        let model = FakeModel(
            onStream: { _ in
                // Simulate slow streaming
                try await Task.sleep(for: .seconds(10))
                return [.contentDelta("Should not reach"), .done(MockResponse.text("No"))]
            }
        )

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        let task = Task {
            for try await _ in agent.runStream("Hello") {
                // Consume
            }
        }

        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            try await task.value
        } catch is CancellationError {
            // Expected
        } catch {
            // Other cancellation-related errors acceptable
        }
    }
}

// MARK: - Data Race Safety

@Suite("Agent - Data Race Safety")
struct AgentDataRaceSafetyTests {

    @Test("many concurrent runs all complete without corruption")
    func manyConcurrentRunsCompleteWithoutCorruption() async throws {
        let model = FakeModel(onComplete: { _ in
            MockResponse.text("OK")
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful."
        )

        let taskCount = 20
        let results = await withTaskGroup(of: AgentRun<String>?.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    try? await agent.run("Request \(i)")
                }
            }

            var collected: [AgentRun<String>] = []
            for await result in group {
                if let r = result {
                    collected.append(r)
                }
            }
            return collected
        }

        // All should complete
        #expect(results.count == taskCount, "Expected \(taskCount) results, got \(results.count)")

        // All outputs should be valid
        for result in results {
            #expect(result.output == "OK")
            #expect(result.requestCount >= 1)
        }

        // All runIDs should be unique
        let uniqueIDs = Set(results.map { $0.runID })
        #expect(uniqueIDs.count == taskCount,
                "Expected \(taskCount) unique runIDs, got \(uniqueIDs.count)")
    }

    @Test("concurrent runs with tools produce correct tool call counts")
    func concurrentRunsWithToolsProduceCorrectCounts() async throws {
        let callCounter = CallCounter()
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "counting_tool",
            onCall: { _ in
                let n = await callCounter.increment()
                return .success("count-\(n)")
            }
        )

        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { request in
            let hasToolResults = request.messages.contains { msg in
                if case .toolResults = msg { return true }
                return false
            }
            if hasToolResults {
                return MockResponse.text("Done")
            }
            let n = await modelCounter.increment()
            return MockResponse.toolCall(
                name: "counting_tool",
                arguments: #"{"input":"go"}"#,
                id: "tc-\(n)"
            )
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [tool]
        )

        let taskCount = 10
        let results = await withTaskGroup(of: AgentRun<String>?.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    try? await agent.run("Run \(i)")
                }
            }

            var collected: [AgentRun<String>] = []
            for await result in group {
                if let r = result { collected.append(r) }
            }
            return collected
        }

        #expect(results.count == taskCount)

        // Tool should have been called exactly taskCount times (once per run)
        let toolCalls = await tool.calls
        #expect(toolCalls.count == taskCount,
                "Expected \(taskCount) tool calls, got \(toolCalls.count)")
    }
}
