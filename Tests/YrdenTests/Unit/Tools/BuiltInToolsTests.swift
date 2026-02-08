/// Tests for BuiltInTools factory.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("BuiltInTools")
struct BuiltInToolsTests {

    @Test("creates all three tools", .timeLimit(.minutes(1)))
    func createsAllThreeTools() async throws {
        let env = ShellEnvironment.inherited()
        let tools = try await BuiltInTools(
            workingDirectory: "/tmp",
            environment: env
        )

        #expect(tools.shell.name == "shell")
        #expect(tools.readFile.name == "read_file")
        #expect(tools.writeFile.name == "write_file")
    }

    @Test("all returns three tools", .timeLimit(.minutes(1)))
    func allReturnsThreeTools() async throws {
        let env = ShellEnvironment.inherited()
        let tools = try await BuiltInTools(
            workingDirectory: "/tmp",
            environment: env
        )

        let all = tools.all
        #expect(all.count == 3)
        let names = Set(all.map { $0.name })
        #expect(names == ["shell", "read_file", "write_file"])
    }

    @Test("tool names are distinct", .timeLimit(.minutes(1)))
    func toolNamesDistinct() async throws {
        let env = ShellEnvironment.inherited()
        let tools = try await BuiltInTools(
            workingDirectory: "/tmp",
            environment: env
        )

        let names = tools.all.map { $0.name }
        #expect(Set(names).count == names.count)
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
}
