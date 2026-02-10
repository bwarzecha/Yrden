/// Tests for ReadFileTool file reading with truncation and line numbers.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("ReadFileTool")
struct ReadFileToolTests {

    private let tempDir: String = NSTemporaryDirectory() + "yrden-read-tests-\(UUID().uuidString)"

    private func makeTool(
        totalCharacterLimit: Int = 100_000,
        perLineCharacterLimit: Int = 4_000,
        defaultLineLimit: Int = 500
    ) -> ReadFileTool {
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: ["/"]
        )
        return ReadFileTool(
            pathValidator: validator,
            totalCharacterLimit: totalCharacterLimit,
            perLineCharacterLimit: perLineCharacterLimit,
            defaultLineLimit: defaultLineLimit
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

    @Test("small file returns full content with header and line numbers")
    func smallFileFullContent() async throws {
        let content = "line one\nline two\nline three"
        let path = try writeTestFile(content)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: path, offset: nil, limit: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }

        #expect(output.contains("[File:"))
        #expect(output.contains("Lines 1-3 of 3"))
        #expect(output.contains("1\tline one"))
        #expect(output.contains("2\tline two"))
        #expect(output.contains("3\tline three"))
    }

    @Test("offset skips lines")
    func offsetSkipsLines() async throws {
        let lines = (1...10).map { "Line \($0)" }.joined(separator: "\n")
        let path = try writeTestFile(lines)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: path, offset: 5, limit: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("5\tLine 5"))
        #expect(!output.contains("4\tLine 4"))
    }

    @Test("limit caps output at N lines")
    func limitCapsLines() async throws {
        let lines = (1...100).map { "Line \($0)" }.joined(separator: "\n")
        let path = try writeTestFile(lines)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool(defaultLineLimit: 10)
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: path, offset: nil, limit: 3)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // With early break optimization, header shows "N+" when limit was hit
        #expect(output.contains("Lines 1-3 of"))
        #expect(output.contains("3\tLine 3"))
        #expect(!output.contains("4\tLine 4"))
    }

    @Test("offset and limit combined")
    func offsetPlusLimit() async throws {
        let lines = (1...20).map { "Line \($0)" }.joined(separator: "\n")
        let path = try writeTestFile(lines)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: path, offset: 5, limit: 3)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // With early break, header shows "of N+" when limit was hit
        #expect(output.contains("Lines 5-7 of"))
        #expect(output.contains("5\tLine 5"))
        #expect(output.contains("7\tLine 7"))
        #expect(!output.contains("8\tLine 8"))
    }

    @Test("long line is truncated with overflow indicator")
    func longLineTruncated() async throws {
        let longLine = String(repeating: "x", count: 10_000)
        let path = try writeTestFile(longLine)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool(perLineCharacterLimit: 4_000)
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: path, offset: nil, limit: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("[...+6000 chars]"))
    }

    @Test("total character cap triggers truncation")
    func totalCharCapTruncation() async throws {
        // Create content that exceeds the total character limit
        let lines = (1...200).map { "Line \($0): " + String(repeating: "a", count: 100) }
        let content = lines.joined(separator: "\n")
        let path = try writeTestFile(content)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool(totalCharacterLimit: 1_000)
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: path, offset: nil, limit: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // Should contain the truncation marker from OutputTruncation
        #expect(output.contains("[...truncated"))
    }

    @Test("file not found returns error")
    func fileNotFound() async throws {
        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: "/nonexistent/file.txt", offset: nil, limit: nil)
        )

        guard case .success(let output) = result else {
            // Could be .error from ToolResult
            return
        }
        #expect(output.contains("not found") || output.contains("Error"))
    }

    @Test("binary file returns error")
    func binaryFile() async throws {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let path = tempDir + "/binary.bin"
        let binaryData = Data([0x00, 0x01, 0x02, 0xFF, 0x00, 0x03])
        try binaryData.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: path, offset: nil, limit: nil)
        )

        guard case .success(let output) = result else { return }
        #expect(output.contains("binary file"))
    }

    @Test("empty file returns header with 0 lines")
    func emptyFile() async throws {
        let path = try writeTestFile("")
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: path, offset: nil, limit: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("Lines 0-0 of 0"))
    }

    @Test("path validation blocks denied directories")
    func pathValidationBlocked() async throws {
        let validator = PathValidator(
            allowedReadDirectories: ["/tmp"],
            allowedWriteDirectories: ["/tmp"]
        )
        let tool = ReadFileTool(pathValidator: validator)
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: "/etc/passwd", offset: nil, limit: nil)
        )

        guard case .success(let output) = result else { return }
        #expect(output.contains("outside allowed") || output.contains("denied"))
    }

    @Test("tool definition schema is valid")
    func toolDefinitionSchema() {
        let tool = makeTool()
        #expect(tool.name == "read_file")
        #expect(!tool.description.isEmpty)
        #expect(tool.requiresApproval == false)
    }

    @Test("limit caps output but header shows exact total line count")
    func limitHeaderShowsTotal() async throws {
        let lines = (1...1000).map { "Line \($0)" }.joined(separator: "\n")
        let path = try writeTestFile(lines)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: path, offset: nil, limit: 3)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // Header shows exact total even when limit is hit
        #expect(output.contains("Lines 1-3 of 1000"))
    }

    @Test("blank lines preserved with correct line numbers")
    func blankLinesPreserved() async throws {
        let content = "line1\n\nline3\n\n\nline6"
        let path = try writeTestFile(content)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: path, offset: nil, limit: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }

        #expect(output.contains("Lines 1-6 of 6"))
        #expect(output.contains("1\tline1"))
        #expect(output.contains("2\t"))
        #expect(output.contains("3\tline3"))
        #expect(output.contains("4\t"))
        #expect(output.contains("5\t"))
        #expect(output.contains("6\tline6"))
    }

    @Test("offset and limit work correctly with blank lines")
    func offsetLimitWithBlankLines() async throws {
        let content = "a\n\nb\n\nc"  // 5 lines: "a", "", "b", "", "c"
        let path = try writeTestFile(content)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: path, offset: 2, limit: 3)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }

        #expect(output.contains("2\t"))
        #expect(output.contains("3\tb"))
        #expect(output.contains("4\t"))
        #expect(!output.contains("5\tc"))
    }

    @Test("non-UTF-8 file returns error instead of crashing")
    func nonUTF8FileReturnsError() async throws {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let path = tempDir + "/invalid-utf8.txt"

        // Write valid UTF-8 prefix followed by invalid UTF-8 byte sequence
        // 0xC0 0xAF is an overlong encoding (invalid UTF-8)
        var data = "Valid start\n".data(using: .utf8)!
        data.append(contentsOf: [0xC0, 0xAF, 0xFE, 0xFF])
        data.append("\nMore text".data(using: .utf8)!)
        try data.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ReadFileArgs(path: path, offset: nil, limit: nil)
        )

        // Should either return an error or succeed partially — must NOT crash
        switch result {
        case .success(let output):
            // If it succeeds, it read at least something
            #expect(!output.isEmpty)
        case .failure:
            // If it fails, it caught the error gracefully
            break
        case .deferred:
            Issue.record("Unexpected deferred result")
        }
    }
}
