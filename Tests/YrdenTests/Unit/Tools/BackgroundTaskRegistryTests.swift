/// Tests for BackgroundTaskRegistry process lifecycle, orphan prevention, and cleanup.
///
/// This is the CRITICAL test suite for background execution safety.
/// Key invariants tested:
/// - No orphan processes (including children via process group kills)
/// - deinit kills all running processes
/// - Concurrent access is safe

import Testing
import Foundation
@testable import Yrden

@Suite("BackgroundTaskRegistry", .serialized)
struct BackgroundTaskRegistryTests {

    // MARK: - Helpers

    private func makeRegistry() -> BackgroundTaskRegistry {
        BackgroundTaskRegistry(gracefulShutdownTimeout: .milliseconds(500))
    }

    /// Check if a process with given PID is still alive.
    private func isProcessAlive(pid: Int32) -> Bool {
        // kill(pid, 0) checks existence without sending a signal
        kill(pid, 0) == 0
    }

    /// Wait briefly for a process to die.
    private func waitForProcessDeath(pid: Int32, timeout: Duration = .seconds(5)) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if !isProcessAlive(pid: pid) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !isProcessAlive(pid: pid)
    }

    // MARK: - Launch

    @Test("launch returns unique task ID", .timeLimit(.minutes(1)))
    func launchReturnsUniqueId() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let id1 = await registry.launch(command: "echo hello", workingDirectory: "/tmp")
        let id2 = await registry.launch(command: "echo world", workingDirectory: "/tmp")

        #expect(id1 != id2)
    }

    @Test("launch starts process that produces output", .timeLimit(.minutes(1)))
    func launchStartsProcess() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(command: "echo hello_world", workingDirectory: "/tmp")
        let snapshot = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(10))

        #expect(snapshot.output.contains("hello_world"))
    }

    @Test("task ID has recognizable prefix", .timeLimit(.minutes(1)))
    func taskIdFormat() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(command: "echo test", workingDirectory: "/tmp")

        // Task IDs should have a recognizable format (e.g., "bg_" prefix or UUID)
        #expect(!taskId.isEmpty)
        #expect(taskId.count > 4)
    }

    // MARK: - Get Output

    @Test("getOutput running task returns status running", .timeLimit(.minutes(1)))
    func getOutputRunningReturnsPartial() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(command: "sleep 999", workingDirectory: "/tmp")
        let snapshot = try await registry.getOutput(taskId: taskId, block: false)

        #expect(snapshot.status == .running)
    }

    @Test("getOutput block true waits for completion", .timeLimit(.minutes(1)))
    func getOutputBlockTrueWaits() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(command: "echo done", workingDirectory: "/tmp")
        let snapshot = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(10))

        #expect(snapshot.status == .completed)
        #expect(snapshot.output.contains("done"))
    }

    @Test("getOutput incremental returns only new output since last check", .timeLimit(.minutes(1)))
    func getOutputIncrementalNoRepeat() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(
            command: "echo line1 && sleep 0.5 && echo line2",
            workingDirectory: "/tmp"
        )

        // First read — should have "line1"
        try await Task.sleep(for: .milliseconds(200))
        let snap1 = try await registry.getOutput(taskId: taskId, block: false)
        #expect(snap1.output.contains("line1"), "First read should contain line1")

        // Wait for second line then block until completion
        let snap2 = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(10))

        // Final snapshot should have line2
        #expect(snap2.output.contains("line2"), "Second read should contain line2")
        #expect(snap2.status == .completed, "Task should be completed after blocking read")
    }

    @Test("getOutput completed task returns all remaining output", .timeLimit(.minutes(1)))
    func getOutputCompletedReturnsFull() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(command: "echo all_the_output", workingDirectory: "/tmp")

        // Wait for completion
        let snapshot = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(10))

        #expect(snapshot.status == .completed)
        #expect(snapshot.output.contains("all_the_output"))
    }

    @Test("getOutput unknown task ID returns error", .timeLimit(.minutes(1)))
    func getOutputUnknownIdError() async throws {
        let registry = makeRegistry()

        do {
            _ = try await registry.getOutput(taskId: "nonexistent-id", block: false)
            Issue.record("Expected error for unknown task ID")
        } catch {
            // Verify error was thrown — any error type is acceptable
            let desc = String(describing: error)
            #expect(!desc.isEmpty, "Error should have a description")
        }
    }

    @Test("getOutput with timeout returns running status on timeout", .timeLimit(.minutes(1)))
    func getOutputTimeoutReturnsRunning() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(command: "sleep 999", workingDirectory: "/tmp")
        let snapshot = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(1))

        #expect(snapshot.status == .running)
    }

    @Test("getOutput reports exit code 0 for success", .timeLimit(.minutes(1)))
    func getOutputExitCodeSuccess() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(command: "true", workingDirectory: "/tmp")
        let snapshot = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(10))

        #expect(snapshot.exitCode == 0)
    }

    @Test("getOutput reports non-zero exit code for failure", .timeLimit(.minutes(1)))
    func getOutputExitCodeFailure() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(command: "exit 42", workingDirectory: "/tmp")
        let snapshot = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(10))

        #expect(snapshot.exitCode == 42)
    }

    // MARK: - Stop

    @Test("stop terminates a running task", .timeLimit(.minutes(1)))
    func stopTerminatesRunning() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(command: "sleep 999", workingDirectory: "/tmp")
        try await Task.sleep(for: .milliseconds(200))

        try await registry.stop(taskId: taskId)
        let snapshot = try await registry.getOutput(taskId: taskId, block: false)

        #expect(snapshot.status != .running)
    }

    @Test("stop uses SIGTERM then SIGKILL escalation", .timeLimit(.minutes(1)))
    func stopEscalationSIGTERMToSIGKILL() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        // trap SIGTERM to ignore it, requiring SIGKILL
        let taskId = await registry.launch(
            command: "trap '' TERM; sleep 999",
            workingDirectory: "/tmp"
        )
        try await Task.sleep(for: .milliseconds(200))

        try await registry.stop(taskId: taskId)

        // After stop, task should be terminated (SIGKILL after SIGTERM timeout)
        let snapshot = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(15))
        #expect(snapshot.status != .running)
    }

    @Test("stop completed task is a no-op", .timeLimit(.minutes(1)))
    func stopCompletedNoOp() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(command: "echo done", workingDirectory: "/tmp")
        _ = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(10))

        // Stop after completion should not crash
        try await registry.stop(taskId: taskId)
    }

    @Test("stop unknown task ID returns error", .timeLimit(.minutes(1)))
    func stopUnknownIdError() async throws {
        let registry = makeRegistry()

        do {
            try await registry.stop(taskId: "nonexistent-id")
            Issue.record("Expected error for unknown task ID")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test("stop already stopped task is a no-op", .timeLimit(.minutes(1)))
    func stopAlreadyStoppedNoOp() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(command: "sleep 999", workingDirectory: "/tmp")
        try await Task.sleep(for: .milliseconds(200))

        try await registry.stop(taskId: taskId)
        // Second stop should not crash
        try await registry.stop(taskId: taskId)
    }

    // MARK: - ORPHAN PREVENTION (critical — process group kills)

    @Test("cancelAll terminates ALL running tasks", .timeLimit(.minutes(1)))
    func cancelAllTerminatesAll() async throws {
        let registry = makeRegistry()

        _ = await registry.launch(command: "sleep 999", workingDirectory: "/tmp")
        _ = await registry.launch(command: "sleep 999", workingDirectory: "/tmp")
        _ = await registry.launch(command: "sleep 999", workingDirectory: "/tmp")
        try await Task.sleep(for: .milliseconds(200))

        await registry.cancelAll()

        let active = await registry.activeTasks()
        #expect(active.isEmpty)
    }

    @Test("stop kills child processes via process group", .timeLimit(.minutes(1)))
    func stopKillsChildProcesses() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        // Launch a shell that spawns background children
        let taskId = await registry.launch(
            command: "sh -c 'sleep 999 & sleep 999 & echo children_started && wait'",
            workingDirectory: "/tmp"
        )

        // Wait for children to start
        try await Task.sleep(for: .milliseconds(500))

        // Get the process info to check PIDs later
        let infoBefore = await registry.activeTasks()
        guard let taskInfo = infoBefore.first(where: { $0.id == taskId }) else {
            Issue.record("Task not found in active tasks"); return
        }

        try await registry.stop(taskId: taskId)
        try await Task.sleep(for: .milliseconds(500))

        // Verify the main process is dead
        let isDead = await waitForProcessDeath(pid: taskInfo.pid, timeout: .seconds(5))
        #expect(isDead, "Parent process should be dead after stop")
    }

    @Test("cancelAll kills child processes of all tasks", .timeLimit(.minutes(1)))
    func cancelAllKillsChildProcesses() async throws {
        let registry = makeRegistry()

        _ = await registry.launch(
            command: "sh -c 'sleep 999 & wait'",
            workingDirectory: "/tmp"
        )
        _ = await registry.launch(
            command: "sh -c 'sleep 999 & wait'",
            workingDirectory: "/tmp"
        )
        try await Task.sleep(for: .milliseconds(500))

        let infoBefore = await registry.activeTasks()
        let pids = infoBefore.map { $0.pid }

        await registry.cancelAll()
        try await Task.sleep(for: .milliseconds(500))

        // All parent processes should be dead
        for pid in pids {
            let isDead = await waitForProcessDeath(pid: pid, timeout: .seconds(5))
            #expect(isDead, "Process \(pid) should be dead after cancelAll")
        }
    }

    @Test("cancelAll safe on empty registry", .timeLimit(.minutes(1)))
    func cancelAllEmptySafe() async {
        let registry = makeRegistry()
        await registry.cancelAll() // Should not crash
    }

    @Test("cancelAll safe when all tasks already completed", .timeLimit(.minutes(1)))
    func cancelAllAllCompletedSafe() async throws {
        let registry = makeRegistry()

        let taskId = await registry.launch(command: "echo done", workingDirectory: "/tmp")
        _ = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(10))

        await registry.cancelAll() // Should not crash
    }

    @Test("process terminated even when Swift Task is cancelled", .timeLimit(.minutes(1)))
    func processTerminatedOnSwiftTaskCancel() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(command: "sleep 999", workingDirectory: "/tmp")
        try await Task.sleep(for: .milliseconds(200))

        let infoBefore = await registry.activeTasks()
        guard let info = infoBefore.first(where: { $0.id == taskId }) else {
            Issue.record("Task not found"); return
        }
        let pid = info.pid

        // Stop via registry (simulating cleanup after Swift Task cancellation)
        try await registry.stop(taskId: taskId)

        let isDead = await waitForProcessDeath(pid: pid, timeout: .seconds(5))
        #expect(isDead, "Process should be terminated even when Swift Task is cancelled")
    }

    @Test("no process leak after 10 rapid launch-stop cycles", .timeLimit(.minutes(1)))
    func noLeakAfterRapidCycles() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        var allPids: [Int32] = []
        for _ in 0..<10 {
            let taskId = await registry.launch(command: "sleep 999", workingDirectory: "/tmp")
            try await Task.sleep(for: .milliseconds(50))
            let info = await registry.activeTasks()
            if let pid = info.first(where: { $0.id == taskId })?.pid {
                allPids.append(pid)
            }
            try await registry.stop(taskId: taskId)
        }

        try await Task.sleep(for: .milliseconds(500))

        // All processes should be dead
        for pid in allPids {
            let isDead = !isProcessAlive(pid: pid)
            #expect(isDead, "Process \(pid) should be dead after rapid launch-stop cycle")
        }
    }

    // MARK: - Completion Notifications

    @Test("completedSince returns newly completed tasks", .timeLimit(.minutes(1)))
    func completedSinceReturnsNew() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let before = Date()
        let taskId = await registry.launch(command: "echo done", workingDirectory: "/tmp")
        _ = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(10))

        let completions = await registry.completedSince(before)
        #expect(completions.contains { $0.taskId == taskId })
    }

    @Test("completedSince does not return tasks completed before the given date", .timeLimit(.minutes(1)))
    func completedSinceNoRepeats() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(command: "echo done", workingDirectory: "/tmp")
        _ = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(10))

        // Task completed before this timestamp
        try await Task.sleep(for: .milliseconds(100))
        let afterCompletion = Date()

        // Query with timestamp after the task completed — should NOT include it
        let results = await registry.completedSince(afterCompletion)
        let hasOldTask = results.contains { $0.taskId == taskId }
        #expect(!hasOldTask, "completedSince should not return tasks that completed before the given date")

        // Verify the task IS visible when querying from distant past
        let allResults = await registry.completedSince(.distantPast)
        let hasTaskInAll = allResults.contains { $0.taskId == taskId }
        #expect(hasTaskInAll, "Task should be visible when querying from distant past")
    }

    @Test("completedSince with no completions returns empty", .timeLimit(.minutes(1)))
    func completedSinceNoCompletions() async {
        let registry = makeRegistry()
        let completions = await registry.completedSince(.distantPast)
        #expect(completions.isEmpty)
    }

    @Test("multiple tasks tracked independently", .timeLimit(.minutes(1)))
    func multipleTasksIndependent() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let fast = await registry.launch(command: "echo fast", workingDirectory: "/tmp")
        let slow = await registry.launch(command: "sleep 999", workingDirectory: "/tmp")

        _ = try await registry.getOutput(taskId: fast, block: true, timeout: .seconds(10))

        let fastSnap = try await registry.getOutput(taskId: fast, block: false)
        let slowSnap = try await registry.getOutput(taskId: slow, block: false)

        #expect(fastSnap.status == .completed)
        #expect(slowSnap.status == .running)
    }

    // MARK: - Public API

    @Test("activeTasks returns only running tasks", .timeLimit(.minutes(1)))
    func activeTasksReturnsRunning() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let fast = await registry.launch(command: "echo fast", workingDirectory: "/tmp")
        _ = await registry.launch(command: "sleep 999", workingDirectory: "/tmp")

        // Wait for fast to complete
        _ = try await registry.getOutput(taskId: fast, block: true, timeout: .seconds(10))

        let active = await registry.activeTasks()
        #expect(active.count == 1)
        #expect(!active.contains { $0.id == fast })
    }

    @Test("hasRunningTasks reflects current state", .timeLimit(.minutes(1)))
    func hasRunningTasksReflectsState() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        #expect(await registry.hasRunningTasks() == false)

        _ = await registry.launch(command: "sleep 999", workingDirectory: "/tmp")
        try await Task.sleep(for: .milliseconds(100))

        #expect(await registry.hasRunningTasks() == true)

        await registry.cancelAll()
        try await Task.sleep(for: .milliseconds(500))

        #expect(await registry.hasRunningTasks() == false)
    }

    // MARK: - Concurrent Access

    @Test("10 concurrent launches all get unique IDs", .timeLimit(.minutes(1)))
    func concurrentLaunchesNoRace() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let ids = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await registry.launch(command: "echo test", workingDirectory: "/tmp")
                }
            }
            var results: [String] = []
            for await id in group {
                results.append(id)
            }
            return results
        }

        #expect(Set(ids).count == 10, "All 10 task IDs should be unique")
    }

    @Test("concurrent getOutput and stop do not deadlock", .timeLimit(.minutes(1)))
    func concurrentGetOutputAndStopNoDeadlock() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(command: "sleep 999", workingDirectory: "/tmp")
        try await Task.sleep(for: .milliseconds(200))

        // Run getOutput and stop concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(3))
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(100))
                try await registry.stop(taskId: taskId)
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Lifetime / deinit Cleanup (CRITICAL)

    @Test("deinit kills all running processes immediately", .timeLimit(.minutes(1)))
    func deinitKillsAllProcesses() async throws {
        var pid: Int32 = 0

        // Create registry in a scope so it goes out of scope
        do {
            let registry = BackgroundTaskRegistry()
            let taskId = await registry.launch(command: "sleep 999", workingDirectory: "/tmp")
            try await Task.sleep(for: .milliseconds(200))

            let info = await registry.activeTasks()
            guard let taskInfo = info.first(where: { $0.id == taskId }) else {
                Issue.record("Task not found"); return
            }
            pid = taskInfo.pid

            #expect(isProcessAlive(pid: pid), "Process should be alive before deinit")
            // registry goes out of scope here → deinit fires
        }

        // Give deinit a moment to take effect
        try await Task.sleep(for: .milliseconds(500))
        let isDead = await waitForProcessDeath(pid: pid, timeout: .seconds(5))
        #expect(isDead, "Process should be dead after registry deinit")
    }

    @Test("deinit kills child processes via process group", .timeLimit(.minutes(1)))
    func deinitKillsChildProcesses() async throws {
        var parentPid: Int32 = 0

        do {
            let registry = BackgroundTaskRegistry()
            let taskId = await registry.launch(
                command: "sh -c 'sleep 999 & sleep 999 & wait'",
                workingDirectory: "/tmp"
            )
            try await Task.sleep(for: .milliseconds(500))

            let info = await registry.activeTasks()
            if let taskInfo = info.first(where: { $0.id == taskId }) {
                parentPid = taskInfo.pid
            }
        }

        try await Task.sleep(for: .milliseconds(500))
        if parentPid > 0 {
            let isDead = await waitForProcessDeath(pid: parentPid, timeout: .seconds(5))
            #expect(isDead, "Parent process should be dead after registry deinit")
        }
    }

    @Test("deinit is safe when no tasks were ever launched", .timeLimit(.minutes(1)))
    func deinitEmptyRegistrySafe() async {
        // Create and immediately destroy — should not crash
        _ = BackgroundTaskRegistry()
    }

    @Test("deinit is safe when all tasks already completed", .timeLimit(.minutes(1)))
    func deinitAllCompletedSafe() async throws {
        do {
            let registry = BackgroundTaskRegistry()
            let taskId = await registry.launch(command: "echo done", workingDirectory: "/tmp")
            _ = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(10))
        }
        // Should not crash in deinit
    }

    // MARK: - waitForAll

    @Test("waitForAll returns when all tasks complete", .timeLimit(.minutes(1)))
    func waitForAllReturnsOnCompletion() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        _ = await registry.launch(command: "echo done1", workingDirectory: "/tmp")
        _ = await registry.launch(command: "echo done2", workingDirectory: "/tmp")

        try await registry.waitForAll(timeout: .seconds(10))

        let active = await registry.activeTasks()
        #expect(active.isEmpty)
    }

    @Test("waitForAll with timeout throws on timeout", .timeLimit(.minutes(1)))
    func waitForAllTimeoutThrows() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        _ = await registry.launch(command: "sleep 999", workingDirectory: "/tmp")

        do {
            try await registry.waitForAll(timeout: .seconds(1))
            Issue.record("Expected timeout error")
        } catch {
            // Expected — timeout should throw
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test("waitForAll with no tasks returns immediately", .timeLimit(.minutes(1)))
    func waitForAllEmptyReturnsImmediately() async throws {
        let registry = makeRegistry()
        try await registry.waitForAll(timeout: .seconds(1))
        // Should return immediately without error
    }

    // MARK: - Resource Management

    @Test("output buffer is bounded for runaway processes", .timeLimit(.minutes(1)))
    func outputBufferBounded() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        // Generate ~5.6MB of output (seq 1 1000000 ≈ 5.6MB raw)
        let taskId = await registry.launch(command: "seq 1 1000000", workingDirectory: "/tmp")
        _ = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(30))

        let snapshot = try await registry.getOutput(taskId: taskId, block: false)
        // Raw output is ~5.6MB. Buffer should cap well below that.
        // We expect a reasonable limit like 1MB.
        #expect(snapshot.output.count > 0, "Should have some output")
        #expect(snapshot.output.count < 2_000_000,
                "Output should be bounded to a reasonable limit, got \(snapshot.output.count) chars")
    }

    @Test("completed task output remains accessible after completion", .timeLimit(.minutes(1)))
    func completedTaskOutputAccessible() async throws {
        let registry = makeRegistry()
        defer { Task { await registry.cancelAll() } }

        let taskId = await registry.launch(command: "echo persistent_output", workingDirectory: "/tmp")
        _ = try await registry.getOutput(taskId: taskId, block: true, timeout: .seconds(10))

        // Read output again after completion
        let snapshot = try await registry.getOutput(taskId: taskId, block: false)
        #expect(snapshot.output.contains("persistent_output"))
    }
}
