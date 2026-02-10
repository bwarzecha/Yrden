/// Tests for FileEnumerator directory traversal with glob and gitignore filtering.

import Testing
import Foundation
@testable import Yrden

@Suite("FileEnumerator")
struct FileEnumeratorTests {

    private let tempDir: String = NSTemporaryDirectory() + "yrden-enum-tests-\(UUID().uuidString)"

    // MARK: - Helpers

    private func createFileTree() throws -> String {
        let root = tempDir
        let fm = FileManager.default

        // src/main.swift, src/utils.swift
        try fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try "func main()".write(toFile: root + "/src/main.swift", atomically: true, encoding: .utf8)
        try "func utils()".write(toFile: root + "/src/utils.swift", atomically: true, encoding: .utf8)

        // tests/test.swift
        try fm.createDirectory(atPath: root + "/tests", withIntermediateDirectories: true)
        try "test".write(toFile: root + "/tests/test.swift", atomically: true, encoding: .utf8)

        // build/output.o
        try fm.createDirectory(atPath: root + "/build", withIntermediateDirectories: true)
        try "binary".write(toFile: root + "/build/output.o", atomically: true, encoding: .utf8)

        // .git/HEAD
        try fm.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
        try "ref: refs/heads/main".write(toFile: root + "/.git/HEAD", atomically: true, encoding: .utf8)

        // README.md
        try "# Project".write(toFile: root + "/README.md", atomically: true, encoding: .utf8)

        // node_modules/pkg/index.js
        try fm.createDirectory(atPath: root + "/node_modules/pkg", withIntermediateDirectories: true)
        try "module.exports".write(toFile: root + "/node_modules/pkg/index.js", atomically: true, encoding: .utf8)

        return root
    }

    private func makeValidator(read: [String] = ["/"]) -> PathValidator {
        PathValidator(allowedReadDirectories: read, allowedWriteDirectories: ["/"])
    }

    // MARK: - Basic Enumeration

    @Test("enumerates all files in directory tree")
    func enumeratesAllFiles() throws {
        let root = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let enumerator = FileEnumerator(
            rootDirectory: root,
            pathValidator: makeValidator(),
            respectGitignore: false
        )
        let files = try enumerator.enumerate()

        // Should include files from src, tests, build, node_modules, and root (.git always excluded)
        #expect(files.count >= 6)
    }

    @Test("returns paths relative to root directory")
    func returnsRelativePaths() throws {
        let root = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let enumerator = FileEnumerator(
            rootDirectory: root,
            pathValidator: makeValidator(),
            respectGitignore: false
        )
        let files = try enumerator.enumerate()
        let paths = files.map { $0.relativePath }

        #expect(paths.contains("src/main.swift"))
        #expect(paths.contains("README.md"))
        // No absolute paths
        #expect(!paths.contains { $0.hasPrefix("/") })
    }

    @Test("empty directory returns empty array without error")
    func emptyDirectoryReturnsEmpty() throws {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let enumerator = FileEnumerator(
            rootDirectory: tempDir,
            pathValidator: makeValidator(),
            respectGitignore: false
        )
        let files = try enumerator.enumerate()

        #expect(files.isEmpty)
    }

