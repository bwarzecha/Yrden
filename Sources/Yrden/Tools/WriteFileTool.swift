/// Write content to a file, creating parent directories if needed.
///
/// Writes atomically to prevent partial writes. Enforces a maximum
/// write size to prevent accidental multi-GB writes from LLM output.

import Foundation

@Schema(description: "Write content to a file, creating it if it doesn't exist")
public struct WriteFileArgs {
    @Guide(description: "Absolute path to the file")
    public let path: String

    @Guide(description: "Content to write to the file")
    public let content: String
}

public struct WriteFileTool: TypedTool {
    public typealias Args = WriteFileArgs

    public let name = "write_file"
    public let description = "Write content to a file. Creates parent directories if they don't exist. Overwrites existing files atomically (no partial writes). Maximum size: 10 MB."

    public let pathValidator: PathValidator
    public let createDirectories: Bool
    public let maxWriteSize: Int

    public init(
        pathValidator: PathValidator,
        createDirectories: Bool = true,
        maxWriteSize: Int = 10_000_000
    ) {
        self.pathValidator = pathValidator
        self.createDirectories = createDirectories
        self.maxWriteSize = maxWriteSize
    }

    public func execute(
        context: ToolContext,
        arguments: WriteFileArgs
    ) async throws -> ToolResult<String> {
        do {
            let resolvedPath = try pathValidator.validateWrite(arguments.path)

            // Size check
            let byteCount = arguments.content.utf8.count
            if byteCount > maxWriteSize {
                return .error("Content size \(byteCount) bytes exceeds maximum \(maxWriteSize) bytes.")
            }

            // Create parent directories if needed
            if createDirectories {
                let parent = URL(fileURLWithPath: resolvedPath).deletingLastPathComponent().path
                try FileManager.default.createDirectory(
                    atPath: parent,
                    withIntermediateDirectories: true
                )
            }

            // Write atomically
            try arguments.content.write(
                toFile: resolvedPath,
                atomically: true,
                encoding: .utf8
            )

            return .success("Wrote \(byteCount) bytes to \(arguments.path)")

        } catch let error as PathValidationError {
            return .error(error.localizedDescription ?? String(describing: error))
        } catch {
            return .error("Failed to write \(arguments.path): \(error.localizedDescription)")
        }
    }
}
