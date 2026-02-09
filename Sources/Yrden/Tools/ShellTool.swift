/// Execute shell commands with CWD tracking, output truncation, and spillover.
///
/// Each command runs as a fresh process. Working directory persists between
/// calls via a sentinel marker appended to each command. Output exceeding
/// the character limit is truncated (head+tail) with full output saved
/// to a spillover file.

import Foundation

@Schema(description: "Execute a shell command")
public struct ShellToolArgs {
    @Guide(description: "Shell command to execute")
    public let command: String

    @Guide(description: "Working directory for the command")
    public let workingDirectory: String?

    @Guide(description: "Timeout in seconds (default: 120, max: 600)")
    public let timeout: Int?

    @Guide(description: "Run the command in the background and return immediately with a task ID")
    public let runInBackground: Bool?

    @Guide(description: "Description of what this background task does")
    public let description: String?

    private enum CodingKeys: String, CodingKey {
        case command
        case workingDirectory = "working_directory"
        case timeout
        case runInBackground = "run_in_background"
        case description
    }
}

public struct ShellTool: TypedTool {
    public typealias Args = ShellToolArgs

    public let name = "shell"

    public var description: String {
        var desc = "Execute a shell command and return its output. The user's full shell environment is available (Homebrew, nvm, pyenv, etc.). Working directory starts at \(initialWorkingDirectory) and persists between calls — if you cd, subsequent calls start from the new directory. Prefer absolute paths over cd. Output is truncated to \(maxOutputLength) characters; when truncated, full output is saved to a file whose path is shown."
        if let info = environmentInfo {
            desc += info.descriptionSuffix
        }
        return desc
    }

    public let initialWorkingDirectory: String
    public let maxOutputLength: Int
    public let spilloverDirectory: String
    public let defaultTimeout: Duration
    public let maxTimeout: Duration
    public let environment: ShellEnvironment
    public let pathValidator: PathValidator
    public var requiresApproval: Bool
    public let backgroundTaskRegistry: BackgroundTaskRegistry?
    public let environmentInfo: EnvironmentInfo?

    private let state: ShellToolState

    public init(
        environment: ShellEnvironment,
        pathValidator: PathValidator,
        workingDirectory: String,
        maxOutputLength: Int = 30_000,
        spilloverDirectory: String? = nil,
        defaultTimeout: Duration = .seconds(120),
        maxTimeout: Duration = .seconds(600),
        backgroundTaskRegistry: BackgroundTaskRegistry? = nil,
        requiresApproval: Bool = true,
        environmentInfo: EnvironmentInfo? = nil
    ) {
        self.environment = environment
        self.pathValidator = pathValidator
        self.initialWorkingDirectory = workingDirectory
        self.maxOutputLength = maxOutputLength
        self.spilloverDirectory = spilloverDirectory
            ?? NSTemporaryDirectory() + "yrden-shell-\(UUID().uuidString)"
        self.defaultTimeout = defaultTimeout
        self.maxTimeout = maxTimeout
        self.backgroundTaskRegistry = backgroundTaskRegistry
        self.requiresApproval = requiresApproval
        self.environmentInfo = environmentInfo
        self.state = ShellToolState(workingDirectory: workingDirectory)
    }

    public func execute(
        context: ToolContext,
        arguments: ShellToolArgs
    ) async throws -> ToolResult<String> {
        // Resolve CWD — validate requested directory against PathValidator
        let cwd: String
        if let requestedCwd = arguments.workingDirectory {
            do {
                cwd = try pathValidator.validateRead(requestedCwd)
            } catch {
                return .error("Working directory not allowed: \(requestedCwd)")
            }
        } else {
            cwd = await state.getCWD()
        }

        // Background mode — delegate to registry and return immediately
        if arguments.runInBackground == true {
            guard let registry = backgroundTaskRegistry else {
                return .error("Background execution not available: no task registry configured")
            }
            let timeoutSeconds = arguments.timeout.map { max(1, min($0, Int(maxTimeout.components.seconds))) }
                ?? Int(defaultTimeout.components.seconds)
            let taskId = await registry.launch(
                command: arguments.command,
                workingDirectory: cwd,
                environment: environment.variables,
                timeout: .seconds(timeoutSeconds)
            )
            let desc = arguments.description.map { " (\($0))" } ?? ""
            return .success("Background task started\(desc). Task ID: \(taskId)")
        }

        // Clamp timeout
        let timeoutSeconds = arguments.timeout.map { max(1, min($0, Int(maxTimeout.components.seconds))) }
            ?? Int(defaultTimeout.components.seconds)
        // Wrap command with CWD sentinel
        let wrappedCommand = """
        \(arguments.command); __yrden_exit=$?; echo ""; echo "__YRDEN_CWD__:$(pwd)"; exit $__yrden_exit
        """

        let shellPath = environment.shellPath

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shellPath)
            process.arguments = ["-c", wrappedCommand]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()

