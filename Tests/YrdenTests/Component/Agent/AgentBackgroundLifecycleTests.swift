/// Component tests for Agent background task lifecycle.
///
/// Tests the three ownership models:
/// - run(): library auto-injects notifications, tasks outlive the run
/// - runStream(): library auto-injects events, tasks outlive the stream
/// - iter(): customer controls everything
///
/// Also tests registry lifetime cleanup (deinit kills all).

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

// MARK: - Test Helpers (actor-based for Sendable compliance)

private actor BoolFlag {
    private(set) var value = false
    func set() { value = true }
}

private actor MessageCapture {
    private(set) var messages: [Message] = []
    func capture(_ msgs: [Message]) { messages = msgs }
}

@Suite("Agent - Background Task Lifecycle")
struct AgentBackgroundLifecycleTests {

    // MARK: - Helpers

    private func makeToolsAndRegistry() -> (tools: [any Tool], registry: BackgroundTaskRegistry) {
        let env = ShellEnvironment.inherited()
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: ["/"]
        )
        let registry = BackgroundTaskRegistry()
        let shell = ShellTool(
            environment: env,
            pathValidator: validator,
            workingDirectory: "/tmp",
            backgroundTaskRegistry: registry,
            requiresApproval: false
        )
        let readFile = ReadFileTool(pathValidator: validator)
        let writeFile = WriteFileTool(pathValidator: validator)
        let taskOutput = TaskOutputTool(registry: registry)
        let taskStop = TaskStopTool(registry: registry)

