/// Tests for PathValidator path resolution and directory restriction.

import Testing
import Foundation
@testable import Yrden

@Suite("PathValidator")
struct PathValidatorTests {

    @Test("path within allowed read directory succeeds")
    func pathWithinAllowedRead() throws {
        let validator = PathValidator(
            allowedReadDirectories: ["/tmp"],
            allowedWriteDirectories: ["/tmp"]
        )
        let result = try validator.validateRead("/tmp/test.txt")
        #expect(result.contains("/tmp/test.txt") || result.contains("/private/tmp/test.txt"))
    }

    @Test("path outside allowed read directory throws")
    func pathOutsideAllowedRead() throws {
        let validator = PathValidator(
            allowedReadDirectories: ["/tmp"],
            allowedWriteDirectories: ["/tmp"]
        )
        #expect(throws: PathValidationError.self) {
            try validator.validateRead("/etc/passwd")
        }
    }

    @Test("path within allowed write directory succeeds")
    func pathWithinAllowedWrite() throws {
        let validator = PathValidator(
            allowedWriteDirectories: ["/tmp"]
        )
        let result = try validator.validateWrite("/tmp/output.txt")
        #expect(result.contains("tmp/output.txt"))
    }

    @Test("path outside allowed write directory throws")
    func pathOutsideAllowedWrite() throws {
        let validator = PathValidator(
            allowedWriteDirectories: ["/tmp"]
        )
        #expect(throws: PathValidationError.self) {
            try validator.validateWrite("/etc/output.txt")
        }
    }

    @Test("dot-dot traversal is normalized before check")
    func dotDotTraversal() throws {
        let validator = PathValidator(
            allowedReadDirectories: ["/tmp"],
            allowedWriteDirectories: ["/tmp"]
        )
        // /tmp/../etc/passwd normalizes to /etc/passwd — should be denied
        #expect(throws: PathValidationError.self) {
            try validator.validateRead("/tmp/../etc/passwd")
        }
    }

    @Test("prefix confusion: /data does not match /data-archived")
    func prefixConfusion() throws {
        let validator = PathValidator(
            allowedReadDirectories: ["/data"],
            allowedWriteDirectories: ["/data"]
        )
        #expect(throws: PathValidationError.self) {
            try validator.validateRead("/data-archived/secret.txt")
        }
    }

    @Test("macOS /var normalizes to /private/var")
    func varNormalization() throws {
        let validator = PathValidator(
            allowedReadDirectories: ["/private/var"],
            allowedWriteDirectories: ["/private/var"]
        )
        // /var/tmp should normalize to /private/var/tmp
        let result = try validator.validateRead("/var/tmp/test.txt")
        #expect(result.hasPrefix("/private/var"))
    }

    @Test("denied read directories take priority over allowed")
    func deniedOverridesAllowed() throws {
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: ["/"],
            deniedReadDirectories: ["/secret"]
        )
        // Root is allowed, but /secret is denied
        #expect(throws: PathValidationError.self) {
            try validator.validateRead("/secret/key.pem")
        }
    }

    @Test("default read allows everything except denied")
    func defaultReadConfig() throws {
        let home = NSHomeDirectory()
        let validator = PathValidator(
            allowedWriteDirectories: [home],
            deniedReadDirectories: [home + "/.ssh"]
        )
        // Default allows reading from /
        let result = try validator.validateRead("/usr/bin/env")
        #expect(!result.isEmpty)

        // But ~/.ssh is denied
        #expect(throws: PathValidationError.self) {
            try validator.validateRead(home + "/.ssh/id_rsa")
        }
    }

    @Test("tilde expansion works in denied directories")
    func tildeExpansion() throws {
        let home = NSHomeDirectory()
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: [home],
            deniedReadDirectories: ["~/.ssh"]
        )
        // ~/.ssh should expand and deny
        #expect(throws: PathValidationError.self) {
            try validator.validateRead(home + "/.ssh/id_rsa")
        }
    }

    @Test("tilde expansion works in path argument")
    func tildeExpansionInPath() throws {
        let home = NSHomeDirectory()
        let validator = PathValidator(
            allowedReadDirectories: [home],
            allowedWriteDirectories: [home]
        )
        let result = try validator.validateRead("~/Desktop")
        #expect(result.hasPrefix(home))
    }

    @Test("exact directory path matches")
    func exactDirectoryMatch() throws {
        let validator = PathValidator(
            allowedReadDirectories: ["/tmp"],
            allowedWriteDirectories: ["/tmp"]
        )
        // The directory itself should be allowed (path == dir)
        let result = try validator.validateRead("/tmp")
        #expect(result.contains("tmp"))
    }

    // MARK: - Relative Path Resolution

    @Test("relative path resolves against workingDirectory")
    func relativePathResolvesAgainstWorkDir() throws {
        let validator = PathValidator(
            allowedWriteDirectories: ["/tmp"],
            workingDirectory: "/tmp"
        )
        let result = try validator.validateWrite("subdir/file.txt")
        // Should resolve to /tmp/subdir/file.txt (or /private/tmp/... on macOS)
        #expect(result.contains("tmp/subdir/file.txt"))
    }

    @Test("relative path with dot resolves against workingDirectory")
    func relativePathWithDotResolvesAgainstWorkDir() throws {
        let validator = PathValidator(
            allowedWriteDirectories: ["/tmp"],
            workingDirectory: "/tmp"
        )
        let result = try validator.validateWrite("./subdir/file.txt")
        #expect(result.contains("tmp/subdir/file.txt"))
    }

    @Test("relative path without workingDirectory resolves against process CWD")
    func relativePathWithoutWorkDirUsesProcessCwd() throws {
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: ["/"]
        )
        // No workingDirectory set — should resolve against process CWD
        let result = try validator.validateRead("Package.swift")
        #expect(result.hasPrefix("/"))
    }
}
