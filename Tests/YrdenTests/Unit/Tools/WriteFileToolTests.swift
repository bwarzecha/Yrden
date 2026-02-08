/// Tests for WriteFileTool atomic file writing.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("WriteFileTool")
struct WriteFileToolTests {

    private let tempDir: String = NSTemporaryDirectory() + "yrden-write-tests-\(UUID().uuidString)"

    private func makeTool(maxWriteSize: Int = 10_000_000) -> WriteFileTool {
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: [NSTemporaryDirectory()]
        )
        return WriteFileTool(
            pathValidator: validator,
            maxWriteSize: maxWriteSize
        )
    }

    private func makeContext() -> ToolContext {
        ToolContext(model: FakeModel())
    }

    @Test("new file is created with correct content")
    func newFileCreated() async throws {
        let path = tempDir + "/new-file.txt"
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: WriteFileArgs(path: path, content: "Hello, world!")
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)"); return
        }

        #expect(output.contains("Wrote"))
        #expect(output.contains("13 bytes"))

        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written == "Hello, world!")
    }

    @Test("existing file is overwritten")
    func existingFileOverwritten() async throws {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let path = tempDir + "/existing.txt"
        try "old content".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        _ = try await tool.execute(
            context: makeContext(),
            arguments: WriteFileArgs(path: path, content: "new content")
        )

        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written == "new content")
    }

    @Test("nested parent directories are created")
    func nestedDirsCreated() async throws {
        let path = tempDir + "/a/b/c/deep.txt"
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: WriteFileArgs(path: path, content: "deep content")
        )

        guard case .success = result else {
            Issue.record("Expected success"); return
        }

        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written == "deep content")
    }

    @Test("content exceeding size limit returns error")
    func overSizeLimit() async throws {
        let tool = makeTool(maxWriteSize: 100)
        let largeContent = String(repeating: "x", count: 200)
        let path = tempDir + "/large.txt"
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let result = try await tool.execute(
            context: makeContext(),
            arguments: WriteFileArgs(path: path, content: largeContent)
        )

        guard case .success(let output) = result else { return }
        #expect(output.contains("exceeds maximum"))
    }

    @Test("multi-byte UTF-8 byte count is correct")
    func multiByteUTF8() async throws {
        let emoji = "Hello 🌍🎉"  // Contains multi-byte characters
        let path = tempDir + "/emoji.txt"
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: WriteFileArgs(path: path, content: emoji)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        let expectedBytes = emoji.utf8.count
        #expect(output.contains("\(expectedBytes) bytes"))
    }

    @Test("path with spaces works")
    func pathWithSpaces() async throws {
        let path = tempDir + "/path with spaces/file name.txt"
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: WriteFileArgs(path: path, content: "spaced content")
        )

        guard case .success = result else {
            Issue.record("Expected success"); return
        }

        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written == "spaced content")
    }

    @Test("path validation blocks writes outside allowed directories")
    func pathValidationBlocked() async throws {
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: ["/tmp/yrden-allowed-only"]
        )
        let tool = WriteFileTool(pathValidator: validator)

        let result = try await tool.execute(
            context: makeContext(),
            arguments: WriteFileArgs(path: "/etc/dangerous.txt", content: "bad")
        )

        guard case .success(let output) = result else { return }
        #expect(output.contains("outside allowed") || output.contains("denied"))
    }

    @Test("tool definition schema is valid")
    func toolDefinitionSchema() {
        let tool = makeTool()
        #expect(tool.name == "write_file")
        #expect(!tool.description.isEmpty)
        #expect(tool.requiresApproval == false)
    }

    @Test("directory creation failure returns error instead of crashing")
    func directoryCreationFailure() async throws {
        // Write to a path where the parent is a file (not a directory)
        // so createDirectory fails
        let blockerFile = tempDir + "/blocker"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        try "I am a file".write(toFile: blockerFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // Attempt to create a file inside what is actually a file, not a dir
        let impossiblePath = blockerFile + "/subdir/file.txt"
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: [NSTemporaryDirectory()]
        )
        let tool = WriteFileTool(pathValidator: validator)
        let result = try await tool.execute(
            context: makeContext(),
            arguments: WriteFileArgs(path: impossiblePath, content: "test")
        )

        // Should return error, not crash
        switch result {
        case .success(let output):
            #expect(output.contains("Failed") || output.contains("Error"))
        case .failure:
            break  // Graceful error
        case .deferred:
            Issue.record("Unexpected deferred result")
        }
    }
}
