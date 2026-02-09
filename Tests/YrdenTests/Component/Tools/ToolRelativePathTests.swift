/// Cross-tool consistency tests for relative path resolution.
///
/// Verifies that ALL file tools resolve relative paths against the configured
/// working directory, not the process CWD. This prevents a class of bug where
/// tools silently operate on the wrong directory.
///
/// Pattern: create a temp dir, configure tools with workingDirectory=tempDir,
/// then use relative paths. Process CWD is intentionally different.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Tool Relative Path Resolution")
struct ToolRelativePathTests {

    private let tempDir: String = NSTemporaryDirectory() + "yrden-relpath-tests-\(UUID().uuidString)"

    // MARK: - Helpers

    private func makeValidator() -> PathValidator {
        PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: [NSTemporaryDirectory()],
            workingDirectory: tempDir
        )
    }

    private func makeContext() -> ToolContext {
        ToolContext(model: FakeModel())
    }

    /// Create tempDir with a known file inside it.
    private func setupTempDir() throws {
        try FileManager.default.createDirectory(
            atPath: tempDir, withIntermediateDirectories: true
        )
        try "original content\n".write(
            toFile: tempDir + "/existing.txt", atomically: true, encoding: .utf8
        )
        try FileManager.default.createDirectory(
            atPath: tempDir + "/subdir", withIntermediateDirectories: true
        )
        try "nested content\n".write(
            toFile: tempDir + "/subdir/nested.txt", atomically: true, encoding: .utf8
        )
    }

    private func cleanup() {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    // MARK: - ReadFileTool

    @Test("read_file resolves relative path against workingDirectory", .timeLimit(.minutes(1)))
    func readFileRelativePath() async throws {
        try setupTempDir()
        defer { cleanup() }

        let tool = ReadFileTool(pathValidator: makeValidator())
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: "existing.txt", offset: nil, limit: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)"); return
        }
        #expect(output.contains("original content"))
    }

    @Test("read_file resolves relative path with subdir", .timeLimit(.minutes(1)))
    func readFileRelativeSubdir() async throws {
        try setupTempDir()
        defer { cleanup() }

        let tool = ReadFileTool(pathValidator: makeValidator())
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: "subdir/nested.txt", offset: nil, limit: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)"); return
        }
        #expect(output.contains("nested content"))
    }

    // MARK: - WriteFileTool

    @Test("write_file resolves relative path against workingDirectory", .timeLimit(.minutes(1)))
    func writeFileRelativePath() async throws {
        try setupTempDir()
        defer { cleanup() }

        let tool = WriteFileTool(pathValidator: makeValidator())
        let result = try await tool.execute(
            context: makeContext(),
            arguments: WriteFileArgs(path: "output.txt", content: "written via relative path\n")
        )

        guard case .success = result else {
            Issue.record("Expected success, got \(result)"); return
        }

        // Verify file was created in tempDir, not process CWD
        let content = try String(contentsOfFile: tempDir + "/output.txt", encoding: .utf8)
        #expect(content == "written via relative path\n")
        #expect(!FileManager.default.fileExists(atPath: "output.txt"),
                "File should NOT exist in process CWD")
    }

    // MARK: - EditFileTool

    @Test("edit_file resolves relative path against workingDirectory", .timeLimit(.minutes(1)))
    func editFileRelativePath() async throws {
        try setupTempDir()
        defer { cleanup() }

        let tool = EditFileTool(pathValidator: makeValidator())
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: "existing.txt",
                oldString: "original content",
                newString: "modified content",
                replaceAll: false
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)"); return
        }
        #expect(output.contains("replaced"))

        let content = try String(contentsOfFile: tempDir + "/existing.txt", encoding: .utf8)
        #expect(content.contains("modified content"))
    }

    // MARK: - GlobTool

    @Test("glob resolves relative search path against workingDirectory", .timeLimit(.minutes(1)))
    func globRelativePath() async throws {
        try setupTempDir()
        defer { cleanup() }

        let tool = GlobTool(
            pathValidator: makeValidator(),
            workingDirectory: tempDir
        )
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "*.txt", path: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)"); return
        }
        #expect(output.contains("existing.txt"))
    }

    // MARK: - GrepTool

    @Test("grep resolves relative search path against workingDirectory", .timeLimit(.minutes(1)))
    func grepRelativePath() async throws {
        try setupTempDir()
        defer { cleanup() }

        let tool = GrepTool(
            pathValidator: makeValidator(),
            workingDirectory: tempDir
        )
        let result = try await tool.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "original",
                path: nil,
                glob: nil,
                outputMode: "content",
                caseInsensitive: nil,
                contextLines: nil,
                maxResults: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)"); return
        }
        #expect(output.contains("original content"))
    }
}
