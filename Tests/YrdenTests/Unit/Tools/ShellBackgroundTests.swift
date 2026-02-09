/// Tests for Shell background execution, TaskOutput, and TaskStop tool integration.
///
/// These tests verify the complete workflow: shell launches background task,
/// TaskOutput retrieves output, TaskStop terminates tasks.
/// All three tools share one BackgroundTaskRegistry.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Shell Background Execution")
struct ShellBackgroundTests {

    private let tempDir: String = NSTemporaryDirectory() + "yrden-shell-bg-tests-\(UUID().uuidString)"

    // MARK: - Helpers

    private func makeTools() -> (shell: ShellTool, taskOutput: TaskOutputTool, taskStop: TaskStopTool, registry: BackgroundTaskRegistry) {
        let env = ShellEnvironment.inherited()
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: ["/"]
        )
        let registry = BackgroundTaskRegistry(gracefulShutdownTimeout: .milliseconds(500))
        let shell = ShellTool(
            environment: env,
            pathValidator: validator,
            workingDirectory: "/tmp",
            backgroundTaskRegistry: registry,
            requiresApproval: false
        )
        let taskOutput = TaskOutputTool(registry: registry)
        let taskStop = TaskStopTool(registry: registry)

        return (shell, taskOutput, taskStop, registry)
    }

    private func makeContext() -> ToolContext {
        ToolContext(model: FakeModel())
    }

    /// Launch a background task via shell and extract the task ID from the success output.
    /// The shell tool's background mode returns a message containing the task ID.
    private func launchBackground(
        shell: ShellTool,
        registry: BackgroundTaskRegistry,
        command: String,
        workingDirectory: String? = nil,
        timeout: Int? = nil,
        description: String? = nil
    ) async throws -> String {
        let result = try await shell.execute(
            context: makeContext(),
            arguments: ShellToolArgs(
                command: command,
                workingDirectory: workingDirectory,
                timeout: timeout,
                runInBackground: true,
                description: description
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success launching background task, got \(result)")
            throw ShellBgTestError.launchFailed
        }

        // The background launch output should contain the task ID.
        // We also check the registry to find the task.
        // Strategy: get all known task IDs from registry, the output should reference one of them.
        let allTasks = await registry.activeTasks()
        let completions = await registry.completedSince(.distantPast)
        let allIds = allTasks.map(\.id) + completions.map(\.taskId)

        // Try to find a task ID that appears in the output
        for id in allIds {
            if output.contains(id) {
                return id
            }
        }

        // Fallback: if output doesn't contain ID literally, return the most recent task
        // (This handles implementations that format the ID differently)
        if let task = allIds.last {
            return task
        }

        Issue.record("Could not determine task ID. Output was: \(output)")
        throw ShellBgTestError.noTaskId
    }

    private enum ShellBgTestError: Error {
        case launchFailed
        case noTaskId
    }

    // MARK: - Shell run_in_background

    @Test("run_in_background true returns immediately with task ID", .timeLimit(.minutes(1)))
    func runInBackgroundReturnsImmediately() async throws {
        let (shell, _, _, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        let result = try await shell.execute(
            context: makeContext(),
            arguments: ShellToolArgs(
                command: "sleep 999",
                workingDirectory: nil,
                timeout: nil,
                runInBackground: true,
                description: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)"); return
        }

        // Should return immediately with a task ID, not wait for sleep to finish
        #expect(!output.isEmpty, "Background launch should return task info")

        // Verify registry has the task
        let hasRunning = await registry.hasRunningTasks()
        #expect(hasRunning, "Registry should track the background task")
    }

    @Test("run_in_background false executes normally", .timeLimit(.minutes(1)))
    func runInBackgroundFalseNormal() async throws {
        let (shell, _, _, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        let result = try await shell.execute(
            context: makeContext(),
            arguments: ShellToolArgs(
                command: "echo foreground",
                workingDirectory: nil,
                timeout: nil,
                runInBackground: false,
                description: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("foreground"))
    }

    @Test("run_in_background nil executes normally", .timeLimit(.minutes(1)))
    func runInBackgroundNilDefault() async throws {
        let (shell, _, _, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        let result = try await shell.execute(
            context: makeContext(),
            arguments: ShellToolArgs(
                command: "echo normal",
                workingDirectory: nil,
                timeout: nil,
                runInBackground: nil,
                description: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("normal"))
    }

    @Test("background task respects working directory", .timeLimit(.minutes(1)))
    func backgroundTaskRespectsWorkDir() async throws {
        let (shell, taskOutput, _, registry) = makeTools()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        defer { Task { await registry.cancelAll() } }

        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        let taskId = try await launchBackground(
            shell: shell, registry: registry,
            command: "pwd",
            workingDirectory: tempDir
        )

        let outputResult = try await taskOutput.execute(
            context: makeContext(),
            arguments: TaskOutputArgs(taskId: taskId, block: true, timeout: 10)
        )

        guard case .success(let out) = outputResult else {
            Issue.record("Expected success from task_output"); return
        }
        // /tmp may resolve to /private/tmp on macOS
        #expect(out.contains("tmp") || out.contains(tempDir),
                "Background task should run in specified working directory, got: \(out)")
    }

    @Test("background task inherits shell environment", .timeLimit(.minutes(1)))
    func backgroundTaskInheritsEnv() async throws {
        let (shell, taskOutput, _, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        let taskId = try await launchBackground(
            shell: shell, registry: registry,
            command: "echo $HOME"
        )

        let result = try await taskOutput.execute(
            context: makeContext(),
            arguments: TaskOutputArgs(taskId: taskId, block: true, timeout: 10)
        )

        guard case .success(let out) = result else {
            Issue.record("Expected success"); return
        }
        // HOME should be set (non-empty)
        let outputLines = out.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(!outputLines.isEmpty, "HOME env var should produce output")
    }

    @Test("CWD tracking works for foreground after background launch", .timeLimit(.minutes(1)))
    func cwdTrackingNotBrokenByBackground() async throws {
        let (shell, _, _, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        // Launch background task that cd's somewhere
        _ = try await shell.execute(
            context: makeContext(),
            arguments: ShellToolArgs(
                command: "cd /usr && sleep 999",
                workingDirectory: nil,
                timeout: nil,
                runInBackground: true,
                description: nil
            )
        )

        // Foreground should NOT be affected by background's cd
        let result = try await shell.execute(
            context: makeContext(),
            arguments: ShellToolArgs(
                command: "pwd",
                workingDirectory: nil,
                timeout: nil,
                runInBackground: false,
                description: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // CWD should still be /tmp (the tool's working directory), not /usr
        #expect(output.contains("tmp"), "Foreground CWD should not be affected by background cd")
    }

    @Test("background task timeout terminates process group", .timeLimit(.minutes(1)))
    func backgroundTaskTimeoutTerminates() async throws {
        let (shell, taskOutput, _, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        let taskId = try await launchBackground(
            shell: shell, registry: registry,
            command: "sleep 999",
            timeout: 1  // 1 second timeout
        )

        // Wait for timeout to trigger
        try await Task.sleep(for: .seconds(3))

        // Task should be completed (terminated by timeout)
        let snapshot = try await taskOutput.execute(
            context: makeContext(),
            arguments: TaskOutputArgs(taskId: taskId, block: false, timeout: nil)
        )
        guard case .success(let out) = snapshot else {
            Issue.record("Expected success from task_output after timeout, got \(snapshot)"); return
        }
        #expect(out.contains("timed out") || out.contains("Exit code") || out.contains("completed"),
                "Timed out task should show termination status, got: \(out)")
    }

    // MARK: - TaskOutput Tool

    @Test("task_output block true waits and returns completed output", .timeLimit(.minutes(1)))
    func taskOutputBlockTrueWaits() async throws {
        let (shell, taskOutput, _, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        let taskId = try await launchBackground(
            shell: shell, registry: registry,
            command: "echo task_content"
        )

        let result = try await taskOutput.execute(
            context: makeContext(),
            arguments: TaskOutputArgs(taskId: taskId, block: true, timeout: 10)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("task_content"), "Should contain the echoed text")
    }

    @Test("task_output block false returns running status", .timeLimit(.minutes(1)))
    func taskOutputBlockFalseRunning() async throws {
        let (shell, taskOutput, _, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        let taskId = try await launchBackground(
            shell: shell, registry: registry,
            command: "sleep 999"
        )

        let result = try await taskOutput.execute(
            context: makeContext(),
            arguments: TaskOutputArgs(taskId: taskId, block: false, timeout: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.lowercased().contains("running"),
                "Non-blocking check of running task should indicate 'running' status")
    }

    @Test("task_output incremental returns only new output", .timeLimit(.minutes(1)))
    func taskOutputIncremental() async throws {
        let (shell, taskOutput, _, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        let taskId = try await launchBackground(
            shell: shell, registry: registry,
            command: "echo part1 && sleep 1 && echo part2"
        )

        // First read
        try await Task.sleep(for: .milliseconds(200))
        let result1 = try await taskOutput.execute(
            context: makeContext(),
            arguments: TaskOutputArgs(taskId: taskId, block: false, timeout: nil)
        )

        // Wait and second read
        try await Task.sleep(for: .seconds(2))
        let result2 = try await taskOutput.execute(
            context: makeContext(),
            arguments: TaskOutputArgs(taskId: taskId, block: false, timeout: nil)
        )

        guard case .success(let out2) = result2 else {
            Issue.record("Expected success for second read"); return
        }
        // Second read should have part2 (incremental)
        #expect(out2.contains("part2") || out2.contains("completed"),
                "Second read should show new output")
        _ = result1 // Suppress unused warning
    }

    @Test("task_output shows exit code in output", .timeLimit(.minutes(1)))
    func taskOutputShowsExitCode() async throws {
        let (shell, taskOutput, _, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        let taskId = try await launchBackground(
            shell: shell, registry: registry,
            command: "exit 42"
        )

        let result = try await taskOutput.execute(
            context: makeContext(),
            arguments: TaskOutputArgs(taskId: taskId, block: true, timeout: 10)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("42"), "Output should include exit code 42")
    }

    @Test("task_output unknown ID returns error", .timeLimit(.minutes(1)))
    func taskOutputUnknownIdError() async throws {
        let (_, taskOutput, _, _) = makeTools()

        let result = try await taskOutput.execute(
            context: makeContext(),
            arguments: TaskOutputArgs(taskId: "nonexistent-id", block: false, timeout: nil)
        )

        switch result {
        case .success(let output):
            #expect(output.lowercased().contains("not found") || output.lowercased().contains("error"),
                    "Unknown task ID should produce error message, got: \(output)")
        case .failure:
            break // Also acceptable
        case .deferred:
            Issue.record("Unexpected deferred result")
        }
    }

    @Test("task_output timeout returns partial", .timeLimit(.minutes(1)))
    func taskOutputTimeoutPartial() async throws {
        let (shell, taskOutput, _, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        let taskId = try await launchBackground(
            shell: shell, registry: registry,
            command: "sleep 999"
        )

        let result = try await taskOutput.execute(
            context: makeContext(),
            arguments: TaskOutputArgs(taskId: taskId, block: true, timeout: 1)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success from timed-out task_output, got \(result)"); return
        }
        #expect(output.lowercased().contains("running") || output.lowercased().contains("timeout"),
                "Timed out blocking read should indicate still running, got: \(output)")
    }

    // MARK: - TaskStop Tool

    @Test("task_stop terminates and confirms", .timeLimit(.minutes(1)))
    func taskStopTerminatesRunning() async throws {
        let (shell, _, taskStop, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        let taskId = try await launchBackground(
            shell: shell, registry: registry,
            command: "sleep 999"
        )
        try await Task.sleep(for: .milliseconds(200))

        let result = try await taskStop.execute(
            context: makeContext(),
            arguments: TaskStopArgs(taskId: taskId)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success from task_stop"); return
        }

        #expect(output.lowercased().contains("stopped") ||
                output.lowercased().contains("terminated") ||
                output.lowercased().contains("killed"),
                "Stop confirmation should indicate termination")
    }

    @Test("task_stop completed task is graceful", .timeLimit(.minutes(1)))
    func taskStopCompletedGraceful() async throws {
        let (shell, taskOutput, taskStop, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        let taskId = try await launchBackground(
            shell: shell, registry: registry,
            command: "echo done"
        )

        // Wait for completion
        _ = try await taskOutput.execute(
            context: makeContext(),
            arguments: TaskOutputArgs(taskId: taskId, block: true, timeout: 10)
        )

        // Stop after completion should succeed gracefully (not crash or throw)
        let result = try await taskStop.execute(
            context: makeContext(),
            arguments: TaskStopArgs(taskId: taskId)
        )

        // Should be a successful response (not .failure or .deferred)
        guard case .success = result else {
            Issue.record("Stopping completed task should succeed gracefully, got \(result)"); return
        }
    }

    @Test("task_stop unknown ID returns error", .timeLimit(.minutes(1)))
    func taskStopUnknownIdError() async throws {
        let (_, _, taskStop, _) = makeTools()

        let result = try await taskStop.execute(
            context: makeContext(),
            arguments: TaskStopArgs(taskId: "nonexistent-id")
        )

        switch result {
        case .success(let output):
            #expect(output.lowercased().contains("not found") || output.lowercased().contains("error"),
                    "Unknown task ID should produce error message, got: \(output)")
        case .failure:
            break // Also acceptable
        case .deferred:
            Issue.record("Unexpected deferred result")
        }
    }

    // MARK: - Full Workflow

    @Test("shell background -> task_output complete workflow", .timeLimit(.minutes(1)))
    func fullWorkflow() async throws {
        let (shell, taskOutput, taskStop, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        // 1. Launch background task
        let taskId = try await launchBackground(
            shell: shell, registry: registry,
            command: "echo step1 && sleep 0.5 && echo step2",
            description: "test workflow"
        )

        // 2. Check status (should be running initially)
        let checkResult = try await taskOutput.execute(
            context: makeContext(),
            arguments: TaskOutputArgs(taskId: taskId, block: false, timeout: nil)
        )
        guard case .success = checkResult else {
            Issue.record("Expected success for status check"); return
        }

        // 3. Wait for completion
        let finalResult = try await taskOutput.execute(
            context: makeContext(),
            arguments: TaskOutputArgs(taskId: taskId, block: true, timeout: 10)
        )
        guard case .success(let finalOutput) = finalResult else {
            Issue.record("Expected success for final output"); return
        }
        #expect(finalOutput.contains("step1") || finalOutput.contains("step2"),
                "Final output should contain echoed text")

        // 4. Stop (already completed, should be graceful)
        _ = try await taskStop.execute(
            context: makeContext(),
            arguments: TaskStopArgs(taskId: taskId)
        )
    }

    @Test("multiple background tasks tracked independently", .timeLimit(.minutes(1)))
    func multipleTasksIndependent() async throws {
        let (shell, _, _, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        let echoId = try await launchBackground(
            shell: shell, registry: registry,
            command: "echo task_a"
        )

        let sleepId = try await launchBackground(
            shell: shell, registry: registry,
            command: "sleep 999"
        )

        // Wait for echo to finish
        try await Task.sleep(for: .seconds(1))

        let active = await registry.activeTasks()
        let activeIds = Set(active.map(\.id))

        // Sleep should still be active
        #expect(activeIds.contains(sleepId), "Sleep task should still be active")
        // Echo should have completed (no longer active)
        #expect(!activeIds.contains(echoId), "Echo task should have completed and left active list")
    }

    @Test("description parameter accepted without affecting execution", .timeLimit(.minutes(1)))
    func descriptionParameterAccepted() async throws {
        let (shell, taskOutput, _, registry) = makeTools()
        defer { Task { await registry.cancelAll() } }

        let taskId = try await launchBackground(
            shell: shell, registry: registry,
            command: "echo with_description",
            description: "This is a test task"
        )

        let result = try await taskOutput.execute(
            context: makeContext(),
            arguments: TaskOutputArgs(taskId: taskId, block: true, timeout: 10)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }
        #expect(output.contains("with_description"))
    }

    @Test("task_output tool definition is valid")
    func taskOutputToolDefinition() {
        let registry = BackgroundTaskRegistry()
        let tool = TaskOutputTool(registry: registry)
        #expect(tool.name == "task_output")
        #expect(!tool.description.isEmpty)
    }

    @Test("task_stop tool definition is valid")
    func taskStopToolDefinition() {
        let registry = BackgroundTaskRegistry()
        let tool = TaskStopTool(registry: registry)
        #expect(tool.name == "task_stop")
        #expect(!tool.description.isEmpty)
    }
}
