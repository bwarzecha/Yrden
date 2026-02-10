/// File pattern matching tool using glob patterns.
///
/// Enumerates files matching a glob pattern, sorted by modification time
/// (newest first). Respects .gitignore by default.

import Foundation

@Schema(description: "Find files matching a glob pattern")
public struct GlobToolArgs {
    @Guide(description: "Glob pattern to match (e.g. '**/*.swift')")
    public let pattern: String

    @Guide(description: "Directory to search in (defaults to working directory)")
    public let path: String?
}

public struct GlobTool: TypedTool {
    public typealias Args = GlobToolArgs

    public let name = "glob"
    public let description = """
        Find files matching a glob pattern. Use this to discover files by name or extension \
        before reading or editing them.

        Pattern syntax:
        - * matches any characters within a directory (e.g. '*.swift')
        - ** matches across directories (e.g. '**/*.swift' finds all Swift files recursively)
        - ? matches a single character, [] matches character sets, {} matches alternatives

        Usage:
        - Results are sorted by modification time (newest first).
        - Returns relative paths from the search directory.
        - Respects .gitignore by default.
        - Use the path parameter to search in a specific directory.

        Cross-tool tips:
        - glob then read_file: Use glob to find files, then read_file to inspect them.
        - glob then grep: Use glob to confirm a file exists, then grep to search its contents.
        - Use grep instead when searching by file content rather than file name.
        """

    public let pathValidator: PathValidator
    public let workingDirectory: String
    public let maxResults: Int
    public let respectGitignore: Bool

    public init(
        pathValidator: PathValidator,
        workingDirectory: String,
        maxResults: Int = 1000,
        respectGitignore: Bool = true
    ) {
        self.pathValidator = pathValidator
        self.workingDirectory = workingDirectory
        self.maxResults = maxResults
        self.respectGitignore = respectGitignore
    }

    public func execute(
        context: ToolContext,
        arguments: GlobToolArgs
    ) async throws -> ToolResult<String> {
        // Resolve search directory
        let searchDir: String
        if let path = arguments.path {
            do {
                searchDir = try pathValidator.validateRead(path)
            } catch {
                return .failure(error)
            }
        } else {
            searchDir = workingDirectory
        }

        // Check directory exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: searchDir, isDirectory: &isDir),
              isDir.boolValue else {
            return .error("Directory not found: \(arguments.path ?? workingDirectory)")
        }

        let enumerator = FileEnumerator(
            rootDirectory: searchDir,
            pathValidator: pathValidator,
            respectGitignore: respectGitignore,
            globPattern: arguments.pattern
        )

        let files: [FileEntry]
        do {
            files = try enumerator.enumerate()
        } catch {
            return .error("Enumeration error: \(error.localizedDescription)")
        }

        // Sort by modification time, newest first
        let sorted = files.sorted { $0.modificationDate > $1.modificationDate }

        // Apply maxResults
        let truncated = sorted.count > maxResults
        let limited = truncated ? Array(sorted.prefix(maxResults)) : sorted

        if limited.isEmpty {
            return .success("No files matched pattern '\(arguments.pattern)'")
        }

        var output = limited.map { $0.relativePath }.joined(separator: "\n")

        if truncated {
            output += "\n\n[Results truncated. Showing \(maxResults) of \(sorted.count) files. Use a more specific pattern to see all results.]"
        } else {
            output += "\n\n[\(limited.count) files matched]"
        }

        return .success(output)
    }
}
