/// Empty Tool Arguments Bug Test
///
/// Validates the fix for a bug where empty tool arguments caused the agent
/// loop to crash with a DecodingError.
///
/// Root Cause:
/// - `AnthropicModel.parseToolArguments("")` → tried to decode empty JSON → crash
/// - `BedrockModel.parseJSONToDocument("")` → same issue → crash
/// - `parseMCPArguments("")` → returned nil instead of `[:]` → MCP server rejected
///
/// Fix: All JSON parsing functions treat empty/whitespace strings as `{}`.
///
/// Run with: MCP_TESTS=1 swift test --filter "MCPToolError"

import Testing
import Foundation
@testable import Yrden

// MARK: - Mock Model

private struct MCPMockModel: Model {
    static let providerId = "test"
    var name: String { "mock" }
    var capabilities: ModelCapabilities { .claude45Haiku }

    func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        fatalError("Not implemented - test doesn't use model")
    }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        fatalError("Not implemented - test doesn't use model")
    }
}

// MARK: - Shared MCP Server

/// Shared filesystem MCP server for tool error repro tests.
private actor SharedFilesystemServer {
    static let shared = SharedFilesystemServer()

    private var server: MCPServerConnection?

    func connection() async throws -> MCPServerConnection {
        if let server = server {
            return server
        }

        let server = try await MCPServerConnection.stdio(
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
            id: "shared-filesystem"
        )
        self.server = server
        return server
    }

    func teardown() async {
        await server?.disconnect()
        server = nil
    }
}

// MARK: - Test Suite

@Suite("Empty Tool Arguments Bug Fix", .serialized)
struct MCPToolErrorReproTest {

    // MARK: - Gating

    private static var mcpTestsEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["MCP_TESTS"] != nil || env["INTEGRATION"] != nil
    }

    private static var isNpxAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["npx"]
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

    // MARK: - Direct Tool Call Tests

    @Test("MCP tool with empty arguments works after fix")
    func mcpToolEmptyArgsWorks() async throws {
        guard Self.mcpTestsEnabled else { return }
        guard Self.isNpxAvailable else {
            print("Skipping: npx not available")
            return
        }

        let server: MCPServerConnection
        do {
            server = try await SharedFilesystemServer.shared.connection()
        } catch {
            print("Skipping: Failed to connect: \(error)")
            return
        }

        let mcpTools: [any Tool] = try await server.tools()

        guard let listDirsTool = mcpTools.first(where: { $0.name == "list_allowed_directories" }) else {
            print("Skipping: list_allowed_directories tool not found")
            return
        }

        // Call with EMPTY arguments — this used to crash
        let result = try await listDirsTool.call(
            context: ToolContext(
                model: MCPMockModel(),
                usage: Usage(inputTokens: 0, outputTokens: 0),
                toolCallID: "test-call",
                runID: "test-run",
                messages: []
            ),
            argumentsJSON: ""
        )

        switch result {
        case .success(let value):
            print("Tool succeeded: \(value)")
            #expect(value.contains("tmp") || value.contains("private"),
                   "Should return directory info")
        case .failed(let error):
            Issue.record("Tool should not fail after fix: \(error)")
        case .denied, .replaced, .deferred, .failure:
            Issue.record("Unexpected result: \(result)")
        }
    }

    // MARK: - Full Agent Loop Test (All Providers)

    @Test("Agent handles empty tool arguments", arguments: ProviderFixture.all)
    func agentHandlesEmptyToolArgs(fixture: ProviderFixture) async throws {
        guard Self.mcpTestsEnabled else { return }
        let subject = fixture.subject
        guard subject.constraints.supportsTools else {
            print("Skipping \(subject.providerName): doesn't support tools")
            return
        }
        guard Self.isNpxAvailable else {
            print("Skipping: npx not available")
            return
        }

        let server: MCPServerConnection
        do {
            server = try await SharedFilesystemServer.shared.connection()
        } catch {
            print("Skipping: Failed to connect MCP: \(error)")
            return
        }

        let mcpTools: [any Tool] = try await server.tools()
        print("[\(subject.providerName)] MCP tools: \(mcpTools.map { $0.name })")

        let agent = try Agent<String>(
            model: subject.model,
            systemPrompt: """
            You have access to filesystem tools. When asked about directories,
            ALWAYS call list_allowed_directories first to see what directories are available.
            After getting the result, summarize what you found.
            """,
            tools: mcpTools,
            maxIterations: 5
        )

        let prompt = "What directories can you access? Please check."

        do {
            let run = try await agent.run(prompt)
            let output = try run.result()

            print("[\(subject.providerName)] Agent completed: \(output.prefix(100))...")

            #expect(!output.isEmpty, "Should produce output")
            #expect(output.lowercased().contains("tmp") ||
                    output.lowercased().contains("directory") ||
                    output.lowercased().contains("access"),
                   "Should mention directories or access")

        } catch let error as DecodingError {
            // This was the original bug — should NOT happen after fix
            Issue.record("[\(subject.providerName)] BUG: DecodingError with empty args: \(error)")

        } catch let error as AgentError<String> {
            // iterationLimitReached is acceptable (flaky LLM behavior)
            if case .iterationLimitReached = error {
                print("[\(subject.providerName)] Max iterations (flaky, not a bug)")
            } else {
                Issue.record("[\(subject.providerName)] AgentError: \(error)")
            }

        } catch {
            Issue.record("[\(subject.providerName)] Error: \(error)")
        }
    }

    // MARK: - Unit Test for JSON Parsing (no gating — pure logic)

    @Test("parseMCPArguments handles empty strings")
    func parseMCPArgumentsEmpty() {
        // Empty string should return empty dict, not nil
        let result1 = parseMCPArguments("")
        switch result1 {
        case .success(let args):
            #expect(args != nil, "Should return non-nil (empty dict)")
            #expect(args?.isEmpty == true, "Should be empty dict")
        case .error(let error):
            Issue.record("Should not error on empty string: \(error)")
        }

        // Whitespace-only should also return empty dict
        let result2 = parseMCPArguments("   ")
        switch result2 {
        case .success(let args):
            #expect(args != nil, "Should return non-nil for whitespace")
        case .error(let error):
            Issue.record("Should not error on whitespace: \(error)")
        }

        // "{}" should return empty dict
        let result3 = parseMCPArguments("{}")
        switch result3 {
        case .success(let args):
            #expect(args != nil, "Should return non-nil for {}")
            #expect(args?.isEmpty == true, "Should be empty dict")
        case .error(let error):
            Issue.record("Should not error on {}: \(error)")
        }
    }
}
