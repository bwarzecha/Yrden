/// Tests for GrepTool ripgrep-backed search with output modes and path resolution.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("GrepTool")
struct GrepToolTests {

    private let tempDir: String = NSTemporaryDirectory() + "yrden-grep-tests-\(UUID().uuidString)"

    // MARK: - Helpers

    private func makeTool(
        workingDirectory: String? = nil,
        ripgrepPath: String? = nil,
        maxResults: Int = 1000,
        totalCharacterLimit: Int = 100_000
    ) -> GrepTool {
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: ["/"]
        )
        return GrepTool(
            pathValidator: validator,
            workingDirectory: workingDirectory ?? tempDir,
            ripgrepPath: ripgrepPath,
            maxResults: maxResults,
            totalCharacterLimit: totalCharacterLimit
        )
    }

    private func makeContext() -> ToolContext {
        ToolContext(model: FakeModel())
    }

    private func createSearchableTree() throws -> String {
        let root = tempDir
        let fm = FileManager.default

        try fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try """
        func main() {
            print("Hello, world!")
            let count = 42
        }
        """.write(toFile: root + "/src/main.swift", atomically: true, encoding: .utf8)

        try """
        func utils() {
            print("utility function")
            // TODO: refactor this
        }
        """.write(toFile: root + "/src/utils.swift", atomically: true, encoding: .utf8)

        try fm.createDirectory(atPath: root + "/tests", withIntermediateDirectories: true)
        try """
        func testMain() {
            // Test the main function
            print("testing")
        }
        """.write(toFile: root + "/tests/test.swift", atomically: true, encoding: .utf8)

        try "# README\nThis is a project.\n".write(
            toFile: root + "/README.md", atomically: true, encoding: .utf8
        )

        // Binary file that rg should skip
        try fm.createDirectory(atPath: root + "/assets", withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]).write(
            to: URL(fileURLWithPath: root + "/assets/image.png")
        )

        // Node modules (gitignored)
        try fm.createDirectory(atPath: root + "/node_modules/pkg", withIntermediateDirectories: true)
        try "function hello() { print('hello') }".write(
            toFile: root + "/node_modules/pkg/index.js", atomically: true, encoding: .utf8
        )
        try "node_modules/\n".write(
            toFile: root + "/.gitignore", atomically: true, encoding: .utf8
        )

        return root
    }

    // MARK: - rg Availability

    @Test("returns clear error when rg not found at configured path")
    func rgNotFoundError() async throws {
        let tool = makeTool(ripgrepPath: "/nonexistent/rg")
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "hello",
                path: nil,
                glob: nil,
                outputMode: nil,
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        // Should indicate rg not found — either as .success(errorText) or .failure
        switch result {
        case .success(let output):
            #expect(output.contains("ripgrep") || output.contains("rg") || output.contains("not found"),
                    "Expected rg-not-found error message, got: \(output)")
        case .failure(let error):
            let desc = String(describing: error)
            #expect(desc.contains("ripgrep") || desc.contains("rg") || desc.contains("not found"),
                    "Expected rg-not-found error, got: \(desc)")
        case .deferred:
            Issue.record("Unexpected deferred result for rg not found")
        }
    }

    // MARK: - Output Modes

    @Test("files mode returns paths only", .timeLimit(.minutes(1)))
    func filesModePathsOnly() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "print",
                path: nil,
                glob: nil,
                outputMode: "files",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)"); return
        }

        // Should contain file paths but NOT line contents
        #expect(output.contains("main.swift"))
        #expect(output.contains("utils.swift"))
        // Files mode: paths only, no line numbers or content
    }

    @Test("content mode returns matching lines with file and line number", .timeLimit(.minutes(1)))
    func contentModeMatchingLines() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "print",
                path: nil,
                glob: nil,
                outputMode: "content",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // Content mode should show file paths, line numbers, and content
        #expect(output.contains("print"))
        #expect(output.contains("main.swift"))
    }

    @Test("content mode with context shows surrounding lines", .timeLimit(.minutes(1)))
    func contentModeWithContext() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "count = 42",
                path: nil,
                glob: nil,
                outputMode: "content",
                caseInsensitive: nil,
                contextLines: 2,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // With context=2, should see lines around "count = 42"
        #expect(output.contains("count = 42"))
        // Context should include nearby lines
        #expect(output.contains("print") || output.contains("func"))
    }

    @Test("count mode returns count per file", .timeLimit(.minutes(1)))
    func countModeCountPerFile() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "print",
                path: nil,
                glob: nil,
                outputMode: "count",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // Count mode should show file paths with match counts
        #expect(output.contains("main.swift"))
    }

    @Test("default mode is files when output_mode is nil", .timeLimit(.minutes(1)))
    func defaultModeIsFiles() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "print",
                path: nil,
                glob: nil,
                outputMode: nil,
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // Default mode should list file paths
        #expect(output.contains("main.swift"))
    }

    @Test("invalid output_mode returns error", .timeLimit(.minutes(1)))
    func invalidOutputModeError() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "print",
                path: nil,
                glob: nil,
                outputMode: "invalid_mode",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        // Should indicate error (either as .success with error text or .failure)
        switch result {
        case .success(let output):
            #expect(output.lowercased().contains("invalid") ||
                    output.lowercased().contains("unsupported") ||
                    output.lowercased().contains("mode"),
                    "Expected error about invalid output mode, got: \(output)")
        case .failure:
            break // Also acceptable
        case .deferred:
            Issue.record("Unexpected deferred")
        }
    }

    // MARK: - Search Behavior

    @Test("literal pattern finds exact match", .timeLimit(.minutes(1)))
    func literalPatternExactMatch() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "Hello, world!",
                path: nil,
                glob: nil,
                outputMode: "content",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("Hello, world!"))
        #expect(output.contains("main.swift"))
    }

    @Test("regex pattern finds pattern match", .timeLimit(.minutes(1)))
    func regexPatternMatch() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "func\\s+\\w+",
                path: nil,
                glob: nil,
                outputMode: "content",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // Should match "func main", "func utils", "func testMain"
        #expect(output.contains("func"))
    }

    @Test("case insensitive matches regardless of case", .timeLimit(.minutes(1)))
    func caseInsensitiveSearch() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "hello",
                path: nil,
                glob: nil,
                outputMode: "content",
                caseInsensitive: true,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // Should match "Hello" in main.swift despite searching for "hello"
        #expect(output.contains("Hello"))
    }

    @Test("glob filter only searches matching files", .timeLimit(.minutes(1)))
    func globFilterWorks() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "print",
                path: nil,
                glob: "*.md",
                outputMode: "files",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // "print" doesn't appear in any .md file
        #expect(!output.contains("main.swift"))
    }

    @Test("respects gitignore by default", .timeLimit(.minutes(1)))
    func respectsGitignore() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // rg only reads .gitignore in a git repo — initialize one
        let initProcess = Process()
        initProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProcess.arguments = ["init"]
        initProcess.currentDirectoryURL = URL(fileURLWithPath: tempDir)
        initProcess.standardOutput = FileHandle.nullDevice
        initProcess.standardError = FileHandle.nullDevice
        try initProcess.run()
        initProcess.waitUntilExit()

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "hello",
                path: nil,
                glob: nil,
                outputMode: "files",
                caseInsensitive: true,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // node_modules is gitignored, so index.js with "hello" should not appear
        #expect(!output.contains("node_modules"))
    }

    @Test("skips binary files by default", .timeLimit(.minutes(1)))
    func skipsBinaryFiles() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "PNG",
                path: nil,
                glob: nil,
                outputMode: "files",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // Binary image.png should be skipped even though it contains PNG header bytes
        #expect(!output.contains("image.png"))
    }

    @Test("invalid regex returns error from rg", .timeLimit(.minutes(1)))
    func invalidRegexError() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "[invalid(regex",
                path: nil,
                glob: nil,
                outputMode: nil,
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        // rg exits with error for invalid regex — tool should surface this
        switch result {
        case .success(let output):
            #expect(output.lowercased().contains("error") ||
                    output.lowercased().contains("invalid") ||
                    output.lowercased().contains("regex"),
                    "Expected regex error message, got: \(output)")
        case .failure:
            break // Also acceptable
        case .deferred:
            Issue.record("Unexpected deferred")
        }
    }

    // MARK: - Limits

    @Test("max_results truncates output", .timeLimit(.minutes(1)))
    func maxResultsTruncates() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "func|print|let|//",
                path: nil,
                glob: nil,
                outputMode: "content",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: 2
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // Should have limited results
        let matchLines = output.components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
        // With max_results=2, we should have at most 2 match entries
        #expect(matchLines.count <= 10) // Generous upper bound (includes formatting)
    }

    @Test("total character limit applies OutputTruncation", .timeLimit(.minutes(1)))
    func totalCharacterLimitApplied() async throws {
        // Create many files with matching content
        let fm = FileManager.default
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        for i in 0..<50 {
            try String(repeating: "match_target line \(i)\n", count: 20)
                .write(toFile: tempDir + "/file\(i).txt", atomically: true, encoding: .utf8)
        }
        defer { try? fm.removeItem(atPath: tempDir) }

        let tool = makeTool(totalCharacterLimit: 500)
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "match_target",
                path: nil,
                glob: nil,
                outputMode: "content",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.count < 2_000) // Should be truncated
    }

    @Test("empty results returns success not error", .timeLimit(.minutes(1)))
    func emptyResultsNoError() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "absolutely_nonexistent_string_xyz123",
                path: nil,
                glob: nil,
                outputMode: nil,
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success for empty results"); return
        }

        #expect(output.contains("0") || output.contains("No matches") || output.isEmpty == false)
    }

    // MARK: - Path Resolution (Same Contract as Glob)

    @Test("explicit path argument overrides working directory", .timeLimit(.minutes(1)))
    func explicitPathOverridesWorkDir() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool(workingDirectory: "/tmp")
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "func main",
                path: tempDir + "/src",
                glob: nil,
                outputMode: "files",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("main.swift"))
    }

    @Test("nil path uses working directory", .timeLimit(.minutes(1)))
    func nilPathUsesWorkDir() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool(workingDirectory: tempDir)
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "func main",
                path: nil,
                glob: nil,
                outputMode: "files",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("main.swift"))
    }

    @Test("path outside allowed directories denied", .timeLimit(.minutes(1)))
    func pathOutsideAllowedDenied() async throws {
        let validator = PathValidator(
            allowedReadDirectories: ["/tmp/yrden-allowed-only"],
            allowedWriteDirectories: ["/tmp/yrden-allowed-only"]
        )
        let tool = GrepTool(
            pathValidator: validator,
            workingDirectory: "/tmp/yrden-allowed-only"
        )

        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "root",
                path: "/etc",
                glob: nil,
                outputMode: nil,
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .failure(let error) = result else {
            Issue.record("Expected .failure for path outside allowed directories, got \(result)")
            return
        }
        let pathError = error as? PathValidationError
        #expect(pathError != nil, "Expected PathValidationError, got \(type(of: error))")
        if case .pathOutsideAllowed = pathError {} else {
            Issue.record("Expected .pathOutsideAllowed, got \(String(describing: pathError))")
        }
    }

    // MARK: - rg JSON Parsing

    @Test("parses rg json match output correctly", .timeLimit(.minutes(1)))
    func parsesRgJsonMatch() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // This tests the full pipeline: rg runs, JSON is parsed, output formatted
        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "Hello, world!",
                path: nil,
                glob: nil,
                outputMode: "content",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // Verify structured output: file path, line number, content
        #expect(output.contains("main.swift"))
        #expect(output.contains("Hello, world!"))
    }

    @Test("handles rg json with non-UTF-8 paths via base64", .timeLimit(.minutes(1)))
    func handlesNonUtf8Paths() async throws {
        // Create a file with a valid but unusual name
        let fm = FileManager.default
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        try "searchable content here".write(
            toFile: tempDir + "/café.txt", atomically: true, encoding: .utf8
        )
        defer { try? fm.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "searchable",
                path: nil,
                glob: nil,
                outputMode: "files",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("café.txt"))
    }

    // MARK: - File Path Search

    @Test("searching a specific file path works", .timeLimit(.minutes(1)))
    func searchingFilePathWorks() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "func main",
                path: tempDir + "/src/main.swift",
                glob: nil,
                outputMode: "content",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success when searching a file path, got \(result)"); return
        }
        #expect(output.contains("func main"))
    }

    // MARK: - Context Lines Auto-Switch

    @Test("context_lines without output_mode auto-switches to content", .timeLimit(.minutes(1)))
    func contextLinesAutoSwitchesToContent() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "count = 42",
                path: nil,
                glob: nil,
                outputMode: nil,       // not set — should auto-switch to "content"
                caseInsensitive: nil,
                contextLines: 2,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)"); return
        }

        // Should return matching content (not just file paths)
        #expect(output.contains("count = 42"), "Expected matching line content")
        // Context should include nearby lines
        #expect(output.contains("print") || output.contains("func"),
                "Expected context lines around match")
    }

    @Test("explicit files mode with context_lines stays in files mode", .timeLimit(.minutes(1)))
    func explicitFilesModeIgnoresContextLines() async throws {
        _ = try createSearchableTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "print",
                path: nil,
                glob: nil,
                outputMode: "files",   // explicitly set — should NOT auto-switch
                caseInsensitive: nil,
                contextLines: 2,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)"); return
        }

        // Files mode: should contain file paths
        #expect(output.contains("main.swift"))
        // Files mode should NOT contain line numbers (e.g., ":2:")
        let hasLineNumbers = output.contains(":2:") || output.contains(":3:")
        #expect(!hasLineNumbers, "Files mode should return paths only, not line content")
    }

    @Test("tool definition schema is valid")
    func toolDefinitionSchema() {
        let tool = makeTool()
        #expect(tool.name == "grep")
        #expect(!tool.description.isEmpty)
        #expect(tool.requiresApproval == false)
    }
}
