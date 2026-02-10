/// Read a file's contents with line numbers, offset/limit, and truncation.
///
/// Three-layer defense against token waste:
/// 1. Line count limit (default 500)
/// 2. Per-line character truncation (default 4K)
/// 3. Total character cap (default 100K) via OutputTruncation

import Foundation

@Schema(description: "Read a file's contents with optional line range")
public struct ReadFileArgs {
    @Guide(description: "Absolute path to the file")
    public let path: String

    @Guide(description: "Starting line number (1-based)")
    public let offset: Int?

    @Guide(description: "Maximum number of lines to read")
    public let limit: Int?
}

public struct ReadFileTool: TypedTool {
    public typealias Args = ReadFileArgs

    public let name = "read_file"
    public let description = """
        Read a file's contents with line numbers. Use this to inspect files, verify edits, \
        and understand code before making changes.

        Output format: Each line is printed as N<TAB>content where N is the 1-based line \
        number and a tab character separates it from the exact file content. Blank lines appear \
        as just N<TAB> with nothing after the tab.

        Usage:
        - Always read a file before editing it with edit_file.
        - Use offset and limit to paginate large files (default limit: 500 lines).
        - After editing, read the file again to verify your changes.
        - Supports ~ (tilde) and relative paths.

        Cross-tool tips:
        - read_file then edit_file: Use the content AFTER the tab as edit_file's old_string. \
        Never include the line number or tab prefix — old_string must be raw file content.
        - grep then read_file: Use grep to find line numbers, then read_file with offset to \
        see surrounding context.
        - glob then read_file: Use glob to discover files by name, then read_file to inspect them.
        """

    public let pathValidator: PathValidator
    public let totalCharacterLimit: Int
    public let perLineCharacterLimit: Int
    public let defaultLineLimit: Int

    public init(
        pathValidator: PathValidator,
        totalCharacterLimit: Int = 100_000,
        perLineCharacterLimit: Int = 4_000,
        defaultLineLimit: Int = 500
    ) {
        self.pathValidator = pathValidator
        self.totalCharacterLimit = totalCharacterLimit
        self.perLineCharacterLimit = perLineCharacterLimit
        self.defaultLineLimit = defaultLineLimit
    }

    public func execute(
        context: ToolContext,
        arguments: ReadFileArgs
    ) async throws -> ToolResult<String> {
        do {
            let resolvedPath = try pathValidator.validateRead(arguments.path)
            let url = URL(fileURLWithPath: resolvedPath)

            // Check file exists and is not a directory
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir) else {
                return .error("File not found: \(arguments.path)")
            }
            if isDir.boolValue {
                return .error("\(arguments.path) is a directory, not a file. Use glob to list directory contents.")
            }

            // Binary check: read first 8KB and look for null bytes
            if try isBinaryFile(url: url) {
                return .error("\(arguments.path) appears to be a binary file (null bytes detected in first 8KB).")
            }

            // Get file size for header
            let attrs = try FileManager.default.attributesOfItem(atPath: resolvedPath)
            let fileSize = (attrs[.size] as? UInt64) ?? 0

            let offset = max(1, arguments.offset ?? 1)
            let limit = arguments.limit ?? defaultLineLimit

            // Read file and split on newlines, preserving empty lines
            let fileContent = try String(contentsOf: url, encoding: .utf8)

            // Handle empty file
            if fileContent.isEmpty {
                let header = "[File: \(arguments.path) | Lines 0-0 of 0 | \(formatSize(fileSize))]"
                return .success(header)
            }

            var allLines = fileContent.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            // File ending with \n has no trailing "line" — trim the phantom empty element
            if fileContent.hasSuffix("\n") && !allLines.isEmpty {
                allLines.removeLast()
            }
            let totalLineCount = allLines.count

            var linesRead = 0
            var outputLines: [(lineNumber: Int, content: String)] = []
            var startLine = 0
            var endLine = 0
            var hitLimit = false

            for line in allLines {
                linesRead += 1

                // Skip lines before offset
                if linesRead < offset { continue }

                // Stop after limit
                if outputLines.count >= limit {
                    hitLimit = true
                    break
                }

                if startLine == 0 { startLine = linesRead }
                endLine = linesRead

                // Per-line truncation
                let truncatedLine: String
                if line.count > perLineCharacterLimit {
                    let overflow = line.count - perLineCharacterLimit
                    truncatedLine = String(line.prefix(perLineCharacterLimit)) + " [...+\(overflow) chars]"
                } else {
                    truncatedLine = line
                }

                outputLines.append((linesRead, truncatedLine))
            }

            // Build output with compact line numbers
            var result = outputLines.map { "\($0.lineNumber)\t\($0.content)" }
                .joined(separator: "\n")

            // Total character cap
            result = OutputTruncation.truncate(result, maxLength: totalCharacterLimit)

            // Prepend header with total line count
            let totalLabel = hitLimit ? "\(totalLineCount)" : "\(totalLineCount)"
            let header = "[File: \(arguments.path) | Lines \(startLine)-\(endLine) of \(totalLabel) | \(formatSize(fileSize))]"
            return .success(header + "\n" + result)

        } catch let error as PathValidationError {
            return .error(error.localizedDescription ?? String(describing: error))
        } catch {
            return .error("Failed to read \(arguments.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func isBinaryFile(url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        guard let data = try handle.read(upToCount: 8192) else { return false }
        return data.contains(0)
    }

    private func formatSize(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024.0
        if kb < 1 { return "\(bytes) B" }
        let mb = kb / 1024.0
        if mb < 1 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", mb)
    }
}
