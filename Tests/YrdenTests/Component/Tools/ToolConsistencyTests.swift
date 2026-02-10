/// Cross-tool consistency tests proving invariants between built-in tools.
///
/// These tests verify that tools work together correctly:
/// - Line numbers agree between grep and read_file
/// - Content from read_file is usable as edit_file old_string
/// - Blank lines are handled consistently across tools
/// - Paths from glob work directly in read_file
/// - read_file on a directory gives a clear error

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Tool Cross-Tool Consistency")
struct ToolConsistencyTests {

    private let tempDir: String = NSTemporaryDirectory()
        + "yrden-consistency-tests-\(UUID().uuidString)"

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

    private func setupTempDir() throws {
        try FileManager.default.createDirectory(
            atPath: tempDir, withIntermediateDirectories: true
        )
    }

    private func cleanup() {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    // MARK: - INV-1: Line Number Agreement

    @Test("grep and read_file agree on line numbers with blank lines",
          .timeLimit(.minutes(1)))
    func grepAndReadFileLineNumberAgreement() async throws {
        try setupTempDir()
        defer { cleanup() }

        // 6 lines: blanks at 2, 4, 5
        let content = "line1\n\nline3\n\n\nline6\n"
        let filePath = tempDir + "/blanks.txt"
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)

        let validator = makeValidator()

        // grep for "line3" in content mode
        let grep = GrepTool(pathValidator: validator, workingDirectory: tempDir)
        let grepResult = try await grep.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "line3", path: filePath, glob: nil,
                outputMode: "content", caseInsensitive: nil,
                contextLines: nil, maxResults: nil
            )
        )

        guard case .success(let grepOutput) = grepResult else {
            Issue.record("grep failed: \(grepResult)"); return
        }

        // ripgrep content format: "filename:N:content" or just lines
        // Extract line number — find the digit before ":line3"
        let grepLines = grepOutput.components(separatedBy: "\n")
        let matchLine = grepLines.first { $0.contains("line3") }!
        // Parse N from "...:N:line3"
        let parts = matchLine.components(separatedBy: ":")
        // parts: [filename_or_empty, linenum, content...]
        let lineNumber = Int(parts[parts.count - 2])!
        #expect(lineNumber == 3, "grep should report line3 at line 3")

        // read_file at that offset should show the same content
        let readTool = ReadFileTool(pathValidator: validator)
        let readResult = try await readTool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: filePath, offset: lineNumber, limit: 1)
        )

        guard case .success(let readOutput) = readResult else {
            Issue.record("read_file failed: \(readResult)"); return
        }

        #expect(readOutput.contains("\(lineNumber)\tline3"),
                "read_file at offset \(lineNumber) should show 'line3', got: \(readOutput)")
    }

    // MARK: - INV-2: Content Fidelity (read_file \t edit_file)

    @Test("read_file content usable as edit_file old_string through blank lines",
          .timeLimit(.minutes(1)))
    func readContentMatchesEditOldString() async throws {
        try setupTempDir()
        defer { cleanup() }

        // File with blank line between function signature and body
        let content = "func hello() {\n\n    print(\"hi\")\n}\n"
        let filePath = tempDir + "/editable.swift"
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)

        let validator = makeValidator()

        // Read the file
        let readTool = ReadFileTool(pathValidator: validator)
        let readResult = try await readTool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: filePath, offset: nil, limit: nil)
        )
        guard case .success(let readOutput) = readResult else {
            Issue.record("read_file failed"); return
        }

        // Strip N\t prefixes to recover original content (simulating what an LLM does)
        let outputLines = readOutput.components(separatedBy: "\n")
            .dropFirst() // skip header line
        let stripped = outputLines.map { line -> String in
            // Strip "N\t" prefix
            guard let arrowIndex = line.firstIndex(of: "\t") else { return line }
            let prefix = line[line.startIndex..<arrowIndex]
            if prefix.allSatisfy(\.isNumber) {
                return String(line[line.index(after: arrowIndex)...])
            }
            return line
        }.joined(separator: "\n")

        // Multi-line old_string spanning the blank line
        let targetOldString = "func hello() {\n\n    print(\"hi\")"
        #expect(stripped.contains(targetOldString),
                "Stripped read output should contain original content")

        // Use it as edit_file old_string — this is the critical invariant
        let editTool = EditFileTool(pathValidator: validator)
        let editResult = try await editTool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: filePath,
                oldString: targetOldString,
                newString: "func hello() {\n    // fixed\n    print(\"hi\")",
                replaceAll: nil
            )
        )

        guard case .success(let editOutput) = editResult else {
            Issue.record("edit_file failed: \(editResult)"); return
        }
        #expect(editOutput.contains("replaced"))
    }

    // MARK: - INV-3: Blank Line Consistency

    @Test("blank lines counted identically by grep and read_file",
          .timeLimit(.minutes(1)))
    func blankLineCountConsistency() async throws {
        try setupTempDir()
        defer { cleanup() }

        let content = "a\n\nb\n"  // 3 lines: "a", "", "b"
        let filePath = tempDir + "/blanks-count.txt"
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)

        let validator = makeValidator()

        // read_file should show 3 lines with blank at line 2
        let readTool = ReadFileTool(pathValidator: validator)
        let readResult = try await readTool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: filePath, offset: nil, limit: nil)
        )
        guard case .success(let readOutput) = readResult else {
            Issue.record("read_file failed"); return
        }
        #expect(readOutput.contains("Lines 1-3 of 3"))
        #expect(readOutput.contains("1\ta"))
        #expect(readOutput.contains("2\t"))
        #expect(readOutput.contains("3\tb"))

        // grep should find "b" at line 3 (not line 2)
        let grep = GrepTool(pathValidator: validator, workingDirectory: tempDir)
        let grepResult = try await grep.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "^b$", path: filePath, glob: nil,
                outputMode: "content", caseInsensitive: nil,
                contextLines: nil, maxResults: nil
            )
        )
        guard case .success(let grepOutput) = grepResult else {
            Issue.record("grep failed"); return
        }
        // Single-file grep omits filename prefix: output is "3:b" not "file:3:b"
        #expect(grepOutput.contains("3:b"),
                "grep should report 'b' at line 3, got: \(grepOutput)")
    }

    @Test("grep context preserves blank lines",
          .timeLimit(.minutes(1)))
    func grepContextPreservesBlankLines() async throws {
        try setupTempDir()
        defer { cleanup() }

        let content = "before\n\ntarget\n\nafter\n"
        let filePath = tempDir + "/context-blanks.txt"
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)

        let validator = makeValidator()
        let grep = GrepTool(pathValidator: validator, workingDirectory: tempDir)
        let grepResult = try await grep.execute(
            context: makeContext(),
            arguments: GrepToolArgs(
                pattern: "target", path: filePath, glob: nil,
                outputMode: "content", caseInsensitive: nil,
                contextLines: 2, maxResults: nil
            )
        )
        guard case .success(let grepOutput) = grepResult else {
            Issue.record("grep with context failed"); return
        }

        // Context should include "before" and "after" — blank lines must not
        // collapse the context window
        #expect(grepOutput.contains("before"), "context should include 'before'")
        #expect(grepOutput.contains("after"), "context should include 'after'")
        #expect(grepOutput.contains("target"), "should include the match")
    }

    // MARK: - INV-4: Path Roundtrip (glob \t read_file)

    @Test("glob returned paths work directly in read_file",
          .timeLimit(.minutes(1)))
    func globPathsWorkInReadFile() async throws {
        try setupTempDir()
        defer { cleanup() }

        try "hello from file".write(
            toFile: tempDir + "/readable.txt", atomically: true, encoding: .utf8
        )

        let validator = makeValidator()

        // Glob finds the file
        let glob = GlobTool(pathValidator: validator, workingDirectory: tempDir)
        let globResult = try await glob.execute(
            context: makeContext(),
            arguments: GlobToolArgs(pattern: "*.txt", path: nil)
        )
        guard case .success(let globOutput) = globResult else {
            Issue.record("glob failed"); return
        }
        #expect(globOutput.contains("readable.txt"))

        // Extract relative path from glob output (first line)
        let relativePath = globOutput.components(separatedBy: "\n")
            .first { $0.contains("readable.txt") }!
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Use that exact path in read_file
        let readTool = ReadFileTool(pathValidator: validator)
        let readResult = try await readTool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: relativePath, offset: nil, limit: nil)
        )
        guard case .success(let readOutput) = readResult else {
            Issue.record("read_file with glob path failed: \(readResult)"); return
        }
        #expect(readOutput.contains("hello from file"))
    }

    // MARK: - INV-5: Directory Guard

    @Test("read_file on directory returns clear error mentioning 'directory'",
          .timeLimit(.minutes(1)))
    func readFileOnDirectoryReturnsHelpfulError() async throws {
        try setupTempDir()
        defer { cleanup() }

        let validator = makeValidator()
        let readTool = ReadFileTool(pathValidator: validator)
        let result = try await readTool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: tempDir, offset: nil, limit: nil)
        )

        switch result {
        case .success(let output):
            #expect(output.lowercased().contains("directory"),
                    "Expected directory error message, got: \(output)")
        case .failure(let error):
            let desc = String(describing: error)
            #expect(desc.lowercased().contains("directory"),
                    "Expected directory error, got: \(desc)")
        case .deferred:
            Issue.record("Unexpected deferred result")
        }
    }
}
