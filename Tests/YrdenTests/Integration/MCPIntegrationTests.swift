/// Integration tests for MCP (Model Context Protocol) support.
///
/// These tests require MCP servers to be installed and available.
/// They test real MCP server connections via stdio transport.
///
/// Run with: MCP_TESTS=1 swift test --filter MCPIntegration
///
/// Prerequisites:
/// - Install uvx: `pip install uv` or `brew install uv`
/// - Python MCP servers (mcp-server-git, mcp-server-fetch) are installed automatically via uvx

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

// MARK: - Mock Model

/// Minimal mock model for testing MCP tool calls directly.
/// MCP tests don't invoke the model — only tool execution.
private struct MCPTestModel: Model {
    static let providerId = "test"
    let name: String = "mcp-test-model"
    let capabilities: ModelCapabilities = .claude45Haiku

    func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        fatalError("Not implemented for MCP tests")
    }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        fatalError("Not implemented for MCP tests")
    }
}

// MARK: - Structured Output Schemas

@Schema(description: "Extracted git repository information")
private struct GitRepoInfo: Equatable {
    @Guide(description: "The most recent commit message")
    let lastCommitMessage: String
    @Guide(description: "The author of the most recent commit")
    let lastCommitAuthor: String
    @Guide(description: "The name of the current branch")
    let currentBranch: String
}

// MARK: - Git Helpers

