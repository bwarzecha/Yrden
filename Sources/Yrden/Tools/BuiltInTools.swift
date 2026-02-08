/// Factory that creates all built-in tools with shared configuration.
///
/// Creates ShellTool, ReadFileTool, and WriteFileTool with a shared
/// PathValidator, ensuring consistent security boundaries across tools.
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

    /// All tools as an array, ready to pass to Agent.
    public var all: [any Tool] { [shell, readFile, writeFile] }

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

        self.shell = ShellTool(
            environment: env,
            pathValidator: validator,
            workingDirectory: workingDirectory,
            requiresApproval: shellApprovalRequired
        )

        self.readFile = ReadFileTool(pathValidator: validator)
        self.writeFile = WriteFileTool(pathValidator: validator)
    }
}
