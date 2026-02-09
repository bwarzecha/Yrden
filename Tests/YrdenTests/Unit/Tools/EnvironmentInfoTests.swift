/// Tests for EnvironmentInfo discovery, parsing, and formatting.

import Testing
import Foundation
@testable import Yrden

@Suite("EnvironmentInfo")
struct EnvironmentInfoTests {

    // MARK: - Parsing

    @Test("parses complete discovery output")
    func parseCompleteOutput() {
        let output = """
            OS:Darwin
            OSVERSION:15.2
            ARCH:arm64
            TOOL:python3:Python 3.12.1
            TOOL:git:git version 2.43.0
            TOOL:node:v20.11.0
            TOOL:cargo:NOT_FOUND
            """
        let info = EnvironmentInfo.parseDiscoveryOutput(
            output,
            requestedTools: ["python3", "git", "node", "cargo"]
        )

        #expect(info.osName == "macOS")
        #expect(info.osVersion == "15.2")
        #expect(info.architecture == "arm64")
        #expect(info.availableTools.count == 3)
        #expect(info.availableTools[0].name == "python3")
        #expect(info.availableTools[0].version == "3.12.1")
        #expect(info.availableTools[1].name == "git")
        #expect(info.availableTools[1].version == "2.43.0")
        #expect(info.availableTools[2].name == "node")
        #expect(info.availableTools[2].version == "20.11.0")
        #expect(info.missingTools == ["cargo"])
    }

    @Test("maps Darwin to macOS")
    func darwinBecomesMacOS() {
        let output = "OS:Darwin\nOSVERSION:14.0\nARCH:x86_64\n"
        let info = EnvironmentInfo.parseDiscoveryOutput(output, requestedTools: [])
        #expect(info.osName == "macOS")
    }

    @Test("preserves Linux as-is")
    func linuxPreserved() {
        let output = "OS:Linux\nOSVERSION:6.5.0\nARCH:x86_64\n"
        let info = EnvironmentInfo.parseDiscoveryOutput(output, requestedTools: [])
        #expect(info.osName == "Linux")
    }

    @Test("handles 'not found' in various formats")
    func notFoundVariants() {
        let output = """
            OS:Darwin
            OSVERSION:15.0
            ARCH:arm64
            TOOL:python:NOT_FOUND
            TOOL:fd:fd: command not found
            TOOL:wget:No such file or directory
            """
        let info = EnvironmentInfo.parseDiscoveryOutput(
            output,
            requestedTools: ["python", "fd", "wget"]
        )
        #expect(info.availableTools.isEmpty)
        #expect(info.missingTools.count == 3)
    }

    @Test("missing tools are tools in requestedTools not found in output")
    func missingToolsFromRequested() {
        let output = """
            OS:Linux
            OSVERSION:6.5.0
            ARCH:x86_64
            TOOL:git:git version 2.40.0
            """
        let info = EnvironmentInfo.parseDiscoveryOutput(
            output,
            requestedTools: ["git", "cargo", "docker"]
        )
        #expect(info.availableTools.count == 1)
        #expect(info.missingTools == ["cargo", "docker"])
    }

    @Test("handles empty output gracefully")
    func emptyOutput() {
        let info = EnvironmentInfo.parseDiscoveryOutput("", requestedTools: ["git"])
        #expect(info.osName == "Unknown")
        #expect(info.osVersion == "")
        #expect(info.architecture == "")
        #expect(info.availableTools.isEmpty)
        #expect(info.missingTools == ["git"])
    }

    // MARK: - Version Cleaning

    @Test("cleans Python version")
    func cleanPythonVersion() {
        let result = EnvironmentInfo.cleanVersionString("Python 3.12.1", toolName: "python3")
        #expect(result == "3.12.1")
    }

    @Test("cleans git version")
    func cleanGitVersion() {
        let result = EnvironmentInfo.cleanVersionString("git version 2.43.0", toolName: "git")
        #expect(result == "2.43.0")
    }

    @Test("cleans go version")
    func cleanGoVersion() {
        let result = EnvironmentInfo.cleanVersionString(
            "go version go1.22.0 darwin/arm64", toolName: "go"
        )
        #expect(result == "1.22.0")
    }

    @Test("cleans node version")
    func cleanNodeVersion() {
        let result = EnvironmentInfo.cleanVersionString("v20.11.0", toolName: "node")
        #expect(result == "20.11.0")
    }