/// Run a git command in a directory and return stdout.
private func gitOutput(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Create a temp git repo with one commit. Returns the repo directory.
private func createTempGitRepo() throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("yrden-mcp-git-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = tempDir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    try git(["init", "-b", "main"])
    try git(["config", "user.name", "Test User"])
    try git(["config", "user.email", "test@example.com"])

    let testFile = tempDir.appendingPathComponent("README.md")
    try "# Test Repository\n\nThis is a test.".write(to: testFile, atomically: true, encoding: .utf8)

    try git(["add", "."])
    try git(["commit", "-m", "Initial commit"])

    return tempDir
}

// MARK: - Shared MCP Server

/// Lazily-created, shared MCP server connections to avoid subprocess startup overhead.
/// Read-only tests reuse these. Mutation tests create their own isolated servers.
private actor SharedMCPServers {
    static let shared = SharedMCPServers()

    private var gitServer: MCPServerConnection?
    private var gitRepoDir: URL?
    private var fetchServer: MCPServerConnection?

    func gitConnection() async throws -> (server: MCPServerConnection, repoDir: URL) {
        if let server = gitServer, let dir = gitRepoDir {
            return (server, dir)
        }

        let repoDir = try createTempGitRepo()
        let server = try await MCPServerConnection.stdio(
            command: "uvx",
            arguments: ["mcp-server-git", "--repository", repoDir.path],
            id: "shared-git"
        )
        self.gitServer = server
        self.gitRepoDir = repoDir
        return (server, repoDir)
    }

    func fetchConnection() async throws -> MCPServerConnection {
        if let server = fetchServer {
            return server
        }

        let server = try await MCPServerConnection.stdio(
            command: "uvx",
            arguments: ["mcp-server-fetch"],
            id: "shared-fetch"
        )
        self.fetchServer = server
        return server
    }

    func teardown() async {
        await gitServer?.disconnect()
        await fetchServer?.disconnect()
        if let dir = gitRepoDir {
            try? FileManager.default.removeItem(at: dir)
        }
        gitServer = nil
        fetchServer = nil
        gitRepoDir = nil
    }
}

// MARK: - Test Suite

@Suite("MCP Integration", .serialized)
struct MCPIntegrationTests {

    // MARK: - Gating

    private static var mcpTestsEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["MCP_TESTS"] != nil || env["INTEGRATION"] != nil
    }

    private static func isCommandAvailable(_ command: String) -> Bool {
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

    private static var isUvxAvailable: Bool { isCommandAvailable("uvx") }
    private static var isGitAvailable: Bool { isCommandAvailable("git") }

    // MARK: - Server Connection Tests

    @Test("Connect to git MCP server via stdio")
    func connectGitServer() async throws {
        guard Self.mcpTestsEnabled else { return }
        guard Self.isUvxAvailable && Self.isGitAvailable else {
            print("Skipping: uvx or git not available")
            return
        }

        let (server, _) = try await SharedMCPServers.shared.gitConnection()

        let tools = try await server.listTools()
        let toolNames = Set(tools.map { $0.name })

        // Git MCP server must expose these core tools
        for expected in ["git_status", "git_log", "git_diff"] {
            #expect(toolNames.contains(expected), "Missing expected tool '\(expected)'. Got: \(toolNames)")
        }

        // Each tool must have a name and description
        for tool in tools {
            #expect(!tool.name.isEmpty)
            #expect(tool.description?.isEmpty == false, "Tool '\(tool.name)' missing description")
        }
    }

    @Test("Get tools as [any Tool]")
    func getToolsAsAgentTools() async throws {
        guard Self.mcpTestsEnabled else { return }
        guard Self.isUvxAvailable && Self.isGitAvailable else {
            print("Skipping: uvx or git not available")
            return
        }

        let (server, _) = try await SharedMCPServers.shared.gitConnection()

        let agentTools: [any Tool] = try await server.tools()

        // Should match the raw MCP tool count
        let rawTools = try await server.listTools()
        #expect(agentTools.count == rawTools.count, "tools() should return same count as listTools")

        for tool in agentTools {
            #expect(!tool.name.isEmpty, "Tool name should not be empty")
            #expect(!tool.description.isEmpty, "Tool '\(tool.name)' should have a description")

            // Definition must be consistent
            #expect(tool.definition.name == tool.name)
            #expect(!tool.definition.description.isEmpty)

            // Each tool should have an input schema with properties
            let schema = tool.definition.inputSchema
            #expect(schema["type"] == "object", "Tool '\(tool.name)' schema should be an object")
        }
    }

    @Test("Execute git_status tool on MCP server")
    func executeGitStatusTool() async throws {
        guard Self.mcpTestsEnabled else { return }
        guard Self.isUvxAvailable && Self.isGitAvailable else {
            print("Skipping: uvx or git not available")
            return
        }

        let (server, repoDir) = try await SharedMCPServers.shared.gitConnection()

        let tools: [any Tool] = try await server.tools()
        guard let statusTool = tools.first(where: { $0.name == "git_status" }) else {
            print("git_status tool not found, available tools: \(tools.map { $0.name })")
            return
        }

        let context = ToolContext(model: MCPTestModel())

        let result = try await statusTool.call(
            context: context,
            argumentsJSON: "{\"repo_path\": \"\(repoDir.path)\"}"
        )

        // We created a clean repo with one commit, so status should say "clean"
        guard case .success(let output) = result else {
            Issue.record("Expected .success, got: \(result)")
            return
        }

        #expect(output.contains("nothing to commit") || output.contains("clean"),
               "Fresh repo should be clean. Got: \(output)")
    }

    // MARK: - Fetch Server Tests

    @Test("Connect to fetch MCP server")
    func connectFetchServer() async throws {
        guard Self.mcpTestsEnabled else { return }
        guard Self.isUvxAvailable else {
            print("Skipping: uvx not available")
            return
        }

        let server = try await SharedMCPServers.shared.fetchConnection()

        let tools = try await server.listTools()
        let toolNames = Set(tools.map { $0.name })

        // Fetch MCP server should expose a "fetch" tool
        #expect(toolNames.contains("fetch"), "Should have 'fetch' tool. Got: \(toolNames)")
    }

    // MARK: - Error Handling Tests

    @Test("Handle server connection failure gracefully")
    func handleConnectionFailure() async throws {
        guard Self.mcpTestsEnabled else { return }

        do {
            _ = try await MCPServerConnection.stdio(
                command: "nonexistent-mcp-server-command-12345",
                arguments: [],
                id: "invalid"
            )
            Issue.record("Should have thrown an error")
        } catch {
            print("Got expected error: \(type(of: error)) - \(error)")
        }
    }

    @Test("Handle tool execution with missing required arguments")
    func handleMissingToolArguments() async throws {
        guard Self.mcpTestsEnabled else { return }
        guard Self.isUvxAvailable && Self.isGitAvailable else {
            print("Skipping: uvx or git not available")
            return
        }

        let (server, _) = try await SharedMCPServers.shared.gitConnection()

        let tools: [any Tool] = try await server.tools()

        guard let tool = tools.first else {
            return
        }

        let context = ToolContext(model: MCPTestModel())

        // Execute with empty arguments — should work for some tools or fail gracefully
        let result = try await tool.call(
            context: context,
            argumentsJSON: "{}"
        )

        // Should either succeed or return an error (not crash)
        switch result {
        case .success:
            break
        case .failed:
            break
        case .denied:
            break
        case .replaced:
            break
        case .deferred:
            break
        case .failure:
            break
        }
    }

    // MARK: - Agent Loop with MCP Tools

    @Test("Agent extracts structured repo info via MCP git tools", arguments: ProviderFixture.all)
    func agentExtractsStructuredRepoInfo(fixture: ProviderFixture) async throws {
        guard Self.mcpTestsEnabled else { return }
        let subject = fixture.subject
        guard subject.constraints.supportsTools else {
            print("Skipping \(subject.providerName): doesn't support tools")
            return
        }
        guard Self.isUvxAvailable && Self.isGitAvailable else {
            print("Skipping: uvx or git not available")
            return
        }

        let (server, repoDir) = try await SharedMCPServers.shared.gitConnection()
        let mcpTools: [any Tool] = try await server.tools()

        let agent = try Agent<GitRepoInfo>(
            model: subject.model,
            systemPrompt: """
            You have access to git tools. The repository is at: \(repoDir.path)
            Use the git tools to find the requested information. Do not guess — use tools.
            """,
            tools: mcpTools,
            maxIterations: 5
        )

        let run = try await agent.run(
            "Get the last commit message, its author name, and the current branch name."
        )
        let info = try run.result()

        // Agent must have called at least one MCP tool
        #expect(run.toolCallCount >= 1,
               "[\(subject.providerName)] Should call git tools, called \(run.toolCallCount)")

        // We created the repo with known values — assert on exact fields
        #expect(info.lastCommitMessage.lowercased().contains("initial commit"),
               "[\(subject.providerName)] lastCommitMessage should be 'Initial commit', got: \(info.lastCommitMessage)")
        #expect(info.lastCommitAuthor.contains("Test User"),
               "[\(subject.providerName)] lastCommitAuthor should be 'Test User', got: \(info.lastCommitAuthor)")
        #expect(info.currentBranch == "main" || info.currentBranch == "master",
               "[\(subject.providerName)] currentBranch should be 'main' or 'master', got: \(info.currentBranch)")
    }

    @Test("Agent creates a git branch via MCP tools", arguments: ProviderFixture.all)
    func agentCreatesBranch(fixture: ProviderFixture) async throws {
        guard Self.mcpTestsEnabled else { return }
        let subject = fixture.subject
        guard subject.constraints.supportsTools else {
            print("Skipping \(subject.providerName): doesn't support tools")
            return
        }
        guard Self.isUvxAvailable && Self.isGitAvailable else {
            print("Skipping: uvx or git not available")
            return
        }

        // Mutation test needs its own isolated repo — don't pollute the shared one
        let repoDir = try createTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repoDir) }

        let server = try await MCPServerConnection.stdio(
            command: "uvx",
            arguments: ["mcp-server-git", "--repository", repoDir.path],
            id: "mutation-test-\(subject.providerName)"
        )
        defer { Task { await server.disconnect() } }

        let mcpTools: [any Tool] = try await server.tools()
        let branchName = "feature/test-branch"

        let agent = try Agent<String>(
            model: subject.model,
            systemPrompt: """
            You have access to git tools. The repository is at: \(repoDir.path)
            Execute the requested git operations using the available tools.
            After completing the operation, confirm what you did.
            """,
            tools: mcpTools,
            maxIterations: 5
        )

        let run = try await agent.run(
            "Create a new git branch called '\(branchName)' in this repository."
        )
        _ = try run.result()

        #expect(run.toolCallCount >= 1,
               "[\(subject.providerName)] Should call git tools, called \(run.toolCallCount)")

        // Verify the branch actually exists by running git directly
        let branches = try gitOutput(["branch", "--list"], in: repoDir)
        #expect(branches.contains("feature/test-branch"),
               "[\(subject.providerName)] Branch 'feature/test-branch' should exist. Branches: \(branches)")
    }
}
