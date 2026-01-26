/// File write tool with human-in-the-loop approval.

import Foundation
import Yrden

/// File write tool that requires human approval.
///
/// Demonstrates the deferred/human-in-the-loop pattern.
struct FileWriteTool: AgentTool {
    typealias Deps = AppDependencies
    typealias Args = FileWriteArgs
    typealias Output = String

    var name: String { "write_file" }
    var description: String {
        "Write content to a file. Requires user approval before writing. Use for saving text, notes, or code."
    }

    func call(
        context: AgentContext<AppDependencies>,
        arguments: Args
    ) async throws -> ToolResult<String> {
        // Validate filename
        guard !arguments.filename.isEmpty else {
            return .retry(message: "Filename cannot be empty.")
        }

        // Sanitize filename (remove path separators)
        let sanitized = arguments.filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")

        // Return deferred to require user approval
        // The agent will pause and the UI will show an approval dialog
        return .deferred(
            .needsApproval(
                id: context.toolCallID ?? UUID().uuidString,
                reason: "Write \(arguments.content.count) characters to '\(sanitized)'"
            )
        )
    }

    /// Execute after approval.
    ///
    /// This is called by the app when the user approves the write operation.
    static func executeApproved(
        args: FileWriteArgs,
        deps: AppDependencies
    ) throws -> String {
        // Ensure base directory exists
        try FileManager.default.createDirectory(
            at: deps.baseDirectory,
            withIntermediateDirectories: true
        )

        // Sanitize and create file path
        let sanitized = args.filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let filePath = deps.baseDirectory.appendingPathComponent(sanitized)

        // Write content
        try args.content.write(to: filePath, atomically: true, encoding: .utf8)

        return "Successfully wrote \(args.content.count) characters to \(filePath.lastPathComponent)"
    }
}

/// Arguments for file write.
@Schema(description: "File write parameters")
struct FileWriteArgs {
    @Guide(description: "Name of the file to write")
    let filename: String

    @Guide(description: "Content to write to the file")
    let content: String
}
