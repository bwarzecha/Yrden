/// Integration tests for built-in tools with real LLMs.
///
/// Verifies that real LLMs can discover and correctly use the built-in tools
/// (glob, grep, read_file, write_file, edit_file, shell) through the agent loop.
///
/// Assertions focus on **side effects** (files on disk) and **message history**
/// (which tools were called), not LLM prose — because LLM text is nondeterministic.
///
/// Run with: ANTHROPIC_TESTS=1 swift test --filter BuiltInToolsIntegration
///
/// Prerequisites:
/// - ANTHROPIC_API_KEY and/or OPENAI_API_KEY environment variables

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Built-in Tools Integration", .serialized)
struct BuiltInToolsIntegrationTests {

    // MARK: - Helpers

    /// Creates a temp directory with a small project structure for testing.
    private func createTestProject() throws -> String {
        let tempDir = NSTemporaryDirectory() + "yrden-builtin-\(UUID().uuidString)"
        let fm = FileManager.default

        try fm.createDirectory(atPath: tempDir + "/src", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: tempDir + "/tests", withIntermediateDirectories: true)

        try """
        import Foundation

        func greetUser(name: String) -> String {
            return "Hello, \\(name)!"
        }

        func addNumbers(a: Int, b: Int) -> Int {
            return a + b
        }
        """.write(toFile: tempDir + "/src/utils.swift", atomically: true, encoding: .utf8)

        try """
        import Foundation

        struct Config {
            let apiUrl: String
            let timeout: Int
            let debugMode: Bool
        }

        let defaultConfig = Config(
            apiUrl: "https://api.example.com",
            timeout: 30,
            debugMode: false
        )
        """.write(toFile: tempDir + "/src/config.swift", atomically: true, encoding: .utf8)

        try """
        func testAddNumbers() {
            assert(addNumbers(a: 2, b: 3) == 5)
            assert(addNumbers(a: -1, b: 1) == 0)
        }
        """.write(toFile: tempDir + "/tests/test_utils.swift", atomically: true, encoding: .utf8)

        return tempDir
    }

    /// Creates an agent wired up with built-in tools and the given model.
    private func makeAgent(
        model: any Model,
        workingDirectory: String,
        systemPrompt: String
    ) async throws -> (agent: Agent<String>, registry: BackgroundTaskRegistry) {
        let env = ShellEnvironment.inherited()
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: [workingDirectory]
        )
        let registry = BackgroundTaskRegistry(gracefulShutdownTimeout: .milliseconds(500))
        let shell = ShellTool(
            environment: env,
            pathValidator: validator,
            workingDirectory: workingDirectory,
            backgroundTaskRegistry: registry,
            requiresApproval: false
        )
        let readFile = ReadFileTool(pathValidator: validator)
        let writeFile = WriteFileTool(pathValidator: validator)
        let editFile = EditFileTool(pathValidator: validator)
        let glob = GlobTool(pathValidator: validator, workingDirectory: workingDirectory)
        let grep = GrepTool(pathValidator: validator, workingDirectory: workingDirectory)

        let agent = try Agent<String>(
            model: model,
            systemPrompt: systemPrompt,
            tools: [shell, readFile, writeFile, editFile, glob, grep],
            maxIterations: 15,
            backgroundTaskRegistry: registry
        )

