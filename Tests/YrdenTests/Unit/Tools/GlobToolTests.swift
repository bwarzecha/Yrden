/// Tests for GlobTool file pattern matching with gitignore and path resolution.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("GlobTool")
struct GlobToolTests {

    private let tempDir: String = NSTemporaryDirectory() + "yrden-glob-tests-\(UUID().uuidString)"

    // MARK: - Helpers

    private func makeTool(
        workingDirectory: String? = nil,
        maxResults: Int = 1000
    ) -> GlobTool {
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: ["/"]
        )
        return GlobTool(
            pathValidator: validator,
            workingDirectory: workingDirectory ?? tempDir,
            maxResults: maxResults
        )
    }

    private func makeContext() -> ToolContext {
        ToolContext(model: FakeModel())
    }

    private func createFileTree() throws -> String {
        let root = tempDir
        let fm = FileManager.default

        try fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try "swift".write(toFile: root + "/src/main.swift", atomically: true, encoding: .utf8)
        try "swift".write(toFile: root + "/src/utils.swift", atomically: true, encoding: .utf8)
        try "swift".write(toFile: root + "/src/app.ts", atomically: true, encoding: .utf8)

        try fm.createDirectory(atPath: root + "/tests", withIntermediateDirectories: true)
        try "test".write(toFile: root + "/tests/test.swift", atomically: true, encoding: .utf8)

        try fm.createDirectory(atPath: root + "/docs", withIntermediateDirectories: true)
        try "doc".write(toFile: root + "/docs/readme.md", atomically: true, encoding: .utf8)

        try "root".write(toFile: root + "/Package.swift", atomically: true, encoding: .utf8)

        try fm.createDirectory(atPath: root + "/node_modules/pkg", withIntermediateDirectories: true)
        try "js".write(toFile: root + "/node_modules/pkg/index.js", atomically: true, encoding: .utf8)

        // Stagger modification times for sort testing using explicit timestamps
        try "first".write(toFile: root + "/a_first.txt", atomically: true, encoding: .utf8)
        let pastDate = Date(timeIntervalSinceNow: -10)
        try fm.setAttributes(
            [.modificationDate: pastDate],
            ofItemAtPath: root + "/a_first.txt"
        )
        try "second".write(toFile: root + "/b_second.txt", atomically: true, encoding: .utf8)
        // b_second.txt has current modification time (newer than a_first.txt)

        return root
    }

    // MARK: - Pattern Matching

    @Test("star pattern matches files in specified directory only", .timeLimit(.minutes(1)))
    func starPatternCurrentDir() async throws {
        _ = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "*.swift", path: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)"); return
        }

        // Should match Package.swift at root, not nested files
        #expect(output.contains("Package.swift"))
    }

    @Test("double star pattern matches recursively", .timeLimit(.minutes(1)))
    func doubleStarPatternRecursive() async throws {
        _ = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "**/*.swift", path: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("src/main.swift"))
        #expect(output.contains("src/utils.swift"))
        #expect(output.contains("tests/test.swift"))
        #expect(output.contains("Package.swift"))
        #expect(!output.contains(".ts"))
    }

    @Test("brace alternation matches both options", .timeLimit(.minutes(1)))
    func braceAlternation() async throws {
        _ = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "**/*.{swift,ts}", path: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains(".swift"))
        #expect(output.contains(".ts"))
    }

    @Test("character class matches range", .timeLimit(.minutes(1)))
    func characterClass() async throws {
        _ = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "[ab]_*.txt", path: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("a_first.txt"))
        #expect(output.contains("b_second.txt"))
    }

    @Test("question mark matches single character", .timeLimit(.minutes(1)))
    func questionMark() async throws {
        _ = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "?_first.txt", path: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("a_first.txt"))
    }

    // MARK: - Result Behavior

    @Test("results sorted by modification time newest first", .timeLimit(.minutes(1)))
    func resultsSortedByModTime() async throws {
        _ = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "*.txt", path: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // b_second.txt was written after a_first.txt, should appear first
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        if let bIndex = lines.firstIndex(where: { $0.contains("b_second") }),
           let aIndex = lines.firstIndex(where: { $0.contains("a_first") }) {
            #expect(bIndex < aIndex, "Newest file should appear first")
        }
    }

    @Test("maxResults truncates with message", .timeLimit(.minutes(1)))
    func maxResultsTruncates() async throws {
        _ = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool(maxResults: 2)
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "**/*", path: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("truncated") || output.contains("limit"))
    }

    @Test("empty results returns success not error", .timeLimit(.minutes(1)))
    func emptyResultsNoError() async throws {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "*.nonexistent_extension", path: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success for empty results"); return
        }

        #expect(output.contains("0") || output.contains("No files"))
    }

    @Test("paths returned relative to search directory", .timeLimit(.minutes(1)))
    func relativePathsCorrect() async throws {
        _ = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "**/*.swift", path: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // Paths should be relative, not absolute
        #expect(!output.contains(NSTemporaryDirectory()))
        #expect(output.contains("src/main.swift"))
    }

    // MARK: - Gitignore

    @Test("respects gitignore skips node_modules", .timeLimit(.minutes(1)))
    func respectsGitignoreNodeModules() async throws {
        _ = try createFileTree()
        try "node_modules/\n".write(
            toFile: tempDir + "/.gitignore", atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "**/*.js", path: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(!output.contains("node_modules"))
    }

    @Test("gitignore disabled returns all files", .timeLimit(.minutes(1)))
    func gitignoreDisabledReturnsAll() async throws {
        _ = try createFileTree()
        try "node_modules/\n".write(
            toFile: tempDir + "/.gitignore", atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // GlobTool with gitignore disabled
        let validator = PathValidator(allowedReadDirectories: ["/"], allowedWriteDirectories: ["/"])
        let tool = GlobTool(
            pathValidator: validator,
            workingDirectory: tempDir,
            respectGitignore: false
        )
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "**/*.js", path: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("index.js"))
    }

    // MARK: - Path Resolution

    @Test("explicit path argument overrides working directory", .timeLimit(.minutes(1)))
    func explicitPathOverridesWorkDir() async throws {
        _ = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // Tool's working directory is /tmp, but we pass explicit path
        let tool = makeTool(workingDirectory: "/tmp")
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "*.swift", path: tempDir + "/src")
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("main.swift"))
    }

    @Test("nil path uses working directory", .timeLimit(.minutes(1)))
    func nilPathUsesWorkDir() async throws {
        _ = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool(workingDirectory: tempDir + "/src")
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "*.swift", path: nil)
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
        let tool = GlobTool(pathValidator: validator, workingDirectory: "/tmp/yrden-allowed-only")
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "*", path: "/etc")
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

    @Test("nonexistent directory returns error", .timeLimit(.minutes(1)))
    func nonexistentDirectoryError() async throws {
        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "*", path: "/nonexistent-\(UUID().uuidString)")
        )

        // Nonexistent directory should produce an error (either success with message or failure)
        switch result {
        case .success(let output):
            #expect(output.lowercased().contains("not found") ||
                    output.lowercased().contains("does not exist") ||
                    output.lowercased().contains("error"),
                    "Expected error message for nonexistent directory, got: \(output)")
        case .failure:
            break // Also acceptable
        case .deferred:
            Issue.record("Unexpected deferred")
        }
    }

    @Test("tool definition schema is valid")
    func toolDefinitionSchema() {
        let tool = makeTool()
        #expect(tool.name == "glob")
        #expect(!tool.description.isEmpty)
        #expect(tool.requiresApproval == false)
    }
}
