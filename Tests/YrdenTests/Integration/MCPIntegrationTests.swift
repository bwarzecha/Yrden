/// Integration tests for MCP (Model Context Protocol) support.
///
/// These tests require MCP servers to be installed and available.
/// They test real MCP server connections via stdio transport.
///
/// Run with: swift test --filter MCPIntegration
///
/// Prerequisites:
/// - Install uvx: `pip install uv` or `brew install uv`
/// - Python MCP servers (mcp-server-git, mcp-server-fetch) are installed automatically via uvx

import Testing
import Foundation
@testable import Yrden
import MCP

/// Mock model for testing MCP tool execution.
private struct MCPTestModel: Model {
    let name: String = "mcp-test-model"
    let capabilities: ModelCapabilities = .claude35

    func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        fatalError("Not implemented for MCP tests")
    }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        fatalError("Not implemented for MCP tests")
    }
}

@Suite("MCP Integration")
struct MCPIntegrationTests {

    // MARK: - Helpers

    /// Check if a command is available on the system.
    private func isCommandAvailable(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Check if uvx is available (needed for Python MCP servers).
    private var isUvxAvailable: Bool {
        isCommandAvailable("uvx")
    }

    /// Check if git is available (needed for mcp-server-git).
    private var isGitAvailable: Bool {
        isCommandAvailable("git")
    }

    /// Create a temporary git repository for testing.
    private func createTempGitRepo() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yrden-mcp-git-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Initialize git repo
        let initProcess = Process()
        initProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProcess.arguments = ["init"]
        initProcess.currentDirectoryURL = tempDir
        initProcess.standardOutput = FileHandle.nullDevice
        initProcess.standardError = FileHandle.nullDevice
        try initProcess.run()
        initProcess.waitUntilExit()

        // Configure git user for commits
        let configNameProcess = Process()
        configNameProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        configNameProcess.arguments = ["config", "user.name", "Test User"]
        configNameProcess.currentDirectoryURL = tempDir
        configNameProcess.standardOutput = FileHandle.nullDevice
        configNameProcess.standardError = FileHandle.nullDevice
        try configNameProcess.run()
        configNameProcess.waitUntilExit()

        let configEmailProcess = Process()
        configEmailProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        configEmailProcess.arguments = ["config", "user.email", "test@example.com"]
        configEmailProcess.currentDirectoryURL = tempDir
        configEmailProcess.standardOutput = FileHandle.nullDevice
        configEmailProcess.standardError = FileHandle.nullDevice
        try configEmailProcess.run()
        configEmailProcess.waitUntilExit()

        // Create a test file and commit
        let testFile = tempDir.appendingPathComponent("README.md")
        try "# Test Repository\n\nThis is a test.".write(to: testFile, atomically: true, encoding: .utf8)

        let addProcess = Process()
        addProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        addProcess.arguments = ["add", "."]
        addProcess.currentDirectoryURL = tempDir
        addProcess.standardOutput = FileHandle.nullDevice
        addProcess.standardError = FileHandle.nullDevice
        try addProcess.run()
        addProcess.waitUntilExit()

        let commitProcess = Process()
        commitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        commitProcess.arguments = ["commit", "-m", "Initial commit"]
        commitProcess.currentDirectoryURL = tempDir
        commitProcess.standardOutput = FileHandle.nullDevice
        commitProcess.standardError = FileHandle.nullDevice
        try commitProcess.run()
        commitProcess.waitUntilExit()

        return tempDir
    }

    // MARK: - Server Connection Tests

    @Test("Connect to git MCP server via stdio")
    func connectGitServer() async throws {
        // Skip if prerequisites are not available
        guard isUvxAvailable && isGitAvailable else {
            print("Skipping: uvx or git not available")
            return
        }

        // Create a temporary git repository
        let repoDir = try createTempGitRepo()
        defer {
            try? FileManager.default.removeItem(at: repoDir)
        }

        // Connect to the git server
        let server = try await MCPServerConnection.stdio(
            command: "uvx",
            arguments: ["mcp-server-git", "--repository", repoDir.path],
            id: "test-git"
        )

        // Should be able to list tools
        let tools = try await server.listTools()

        // Git server provides tools like git_status, git_log, git_diff, etc.
        #expect(tools.count > 0, "Should have at least one tool")

        // Find expected git tools
        let toolNames = tools.map { $0.name }
        print("Available git tools: \(toolNames)")

        let hasExpectedTool = toolNames.contains("git_status") ||
                              toolNames.contains("git_log") ||
                              toolNames.contains("git_diff") ||
                              toolNames.contains { $0.hasPrefix("git") }
        #expect(hasExpectedTool, "Should have expected git tools, got: \(toolNames)")

        // Cleanup
        await server.disconnect()
    }

