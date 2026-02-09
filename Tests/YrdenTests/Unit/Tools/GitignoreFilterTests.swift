/// Tests for GitignoreFilter pattern matching and file filtering.

import Testing
import Foundation
@testable import Yrden

@Suite("GitignoreFilter")
struct GitignoreFilterTests {

    private let tempDir: String = NSTemporaryDirectory() + "yrden-gitignore-tests-\(UUID().uuidString)"

    // MARK: - Helpers

    private func createDir(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
    }

    private func writeFile(_ path: String, content: String = "") throws {
        let dir = (path as NSString).deletingLastPathComponent
        try createDir(dir)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Pattern Parsing

    @Test("simple filename pattern matches exact file")
    func simpleFilenamePattern() throws {
        let filter = GitignoreFilter(patterns: ["foo.txt"])

        #expect(filter.isIgnored(path: "foo.txt", isDirectory: false))
        #expect(!filter.isIgnored(path: "bar.txt", isDirectory: false))
    }

    @Test("wildcard star matches any filename")
    func wildcardStar() throws {
        let filter = GitignoreFilter(patterns: ["*.log"])

        #expect(filter.isIgnored(path: "debug.log", isDirectory: false))
        #expect(filter.isIgnored(path: "error.log", isDirectory: false))
        #expect(!filter.isIgnored(path: "debug.txt", isDirectory: false))
    }

    @Test("double star matches nested paths")
    func doubleStarMatchesNested() throws {
        let filter = GitignoreFilter(patterns: ["**/build"])

        #expect(filter.isIgnored(path: "build", isDirectory: true))
        #expect(filter.isIgnored(path: "src/build", isDirectory: true))
        #expect(filter.isIgnored(path: "src/deep/build", isDirectory: true))
    }

    @Test("directory-only pattern only matches directories")
    func directoryOnlyPattern() throws {
        let filter = GitignoreFilter(patterns: ["build/"])

        #expect(filter.isIgnored(path: "build", isDirectory: true))
        #expect(!filter.isIgnored(path: "build", isDirectory: false))
    }

    @Test("negation pattern re-includes previously ignored file")
    func negationPattern() throws {
        let filter = GitignoreFilter(patterns: ["*.log", "!important.log"])

        #expect(filter.isIgnored(path: "debug.log", isDirectory: false))
        #expect(!filter.isIgnored(path: "important.log", isDirectory: false))
    }

    @Test("comment lines are ignored")
    func commentLinesIgnored() throws {
        let filter = GitignoreFilter(patterns: ["# this is a comment", "*.log"])

        // Should only have the *.log rule, not the comment
        #expect(filter.isIgnored(path: "debug.log", isDirectory: false))
        #expect(!filter.isIgnored(path: "# this is a comment", isDirectory: false))
    }

    @Test("empty lines are ignored")
    func emptyLinesIgnored() throws {
        let filter = GitignoreFilter(patterns: ["", "*.log", "", ""])

        #expect(filter.isIgnored(path: "debug.log", isDirectory: false))
        #expect(!filter.isIgnored(path: "readme.md", isDirectory: false))
    }

    @Test("trailing whitespace in pattern is trimmed")
    func trailingWhitespaceTrimmed() throws {
        let filter = GitignoreFilter(patterns: ["*.log   "])

        #expect(filter.isIgnored(path: "debug.log", isDirectory: false))
    }

    @Test("leading slash roots pattern to gitignore directory")
    func leadingSlashRooted() throws {
        let filter = GitignoreFilter(patterns: ["/build"])

        // "/build" should match "build" at root but not "src/build"
        #expect(filter.isIgnored(path: "build", isDirectory: true))
        #expect(!filter.isIgnored(path: "src/build", isDirectory: true))
    }

    // MARK: - Filesystem Integration

    @Test("reads gitignore from directory and filters correctly")
    func readsFromDirectory() throws {
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        try writeFile(tempDir + "/.gitignore", content: "*.log\nbuild/\n")
        try writeFile(tempDir + "/readme.md", content: "hello")
        try writeFile(tempDir + "/debug.log", content: "log data")
        try createDir(tempDir + "/build")
        try writeFile(tempDir + "/build/output.o", content: "binary")

        let filter = try GitignoreFilter(directory: tempDir)

        #expect(filter.isIgnored(path: "debug.log", isDirectory: false))
        #expect(filter.isIgnored(path: "build", isDirectory: true))
        #expect(!filter.isIgnored(path: "readme.md", isDirectory: false))
    }

    @Test("nested gitignore overrides parent rules")
    func nestedGitignoreOverrides() throws {
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // Parent ignores all .log files
        try writeFile(tempDir + "/.gitignore", content: "*.log\n")
        // Nested gitignore re-includes .log files in src/
        try writeFile(tempDir + "/src/.gitignore", content: "!*.log\n")

        let parentFilter = try GitignoreFilter(directory: tempDir)
        let nestedFilter = try GitignoreFilter(
            directory: tempDir + "/src",
            parentFilter: parentFilter
        )

        // Parent still ignores .log
        #expect(parentFilter.isIgnored(path: "debug.log", isDirectory: false))
        // Nested re-includes .log
        #expect(!nestedFilter.isIgnored(path: "debug.log", isDirectory: false))
    }

    @Test("no gitignore file includes all files")
    func noGitignoreIncludesAll() throws {
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        try createDir(tempDir)

        let filter = try GitignoreFilter(directory: tempDir)

        #expect(!filter.isIgnored(path: "anything.txt", isDirectory: false))
        #expect(!filter.isIgnored(path: "node_modules", isDirectory: true))
    }

    @Test(".git directory always excluded even without gitignore")
    func dotGitAlwaysExcluded() throws {
        let filter = GitignoreFilter(patterns: [])

        #expect(filter.isIgnored(path: ".git", isDirectory: true))
        #expect(filter.isIgnored(path: ".git/HEAD", isDirectory: false))
    }

    @Test(".DS_Store always excluded")
    func dsStoreAlwaysExcluded() throws {
        let filter = GitignoreFilter(patterns: [])

        #expect(filter.isIgnored(path: ".DS_Store", isDirectory: false))
        #expect(filter.isIgnored(path: "subdir/.DS_Store", isDirectory: false))
    }

    // MARK: - Edge Cases

    @Test("gitignore with only comments and blank lines produces no rules")
    func onlyCommentsAndBlanks() throws {
        let filter = GitignoreFilter(patterns: ["# comment", "", "# another", ""])

        #expect(!filter.isIgnored(path: "anything.txt", isDirectory: false))
    }

    @Test("path separator in pattern restricts to specific directory")
    func pathSeparatorInPattern() throws {
        // "doc/frotz" means the pattern is relative to the root
        let filter = GitignoreFilter(patterns: ["doc/frotz"])

        #expect(filter.isIgnored(path: "doc/frotz", isDirectory: false))
        #expect(!filter.isIgnored(path: "other/doc/frotz", isDirectory: false))
    }
}
