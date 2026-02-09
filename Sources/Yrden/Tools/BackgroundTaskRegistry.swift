/// Registry for background shell processes with lifecycle management.
///
/// Thread-safe via NSLock with synchronous helper methods (NSLock cannot be
/// called directly from async contexts in Swift 6). Uses `kill(-pgid, signal)`
/// to kill entire process groups, preventing orphan child processes.
/// Synchronous `deinit` ensures no orphans survive when the registry goes out of scope.

import Foundation

// MARK: - Supporting Types

public enum TaskStatus: Sendable, Equatable {
    case running
    case completed
}

public struct TaskSnapshot: Sendable {
    public let output: String
    public let status: TaskStatus
    public let exitCode: Int32?
}

public struct TaskInfo: Sendable {
    public let id: String
    public let pid: Int32
}

public struct TaskCompletion: Sendable {
    public let taskId: String
    public let exitCode: Int32
    public let completedAt: Date
}

public enum BackgroundTaskError: Error, LocalizedError {
    case taskNotFound(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .taskNotFound(let id): return "Task not found: \(id)"
        case .timeout: return "Operation timed out"
        }
    }
}

// MARK: - ManagedTask

private final class ManagedTask: @unchecked Sendable {
    let id: String
    let process: Process
    let outputBuffer: OutputBuffer
    var completedAt: Date?