        return (agent, registry)
    }

    /// Extracts all tool names called during a run from the message history.
    private func toolNamesCalled(in run: AgentRun<String>) -> [String] {
        run.messages.flatMap { $0.toolCalls.map(\.name) }
    }

    /// Extracts all tool result content strings from the message history.
    private func toolResultContents(in run: AgentRun<String>) -> [String] {
        run.messages.compactMap { message in
            switch message {
            case .toolResult(_, let content):
                return content
            case .toolResults(let results):
                return results.map { entry in
                    switch entry.output {
                    case .text(let text): return text
                    case .json(let json): return "\(json)"
                    case .error(let err): return "ERROR: \(err)"
                    }
                }.joined(separator: "\n")
            default:
                return nil
            }
        }
    }

    // MARK: - File Exploration (grep → read_file)

    @Test("real LLM finds a function using grep and reads it", arguments: ProviderFixture.all)
    func fileExploration(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let tempDir = try createTestProject()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let (agent, _) = try await makeAgent(
            model: subject.model,
            workingDirectory: tempDir,
            systemPrompt: """
            You are a code assistant. You have tools to explore files:
            - grep: search file contents for patterns
            - read_file: read a file's full contents

            Use these tools to answer questions about the codebase.
            Be concise in your final answer.
            """
        )

        let run = try await agent.run(
            """
            Search for the function named "greetUser" using grep, \
            then read the file that contains it using read_file. \
            Tell me the exact return statement of that function.
            """
        )

        // 1. Run completed successfully
        #expect(run.isCompleted, "Run should complete, got status: \(run.status)")

        // 2. Verify correct tools were called
        let toolNames = toolNamesCalled(in: run)
        #expect(toolNames.contains("grep"), "Should have called grep, called: \(toolNames)")
        #expect(toolNames.contains("read_file"), "Should have called read_file, called: \(toolNames)")

        // 3. Verify tool results contain the expected file path and content
        let results = toolResultContents(in: run)
        let allResults = results.joined(separator: "\n")
        #expect(allResults.contains("utils.swift"),
               "Tool results should reference utils.swift, got: \(allResults)")
        #expect(allResults.contains("Hello"),
               "read_file result should contain the greeting string from the source")
    }

    // MARK: - File Editing (read_file → edit_file, verified on disk)

    @Test("real LLM edits a file and changes persist on disk", arguments: ProviderFixture.all)
    func fileEditing(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let tempDir = try createTestProject()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let targetFile = tempDir + "/src/config.swift"

        let (agent, _) = try await makeAgent(
            model: subject.model,
            workingDirectory: tempDir,
            systemPrompt: """
            You are a code assistant. You have tools to work with files:
            - read_file: read a file's contents
            - edit_file: edit a file by replacing exact string matches

            When editing, you MUST first read the file, then use edit_file with
            the exact old_string copied from the file contents. Be precise with
            whitespace and formatting.
            """
        )

        let run = try await agent.run(
            """
            Read the file at \(targetFile), then use edit_file to change \
            the timeout value from 30 to 60. Use the exact text from the file for old_string.
            """
        )

        // 1. Run completed successfully
        #expect(run.isCompleted, "Run should complete, got status: \(run.status)")

        // 2. Verify correct tools were called in order: read_file before edit_file
        let toolNames = toolNamesCalled(in: run)
        #expect(toolNames.contains("read_file"), "Should call read_file first, called: \(toolNames)")
        #expect(toolNames.contains("edit_file"), "Should call edit_file, called: \(toolNames)")

        let readIndex = toolNames.firstIndex(of: "read_file")!
        let editIndex = toolNames.firstIndex(of: "edit_file")!
        #expect(readIndex < editIndex, "read_file should be called before edit_file")

        // 3. Verify edit_file succeeded (tool result is not an error)
        let results = toolResultContents(in: run)
        let hasEditError = results.contains { $0.lowercased().contains("error") && $0.contains("edit") }
        #expect(!hasEditError, "edit_file should not return an error")

        // 4. THE REAL ASSERTION: verify the file on disk was actually modified
        let content = try String(contentsOfFile: targetFile, encoding: .utf8)
        #expect(content.contains("timeout: 60"),
               "File on disk should have timeout changed to 60, got:\n\(content)")
        #expect(!content.contains("timeout: 30"),
               "File on disk should no longer contain timeout: 30")

        // 5. Verify rest of the file wasn't corrupted
        #expect(content.contains("struct Config"),
               "File should still contain the Config struct")
        #expect(content.contains("apiUrl"),
               "File should still contain the apiUrl field")
        #expect(content.contains("debugMode: false"),
               "Other fields should be unchanged")
    }

    // MARK: - File Creation (write_file, verified on disk)

    @Test("real LLM creates a new file with write_file", arguments: ProviderFixture.all)
    func fileCreation(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let tempDir = try createTestProject()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let newFile = tempDir + "/src/constants.swift"

        let (agent, _) = try await makeAgent(
            model: subject.model,
            workingDirectory: tempDir,
            systemPrompt: """
            You are a code assistant. You have the write_file tool to create files.
            When asked to create a file, use write_file with the exact path and content provided.
            """
        )

        let run = try await agent.run(
            """
            Create a new file at \(newFile) using write_file with this exact content:
            let maxRetries = 3
            let defaultTimeout = 30
            """
        )

        // 1. Run completed successfully
        #expect(run.isCompleted, "Run should complete, got status: \(run.status)")

        // 2. Verify write_file was called
        let toolNames = toolNamesCalled(in: run)
        #expect(toolNames.contains("write_file"), "Should call write_file, called: \(toolNames)")

        // 3. THE REAL ASSERTION: file exists on disk with correct content
        let exists = FileManager.default.fileExists(atPath: newFile)
        #expect(exists, "File should exist at \(newFile)")

        let content = try String(contentsOfFile: newFile, encoding: .utf8)
        #expect(content.contains("maxRetries = 3"),
               "File should contain maxRetries constant, got:\n\(content)")
        #expect(content.contains("defaultTimeout = 30"),
               "File should contain defaultTimeout constant, got:\n\(content)")
    }
}
