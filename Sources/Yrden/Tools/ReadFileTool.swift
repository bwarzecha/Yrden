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
    public let description = "Read a file's contents with line numbers. Returns at most 500 lines starting from offset. Individual lines longer than 4,000 characters are truncated. Total output capped at 100,000 characters. Use offset and limit to paginate through large files."

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

            // Check file exists
            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                return .error("File not found: \(arguments.path)")
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

            // Stream lines — break early after limit to avoid iterating entire file
            var linesRead = 0
            var outputLines: [(lineNumber: Int, content: String)] = []
            var startLine = 0
            var endLine = 0
            var hitLimit = false

            for try await line in url.lines {
                linesRead += 1

                // Skip lines before offset
                if linesRead < offset { continue }

                // Stop after limit — don't iterate rest of file
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

            // Handle empty file
            if linesRead == 0 {
                let header = "[File: \(arguments.path) | Lines 0-0 of 0 | \(formatSize(fileSize))]"
                return .success(header)
            }

            // Build output with compact line numbers
            var result = outputLines.map { "\($0.lineNumber): \($0.content)" }
                .joined(separator: "\n")

            // Total character cap
            result = OutputTruncation.truncate(result, maxLength: totalCharacterLimit)

            // Prepend header — indicate "more" when we broke early
            let totalLabel = hitLimit ? "\(linesRead)+" : "\(linesRead)"
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
