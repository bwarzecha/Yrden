/// Tests for BuiltInTools factory.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("BuiltInTools")
struct BuiltInToolsTests {

    @Test("creates original three tools", .timeLimit(.minutes(1)))
    func createsOriginalThreeTools() async throws {
        let env = ShellEnvironment.inherited()
        let tools = try await BuiltInTools(
            workingDirectory: "/tmp",
            environment: env
        )

        #expect(tools.shell.name == "shell")
        #expect(tools.readFile.name == "read_file")
        #expect(tools.writeFile.name == "write_file")
    }

    @Test("shell approval defaults to true", .timeLimit(.minutes(1)))
    func shellApprovalDefaultsTrue() async throws {
        let env = ShellEnvironment.inherited()
        let tools = try await BuiltInTools(
            workingDirectory: "/tmp",
            environment: env
        )

        #expect(tools.shell.requiresApproval == true)
    }

    @Test("shell approval can be disabled", .timeLimit(.minutes(1)))
    func shellApprovalCanBeDisabled() async throws {
        let env = ShellEnvironment.inherited()
        let tools = try await BuiltInTools(
            workingDirectory: "/tmp",
            environment: env,
            shellApprovalRequired: false
        )

        #expect(tools.shell.requiresApproval == false)
    }

    @Test("custom write directories applied", .timeLimit(.minutes(1)))
    func customWriteDirectories() async throws {
        let env = ShellEnvironment.inherited()
        let tools = try await BuiltInTools(
            workingDirectory: "/tmp",
            allowedWriteDirectories: ["/tmp", "/var/tmp"],
            environment: env
        )

        // Write to /tmp should work (it's in the allowed list)
        let tempFile = "/tmp/yrden-builtin-test-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let result = try await tools.writeFile.execute(
            context: ToolContext(model: FakeModel()),
            arguments: WriteFileArgs(path: tempFile, content: "test")
        )
        guard case .success = result else {
            Issue.record("Expected success writing to allowed directory"); return
        }
    }

    @Test("default denied directories include ssh", .timeLimit(.minutes(1)))
    func defaultDeniedDirectories() async throws {
        let env = ShellEnvironment.inherited()
        let tools = try await BuiltInTools(
            workingDirectory: "/tmp",
            environment: env
        )

        // Try reading from ~/.ssh - should be denied
        let sshPath = NSHomeDirectory() + "/.ssh/known_hosts"
        let result = try await tools.readFile.execute(
            context: ToolContext(model: FakeModel()),
            arguments: ReadFileArgs(path: sshPath, offset: nil, limit: nil)
        )

        guard case .failure = result else {
            Issue.record("Expected failure reading from denied directory"); return
        }
    }

    // MARK: - Expanded Tool Set (8 tools)

    @Test("creates all eight tools", .timeLimit(.minutes(1)))
    func createsAllEightTools() async throws {
        let env = ShellEnvironment.inherited()
        let tools = try await BuiltInTools(
            workingDirectory: "/tmp",
            environment: env
        )

        #expect(tools.shell.name == "shell")
        #expect(tools.readFile.name == "read_file")
        #expect(tools.writeFile.name == "write_file")
        #expect(tools.editFile.name == "edit_file")
        #expect(tools.glob.name == "glob")
        #expect(tools.grep.name == "grep")
        #expect(tools.taskOutput.name == "task_output")
        #expect(tools.taskStop.name == "task_stop")
    }

    @Test("all returns eight tools", .timeLimit(.minutes(1)))
    func allReturnsEightTools() async throws {
        let env = ShellEnvironment.inherited()
        let tools = try await BuiltInTools(
            workingDirectory: "/tmp",
            environment: env
        )

        let all = tools.all
        #expect(all.count == 8)
        let names = Set(all.map { $0.name })
        #expect(names == [
            "shell", "read_file", "write_file", "edit_file",
            "glob", "grep", "task_output", "task_stop"
        ])
    }

    @Test("core returns six tools without background management", .timeLimit(.minutes(1)))
    func coreReturnsSixTools() async throws {
        let env = ShellEnvironment.inherited()
        let tools = try await BuiltInTools(
            workingDirectory: "/tmp",
            environment: env
        )

        let core = tools.core
        #expect(core.count == 6)
        let names = Set(core.map { $0.name })
        #expect(names == [
            "shell", "read_file", "write_file", "edit_file", "glob", "grep"
        ])
        #expect(!names.contains("task_output"))
        #expect(!names.contains("task_stop"))
    }

    @Test("readOnly returns three tools", .timeLimit(.minutes(1)))
    func readOnlyReturnsThreeTools() async throws {
        let env = ShellEnvironment.inherited()
        let tools = try await BuiltInTools(
            workingDirectory: "/tmp",
            environment: env
        )

        let readOnly = tools.readOnly
        #expect(readOnly.count == 3)
        let names = Set(readOnly.map { $0.name })
        #expect(names == ["read_file", "glob", "grep"])
    }

    @Test("all tool names are distinct (expanded)", .timeLimit(.minutes(1)))
    func allNamesDistinctExpanded() async throws {
        let env = ShellEnvironment.inherited()
        let tools = try await BuiltInTools(
            workingDirectory: "/tmp",
            environment: env
        )

        let names = tools.all.map { $0.name }
        #expect(Set(names).count == names.count, "All tool names must be unique")
    }

    @Test("registry is accessible as public property", .timeLimit(.minutes(1)))
    func registryAccessible() async throws {
        let env = ShellEnvironment.inherited()
        let tools = try await BuiltInTools(
            workingDirectory: "/tmp",
            environment: env
        )

        // Registry should be publicly accessible
        let hasRunning = await tools.registry.hasRunningTasks()
        #expect(hasRunning == false)
    }

    @Test("background registry shared between shell and task tools", .timeLimit(.minutes(1)))
    func sharedBackgroundRegistry() async throws {
        let env = ShellEnvironment.inherited()
        let tools = try await BuiltInTools(
            workingDirectory: "/tmp",
            environment: env,
            shellApprovalRequired: false
        )
        defer { Task { await tools.registry.cancelAll() } }

        // Launch a background task via shell
        let result = try await tools.shell.execute(
            context: ToolContext(model: FakeModel()),
            arguments: ShellToolArgs(
                command: "sleep 999",
                workingDirectory: nil,
                timeout: nil,
                runInBackground: true,
                description: nil
            )
        )

        guard case .success = result else {
            Issue.record("Expected success launching background task"); return
        }

        // Verify registry sees the task
        try await Task.sleep(for: .milliseconds(200))
        let hasRunning = await tools.registry.hasRunningTasks()
        #expect(hasRunning == true, "Registry should see the background task launched by shell")
    }
}