    @Test("cleans rustc version")
    func cleanRustcVersion() {
        let result = EnvironmentInfo.cleanVersionString(
            "rustc 1.75.0 (82e1608df 2023-12-21)", toolName: "rustc"
        )
        #expect(result == "1.75.0")
    }

    @Test("returns empty for unrecognizable version string")
    func unrecognizableVersion() {
        let result = EnvironmentInfo.cleanVersionString("some random text", toolName: "foo")
        #expect(result == "")
    }

    @Test("cleans sed version with hyphenated suffix")
    func cleanSedVersion() {
        let result = EnvironmentInfo.cleanVersionString(
            "sed (GNU sed) 4.9-dirty", toolName: "sed"
        )
        #expect(result == "4.9-dirty")
    }

    // MARK: - Description Suffix

    @Test("description suffix includes macOS BSD warning")
    func descriptionSuffixMacOS() {
        let info = EnvironmentInfo(
            osName: "macOS",
            osVersion: "15.2",
            architecture: "arm64",
            availableTools: [.init(name: "python3", version: "3.12.1")],
            missingTools: ["cargo"]
        )
        let suffix = info.descriptionSuffix

        #expect(suffix.contains("macOS 15.2 (arm64)"))
        #expect(suffix.contains("NOT Linux"))
        #expect(suffix.contains("BSD"))
        #expect(suffix.contains("sed -i"))
        #expect(suffix.contains("python3 (3.12.1)"))
        #expect(suffix.contains("Not found: cargo"))
    }

    @Test("description suffix omits BSD warning for Linux")
    func descriptionSuffixLinux() {
        let info = EnvironmentInfo(
            osName: "Linux",
            osVersion: "6.5.0",
            architecture: "x86_64",
            availableTools: [.init(name: "git", version: "2.40.0")],
            missingTools: []
        )
        let suffix = info.descriptionSuffix

        #expect(suffix.contains("Linux 6.5.0 (x86_64)"))
        #expect(!suffix.contains("NOT Linux"))
        #expect(!suffix.contains("Not found"))
    }

    @Test("description suffix handles tool without version")
    func descriptionSuffixNoVersion() {
        let info = EnvironmentInfo(
            osName: "macOS",
            osVersion: "15.0",
            architecture: "arm64",
            availableTools: [.init(name: "sed", version: "")],
            missingTools: []
        )
        let suffix = info.descriptionSuffix

        // Should show just "sed" without parentheses
        #expect(suffix.contains("Available: sed"))
        #expect(!suffix.contains("sed ()"))
    }

    // MARK: - Discovery Command

    @Test("build command includes OS probes and tool probes")
    func buildCommandStructure() {
        let command = EnvironmentInfo.buildDiscoveryCommand(tools: ["git", "python3"])

        #expect(command.contains("uname -s"))
        #expect(command.contains("sw_vers"))
        #expect(command.contains("uname -m"))
        #expect(command.contains("TOOL:git:"))
        #expect(command.contains("TOOL:python3:"))
    }

    @Test("build command uses 'version' flag for go")
    func buildCommandGoSpecialCase() {
        let command = EnvironmentInfo.buildDiscoveryCommand(tools: ["go"])
        #expect(command.contains("go version"))
    }

    @Test("build command uses '-version' flag for java")
    func buildCommandJavaSpecialCase() {
        let command = EnvironmentInfo.buildDiscoveryCommand(tools: ["java"])
        #expect(command.contains("java -version"))
    }

    // MARK: - Integration

    @Test("discover returns valid info on this machine", .timeLimit(.minutes(1)))
    func discoverReturnsInfo() async throws {
        let env = ShellEnvironment.inherited()
        let info = try await EnvironmentInfo.discover(
            shellPath: env.shellPath,
            environment: env.variables
        )

        // We should at least detect the OS
        #expect(info.osName == "macOS" || info.osName == "Linux")
        #expect(!info.architecture.isEmpty)
        // git should be available on any dev machine
        #expect(info.availableTools.contains { $0.name == "git" })
    }

    @Test("discover with custom tool list only probes those tools")
    func discoverCustomTools() async throws {
        let env = ShellEnvironment.inherited()
        let info = try await EnvironmentInfo.discover(
            shellPath: env.shellPath,
            environment: env.variables,
            tools: ["git"]
        )

        // Should only have git in available + missing, nothing else
        let allNames = info.availableTools.map(\.name) + info.missingTools
        #expect(allNames == ["git"])
    }
}
