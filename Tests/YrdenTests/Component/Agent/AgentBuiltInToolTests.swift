/// Component tests for Agent with built-in tools end-to-end.
///
/// Verifies that the Agent can call ShellTool, ReadFileTool, and WriteFileTool
/// with real execution (no mocking of tools), using a FakeModel that issues
/// tool calls and then returns a final text response.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Agent - Built-in Tools")
struct AgentBuiltInToolTests {

    private func makeTools() -> [any Tool] {
        let env = ShellEnvironment.inherited()
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: ["/"]
        )
        let shell = ShellTool(
            environment: env,
            pathValidator: validator,
            workingDirectory: "/tmp",
            requiresApproval: false
        )
        let read = ReadFileTool(pathValidator: validator)
        let write = WriteFileTool(pathValidator: validator)
        return [shell, read, write]
    }

    @Test("agent calls shell tool and result flows to model", .timeLimit(.minutes(1)))
    func shellToolRoundTrip() async throws {
        let tools = makeTools()

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "shell",
                    arguments: #"{"command":"echo agent-test-output"}"#,
                    id: "tc-shell-1"
                )
            case 2:
                let result = request.toolResultContent(for: "tc-shell-1") ?? ""
                #expect(result.contains("agent-test-output"))
                return MockResponse.text("Shell done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: tools
        )

        let result = try await agent.run("Run a shell command")
        #expect(result.output == "Shell done")
        #expect(result.requestCount == 2)
        #expect(result.toolCallCount == 1)
    }

    @Test("agent calls read_file on a temp file", .timeLimit(.minutes(1)))
    func readFileToolRoundTrip() async throws {
        let tools = makeTools()

        // Create a temp file to read
        let tempFile = NSTemporaryDirectory() + "yrden-agent-read-\(UUID().uuidString).txt"
        try "hello from read test".write(toFile: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let counter = CallCounter()
        let escapedPath = tempFile.replacingOccurrences(of: "\\", with: "\\\\")
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "read_file",
                    arguments: "{\"path\":\"\(escapedPath)\"}",
                    id: "tc-read-1"
                )
            case 2:
                let result = request.toolResultContent(for: "tc-read-1") ?? ""
                #expect(result.contains("hello from read test"))
                return MockResponse.text("Read done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: tools
        )

        let result = try await agent.run("Read the file")
        #expect(result.output == "Read done")
    }

    @Test("agent calls write_file and file appears on disk", .timeLimit(.minutes(1)))
    func writeFileToolRoundTrip() async throws {
        let tools = makeTools()

        let tempFile = NSTemporaryDirectory() + "yrden-agent-write-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let counter = CallCounter()
        let escapedPath = tempFile.replacingOccurrences(of: "\\", with: "\\\\")
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "write_file",
                    arguments: "{\"path\":\"\(escapedPath)\",\"content\":\"written by agent\"}",
                    id: "tc-write-1"
                )
            case 2:
                let result = request.toolResultContent(for: "tc-write-1") ?? ""
                #expect(result.contains("Wrote"))
                return MockResponse.text("Write done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: tools
        )

        let result = try await agent.run("Write a file")
        #expect(result.output == "Write done")

        // Verify file was actually created
        let content = try String(contentsOfFile: tempFile, encoding: .utf8)
        #expect(content == "written by agent")
    }

    @Test("multi-tool sequence: shell writes file then read_file reads it", .timeLimit(.minutes(1)))
    func multiToolSequence() async throws {
        let tools = makeTools()

        let tempFile = NSTemporaryDirectory() + "yrden-agent-multi-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let escapedPath = tempFile.replacingOccurrences(of: "\\", with: "\\\\")
        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                // Step 1: Write file via shell
                return MockResponse.toolCall(
                    name: "shell",
                    arguments: "{\"command\":\"echo -n multi-tool-content > '\(escapedPath)'\"}",
                    id: "tc-shell-1"
                )
            case 2:
                // Step 2: Read the file back
                return MockResponse.toolCall(
                    name: "read_file",
                    arguments: "{\"path\":\"\(escapedPath)\"}",
                    id: "tc-read-1"
                )
            case 3:
                let result = request.toolResultContent(for: "tc-read-1") ?? ""
                #expect(result.contains("multi-tool-content"))
                return MockResponse.text("Multi done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: tools
        )

        let result = try await agent.run("Write then read")
        #expect(result.output == "Multi done")
        #expect(result.requestCount == 3)
        #expect(result.toolCallCount == 2)
    }

    @Test("BuiltInTools.all registers with Agent without duplicate name errors", .timeLimit(.minutes(1)))
    func builtInToolsAllRegisters() async throws {
        let env = ShellEnvironment.inherited()
        let builtIn = try await BuiltInTools(
            workingDirectory: "/tmp",
            environment: env,
            shellApprovalRequired: false
        )

        // Should not throw - all names are distinct
        let agent = try Agent<String>(
            model: FakeModel(),
            systemPrompt: "test",
            tools: builtIn.all
        )

        // Verify agent has all 3 tools
        let toolCount = await agent.tools.count
        #expect(toolCount == 3)
    }
}