        return ([shell, readFile, writeFile, taskOutput, taskStop], registry)
    }

    /// Check if a process with given PID is still alive.
    private func isProcessAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    // MARK: - run() mode: library auto-injects notifications

    @Test("agent.run injects notification for completed background task", .timeLimit(.minutes(1)))
    func runAutoNotification() async throws {
        let (tools, registry) = makeToolsAndRegistry()
        defer { Task { await registry.cancelAll() } }

        let notifFlag = BoolFlag()
        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                // First call: launch a fast background task
                return MockResponse.toolCall(
                    name: "shell",
                    arguments: #"{"command":"echo bg_done","run_in_background":true}"#,
                    id: "tc-bg-1"
                )
            case 2:
                // Tool result comes back with task ID
                // Model makes another tool call to wait a bit
                return MockResponse.toolCall(
                    name: "shell",
                    arguments: #"{"command":"sleep 0.5"}"#,
                    id: "tc-wait-1"
                )
            case 3:
                // After tools, library should have injected notification about bg task completing
                let messages = request.messages
                let hasNotification = messages.contains { msg in
                    if case .system(let content) = msg {
                        return content.contains("Background task") || content.contains("completed")
                    }
                    return false
                }
                if hasNotification { await notifFlag.set() }
                return MockResponse.text("Done with background awareness")
            default:
                return MockResponse.text("Finished")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: tools,
            backgroundTaskRegistry: registry
        )

        let result = try await agent.run("Start a background task")
        #expect(result.output != nil, "Agent run should produce output")
        // The background task is a fast "echo" and we sleep 0.5s in step 2,
        // so the notification should be injected by step 3.
        let sawNotification = await notifFlag.value
        #expect(sawNotification, "Library should auto-inject background task completion notification into messages for run() mode")
    }

    @Test("agent.run does NOT kill background tasks on completion", .timeLimit(.minutes(1)))
    func runDoesNotKillBackgroundTasks() async throws {
        let (tools, registry) = makeToolsAndRegistry()
        defer { Task { await registry.cancelAll() } }

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "shell",
                    arguments: #"{"command":"sleep 999","run_in_background":true}"#,
                    id: "tc-bg-1"
                )
            case 2:
                return MockResponse.text("Started background task")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: tools,
            backgroundTaskRegistry: registry
        )

        _ = try await agent.run("Start a long background task")

        // CRITICAL: After run() completes, background task should STILL be running
        let hasRunning = await registry.hasRunningTasks()
        #expect(hasRunning == true, "Background tasks MUST survive after run() completes — cleanup is tied to registry lifetime, not run lifetime")
    }

    @Test("background tasks survive across multiple run calls", .timeLimit(.minutes(1)))
    func backgroundTasksSurviveAcrossRuns() async throws {
        let (tools, registry) = makeToolsAndRegistry()
        defer { Task { await registry.cancelAll() } }

        // First run: start background task
        let counter1 = CallCounter()
        let model1 = FakeModel(onComplete: { request in
            switch await counter1.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "shell",
                    arguments: #"{"command":"sleep 999","run_in_background":true}"#,
                    id: "tc-bg-1"
                )
            case 2:
                return MockResponse.text("Background started")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent1 = try Agent<String>(
            model: model1,
            systemPrompt: "You are helpful.",
            tools: tools,
            backgroundTaskRegistry: registry
        )
        _ = try await agent1.run("Start background")

        // Second run with different model: verify task is still running
        let model2 = FakeModel(responses: [MockResponse.text("Second run")])

        let agent2 = try Agent<String>(
            model: model2,
            systemPrompt: "You are helpful.",
            tools: tools,
            backgroundTaskRegistry: registry
        )
        _ = try await agent2.run("Check status")

        let hasRunning = await registry.hasRunningTasks()
        #expect(hasRunning == true, "Background task from first run should still be running during second run")
    }

    // MARK: - runStream() mode: library auto-injects, emits events

    @Test("runStream emits backgroundTaskCompleted event", .timeLimit(.minutes(1)))
    func runStreamEmitsEvent() async throws {
        let (tools, registry) = makeToolsAndRegistry()
        defer { Task { await registry.cancelAll() } }

        let counter = CallCounter()
        let bgArgs = #"{"command":"echo stream_bg","run_in_background":true}"#
        let waitArgs = #"{"command":"sleep 0.3"}"#
        let model = FakeModel(onStream: { request in
            switch await counter.increment() {
            case 1:
                // Launch a fast background task
                let toolResponse = MockResponse.toolCall(name: "shell", arguments: bgArgs, id: "tc-bg-1")
                return [
                    .toolCallStart(id: "tc-bg-1", name: "shell"),
                    .toolCallDelta(argumentsDelta: bgArgs),
                    .toolCallEnd(id: "tc-bg-1"),
                    .done(toolResponse)
                ]
            case 2:
                // Foreground wait gives the background echo time to complete
                let toolResponse = MockResponse.toolCall(name: "shell", arguments: waitArgs, id: "tc-wait-1")
                return [
                    .toolCallStart(id: "tc-wait-1", name: "shell"),
                    .toolCallDelta(argumentsDelta: waitArgs),
                    .toolCallEnd(id: "tc-wait-1"),
                    .done(toolResponse)
                ]
            case 3:
                // By now the background echo should have completed
                return [
                    .contentDelta("Stream done"),
                    .done(MockResponse.text("Stream done"))
                ]
            default:
                return [
                    .contentDelta("End"),
                    .done(MockResponse.text("End"))
                ]
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: tools,
            backgroundTaskRegistry: registry
        )

        var eventCount = 0
        var sawBackgroundEvent = false
        for try await event in agent.runStream("Start stream background") {
            eventCount += 1
            if case .backgroundTaskCompleted = event {
                sawBackgroundEvent = true
            }
        }

        #expect(eventCount > 0, "Stream should emit at least some events")
        // The background task is a fast "echo", so it should complete during the stream
        #expect(sawBackgroundEvent, "runStream should emit backgroundTaskCompleted event for completed background tasks")
    }

    @Test("runStream does NOT kill background tasks when stream ends", .timeLimit(.minutes(1)))
    func runStreamDoesNotKillOnEnd() async throws {
        let (tools, registry) = makeToolsAndRegistry()
        defer { Task { await registry.cancelAll() } }

        let counter = CallCounter()
        let bgArgs = #"{"command":"sleep 999","run_in_background":true}"#
        let model = FakeModel(onStream: { request in
            switch await counter.increment() {
            case 1:
                let toolResponse = MockResponse.toolCall(name: "shell", arguments: bgArgs, id: "tc-bg-1")
                return [
                    .toolCallStart(id: "tc-bg-1", name: "shell"),
                    .toolCallDelta(argumentsDelta: bgArgs),
                    .toolCallEnd(id: "tc-bg-1"),
                    .done(toolResponse)
                ]
            case 2:
                return [
                    .contentDelta("Stream complete"),
                    .done(MockResponse.text("Stream complete"))
                ]
            default:
                return [.done(MockResponse.text(""))]
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: tools,
            backgroundTaskRegistry: registry
        )

        for try await _ in agent.runStream("Start background via stream") {
            // Consume all events
        }

        // CRITICAL: After stream ends, background task should still be running
        let hasRunning = await registry.hasRunningTasks()
        #expect(hasRunning == true, "Background tasks MUST survive after runStream completes")
    }

    // MARK: - iter() mode: customer controls notifications

    @Test("iter does not auto-inject notifications", .timeLimit(.minutes(1)))
    func iterNoAutoNotification() async throws {
        let (tools, registry) = makeToolsAndRegistry()
        defer { Task { await registry.cancelAll() } }

        let msgCapture = MessageCapture()
        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "shell",
                    arguments: #"{"command":"echo bg_iter","run_in_background":true}"#,
                    id: "tc-bg-1"
                )
            case 2:
                // Capture messages to verify no auto-injection
                await msgCapture.capture(request.messages)
                return MockResponse.text("Iter done")
            default:
                return MockResponse.text("End")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: tools
        )

        for try await _ in agent.iter("Test iter notifications") {
            // Just consume
        }

        // In iter mode, no automatic notification should be injected
        let capturedMessages = await msgCapture.messages
        let hasAutoNotification = capturedMessages.contains { msg in
            if case .system(let content) = msg {
                return content.contains("Background task") && content.contains("completed")
            }
            return false
        }
        #expect(!hasAutoNotification, "iter() should NOT auto-inject background task notifications")
    }

    @Test("customer can call registry.completedSince from iter", .timeLimit(.minutes(1)))
    func iterCustomerChecksRegistry() async throws {
        let (tools, registry) = makeToolsAndRegistry()
        defer { Task { await registry.cancelAll() } }

        let before = Date()
        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "shell",
                    arguments: #"{"command":"echo customer_check","run_in_background":true}"#,
                    id: "tc-bg-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: tools
        )

        for try await _ in agent.iter("Customer polling") {
            // Customer manually checks registry between iterations
            // (demonstrates the pattern — completions may or may not be ready yet)
        }

        // After iter completes, the fast "echo" background task should have finished.
        // Give it a moment to complete and record in the registry.
        try await Task.sleep(for: .seconds(1))
        let completions = await registry.completedSince(before)
        #expect(!completions.isEmpty, "Customer should be able to see completed background tasks via registry.completedSince()")
    }

    // MARK: - Registry Lifetime Cleanup (the REAL cleanup mechanism)

    @Test("registry going out of scope kills all background tasks", .timeLimit(.minutes(1)))
    func registryDeinitKillsAll() async throws {
        var pids: [Int32] = []

        do {
            let (tools, registry) = makeToolsAndRegistry()

            let counter = CallCounter()
            let model = FakeModel(onComplete: { request in
                switch await counter.increment() {
                case 1:
                    return MockResponse.toolCall(
                        name: "shell",
                        arguments: #"{"command":"sleep 999","run_in_background":true}"#,
                        id: "tc-bg-1"
                    )
                case 2:
                    return MockResponse.text("Started")
                default:
                    throw LLMError.serverError("Unexpected")
                }
            })

            let agent = try Agent<String>(
                model: model,
                systemPrompt: "You are helpful.",
                tools: tools,
                backgroundTaskRegistry: registry
            )
            _ = try await agent.run("Start background for cleanup test")

            // Capture PIDs before scope exit
            let active = await registry.activeTasks()
            pids = active.map { $0.pid }
            #expect(!pids.isEmpty, "Should have at least one running background task")

            // registry and tools go out of scope here -> deinit kills all
        }

        // Give deinit time to kill processes
        try await Task.sleep(for: .seconds(1))

        for pid in pids {
            let alive = isProcessAlive(pid: pid)
            #expect(!alive, "Process \(pid) should be dead after registry deinit")
        }
    }

    @Test("explicit cancelAll kills all background tasks", .timeLimit(.minutes(1)))
    func explicitCancelAllKillsAll() async throws {
        let (tools, registry) = makeToolsAndRegistry()

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "shell",
                    arguments: #"{"command":"sleep 999","run_in_background":true}"#,
                    id: "tc-bg-1"
                )
            case 2:
                return MockResponse.text("Started")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: tools,
            backgroundTaskRegistry: registry
        )
        _ = try await agent.run("Start background for cancelAll test")

        let hasRunning = await registry.hasRunningTasks()
        #expect(hasRunning == true, "Background task should be running before cancelAll")

        await registry.cancelAll()
        try await Task.sleep(for: .milliseconds(500))

        let hasRunningAfter = await registry.hasRunningTasks()
        #expect(hasRunningAfter == false, "All tasks should be terminated after cancelAll")
    }

    @Test("waitForAll waits for background tasks to complete", .timeLimit(.minutes(1)))
    func waitForAllWaits() async throws {
        let (tools, registry) = makeToolsAndRegistry()
        defer { Task { await registry.cancelAll() } }

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "shell",
                    arguments: #"{"command":"sleep 0.5 && echo waited","run_in_background":true}"#,
                    id: "tc-bg-1"
                )
            case 2:
                return MockResponse.text("Started")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: tools,
            backgroundTaskRegistry: registry
        )
        _ = try await agent.run("Start background for waitForAll test")

        // Wait for all background tasks
        try await registry.waitForAll(timeout: .seconds(10))

        let hasRunning = await registry.hasRunningTasks()
        #expect(hasRunning == false, "All tasks should be done after waitForAll")
    }

    // MARK: - Swift Task Cancellation

    @Test("cancelling Swift Task does not orphan background processes", .timeLimit(.minutes(1)))
    func swiftTaskCancelNoOrphans() async throws {
        let (tools, registry) = makeToolsAndRegistry()
        defer { Task { await registry.cancelAll() } }

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "shell",
                    arguments: #"{"command":"sleep 999","run_in_background":true}"#,
                    id: "tc-bg-1"
                )
            case 2:
                // Make the agent loop hang to simulate a long-running agent
                try await Task.sleep(for: .seconds(999))
                return MockResponse.text("Should not reach")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: tools,
            backgroundTaskRegistry: registry
        )

        // Launch agent in a cancellable task
        let task = Task {
            try await agent.run("Start and cancel")
        }

        // Wait for background task to start
        try await Task.sleep(for: .seconds(1))

        // Cancel the Swift Task
        task.cancel()

        // Background processes should still be managed by registry
        // They're alive until registry is cleaned up
        let hasRunning = await registry.hasRunningTasks()
        #expect(hasRunning == true, "Background tasks still managed by registry after Swift Task cancel")

        // Explicit cleanup
        await registry.cancelAll()
        try await Task.sleep(for: .milliseconds(500))

        let hasRunningAfter = await registry.hasRunningTasks()
        #expect(hasRunningAfter == false, "All tasks terminated after explicit cancelAll")
    }
}
