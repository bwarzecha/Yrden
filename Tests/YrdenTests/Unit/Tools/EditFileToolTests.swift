/// Tests for EditFileTool content-based find-and-replace editing.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("EditFileTool")
struct EditFileToolTests {

    private let tempDir: String = NSTemporaryDirectory() + "yrden-edit-tests-\(UUID().uuidString)"

    // MARK: - Helpers

    private func makeTool(maxFileSize: Int = 10_000_000) -> EditFileTool {
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: [NSTemporaryDirectory()]
        )
        return EditFileTool(
            pathValidator: validator,
            maxFileSize: maxFileSize
        )
    }

    private func makeContext() -> ToolContext {
        ToolContext(model: FakeModel())
    }

    private func writeTestFile(_ content: String, name: String = "test.txt") throws -> String {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let path = tempDir + "/" + name
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Extract error text from a ToolResult that should indicate an error.
    /// Tools return errors as .success(errorText) for LLM self-correction,
    /// or as .failure(Error) for system-level failures. Either way, return the message.
    /// Rejects happy-path success messages (containing "replaced" or "edited") to
    /// prevent tests silently passing when the tool unexpectedly succeeds.
    private func expectToolError(_ result: ToolResult<String>, file: String = #filePath, line: Int = #line, column: Int = #column, fileID: String = #fileID) throws -> String {
        switch result {
        case .success(let output):
            // Guard against happy-path success sneaking through
            let lower = output.lowercased()
            if lower.contains("replaced") || lower.contains("edited") || lower.contains("written") {
                Issue.record(
                    "Expected error result, but got success with happy-path output: \(output)",
                    sourceLocation: SourceLocation(fileID: fileID, filePath: file, line: line, column: column)
                )
                throw EditTestError.unexpectedSuccess
            }
            return output
        case .failure(let error):
            return String(describing: error)
        case .deferred:
            Issue.record("Expected error result, got .deferred", sourceLocation: SourceLocation(fileID: fileID, filePath: file, line: line, column: column))
            throw EditTestError.unexpectedDeferred
        }
    }

    private enum EditTestError: Error {
        case unexpectedDeferred
        case unexpectedSuccess
    }

    // MARK: - Core Replacement

    @Test("single match replaces correctly", .timeLimit(.minutes(1)))
    func singleMatchReplaces() async throws {
        let path = try writeTestFile("Hello world\nGoodbye world\n")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "Hello world",
                newString: "Hi there",
                replaceAll: false
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)"); return
        }
        #expect(output.contains("replaced") || output.contains("edited"))

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("Hi there"))
        #expect(!content.contains("Hello world"))
        #expect(content.contains("Goodbye world"))
    }

    @Test("no match returns helpful error", .timeLimit(.minutes(1)))
    func noMatchReturnsError() async throws {
        let path = try writeTestFile("Hello world\n")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "nonexistent text",
                newString: "replacement",
                replaceAll: false
            )
        )

        // Tool should return error text the LLM can read and self-correct from
        let errorText = try expectToolError(result)
        #expect(errorText.contains("not found") || errorText.contains("No match"),
                "Expected 'not found' or 'No match' in: \(errorText)")
    }

    @Test("multiple matches with replace_all false fails with count", .timeLimit(.minutes(1)))
    func multipleMatchesFailsWithCount() async throws {
        let path = try writeTestFile("foo bar foo baz foo\n")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "foo",
                newString: "qux",
                replaceAll: false
            )
        )

        let errorText = try expectToolError(result)
        #expect(errorText.contains("3") || errorText.contains("multiple"),
                "Expected match count in: \(errorText)")
    }

    @Test("multiple matches with replace_all true replaces all", .timeLimit(.minutes(1)))
    func multipleMatchesReplaceAllTrue() async throws {
        let path = try writeTestFile("foo bar foo baz foo\n")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "foo",
                newString: "qux",
                replaceAll: true
            )
        )

        guard case .success = result else {
            Issue.record("Expected success"); return
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "qux bar qux baz qux\n")
    }

    @Test("same strings returns identity error", .timeLimit(.minutes(1)))
    func sameStringsError() async throws {
        let path = try writeTestFile("Hello world\n")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "Hello",
                newString: "Hello",
                replaceAll: false
            )
        )

        let errorText = try expectToolError(result)
        #expect(errorText.contains("same") || errorText.contains("identical"),
                "Expected identity error in: \(errorText)")
    }

    @Test("empty old_string returns error", .timeLimit(.minutes(1)))
    func emptyOldStringError() async throws {
        let path = try writeTestFile("Hello world\n")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "",
                newString: "something",
                replaceAll: false
            )
        )

        let errorText = try expectToolError(result)
        #expect(errorText.contains("empty") || errorText.contains("required"),
                "Expected empty string error in: \(errorText)")
    }

    @Test("file not found returns error", .timeLimit(.minutes(1)))
    func fileNotFoundError() async throws {
        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: tempDir + "/nonexistent.txt",
                oldString: "foo",
                newString: "bar",
                replaceAll: false
            )
        )

        let errorText = try expectToolError(result)
        #expect(errorText.contains("not found") || errorText.contains("No such file"),
                "Expected file not found error in: \(errorText)")
    }

    // MARK: - Whitespace and Content

    @Test("whitespace in old_string must match exactly", .timeLimit(.minutes(1)))
    func whitespaceExactMatch() async throws {
        let path = try writeTestFile("hello   world\nhello world\n")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        // Replace the one with 3 spaces
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "hello   world",
                newString: "replaced",
                replaceAll: false
            )
        )

        guard case .success = result else {
            Issue.record("Expected success"); return
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "replaced\nhello world\n")
    }

    @Test("tabs and spaces are distinguished", .timeLimit(.minutes(1)))
    func tabsAndSpacesDifferent() async throws {
        let path = try writeTestFile("\tfoo\n    foo\n")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "\tfoo",
                newString: "\tbar",
                replaceAll: false
            )
        )

        guard case .success = result else {
            Issue.record("Expected success"); return
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "\tbar\n    foo\n")
    }

    @Test("multiline old_string matches across lines", .timeLimit(.minutes(1)))
    func multilineMatch() async throws {
        let path = try writeTestFile("line1\nline2\nline3\n")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "line1\nline2",
                newString: "replaced1\nreplaced2",
                replaceAll: false
            )
        )

        guard case .success = result else {
            Issue.record("Expected success"); return
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "replaced1\nreplaced2\nline3\n")
    }

    @Test("unicode content preserved exactly", .timeLimit(.minutes(1)))
    func unicodePreserved() async throws {
        let path = try writeTestFile("Hello 🌍 world\n")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "🌍",
                newString: "🎉🚀",
                replaceAll: false
            )
        )

        guard case .success = result else {
            Issue.record("Expected success"); return
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "Hello 🎉🚀 world\n")
    }

    @Test("empty new_string deletes old_string", .timeLimit(.minutes(1)))
    func emptyNewStringDeletes() async throws {
        let path = try writeTestFile("foo bar baz\n")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: " bar",
                newString: "",
                replaceAll: false
            )
        )

        guard case .success = result else {
            Issue.record("Expected success"); return
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "foo baz\n")
    }

    @Test("newlines in strings handled correctly", .timeLimit(.minutes(1)))
    func newlinesHandled() async throws {
        let path = try writeTestFile("before\nmiddle\nafter\n")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "middle\n",
                newString: "new1\nnew2\n",
                replaceAll: false
            )
        )

        guard case .success = result else {
            Issue.record("Expected success"); return
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "before\nnew1\nnew2\nafter\n")
    }

    // MARK: - Safety

    @Test("atomic write preserves content on large file", .timeLimit(.minutes(1)))
    func atomicWriteLargeFile() async throws {
        let largeContent = String(repeating: "a", count: 100_000) + "\nmarker\n" + String(repeating: "b", count: 100_000)
        let path = try writeTestFile(largeContent)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "marker",
                newString: "REPLACED",
                replaceAll: false
            )
        )

        guard case .success = result else {
            Issue.record("Expected success"); return
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("REPLACED"))
        #expect(!content.contains("marker"))
        // Verify surrounding content preserved
        #expect(content.hasPrefix(String(repeating: "a", count: 100_000)))
    }

    @Test("path outside allowed directories denied", .timeLimit(.minutes(1)))
    func pathOutsideAllowedDenied() async throws {
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: ["/tmp/yrden-allowed-only"]
        )
        let tool = EditFileTool(pathValidator: validator)

        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: "/etc/dangerous.txt",
                oldString: "foo",
                newString: "bar",
                replaceAll: false
            )
        )

        // PathValidator violations should return .failure (consistent with existing ReadFile/WriteFile tests)
        guard case .failure(let error) = result else {
            Issue.record("Expected .failure for path outside allowed directories, got \(result)")
            return
        }
        let desc = String(describing: error)
        #expect(desc.contains("outside") || desc.contains("denied") || desc.contains("Outside"),
                "Expected path violation error, got: \(desc)")
    }

    @Test("file exceeding size limit rejected", .timeLimit(.minutes(1)))
    func fileTooLargeRejected() async throws {
        let largeContent = String(repeating: "x", count: 200)
        let path = try writeTestFile(largeContent)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool(maxFileSize: 100)
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "x",
                newString: "y",
                replaceAll: false
            )
        )

        let errorText = try expectToolError(result)
        #expect(errorText.contains("too large") || errorText.contains("exceeds") || errorText.contains("size"),
                "Expected file size error in: \(errorText)")
    }

    // MARK: - Sequential Edits

    @Test("two sequential edits on same file both succeed", .timeLimit(.minutes(1)))
    func twoSequentialEditsSucceed() async throws {
        let path = try writeTestFile("alpha beta gamma\n")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()

        // First edit
        let result1 = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "alpha",
                newString: "ALPHA",
                replaceAll: false
            )
        )
        guard case .success = result1 else {
            Issue.record("First edit failed"); return
        }

        // Second edit
        let result2 = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "gamma",
                newString: "GAMMA",
                replaceAll: false
            )
        )
        guard case .success = result2 else {
            Issue.record("Second edit failed"); return
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "ALPHA beta GAMMA\n")
    }

    @Test("edit after inserting lines works despite line number drift", .timeLimit(.minutes(1)))
    func editAfterInsertLineNumbersDontMatter() async throws {
        let path = try writeTestFile("line1\nline2\nline3\n")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()

        // First edit: insert lines between line1 and line2
        _ = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "line1\nline2",
                newString: "line1\ninserted_a\ninserted_b\nline2",
                replaceAll: false
            )
        )

        // Second edit: modify line3 (which has shifted down)
        let result = try await tool.execute(
            context: makeContext(),
            arguments: EditFileArgs(
                path: path,
                oldString: "line3",
                newString: "LINE3",
                replaceAll: false
            )
        )

        guard case .success = result else {
            Issue.record("Expected success"); return
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "line1\ninserted_a\ninserted_b\nline2\nLINE3\n")
    }

    @Test("tool definition schema is valid")
    func toolDefinitionSchema() {
        let tool = makeTool()
        #expect(tool.name == "edit_file")
        #expect(!tool.description.isEmpty)
        #expect(tool.requiresApproval == false)
    }
}
