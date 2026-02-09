/// Tests for ShellTool shell execution with CWD tracking and output truncation.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("ShellTool")
struct ShellToolTests {

    private let tempDir: String = NSTemporaryDirectory() + "yrden-shell-tests-\(UUID().uuidString)"

    private func makeTool(
        workingDirectory: String? = nil,
        maxOutputLength: Int = 30_000,
        requiresApproval: Bool = false
    ) -> ShellTool {
        let cwd = workingDirectory ?? NSTemporaryDirectory()
        let env = ShellEnvironment.inherited()
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: ["/"]
        )
        return ShellTool(
            environment: env,
            pathValidator: validator,
            workingDirectory: cwd,
            maxOutputLength: maxOutputLength,
            spilloverDirectory: tempDir + "/spillover",
            requiresApproval: requiresApproval
        )
    }

    private func makeContext() -> ToolContext {
        ToolContext(model: FakeModel())
    }

    @Test("echo hello returns output", .timeLimit(.minutes(1)))
    func echoHello() async throws {
        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ShellToolArgs(command: "echo hello", workingDirectory: nil, timeout: nil,
                runInBackground: nil,
                description: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)"); return
        }

        #expect(output.contains("hello"))
    }

    @Test("non-zero exit code reported", .timeLimit(.minutes(1)))
    func nonZeroExitCode() async throws {
        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ShellToolArgs(command: "exit 42", workingDirectory: nil, timeout: nil,
                runInBackground: nil,
                description: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("Exit code: 42"))
    }

    @Test("working directory respected", .timeLimit(.minutes(1)))
    func workingDirectoryRespected() async throws {
        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ShellToolArgs(command: "pwd", workingDirectory: "/tmp", timeout: nil,
                runInBackground: nil,
                description: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // /tmp resolves to /private/tmp on macOS
        #expect(output.contains("tmp"))
    }

    @Test("CWD tracking persists across calls", .timeLimit(.minutes(1)))
    func cwdTrackingPersists() async throws {
        let tool = makeTool(workingDirectory: "/tmp")

        // First call: cd to a specific directory
        _ = try await tool.execute(
            context: makeContext(),
            arguments: ShellToolArgs(command: "cd /usr && pwd", workingDirectory: nil, timeout: nil,
                runInBackground: nil,
                description: nil
            )
        )

        // Second call: should be in /usr now
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ShellToolArgs(command: "pwd", workingDirectory: nil, timeout: nil,
                runInBackground: nil,
                description: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("/usr"))
    }

    @Test("sentinel is stripped from output", .timeLimit(.minutes(1)))
    func sentinelStripped() async throws {
        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ShellToolArgs(command: "echo test", workingDirectory: nil, timeout: nil,
                runInBackground: nil,
                description: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(!output.contains("__YRDEN_CWD__"))
    }

    @Test("exit code preserved through sentinel", .timeLimit(.minutes(1)))
    func exitCodePreservedThroughSentinel() async throws {
        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ShellToolArgs(command: "ls /nonexistent_path_xyz", workingDirectory: nil, timeout: nil,
                runInBackground: nil,
                description: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // Should have non-zero exit code
        #expect(output.contains("Exit code:"))
    }

    @Test("timeout kills long-running process", .timeLimit(.minutes(1)))
    func timeoutKillsProcess() async throws {
        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ShellToolArgs(command: "sleep 999", workingDirectory: nil, timeout: 1, runInBackground: nil, description: nil)
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("timed out") || output.contains("Exit code:"))
    }

    @Test("large output is truncated with spillover", .timeLimit(.minutes(1)))
    func largeOutputTruncatedWithSpillover() async throws {
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tool = makeTool(maxOutputLength: 500)
        // Generate output larger than maxOutputLength
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ShellToolArgs(
                command: "seq 1 1000",
                workingDirectory: nil,
                timeout: nil,
                runInBackground: nil,
                description: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("[...truncated") || output.contains("Full output saved to:"))
    }

    @Test("requiresApproval defaults to true")
    func requiresApprovalDefaultsTrue() {
        let env = ShellEnvironment.inherited()
        let validator = PathValidator(allowedWriteDirectories: ["/"])
        let tool = ShellTool(
            environment: env,
            pathValidator: validator,
            workingDirectory: "/tmp"
        )
        #expect(tool.requiresApproval == true)
    }

    @Test("tool definition schema is valid")
    func toolDefinitionSchema() {
        let tool = makeTool()
        #expect(tool.name == "shell")
        #expect(!tool.description.isEmpty)
    }

    @Test("stderr is included in output", .timeLimit(.minutes(1)))
    func stderrIncluded() async throws {
        let tool = makeTool()
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ShellToolArgs(
                command: "echo stdout_part && echo error_msg >&2",
                workingDirectory: nil,
                timeout: nil,
                runInBackground: nil,
                description: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        #expect(output.contains("error_msg"))
    }

    @Test("workingDirectory outside allowed path is rejected", .timeLimit(.minutes(1)))
    func workingDirectoryValidated() async throws {
        let env = ShellEnvironment.inherited()
        let validator = PathValidator(
            allowedReadDirectories: ["/tmp"],
            allowedWriteDirectories: ["/tmp"]
        )
        let tool = ShellTool(
            environment: env,
            pathValidator: validator,
            workingDirectory: "/tmp",
            requiresApproval: false
        )

        let result = try await tool.execute(
            context: makeContext(),
            arguments: ShellToolArgs(command: "pwd", workingDirectory: "/etc", timeout: nil,
                runInBackground: nil,
                description: nil
            )
        )

        // .error() returns .failure with ToolExecutionError
        guard case .failure(let error) = result else {
            Issue.record("Expected failure for disallowed workingDirectory, got \(result)"); return
        }

        #expect(error.localizedDescription.contains("not allowed"))
    }

    @Test("output capped at collection time prevents OOM", .timeLimit(.minutes(1)))
    func outputCappedAtCollection() async throws {
        // Use a small maxOutputLength so the cap (2x) is small
        let tool = makeTool(maxOutputLength: 1_000)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // Generate ~50KB output (well over 2x 1000 = 2000 byte cap)
        let result = try await tool.execute(
            context: makeContext(),
            arguments: ShellToolArgs(
                command: "seq 1 10000",
                workingDirectory: nil,
                timeout: nil,
                runInBackground: nil,
                description: nil
            )
        )

        guard case .success(let output) = result else {
            Issue.record("Expected success"); return
        }

        // Output should be truncated, not the full 50KB
        #expect(output.count < 5_000)
    }

    @Test("spillover failure does not crash", .timeLimit(.minutes(1)))
    func spilloverFailureDoesNotCrash() async throws {
        let env = ShellEnvironment.inherited()
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: ["/"]
        )
        // Use a read-only directory for spillover so writing fails
        let tool = ShellTool(
            environment: env,
            pathValidator: validator,
            workingDirectory: "/tmp",
            maxOutputLength: 100,
            spilloverDirectory: "/nonexistent-readonly-dir/spillover",
            requiresApproval: false
        )

        let result = try await tool.execute(
            context: makeContext(),
            arguments: ShellToolArgs(command: "seq 1 1000", workingDirectory: nil, timeout: nil,
                runInBackground: nil,
                description: nil
            )
        )

        // Should still succeed with truncated output (no crash)
        guard case .success(let output) = result else {
            Issue.record("Expected success despite spillover failure"); return
        }

        #expect(output.contains("[...truncated"))
    }
}