            // Read pipes on detached tasks to prevent deadlock (>64KB output).
            // These must start before waitUntilExit() to drain buffers concurrently.
            // Cap at 2x maxOutputLength to avoid unbounded memory usage from runaway processes.
            let outputCap = maxOutputLength * 2
            let stdoutTask = Task.detached {
                Self.readCapped(from: stdoutPipe.fileHandleForReading, limit: outputCap)
            }
            let stderrTask = Task.detached {
                Self.readCapped(from: stderrPipe.fileHandleForReading, limit: outputCap)
            }

            // Apply timeout by polling
            let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }

            if process.isRunning {
                process.terminate()
                try await Task.sleep(for: .seconds(1))
                if process.isRunning { kill(-process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                stdoutTask.cancel()
                stderrTask.cancel()
                return .success("Command timed out after \(timeoutSeconds) seconds.")
            }

            // Ensure process has fully terminated before reading pipes
            process.waitUntilExit()

            let stdoutData = await stdoutTask.value
            let stderrData = await stderrTask.value

            let exitCode = process.terminationStatus
            let output = (
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                exitCode: exitCode
            )

            // Parse and strip CWD sentinel from stdout (before merging with stderr)
            let (cleanStdout, newCwd) = parseSentinel(output.stdout)

            // Merge stdout and stderr
            var cleanOutput = cleanStdout
            if !output.stderr.isEmpty {
                if !cleanOutput.isEmpty { cleanOutput += "\n" }
                cleanOutput += output.stderr
            }
            if let newCwd {
                await state.setCWD(newCwd)
            }

            // Spillover if too large
            var finalOutput = cleanOutput
            if cleanOutput.count > maxOutputLength {
                finalOutput = OutputTruncation.truncate(cleanOutput, maxLength: maxOutputLength)
                if let spilloverPath = try? writeSpillover(cleanOutput) {
                    finalOutput += "\n\n[Full output saved to: \(spilloverPath)]"
                }
            }

            // Format output
            if output.exitCode != 0 {
                return .success("Exit code: \(output.exitCode)\n\(finalOutput)")
            }
            return .success(finalOutput)

        } catch {
            return .error("Shell execution failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private static let sentinelPrefix = "__YRDEN_CWD__:"

    /// Parse the CWD sentinel from the last occurrence in the output.
    private func parseSentinel(_ output: String) -> (cleanOutput: String, cwd: String?) {
        guard let range = output.range(of: Self.sentinelPrefix, options: .backwards) else {
            return (output, nil)
        }

        // Extract CWD value (everything from sentinel to end of line)
        let cwdStart = range.upperBound
        let cwdEnd = output[cwdStart...].firstIndex(of: "\n") ?? output.endIndex
        let cwd = String(output[cwdStart..<cwdEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove the sentinel line and any trailing newlines before it
        var cleanEnd = range.lowerBound
        // Remove the newline before the sentinel
        while cleanEnd > output.startIndex {
            let prev = output.index(before: cleanEnd)
            if output[prev] == "\n" || output[prev] == "\r" {
                cleanEnd = prev
            } else {
                break
            }
        }

        let clean = String(output[output.startIndex..<cleanEnd])
        return (clean, cwd.isEmpty ? nil : cwd)
    }

    /// Read from a file handle up to `limit` bytes, discarding the rest.
    /// Prevents unbounded memory usage from runaway processes.
    private static func readCapped(from handle: FileHandle, limit: Int) -> Data {
        var result = Data()
        let chunkSize = 65_536
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            let remaining = limit - result.count
            if remaining <= 0 {
                // Drain remaining data to avoid broken pipe, but don't store it
                while !handle.readData(ofLength: chunkSize).isEmpty {}
                break
            }
            result.append(chunk.prefix(remaining))
        }
        return result
    }

    private func writeSpillover(_ content: String) throws -> String {
        try FileManager.default.createDirectory(
            atPath: spilloverDirectory,
            withIntermediateDirectories: true
        )
        let filename = "shell-output-\(UUID().uuidString).txt"
        let path = spilloverDirectory + "/" + filename
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}

// MARK: - ShellToolState

actor ShellToolState {
    private var currentWorkingDirectory: String

    init(workingDirectory: String) {
        self.currentWorkingDirectory = workingDirectory
    }

    func getCWD() -> String {
        currentWorkingDirectory
    }

    func setCWD(_ cwd: String) {
        currentWorkingDirectory = cwd
    }
}