    @Test("Discover tools as AnyAgentTool")
    func discoverToolsAsAgentTools() async throws {
        guard isUvxAvailable && isGitAvailable else {
            print("Skipping: uvx or git not available")
            return
        }

        let repoDir = try createTempGitRepo()
        defer {
            try? FileManager.default.removeItem(at: repoDir)
        }

        let server = try await MCPServerConnection.stdio(
            command: "uvx",
            arguments: ["mcp-server-git", "--repository", repoDir.path],
            id: "test-git"
        )

        // Discover tools as type-erased AgentTools
        let agentTools: [AnyAgentTool<Void>] = try await server.discoverTools()

        #expect(agentTools.count > 0, "Should discover at least one tool")

        // Each tool should have a valid definition
        for tool in agentTools {
            #expect(!tool.name.isEmpty, "Tool name should not be empty")
            #expect(!tool.description.isEmpty, "Tool description should not be empty")

            // Definition should have matching name
            #expect(tool.definition.name == tool.name)
        }

        await server.disconnect()
    }

    @Test("Execute git_status tool on MCP server")
    func executeGitStatusTool() async throws {
        guard isUvxAvailable && isGitAvailable else {
            print("Skipping: uvx or git not available")
            return
        }

        let repoDir = try createTempGitRepo()
        defer {
            try? FileManager.default.removeItem(at: repoDir)
        }

        let server = try await MCPServerConnection.stdio(
            command: "uvx",
            arguments: ["mcp-server-git", "--repository", repoDir.path],
            id: "test-git"
        )

        // Find the git_status tool
        let tools: [AnyAgentTool<Void>] = try await server.discoverTools()
        guard let statusTool = tools.first(where: { $0.name == "git_status" }) else {
            await server.disconnect()
            print("git_status tool not found, available tools: \(tools.map { $0.name })")
            return
        }

        // Create a mock context (MCP tools don't use context)
        let context = AgentContext<Void>(
            deps: (),
            model: MCPTestModel()
        )

        // Execute the tool with repo_path argument
        let result = try await statusTool.call(
            context: context,
            argumentsJSON: "{\"repo_path\": \"\(repoDir.path)\"}"
        )

        // Verify result
        switch result {
        case .success(let output):
            // Git status should return some text
            print("git_status output: \(output)")
            #expect(!output.isEmpty, "Should return status output")
        case .failure(let error):
            Issue.record("Tool execution failed: \(error)")
        case .retry(let message):
            Issue.record("Tool requested retry: \(message)")
        case .deferred:
            Issue.record("Tool was deferred unexpectedly")
        }

        await server.disconnect()
    }

    // MARK: - Fetch Server Tests (simpler, no filesystem needed)

    @Test("Connect to fetch MCP server")
    func connectFetchServer() async throws {
        guard isUvxAvailable else {
            print("Skipping: uvx not available")
            return
        }

        // Connect to the fetch server (no arguments needed)
        let server = try await MCPServerConnection.stdio(
            command: "uvx",
            arguments: ["mcp-server-fetch"],
            id: "test-fetch"
        )

        // Should be able to list tools
        let tools = try await server.listTools()

        // Fetch server provides a fetch tool
        #expect(tools.count > 0, "Should have at least one tool")

        let toolNames = tools.map { $0.name }
        print("Available fetch tools: \(toolNames)")

        // Cleanup
        await server.disconnect()
    }

    // MARK: - Error Handling Tests

    @Test("Handle server connection failure gracefully")
    func handleConnectionFailure() async throws {
        // Try to connect to a non-existent command
        do {
            _ = try await MCPServerConnection.stdio(
                command: "nonexistent-mcp-server-command-12345",
                arguments: [],
                id: "invalid"
            )
            Issue.record("Should have thrown an error")
        } catch {
            // Expected - connection should fail for non-existent command
            print("Got expected error: \(type(of: error)) - \(error)")
        }
    }

    @Test("Handle tool execution with missing required arguments")
    func handleMissingToolArguments() async throws {
        guard isUvxAvailable && isGitAvailable else {
            print("Skipping: uvx or git not available")
            return
        }

        let repoDir = try createTempGitRepo()
        defer {
            try? FileManager.default.removeItem(at: repoDir)
        }

        let server = try await MCPServerConnection.stdio(
            command: "uvx",
            arguments: ["mcp-server-git", "--repository", repoDir.path],
            id: "test-git"
        )

        let tools: [AnyAgentTool<Void>] = try await server.discoverTools()

        // Find a tool that requires arguments (like git_diff_staged might)
        guard let tool = tools.first else {
            await server.disconnect()
            return
        }

        let context = AgentContext<Void>(
            deps: (),
            model: MCPTestModel()
        )

        // Execute with empty arguments - this should work for some tools or fail gracefully
        let result = try await tool.call(
            context: context,
            argumentsJSON: "{}"
        )

        // Should either succeed or return an error (not crash)
        switch result {
        case .success:
            // Some tools work without arguments
            break
        case .failure:
            // Expected for tools requiring arguments
            break
        case .retry:
            // Also acceptable
            break
        case .deferred:
            // Unexpected but not a crash
            break
        }

        await server.disconnect()
    }
}
