/// Factory that creates all built-in tools with shared configuration.
///
/// Creates all 8 tools with a shared PathValidator and BackgroundTaskRegistry,
/// ensuring consistent security boundaries across tools.
///
/// ```swift
/// let tools = try await BuiltInTools(workingDirectory: "/Users/alice/project")
/// let agent = Agent(model: model, tools: tools.all)
/// ```

import Foundation

public struct BuiltInTools: Sendable {
    public let shell: ShellTool
    public let readFile: ReadFileTool
    public let writeFile: WriteFileTool
    public let editFile: EditFileTool
    public let glob: GlobTool
    public let grep: GrepTool
    public let taskOutput: TaskOutputTool
    public let taskStop: TaskStopTool
    public let registry: BackgroundTaskRegistry

    /// All 8 tools as an array, ready to pass to Agent.
    public var all: [any Tool] {
        [shell, readFile, writeFile, editFile, glob, grep, taskOutput, taskStop]
    }

    /// Core tools (6) — excludes background task management tools.
    public var core: [any Tool] {
        [shell, readFile, writeFile, editFile, glob, grep]
    }

    /// Read-only tools (3) — safe for untrusted contexts.
    public var readOnly: [any Tool] {
        [readFile, glob, grep]
    }

    public init(
        workingDirectory: String,
        allowedWriteDirectories: [String]? = nil,
        deniedReadDirectories: [String]? = nil,
        environment: ShellEnvironment? = nil,
        shellApprovalRequired: Bool = true
    ) async throws {
        let env: ShellEnvironment
        if let environment {
            env = environment
        } else {
            env = try await ShellEnvironment.captureUserEnvironment()
        }

        let writeDirs = allowedWriteDirectories ?? [workingDirectory]
        let deniedDirs = deniedReadDirectories ?? ["~/.ssh", "~/.aws", "~/.gnupg"]

        let validator = PathValidator(
            allowedWriteDirectories: writeDirs,
            deniedReadDirectories: deniedDirs
        )

        let registry = BackgroundTaskRegistry()
        self.registry = registry

        self.shell = ShellTool(
            environment: env,
            pathValidator: validator,
            workingDirectory: workingDirectory,
            backgroundTaskRegistry: registry,
            requiresApproval: shellApprovalRequired
        )

        self.readFile = ReadFileTool(pathValidator: validator)
        self.writeFile = WriteFileTool(pathValidator: validator)
        self.editFile = EditFileTool(pathValidator: validator)
        self.glob = GlobTool(pathValidator: validator, workingDirectory: workingDirectory)
        self.grep = GrepTool(pathValidator: validator, workingDirectory: workingDirectory)
        self.taskOutput = TaskOutputTool(registry: registry)
        self.taskStop = TaskStopTool(registry: registry)
    }
}
