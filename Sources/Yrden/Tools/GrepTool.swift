/// Ripgrep-backed search tool.
///
/// Shells out to `rg` for performance (handles gitignore, binary skipping natively).
/// Parses `--json` output and formats results per the requested output mode.

import Foundation

@Schema(description: "Search file contents using ripgrep")
public struct GrepToolArgs {
    @Guide(description: "The regex pattern to search for")
    public let pattern: String

    @Guide(description: "Directory to search in (defaults to working directory)")
    public let path: String?

    @Guide(description: "Glob pattern to filter files (e.g. '*.swift')")
    public let glob: String?

    @Guide(description: "Output mode: 'files', 'content', or 'count'")
    public let outputMode: String?

    @Guide(description: "Whether to search case-insensitively")
    public let caseInsensitive: Bool?

    @Guide(description: "Number of context lines around matches (implies output_mode: 'content')")
    public let contextLines: Int?

    @Guide(description: "Maximum number of results to return")
    public let maxResults: Int?

    private enum CodingKeys: String, CodingKey {
        case pattern, path, glob
        case outputMode = "output_mode"
        case caseInsensitive = "case_insensitive"
        case contextLines = "context_lines"
        case maxResults = "max_results"
    }
}

public struct GrepTool: TypedTool {
    public typealias Args = GrepToolArgs

    public let name = "grep"
    public let description = "Search file contents using ripgrep (rg). Supports regex patterns, glob filtering, and multiple output modes. Respects .gitignore and skips binary files by default."

    public let pathValidator: PathValidator
    public let workingDirectory: String
    public let ripgrepPath: String?
    public let maxResults: Int
    public let totalCharacterLimit: Int

    public init(
        pathValidator: PathValidator,
        workingDirectory: String,
        ripgrepPath: String? = nil,
        maxResults: Int = 1000,
        totalCharacterLimit: Int = 100_000
    ) {
        self.pathValidator = pathValidator
        self.workingDirectory = workingDirectory
        self.ripgrepPath = ripgrepPath
        self.maxResults = maxResults
        self.totalCharacterLimit = totalCharacterLimit
    }

    public func execute(
        context: ToolContext,
        arguments: GrepToolArgs
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

        // Validate output mode — auto-switch to "content" when context_lines is set
        var mode = arguments.outputMode ?? "files"
        if arguments.contextLines != nil && arguments.outputMode == nil {
            mode = "content"
        }
        guard ["files", "content", "count"].contains(mode) else {
            return .error("Invalid output_mode '\(arguments.outputMode ?? "")'. Must be 'files', 'content', or 'count'.")
        }

        // Find rg binary
        let rgPath: String
        if let configured = ripgrepPath {
            guard FileManager.default.isExecutableFile(atPath: configured) else {
                return .error("ripgrep (rg) not found at \(configured). Install via: brew install ripgrep")
            }
            rgPath = configured
        } else {
            guard let found = findRipgrep() else {
                return .error("ripgrep (rg) not found. Install via: brew install ripgrep")
            }
            rgPath = found
        }

        // Build rg arguments
        var args: [String] = []

        switch mode {
        case "files":
            args.append("--files-with-matches")
        case "count":
            args.append("--count")
        case "content":
            if let ctx = arguments.contextLines {
                args += ["-C", "\(ctx)"]
            }
            args.append("--line-number")
        default:
            break
        }

        if arguments.caseInsensitive == true {
            args.append("--ignore-case")
        }

        if let glob = arguments.glob {
            args += ["--glob", glob]
        }

        let effectiveMaxResults = arguments.maxResults ?? maxResults
        args += ["--max-count", "\(effectiveMaxResults)"]

        args.append(arguments.pattern)
        args.append(searchDir)

        // Run rg — use parent directory as CWD when searching a specific file
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rgPath)
        process.arguments = args
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: searchDir, isDirectory: &isDir), !isDir.boolValue {
            process.currentDirectoryURL = URL(fileURLWithPath: searchDir).deletingLastPathComponent()
        } else {
            process.currentDirectoryURL = URL(fileURLWithPath: searchDir)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .error("Failed to run ripgrep: \(error.localizedDescription)")
        }

        // Read all pipe data BEFORE waiting for exit to avoid pipe buffer deadlock.
        // If we wait for exit first and the output exceeds ~64KB, the process blocks
        // writing and we block waiting — deadlock.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        // Exit code 0 = matches found, 1 = no matches, 2 = error
        let exitCode = process.terminationStatus

        if exitCode == 2 {
            let errorMsg = stderr.isEmpty ? "ripgrep error" : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .error("rg error: \(errorMsg)")
        }

        if exitCode == 1 || stdout.isEmpty {
            return .success("No matches found for '\(arguments.pattern)'")
        }

        // Format output: make paths relative to search dir
        var output = stdout
        let searchDirWithSlash = searchDir.hasSuffix("/") ? searchDir : searchDir + "/"
        output = output.replacingOccurrences(of: searchDirWithSlash, with: "")

        // Apply total character limit
        output = OutputTruncation.truncate(output, maxLength: totalCharacterLimit)

        return .success(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Private

    private func findRipgrep() -> String? {
        let candidates = [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/usr/bin/rg",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try which
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["rg"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty { return path }
            }
        } catch {}

        return nil
    }
}
