/// E2E workflow tests exercising multi-tool chains through the Agent loop.
///
/// Each test simulates a realistic multi-step LLM workflow using FakeModel
/// with real built-in tools operating on a real temp directory. Verifies that
/// tools compose correctly when driven by the agent loop.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Agent - Tool Workflows")
struct AgentToolWorkflowTests {

    private let tempDir = NSTemporaryDirectory() + "yrden-workflow-\(UUID().uuidString)"

    // MARK: - Helpers

    private func makeToolsAndAgent(
        model: FakeModel,
        maxIterations: Int = 10
    ) async throws -> (agent: Agent<String>, registry: BackgroundTaskRegistry) {
        let env = ShellEnvironment.inherited()
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: ["/"]
        )
        let registry = BackgroundTaskRegistry(gracefulShutdownTimeout: .milliseconds(500))
        let shell = ShellTool(
            environment: env,
            pathValidator: validator,
            workingDirectory: tempDir,
            backgroundTaskRegistry: registry,
            requiresApproval: false
        )
        let readFile = ReadFileTool(pathValidator: validator)
        let writeFile = WriteFileTool(pathValidator: validator)
        let editFile = EditFileTool(pathValidator: validator)
        let glob = GlobTool(pathValidator: validator, workingDirectory: tempDir)
        let grep = GrepTool(pathValidator: validator, workingDirectory: tempDir)
        let taskOutput = TaskOutputTool(registry: registry)
        let taskStop = TaskStopTool(registry: registry)

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [shell, readFile, writeFile, editFile, glob, grep, taskOutput, taskStop],
            maxIterations: maxIterations,
            backgroundTaskRegistry: registry
        )

        return (agent, registry)
    }

    private func createFileTree() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: tempDir + "/src", withIntermediateDirectories: true)
        try "import Foundation\n\nfunc calculate(_ x: Int) -> Int {\n    return x * 2\n}\n".write(
            toFile: tempDir + "/src/math.swift", atomically: true, encoding: .utf8
        )
        try "import Foundation\n\nfunc greet(_ name: String) -> String {\n    return \"Hello, \\(name)\"\n}\n".write(
            toFile: tempDir + "/src/greet.swift", atomically: true, encoding: .utf8
        )
        try fm.createDirectory(atPath: tempDir + "/tests", withIntermediateDirectories: true)
        try "import Testing\n\n@Test func testMath() { }\n".write(
            toFile: tempDir + "/tests/test_math.swift", atomically: true, encoding: .utf8
        )
    }

    // MARK: - Workflow 1: File Exploration (glob → grep → read_file)

    @Test("file exploration: glob finds files, grep searches, read_file reads", .timeLimit(.minutes(1)))
    func fileExploration() async throws {
        try createFileTree()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                // Step 1: Find all Swift files
                return MockResponse.toolCall(
                    name: "glob",
                    arguments: #"{"pattern":"**/*.swift"}"#,
                    id: "tc-glob"
                )
            case 2:
                // Step 2: Verify glob found files, then search for "calculate"
                #expect(request.hasToolResult(for: "tc-glob"))
                let globOutput = request.toolResultContent(for: "tc-glob")!
                #expect(globOutput.contains("math.swift"))
                #expect(globOutput.contains("greet.swift"))
                return MockResponse.toolCall(
                    name: "grep",
                    arguments: #"{"pattern":"func calculate","output_mode":"content"}"#,
                    id: "tc-grep"
                )
            case 3:
                // Step 3: Verify grep found match, then read the file
                #expect(request.hasToolResult(for: "tc-grep"))
                let grepOutput = request.toolResultContent(for: "tc-grep")!
                #expect(grepOutput.contains("calculate"))
                return MockResponse.toolCall(
                    name: "read_file",
                    arguments: #"{"path":"\#(self.tempDir)/src/math.swift"}"#,
                    id: "tc-read"
                )
            case 4:
                // Step 4: Verify read content, return final answer
                #expect(request.hasToolResult(for: "tc-read"))
                let readOutput = request.toolResultContent(for: "tc-read")!
                #expect(readOutput.contains("return x * 2"))
                return MockResponse.text("Found calculate function that doubles its input")
            default:
                return MockResponse.text("Done")
            }
        })

        let (agent, _) = try await makeToolsAndAgent(model: model)
        let result = try await agent.run("Find the calculate function")

        #expect(result.output != nil)
        #expect(result.isCompleted)
        #expect(result.toolCallCount == 3)
    }

    // MARK: - Workflow 2: File Creation and Editing (write_file → read_file → edit_file → read_file)

    @Test("file editing: write, read, edit, verify", .timeLimit(.minutes(1)))
    func fileCreationAndEditing() async throws {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let filePath = tempDir + "/hello.swift"
        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                // Step 1: Create a file
                let content = "func hello() -> String {\n    return \"Hello, World\"\n}\n"
                let args = """
                {"path":"\(filePath)","content":"\(content.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\"", with: "\\\""))"}
                """
                return MockResponse.toolCall(name: "write_file", arguments: args, id: "tc-write")
            case 2:
                // Step 2: Read it back
                let writeOk = try request.isToolResultSuccess(for: "tc-write")
                #expect(writeOk)
                return MockResponse.toolCall(
                    name: "read_file",
                    arguments: #"{"path":"\#(filePath)"}"#,
                    id: "tc-read1"
                )
            case 3:
                // Step 3: Edit to change greeting
                let readOutput = request.toolResultContent(for: "tc-read1")!
                #expect(readOutput.contains("Hello, World"))
                return MockResponse.toolCall(
                    name: "edit_file",
                    arguments: #"{"path":"\#(filePath)","old_string":"Hello, World","new_string":"Hello, Swift","replace_all":false}"#,
                    id: "tc-edit"
                )
            case 4:
                // Step 4: Read again to verify
                let editOk = try request.isToolResultSuccess(for: "tc-edit")
                #expect(editOk)
                return MockResponse.toolCall(
                    name: "read_file",
                    arguments: #"{"path":"\#(filePath)"}"#,
                    id: "tc-read2"
                )
            case 5:
                // Step 5: Verify edit and return
                let readOutput = request.toolResultContent(for: "tc-read2")!
                #expect(readOutput.contains("Hello, Swift"))
                #expect(!readOutput.contains("Hello, World"))
                return MockResponse.text("Successfully edited hello.swift")
            default:
                return MockResponse.text("Done")
            }
        })

        let (agent, _) = try await makeToolsAndAgent(model: model)
        let result = try await agent.run("Create and edit hello.swift")

        #expect(result.isCompleted)
        // Verify file on disk
        let finalContent = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(finalContent.contains("Hello, Swift"))
        #expect(!finalContent.contains("Hello, World"))
    }

    // MARK: - Workflow 3: Project Scaffolding (shell → write_file → glob)

    @Test("project scaffolding: shell mkdir, write files, glob verify", .timeLimit(.minutes(1)))
    func projectScaffolding() async throws {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let counter = CallCounter()
        let td = tempDir
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                // Step 1: Create directories
                return MockResponse.toolCall(
                    name: "shell",
                    arguments: #"{"command":"mkdir -p src tests docs"}"#,
                    id: "tc-mkdir"
                )
            case 2:
                // Step 2: Write a source file
                let mkdirOk = try request.isToolResultSuccess(for: "tc-mkdir")
                #expect(mkdirOk)
                return MockResponse.toolCall(
                    name: "write_file",
                    arguments: #"{"path":"\#(td)/src/main.swift","content":"print(\"hello\")\n"}"#,
                    id: "tc-write"
                )
            case 3:
                // Step 3: List everything
                let writeOk = try request.isToolResultSuccess(for: "tc-write")
                #expect(writeOk)
                return MockResponse.toolCall(
                    name: "glob",
                    arguments: #"{"pattern":"**/*"}"#,
                    id: "tc-glob"
                )
            case 4:
                // Step 4: Verify structure and return
                let globOutput = request.toolResultContent(for: "tc-glob")!
                #expect(globOutput.contains("src/main.swift"))
                return MockResponse.text("Project scaffolded")
            default:
                return MockResponse.text("Done")
            }
        })

        let (agent, _) = try await makeToolsAndAgent(model: model)
        let result = try await agent.run("Create a project structure")

        #expect(result.isCompleted)
        // Verify on disk
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: tempDir + "/src/main.swift"))
        #expect(fm.fileExists(atPath: tempDir + "/tests"))
        #expect(fm.fileExists(atPath: tempDir + "/docs"))
    }

    // MARK: - Workflow 4: Background Task Lifecycle (shell bg → task_output poll → task_output block)

    @Test("background lifecycle: launch, poll, wait for completion", .timeLimit(.minutes(1)))
    func backgroundTaskLifecycle() async throws {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let capturedTaskId = CapturedValue()
        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                // Step 1: Start background task
                return MockResponse.toolCall(
                    name: "shell",
                    arguments: #"{"command":"echo started && sleep 0.3 && echo done","run_in_background":true}"#,
                    id: "tc-bg"
                )
            case 2:
                // Step 2: Extract task ID and poll (non-blocking)
                let bgOutput = request.toolResultContent(for: "tc-bg")!
                // Output contains the task ID like "bg_1_XXXXXXXX"
                let taskId = bgOutput.components(separatedBy: CharacterSet.whitespacesAndNewlines)
                    .first { $0.hasPrefix("bg_") } ?? bgOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                await capturedTaskId.set(taskId)
                return MockResponse.toolCall(
                    name: "task_output",
                    arguments: #"{"task_id":"\#(taskId)","block":false}"#,
                    id: "tc-poll"
                )
            case 3:
                // Step 3: Now block until completion
                let taskId = await capturedTaskId.value!
                return MockResponse.toolCall(
                    name: "task_output",
                    arguments: #"{"task_id":"\#(taskId)","block":true,"timeout":10}"#,
                    id: "tc-block"
                )
            case 4:
                // Step 4: Verify completion output
                let blockOutput = request.toolResultContent(for: "tc-block")!
                #expect(blockOutput.contains("done"))
                #expect(blockOutput.lowercased().contains("exit") || blockOutput.lowercased().contains("completed"))
                return MockResponse.text("Background task finished successfully")
            default:
                return MockResponse.text("Done")
            }
        })

        let (agent, registry) = try await makeToolsAndAgent(model: model)
        defer { Task { await registry.cancelAll() } }

        let result = try await agent.run("Run a background task and wait for it")
        #expect(result.isCompleted)
    }

    // MARK: - Workflow 5: Search and Replace (grep → edit_file × 2)

    @Test("search and replace: grep finds, edit_file renames across files", .timeLimit(.minutes(1)))
    func searchAndReplace() async throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: tempDir + "/src", withIntermediateDirectories: true)
        try "func oldName() {\n    print(\"old\")\n}\n".write(
            toFile: tempDir + "/src/a.swift", atomically: true, encoding: .utf8
        )
        try "func oldName() {\n    print(\"also old\")\n}\n".write(
            toFile: tempDir + "/src/b.swift", atomically: true, encoding: .utf8
        )
        defer { try? fm.removeItem(atPath: tempDir) }

        let td = tempDir
        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                // Step 1: Find all files containing "oldName"
                return MockResponse.toolCall(
                    name: "grep",
                    arguments: #"{"pattern":"oldName","output_mode":"files"}"#,
                    id: "tc-grep"
                )
            case 2:
                // Step 2: Edit first file
                let grepOutput = request.toolResultContent(for: "tc-grep")!
                #expect(grepOutput.contains("a.swift"))
                #expect(grepOutput.contains("b.swift"))
                return MockResponse.toolCall(
                    name: "edit_file",
                    arguments: #"{"path":"\#(td)/src/a.swift","old_string":"oldName","new_string":"newName","replace_all":true}"#,
                    id: "tc-edit1"
                )
            case 3:
                // Step 3: Edit second file
                let edit1Ok = try request.isToolResultSuccess(for: "tc-edit1")
                #expect(edit1Ok)
                return MockResponse.toolCall(
                    name: "edit_file",
                    arguments: #"{"path":"\#(td)/src/b.swift","old_string":"oldName","new_string":"newName","replace_all":true}"#,
                    id: "tc-edit2"
                )
            case 4:
                // Step 4: Confirm
                let edit2Ok = try request.isToolResultSuccess(for: "tc-edit2")
                #expect(edit2Ok)
                return MockResponse.text("Renamed oldName to newName in both files")
            default:
                return MockResponse.text("Done")
            }
        })

        let (agent, _) = try await makeToolsAndAgent(model: model)
        let result = try await agent.run("Rename oldName to newName")

        #expect(result.isCompleted)
        // Verify on disk
        let contentA = try String(contentsOfFile: tempDir + "/src/a.swift", encoding: .utf8)
        let contentB = try String(contentsOfFile: tempDir + "/src/b.swift", encoding: .utf8)
        #expect(contentA.contains("newName"))
        #expect(!contentA.contains("oldName"))
        #expect(contentB.contains("newName"))
        #expect(!contentB.contains("oldName"))
    }

    // MARK: - Workflow 6: Error Recovery (tool fails → model self-corrects)

    @Test("error recovery: wrong edit fails, model reads file and retries", .timeLimit(.minutes(1)))
    func errorRecovery() async throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let filePath = tempDir + "/config.txt"
        try "debug = false\nverbose = true\n".write(
            toFile: filePath, atomically: true, encoding: .utf8
        )
        defer { try? fm.removeItem(atPath: tempDir) }

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                // Step 1: Try edit with wrong old_string
                return MockResponse.toolCall(
                    name: "edit_file",
                    arguments: #"{"path":"\#(filePath)","old_string":"debug = true","new_string":"debug = false","replace_all":false}"#,
                    id: "tc-bad-edit"
                )
            case 2:
                // Step 2: Edit failed — check it's an error, then read the file
                let editFailed = try request.isToolResultError(for: "tc-bad-edit")
                #expect(editFailed)
                return MockResponse.toolCall(
                    name: "read_file",
                    arguments: #"{"path":"\#(filePath)"}"#,
                    id: "tc-read"
                )
            case 3:
                // Step 3: Now edit with correct old_string
                let content = request.toolResultContent(for: "tc-read")!
                #expect(content.contains("debug = false"))
                return MockResponse.toolCall(
                    name: "edit_file",
                    arguments: #"{"path":"\#(filePath)","old_string":"debug = false","new_string":"debug = true","replace_all":false}"#,
                    id: "tc-good-edit"
                )
            case 4:
                // Step 4: Verify success
                let editOk = try request.isToolResultSuccess(for: "tc-good-edit")
                #expect(editOk)
                return MockResponse.text("Fixed config")
            default:
                return MockResponse.text("Done")
            }
        })

        let (agent, _) = try await makeToolsAndAgent(model: model)
        let result = try await agent.run("Enable debug mode")

        #expect(result.isCompleted)
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(content.contains("debug = true"))
    }

    // MARK: - Workflow 7: Security Boundary (write outside allowed → error → retry)

    @Test("security boundary: write to denied path fails, retry in allowed succeeds", .timeLimit(.minutes(1)))
    func securityBoundary() async throws {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // Create tools with restricted write directories
        let validator = PathValidator(
            allowedReadDirectories: ["/"],
            allowedWriteDirectories: [tempDir]
        )
        let writeFile = WriteFileTool(pathValidator: validator)
        let readFile = ReadFileTool(pathValidator: validator)

        let td = tempDir
        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                // Step 1: Try to write outside allowed directory
                return MockResponse.toolCall(
                    name: "write_file",
                    arguments: #"{"path":"/tmp/yrden-evil-\#(UUID().uuidString).txt","content":"evil"}"#,
                    id: "tc-denied"
                )
            case 2:
                // Step 2: Got denied — write to allowed directory instead
                let denied = try request.isToolResultError(for: "tc-denied")
                #expect(denied)
                return MockResponse.toolCall(
                    name: "write_file",
                    arguments: #"{"path":"\#(td)/safe.txt","content":"safe content"}"#,
                    id: "tc-allowed"
                )
            case 3:
                let allowed = try request.isToolResultSuccess(for: "tc-allowed")
                #expect(allowed)
                return MockResponse.text("Wrote to allowed directory")
            default:
                return MockResponse.text("Done")
            }
        })

        let agent = try Agent<String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [writeFile, readFile]
        )
        let result = try await agent.run("Write a file")

        #expect(result.isCompleted)
        #expect(FileManager.default.fileExists(atPath: tempDir + "/safe.txt"))
    }

    // MARK: - Workflow 8: Streaming Edit Workflow (via runStream)

    @Test("streaming workflow: tool events emitted during multi-step edit", .timeLimit(.minutes(1)))
    func streamingEditWorkflow() async throws {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let filePath = tempDir + "/stream.txt"
        let counter = CallCounter()
        let model = FakeModel(
            onComplete: { request in
                switch await counter.increment() {
                case 1:
                    return MockResponse.toolCall(
                        name: "write_file",
                        arguments: #"{"path":"\#(filePath)","content":"original line\n"}"#,
                        id: "tc-write"
                    )
                case 2:
                    return MockResponse.toolCall(
                        name: "edit_file",
                        arguments: #"{"path":"\#(filePath)","old_string":"original line","new_string":"edited line","replace_all":false}"#,
                        id: "tc-edit"
                    )
                case 3:
                    return MockResponse.text("Streaming edit complete")
                default:
                    return MockResponse.text("Done")
                }
            },
            onStream: { request in
                switch await counter.increment() {
                case 1:
                    let toolResponse = MockResponse.toolCall(
                        name: "write_file",
                        arguments: #"{"path":"\#(filePath)","content":"original line\n"}"#,
                        id: "tc-write"
                    )
                    return [
                        .toolCallStart(id: "tc-write", name: "write_file"),
                        .toolCallDelta(argumentsDelta: #"{"path":"\#(filePath)","content":"original line\n"}"#),
                        .toolCallEnd(id: "tc-write"),
                        .done(toolResponse)
                    ]
                case 2:
                    let toolResponse = MockResponse.toolCall(
                        name: "edit_file",
                        arguments: #"{"path":"\#(filePath)","old_string":"original line","new_string":"edited line","replace_all":false}"#,
                        id: "tc-edit"
                    )
                    return [
                        .toolCallStart(id: "tc-edit", name: "edit_file"),
                        .toolCallDelta(argumentsDelta: #"{"path":"\#(filePath)","old_string":"original line","new_string":"edited line","replace_all":false}"#),
                        .toolCallEnd(id: "tc-edit"),
                        .done(toolResponse)
                    ]
                case 3:
                    let textResponse = MockResponse.text("Streaming edit complete")
                    return [
                        .contentDelta("Streaming edit complete"),
                        .done(textResponse)
                    ]
                default:
                    let r = MockResponse.text("Done")
                    return [.done(r)]
                }
            }
        )

        let (agent, _) = try await makeToolsAndAgent(model: model)

        var toolCallStarts: [String] = []
        var toolCallEnds: [String] = []
        var contentDeltas: [String] = []
        var finishedRun: AgentRun<String>?

        let stream = agent.runStream("Edit a file")
        for try await event in stream {
            switch event {
            case .toolCallStart(let id, _):
                toolCallStarts.append(id)
            case .toolCallEnd(let id):
                toolCallEnds.append(id)
            case .contentDelta(let text, _):
                contentDeltas.append(text)
            case .finished(let run):
                finishedRun = run
            default:
                break
            }
        }

        #expect(toolCallStarts.count >= 2, "Should see at least 2 tool call starts")
        #expect(toolCallEnds.count >= 2, "Should see at least 2 tool call ends")
        #expect(!contentDeltas.isEmpty, "Should see content deltas")
        #expect(finishedRun != nil, "Stream should emit finished event")
        #expect(finishedRun?.isCompleted == true)

        // Verify file was actually edited
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(content.contains("edited line"))
    }

    // MARK: - Workflow 9: BuiltInTools Factory API Verification

    @Test("BuiltInTools factory creates correct tool collections", .timeLimit(.minutes(1)))
    func builtInToolsFactoryAPI() async throws {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let tools = try await BuiltInTools(
            workingDirectory: tempDir,
            shellApprovalRequired: false
        )

        // all = 8 tools
        #expect(tools.all.count == 8)
        let allNames = Set(tools.all.map(\.name))
        #expect(allNames == ["shell", "read_file", "write_file", "edit_file", "glob", "grep", "task_output", "task_stop"])

        // core = 6 (no task management)
        #expect(tools.core.count == 6)
        let coreNames = Set(tools.core.map(\.name))
        #expect(!coreNames.contains("task_output"))
        #expect(!coreNames.contains("task_stop"))

        // readOnly = 3 (safe for untrusted)
        #expect(tools.readOnly.count == 3)
        let readNames = Set(tools.readOnly.map(\.name))
        #expect(readNames == ["read_file", "glob", "grep"])

        // Individual tool access
        #expect(tools.shell.name == "shell")
        #expect(tools.readFile.name == "read_file")
        #expect(tools.writeFile.name == "write_file")
        #expect(tools.editFile.name == "edit_file")
        #expect(tools.glob.name == "glob")
        #expect(tools.grep.name == "grep")
        #expect(tools.taskOutput.name == "task_output")
        #expect(tools.taskStop.name == "task_stop")

        // Registry is accessible
        let hasRunning = await tools.registry.hasRunningTasks()
        #expect(!hasRunning)
    }
}

// MARK: - Supporting Actor

/// Thread-safe value capture for use in FakeModel callbacks.
private actor CapturedValue {
    var value: String?
    func set(_ v: String) { value = v }
}
