/// Tests for ShellEnvironment detection and parsing.

import Testing
import Foundation
@testable import Yrden

@Suite("ShellEnvironment")
struct ShellEnvironmentTests {

    @Test("inherited returns PATH and HOME")
    func inheritedHasPathAndHome() {
        let env = ShellEnvironment.inherited()
        #expect(env.variables["PATH"] != nil)
        #expect(env.variables["HOME"] != nil)
    }

    @Test("explicit returns exactly what was passed")
    func explicitReturnsExact() {
        let vars = ["FOO": "bar", "BAZ": "qux"]
        let env = ShellEnvironment.explicit(vars)
        #expect(env.variables == vars)
        #expect(env.variables.count == 2)
    }

    @Test("explicit preserves custom shellPath")
    func explicitShellPath() {
        let env = ShellEnvironment.explicit([:], shellPath: "/bin/bash")
        #expect(env.shellPath == "/bin/bash")
    }

    @Test("explicit defaults to /bin/zsh")
    func explicitDefaultShellPath() {
        let env = ShellEnvironment.explicit([:])
        #expect(env.shellPath == "/bin/zsh")
    }

    @Test("capture returns PATH with expected entries")
    func captureReturnsPath() async throws {
        let env = try await ShellEnvironment.captureUserEnvironment()
        #expect(env.variables["PATH"] != nil)
        let path = env.variables["PATH"]!
        // Should have at least /usr/bin
        #expect(path.contains("/usr/bin"))
    }

    @Test("shell detection finds a valid path")
    func shellDetectionFindsValid() {
        let shell = ShellEnvironment.detectShellPath()
        #expect(FileManager.default.fileExists(atPath: shell))
    }

    @Test("env parsing handles equals in value")
    func parseEqualsInValue() {
        let output = "KEY=value=with=equals\nOTHER=simple\n"
        let result = ShellEnvironment.parseEnvironment(output)
        #expect(result["KEY"] == "value=with=equals")
        #expect(result["OTHER"] == "simple")
    }

    @Test("env parsing handles empty value")
    func parseEmptyValue() {
        let output = "EMPTY=\nFILLED=yes\n"
        let result = ShellEnvironment.parseEnvironment(output)
        #expect(result["EMPTY"] == "")
        #expect(result["FILLED"] == "yes")
    }

    @Test("env parsing handles multiple entries")
    func parseMultipleEntries() {
        let output = "A=1\nB=2\nC=3\n"
        let result = ShellEnvironment.parseEnvironment(output)
        #expect(result.count == 3)
        #expect(result["A"] == "1")
        #expect(result["B"] == "2")
        #expect(result["C"] == "3")
    }
}
