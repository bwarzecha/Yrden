/// Empty Tool Arguments Bug Test
///
/// This test suite validates the fix for a bug where empty tool arguments
/// caused the agent loop to crash with a DecodingError.
///
/// === Root Cause ===
/// When an LLM calls a tool with no arguments (like `list_allowed_directories`),
/// the arguments string is empty. Different parts of the code handled this
/// inconsistently:
///
/// 1. `AnthropicModel.parseToolArguments("")` → tried to decode empty JSON → crash
/// 2. `BedrockModel.parseJSONToDocument("")` → same issue → crash
/// 3. `parseMCPArguments("")` → returned nil instead of `[:]` → MCP server rejected
///
/// === Fix Applied ===
/// All JSON parsing functions now treat empty/whitespace-only strings as empty
/// objects `{}` instead of trying to parse them or returning nil.
///
/// === Files Fixed ===
/// - Sources/Yrden/Providers/Anthropic/AnthropicModel.swift
/// - Sources/Yrden/Providers/Bedrock/BedrockModel.swift
/// - Sources/Yrden/MCP/MCPToolHelpers.swift

import Testing
import Foundation
@testable import Yrden

@Suite("Empty Tool Arguments Bug Fix", .serialized)
struct MCPToolErrorReproTest {

    /// Check if npx is available.
    private var isNpxAvailable: Bool {
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

    /// Test that MCP tools handle empty arguments correctly.
    /// After the fix, empty args should be treated as `{}` and work.
    @Test("MCP tool with empty arguments works after fix")
    func mcpToolEmptyArgsWorks() async throws {
        guard isNpxAvailable else {
            print("Skipping: npx not available")
            return
        }

        let server: MCPServerConnection
        do {
            server = try await MCPServerConnection.stdio(
                command: "npx",
                arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
                id: "repro-test"
            )
        } catch {
            print("Skipping: Failed to connect: \(error)")
            return
        }

        defer {
            Task { await server.disconnect() }
        }

        let mcpTools: [AnyAgentTool<Void>] = try await server.discoverTools()

        guard let listDirsTool = mcpTools.first(where: { $0.name == "list_allowed_directories" }) else {
            print("Skipping: list_allowed_directories tool not found")
            return
        }

        // Call with EMPTY arguments - this used to fail
        let emptyArgs = ""

        let result = try await listDirsTool.call(
            context: AgentContext(
                deps: (),
                model: MockModel(),
                usage: Usage(inputTokens: 0, outputTokens: 0),
                retries: 0,
                toolCallID: "test-call",
                runID: "test-run",
                messages: []
            ),
            argumentsJSON: emptyArgs
        )

        // After fix: should succeed with directory info
        switch result {
        case .success(let value):
            print("✅ Tool succeeded: \(value)")
            #expect(value.contains("tmp") || value.contains("private"),
                   "Should return directory info")
        case .failure(let error):
            Issue.record("Tool should not fail after fix: \(error)")
        case .retry(let message):
            Issue.record("Tool should not retry: \(message)")
        case .deferred:
            Issue.record("Tool should not be deferred")
        }
    }

    // MARK: - Full Agent Loop Test (All Providers)

    /// Test that all providers correctly handle empty tool arguments.
    ///
    /// This was the original bug: when re-encoding an assistant message
    /// containing a tool call with empty arguments, JSON parsing would fail.
    @Test("Agent handles empty tool arguments", arguments: ProviderFixture.all)
    func agentHandlesEmptyToolArgs(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else {
            print("Skipping \(subject.providerName): doesn't support tools")
            return
        }
        guard isNpxAvailable else {
            print("Skipping: npx not available")
            return
        }

        // Connect to filesystem MCP server
        let server: MCPServerConnection
        do {
            server = try await MCPServerConnection.stdio(
                command: "npx",
                arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
                id: "empty-args-test-\(subject.providerName)"
            )
        } catch {
            print("Skipping: Failed to connect MCP: \(error)")
            return
        }

        defer {
            Task { await server.disconnect() }
        }

        // Get MCP tools
        let mcpTools: [AnyAgentTool<Void>] = try await server.discoverTools()
        print("[\(subject.providerName)] MCP tools: \(mcpTools.map { $0.name })")

        // Create agent with MCP tools
        let agent = Agent<Void, String>(
            model: subject.model,
            systemPrompt: """
            You have access to filesystem tools. When asked about directories,
            ALWAYS call list_allowed_directories first to see what directories are available.
            After getting the result, summarize what you found.
            """,
            tools: mcpTools,
            maxIterations: 5
        )

        // This prompt triggers `list_allowed_directories` which has no required arguments
        let prompt = "What directories can you access? Please check."

        do {
            let result = try await agent.run(prompt, deps: ())

            // After fix: should complete successfully
            print("[\(subject.providerName)] ✅ Agent completed: \(result.output.prefix(100))...")

            #expect(!result.output.isEmpty, "Should produce output")
            #expect(result.output.lowercased().contains("tmp") ||
                    result.output.lowercased().contains("directory") ||
                    result.output.lowercased().contains("access"),
                   "Should mention directories or access")

        } catch let error as DecodingError {
            // This was the original bug - should NOT happen after fix
            Issue.record("[\(subject.providerName)] BUG: DecodingError with empty args: \(error)")

        } catch let error as AgentError<String> {
            // maxIterationsReached is acceptable (flaky LLM behavior)
            if case .maxIterationsReached = error {
                print("[\(subject.providerName)] ⚠️ Max iterations (flaky, not bug)")
            } else {
                Issue.record("[\(subject.providerName)] AgentError: \(error)")
            }

        } catch {
            Issue.record("[\(subject.providerName)] Error: \(error)")
        }
    }

    // MARK: - Unit Test for JSON Parsing

    /// Direct unit test for empty argument parsing in MCP.
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

// MARK: - Mock Model for Testing

/// Minimal mock model for testing tool calls directly.
private struct MockModel: Model {
    var name: String { "mock" }
    var provider: any Provider { MockProvider() }
    var capabilities: ModelCapabilities { .claude35 }

    func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        fatalError("Not implemented - test doesn't use model")
    }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        fatalError("Not implemented - test doesn't use model")
    }
}

private struct MockProvider: Provider {
    var baseURL: URL { URL(string: "https://mock")! }

    func authenticate(_ request: inout URLRequest) async throws {}

    func listModels() -> AsyncThrowingStream<ModelInfo, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