    @Test("nonexistent directory throws clear error")
    func nonexistentDirectoryThrows() throws {
        let enumerator = FileEnumerator(
            rootDirectory: "/nonexistent-dir-\(UUID().uuidString)",
            pathValidator: makeValidator(),
            respectGitignore: false
        )

        #expect(throws: (any Error).self) {
            try enumerator.enumerate()
        }
    }

    // MARK: - Glob Filtering

    @Test("glob pattern filters to matching files only")
    func globPatternFilters() throws {
        let root = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let enumerator = FileEnumerator(
            rootDirectory: root,
            pathValidator: makeValidator(),
            respectGitignore: false,
            globPattern: "*.swift"
        )
        let files = try enumerator.enumerate()
        let paths = files.map { $0.relativePath }

        // *.swift only matches in current directory, not recursively
        // All .swift files should match with **/*.swift for recursive
        #expect(paths.allSatisfy { $0.hasSuffix(".swift") })
    }

    @Test("double star glob matches files at all depths")
    func doubleStarGlobRecursive() throws {
        let root = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let enumerator = FileEnumerator(
            rootDirectory: root,
            pathValidator: makeValidator(),
            respectGitignore: false,
            globPattern: "**/*.swift"
        )
        let files = try enumerator.enumerate()
        let paths = files.map { $0.relativePath }

        #expect(paths.contains("src/main.swift"))
        #expect(paths.contains("src/utils.swift"))
        #expect(paths.contains("tests/test.swift"))
        #expect(!paths.contains("README.md"))
    }

    @Test("nil glob returns all files")
    func nilGlobReturnsAll() throws {
        let root = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let enumerator = FileEnumerator(
            rootDirectory: root,
            pathValidator: makeValidator(),
            respectGitignore: false,
            globPattern: nil
        )
        let files = try enumerator.enumerate()

        // .git always excluded, so src(2) + tests(1) + build(1) + node_modules(1) + README = 6
        #expect(files.count >= 6)
    }

    // MARK: - Gitignore Filtering

    @Test("gitignore excludes node_modules")
    func gitignoreExcludesNodeModules() throws {
        let root = try createFileTree()
        try "node_modules/\n".write(
            toFile: root + "/.gitignore", atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let enumerator = FileEnumerator(
            rootDirectory: root,
            pathValidator: makeValidator(),
            respectGitignore: true
        )
        let files = try enumerator.enumerate()
        let paths = files.map { $0.relativePath }

        #expect(!paths.contains { $0.hasPrefix("node_modules") })
        #expect(paths.contains("src/main.swift"))
    }

    @Test("respectGitignore false returns everything including ignored")
    func respectGitignoreFalseReturnsAll() throws {
        let root = try createFileTree()
        try "node_modules/\n".write(
            toFile: root + "/.gitignore", atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let enumerator = FileEnumerator(
            rootDirectory: root,
            pathValidator: makeValidator(),
            respectGitignore: false
        )
        let files = try enumerator.enumerate()
        let paths = files.map { $0.relativePath }

        #expect(paths.contains { $0.hasPrefix("node_modules") })
    }

    @Test(".git directory excluded regardless of gitignore setting")
    func dotGitAlwaysExcluded() throws {
        let root = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let enumerator = FileEnumerator(
            rootDirectory: root,
            pathValidator: makeValidator(),
            respectGitignore: false // Even with gitignore off, .git should be excluded
        )
        let files = try enumerator.enumerate()
        let paths = files.map { $0.relativePath }

        #expect(!paths.contains { $0.hasPrefix(".git/") || $0 == ".git" })
    }

    // MARK: - Path Validation

    @Test("root outside allowed directories is rejected")
    func rootOutsideAllowedRejected() throws {
        let validator = PathValidator(
            allowedReadDirectories: ["/tmp/yrden-allowed-only"],
            allowedWriteDirectories: ["/tmp/yrden-allowed-only"]
        )
        let enumerator = FileEnumerator(
            rootDirectory: "/etc",
            pathValidator: validator,
            respectGitignore: false
        )

        #expect(throws: (any Error).self) {
            try enumerator.enumerate()
        }
    }

    // MARK: - Limits

    @Test("maxResults caps output count")
    func maxResultsCaps() throws {
        let root = try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let enumerator = FileEnumerator(
            rootDirectory: root,
            pathValidator: makeValidator(),
            respectGitignore: false,
            maxResults: 3
        )
        let files = try enumerator.enumerate()

        #expect(files.count <= 3)
    }

    // MARK: - Binary Filtering

    @Test("skipBinaryFiles excludes files with null bytes")
    func skipBinaryExcludes() throws {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let binaryPath = tempDir + "/binary.bin"
        let textPath = tempDir + "/text.txt"
        try Data([0x48, 0x65, 0x6C, 0x00, 0x6F]).write(to: URL(fileURLWithPath: binaryPath))
        try "hello".write(toFile: textPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let enumerator = FileEnumerator(
            rootDirectory: tempDir,
            pathValidator: makeValidator(),
            respectGitignore: false,
            skipBinaryFiles: true
        )
        let files = try enumerator.enumerate()
        let paths = files.map { $0.relativePath }

        #expect(paths.contains("text.txt"))
        #expect(!paths.contains("binary.bin"))
    }

    // MARK: - Double Star with Prefix

    @Test("double star with directory prefix matches nested files")
    func doubleStarWithPrefixMatchesNestedFiles() throws {
        let root = tempDir
        let fm = FileManager.default

        // src/top.swift, src/sub/deep/main.swift
        try fm.createDirectory(atPath: root + "/src/sub/deep", withIntermediateDirectories: true)
        try "code".write(toFile: root + "/src/top.swift", atomically: true, encoding: .utf8)
        try "code".write(toFile: root + "/src/sub/deep/main.swift", atomically: true, encoding: .utf8)
        // tests/test.swift (should NOT match src/**)
        try fm.createDirectory(atPath: root + "/tests", withIntermediateDirectories: true)
        try "test".write(toFile: root + "/tests/test.swift", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let enumerator = FileEnumerator(
            rootDirectory: root,
            pathValidator: makeValidator(),
            respectGitignore: false,
            globPattern: "src/**/*.swift"
        )
        let files = try enumerator.enumerate()
        let paths = files.map { $0.relativePath }

        #expect(paths.contains("src/top.swift"))
        #expect(paths.contains("src/sub/deep/main.swift"))
        #expect(!paths.contains("tests/test.swift"))
    }

    @Test("skipBinaryFiles false includes binary files")
    func skipBinaryFalseIncludes() throws {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let binaryPath = tempDir + "/binary.bin"
        try Data([0x48, 0x65, 0x6C, 0x00, 0x6F]).write(to: URL(fileURLWithPath: binaryPath))
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let enumerator = FileEnumerator(
            rootDirectory: tempDir,
            pathValidator: makeValidator(),
            respectGitignore: false,
            skipBinaryFiles: false
        )
        let files = try enumerator.enumerate()
        let paths = files.map { $0.relativePath }

        #expect(paths.contains("binary.bin"))
    }
}