    init(id: String, process: Process) {
        self.id = id
        self.process = process
        self.outputBuffer = OutputBuffer()
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    static let maxSize = 1_048_576 // 1MB

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = Self.maxSize - data.count
        if remaining > 0 {
            data.append(newData.prefix(remaining))
        }
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - BackgroundTaskRegistry

public final class BackgroundTaskRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var tasks: [String: ManagedTask] = [:]
    private var counter = 0

    /// How long to wait for SIGTERM graceful shutdown before escalating to SIGKILL.
    public let gracefulShutdownTimeout: Duration

    public init(gracefulShutdownTimeout: Duration = .seconds(5)) {
        self.gracefulShutdownTimeout = gracefulShutdownTimeout
    }

    deinit {
        lock.lock()
        let running = tasks.values.filter { $0.process.isRunning }
        lock.unlock()
        for task in running {
            kill(-task.process.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Synchronous Lock Helpers

    /// Execute a closure while holding the lock. Called from async methods
    /// because NSLock.lock()/unlock() cannot be called directly from async contexts.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Throwing variant of locked().
    private func lockedThrowing<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Launch

    @discardableResult
    public func launch(
        command: String,
        workingDirectory: String,
        environment: [String: String]? = nil,
        timeout: Duration? = nil
    ) async -> String {
        let taskId = nextTaskId()

        let process = Process()
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        if let env = environment {
            process.environment = env
        }

        let managed = ManagedTask(id: taskId, process: process)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Read stdout/stderr into buffer
        let buffer = managed.outputBuffer
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { buffer.append(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { buffer.append(data) }
        }

        locked { tasks[taskId] = managed }

        do {
            try process.run()
        } catch {
            locked { tasks.removeValue(forKey: taskId) }
            return taskId
        }

        // Monitor completion in background
        let taskTimeout = timeout
        Task.detached { [weak self] in
            // Timeout handling
            if let timeout = taskTimeout {
                let deadline = Date().addingTimeInterval(Double(timeout.components.seconds))
                while process.isRunning && Date() < deadline && !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                }
                if process.isRunning {
                    kill(-process.processIdentifier, SIGTERM)
                    let shutdownSeconds = self?.gracefulShutdownTimeout ?? .seconds(5)
                    let termDeadline = Date().addingTimeInterval(Double(shutdownSeconds.components.seconds))
                    while process.isRunning && Date() < termDeadline && !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
                    }
                    if process.isRunning {
                        kill(-process.processIdentifier, SIGKILL)
                    }
                }
            }

            process.waitUntilExit()

            // Clean up readability handlers
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            // Read any remaining data
            let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingStdout.isEmpty { buffer.append(remainingStdout) }
            if !remainingStderr.isEmpty { buffer.append(remainingStderr) }

            // Mark completed
            self?.markCompleted(taskId: taskId)
        }

        return taskId
    }

    // MARK: - Get Output

    public func getOutput(
        taskId: String,
        block: Bool,
        timeout: Duration? = nil
    ) async throws -> TaskSnapshot {
        let task = try lockedThrowing {
            guard let t = tasks[taskId] else {
                throw BackgroundTaskError.taskNotFound(taskId)
            }
            return t
        }

        if block {
            let deadline: Date
            if let timeout {
                deadline = Date().addingTimeInterval(Double(timeout.components.seconds))
            } else {
                deadline = .distantFuture
            }

            while task.process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        let isRunning = task.process.isRunning
        // Ensure completedAt is set when we observe completion.
        // The monitoring task may not have run markCompleted() yet.
        if !isRunning {
            markCompleted(taskId: taskId)
        }
        return TaskSnapshot(
            output: task.outputBuffer.string,
            status: isRunning ? .running : .completed,
            exitCode: isRunning ? nil : task.process.terminationStatus
        )
    }

    // MARK: - Stop

    public func stop(taskId: String) async throws {
        let task = try lockedThrowing {
            guard let t = tasks[taskId] else {
                throw BackgroundTaskError.taskNotFound(taskId)
            }
            return t
        }

        guard task.process.isRunning else { return }

        // SIGTERM the entire process group
        kill(-task.process.processIdentifier, SIGTERM)

        // Poll for graceful shutdown, checking every 50ms
        let shutdownSeconds = Double(gracefulShutdownTimeout.components.seconds)
        let deadline = Date().addingTimeInterval(shutdownSeconds)
        while task.process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        // Escalate to SIGKILL if still running
        if task.process.isRunning {
            kill(-task.process.processIdentifier, SIGKILL)
            // Brief wait for SIGKILL to take effect
            let killDeadline = Date().addingTimeInterval(1)
            while task.process.isRunning && Date() < killDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    // MARK: - Cancel All

    public func cancelAll() async {
        let running = locked { tasks.values.filter { $0.process.isRunning } }

        // SIGTERM all
        for task in running {
            kill(-task.process.processIdentifier, SIGTERM)
        }

        let shutdownSeconds = Double(gracefulShutdownTimeout.components.seconds)
        let deadline = Date().addingTimeInterval(shutdownSeconds)
        while Date() < deadline && !Task.isCancelled {
            let stillRunning = locked { tasks.values.contains { $0.process.isRunning } }
            if !stillRunning { break }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }

        // SIGKILL survivors
        let survivors = locked { tasks.values.filter { $0.process.isRunning } }

        for task in survivors {
            kill(-task.process.processIdentifier, SIGKILL)
        }

        if !survivors.isEmpty {
            // Brief wait for SIGKILL to take effect
            let killDeadline = Date().addingTimeInterval(1)
            while Date() < killDeadline && !Task.isCancelled {
                let stillRunning = locked { tasks.values.contains { $0.process.isRunning } }
                if !stillRunning { break }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            }
        }

        // Mark all completed
        locked {
            let now = Date()
            for task in tasks.values where task.completedAt == nil && !task.process.isRunning {
                task.completedAt = now
            }
        }
    }

    // MARK: - Completions

    public func completedSince(_ date: Date) async -> [TaskCompletion] {
        // Eagerly mark any tasks that have stopped but haven't been marked yet.
        // The monitoring Task.detached calls markCompleted() asynchronously,
        // so there's a race where the process is done but completedAt is nil.
        let snapshot = locked { Array(tasks.values) }
        let now = Date()
        for task in snapshot where task.completedAt == nil && !task.process.isRunning {
            locked { task.completedAt = now }
        }

        return snapshot.compactMap { task in
            guard let completedAt = task.completedAt, completedAt > date else {
                return nil
            }
            return TaskCompletion(
                taskId: task.id,
                exitCode: task.process.terminationStatus,
                completedAt: completedAt
            )
        }
    }

    // MARK: - Active Tasks

    public func activeTasks() async -> [TaskInfo] {
        let snapshot = locked { Array(tasks.values) }

        return snapshot.compactMap { task in
            guard task.process.isRunning else { return nil }
            return TaskInfo(id: task.id, pid: task.process.processIdentifier)
        }
    }

    public func hasRunningTasks() async -> Bool {
        locked { tasks.values.contains { $0.process.isRunning } }
    }

    // MARK: - Wait For All

    public func waitForAll(timeout: Duration? = nil) async throws {
        let deadline: Date
        if let timeout {
            deadline = Date().addingTimeInterval(Double(timeout.components.seconds))
        } else {
            deadline = .distantFuture
        }

        while Date() < deadline {
            let running = await hasRunningTasks()
            if !running { return }
            try await Task.sleep(for: .milliseconds(100))
        }

        let stillRunning = await hasRunningTasks()
        if stillRunning {
            throw BackgroundTaskError.timeout
        }
    }

    // MARK: - Private

    private func nextTaskId() -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return "bg_\(counter)_\(UUID().uuidString.prefix(8))"
    }

    private func markCompleted(taskId: String) {
        locked { tasks[taskId]?.completedAt = Date() }
    }
}
