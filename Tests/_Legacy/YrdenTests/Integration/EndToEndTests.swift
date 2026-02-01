/// End-to-End Tests for Yrden Agent System.
///
/// These tests exercise the complete agent system with real LLMs:
/// - Full agent loops with multiple tool calls
/// - Multi-turn conversations
/// - MCP server integration
/// - Error recovery and retry handling
/// - Cross-provider compatibility
///
/// Run with: swift test --filter EndToEnd
///
/// Prerequisites:
/// - ANTHROPIC_API_KEY and/or OPENAI_API_KEY environment variables
/// - For MCP tests: uvx (pip install uv or brew install uv)

import Testing
import Foundation
@testable import Yrden

// MARK: - Test Tools

/// Arguments for the calculator tool.
@Schema(description: "Calculator operation arguments")
private struct E2ECalculatorArgs {
    @Guide(description: "First operand")
    let a: Int
    @Guide(description: "Second operand")
    let b: Int
    @Guide(description: "Operation: add, subtract, multiply, divide")
    let operation: String
}

/// A calculator tool that performs basic arithmetic.
private struct E2ECalculatorTool: AgentTool {
    typealias Deps = Void
    typealias Args = E2ECalculatorArgs

    var name: String { "calculator" }
    var description: String { "Perform arithmetic operations. Use operation: add, subtract, multiply, divide" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        let result: Int
        switch arguments.operation.lowercased() {
        case "add", "+":
            result = arguments.a + arguments.b
        case "subtract", "-":
            result = arguments.a - arguments.b
        case "multiply", "*", "x":
            result = arguments.a * arguments.b
        case "divide", "/":
            guard arguments.b != 0 else {
                return .retry(message: "Cannot divide by zero. Please use a non-zero divisor.")
            }
            result = arguments.a / arguments.b
        default:
            return .retry(message: "Unknown operation '\(arguments.operation)'. Use: add, subtract, multiply, or divide.")
        }
        return .success("\(arguments.a) \(arguments.operation) \(arguments.b) = \(result)")
    }
}

/// Arguments for the data lookup tool.
@Schema(description: "Data lookup arguments")
private struct E2EDataLookupArgs {
    @Guide(description: "The key to look up")
    let key: String
}

/// A data store tool that simulates looking up data.
private struct E2EDataStoreTool: AgentTool {
    typealias Deps = Void
    typealias Args = E2EDataLookupArgs

    let dataStore: [String: String]

    var name: String { "lookup_data" }
    var description: String { "Look up data by key. Available keys: \(dataStore.keys.joined(separator: ", "))" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        if let value = dataStore[arguments.key.lowercased()] {
            return .success(value)
        }
        return .retry(message: "Key '\(arguments.key)' not found. Available keys: \(dataStore.keys.joined(separator: ", "))")
    }
}

/// Arguments for the string manipulation tool.
@Schema(description: "String manipulation arguments")
private struct E2EStringToolArgs {
    @Guide(description: "The input string")
    let text: String
    @Guide(description: "Operation: reverse, uppercase, lowercase, length")
    let operation: String
}

/// A string manipulation tool.
private struct E2EStringTool: AgentTool {
    typealias Deps = Void
    typealias Args = E2EStringToolArgs

    var name: String { "string_tool" }
    var description: String { "Manipulate strings. Operations: reverse, uppercase, lowercase, length" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        switch arguments.operation.lowercased() {
        case "reverse":
            return .success(String(arguments.text.reversed()))
        case "uppercase":
            return .success(arguments.text.uppercased())
        case "lowercase":
            return .success(arguments.text.lowercased())
        case "length":
            return .success("Length: \(arguments.text.count)")
        default:
            return .retry(message: "Unknown operation '\(arguments.operation)'. Use: reverse, uppercase, lowercase, or length.")
        }
    }
}

/// A tool that fails a configurable number of times before succeeding.
/// Useful for testing error recovery.
private actor E2EFlakeyTool: AgentTool {
    typealias Deps = Void

    @Schema(description: "Flakey tool arguments")
    struct Args {
        @Guide(description: "Input value")
        let input: String
    }

    private var callCount = 0
    private let failCount: Int
    private let successResult: String

    nonisolated let name: String = "flakey_service"
    nonisolated let description: String = "A service that sometimes fails. Keep trying if you get an error."
    nonisolated let maxRetries: Int = 5

    init(failCount: Int, successResult: String = "Service completed successfully") {
        self.failCount = failCount
        self.successResult = successResult
    }

    nonisolated func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        await execute(arguments: arguments)
    }

    private func execute(arguments: Args) -> ToolResult<String> {
        callCount += 1
        if callCount <= failCount {
            return .retry(message: "Service temporarily unavailable (attempt \(callCount)/\(failCount + 1)). Please try again.")
        }
        return .success("\(successResult) for input: \(arguments.input)")
    }

    func reset() {
        callCount = 0
    }

    var currentCallCount: Int {
        callCount
    }
}

// MARK: - Output Types (prefixed with E2E to avoid conflicts)

@Schema(description: "Multi-step calculation result")
private struct E2EMultiStepResult: Equatable {
    @Guide(description: "Final computed value")
    let finalValue: Int
    @Guide(description: "Description of steps taken")
    let steps: [String]
}

@Schema(description: "Data analysis result for E2E tests")
private struct E2EDataAnalysisResult: Equatable {
    @Guide(description: "Summary of the analysis")
    let summary: String
    @Guide(description: "Key findings from the data")
    let findings: [String]
}

@Schema(description: "Simple numeric result")
private struct E2ENumericResult: Equatable {
    @Guide(description: "The computed value")
    let value: Int
    @Guide(description: "Explanation of computation")
    let explanation: String
}

// MARK: - End-to-End Test Suite

@Suite("End-to-End Tests", .serialized)
struct EndToEndTests {

    // MARK: - Multi-Turn Reasoning Tests

    @Test(arguments: ProviderFixture.all)
    func multiStepCalculation(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let agent = Agent<Void, E2ENumericResult>(
            model: subject.model,
            systemPrompt: """
            You are a math assistant. When asked to calculate something:
            1. Break the problem into steps
            2. Use the calculator tool for each step
            3. Return the final result using final_result
            Show your work by calling the calculator multiple times if needed.
            """,
            tools: [AnyAgentTool(E2ECalculatorTool())],
            maxIterations: 10,
            outputToolDescription: "Return the numeric result with explanation"
        )

        // Problem requires multiple steps: (10 + 5) * 3 = 45
        let result = try await agent.run(
            "Calculate: first add 10 and 5, then multiply that result by 3. Use the calculator for each step.",
            deps: ()
        )

        #expect(result.output.value == 45, "Expected 45, got \(result.output.value)")
        #expect(result.toolCallCount >= 2, "Should use calculator at least twice, used \(result.toolCallCount) times")
    }

    @Test(arguments: ProviderFixture.all)
    func dataLookupAndProcessing(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let dataStore = E2EDataStoreTool(dataStore: [
            "population_us": "330000000",
            "population_uk": "67000000",
            "population_canada": "38000000"
        ])

        let agent = Agent<Void, E2EDataAnalysisResult>(
            model: subject.model,
            systemPrompt: """
            You are a data analyst. Use the lookup_data tool to retrieve data.
            You must look up data before making calculations or summaries.
            After gathering data, use final_result to provide your analysis.
            """,
            tools: [
                AnyAgentTool(dataStore),
                AnyAgentTool(E2ECalculatorTool())
            ],
            maxIterations: 10,
            outputToolDescription: "Return the analysis summary and key findings"
        )

        let result = try await agent.run(
            "Look up the population of the US and UK, then tell me which is larger and by how much.",
            deps: ()
        )

        #expect(result.toolCallCount >= 2, "Should look up at least 2 values")
        #expect(!result.output.summary.isEmpty, "Should have a summary")
        #expect(!result.output.findings.isEmpty, "Should have findings")
    }

    @Test(arguments: ProviderFixture.all)
    func multiToolChaining(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let agent = Agent<Void, String>(
            model: subject.model,
            systemPrompt: """
            You are a helpful assistant with multiple tools.
            Use the appropriate tool for each operation.
            Chain tool calls as needed to solve problems.
            """,
            tools: [
                AnyAgentTool(E2ECalculatorTool()),
                AnyAgentTool(E2EStringTool())
            ],
            maxIterations: 15
        )

        // Task requires using both tools
        let result = try await agent.run(
            "Take the word 'hello', reverse it, then tell me how many characters that is. Use the string_tool for both operations.",
            deps: ()
        )

        // "hello" reversed is "olleh" which has 5 characters
        #expect(result.toolCallCount >= 2, "Should use string_tool at least twice")
        #expect(result.output.contains("5") || result.output.lowercased().contains("five"),
               "Should mention length is 5")
    }

    // MARK: - Error Recovery Tests

    @Test(arguments: ProviderFixture.all)
    func recoversFromToolError(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        // Tool fails twice, then succeeds
        let flakeyTool = E2EFlakeyTool(failCount: 2, successResult: "Data retrieved")

        let agent = Agent<Void, String>(
            model: subject.model,
            systemPrompt: """
            You are a persistent assistant. If a tool fails, try again.
            The flakey_service may fail a few times before succeeding.
            Keep calling it until you get a successful result.
            """,
            tools: [AnyAgentTool(flakeyTool)],
            maxIterations: 15
        )

        let result = try await agent.run(
            "Call the flakey_service with input 'test'. It may fail - keep trying until it works.",
            deps: ()
        )

        let callCount = await flakeyTool.currentCallCount
        #expect(callCount >= 3, "Should have called tool at least 3 times (2 failures + 1 success), got \(callCount)")
        #expect(result.output.lowercased().contains("success") ||
                result.output.lowercased().contains("retrieved") ||
                result.output.lowercased().contains("completed"),
               "Should report success")
    }

    @Test(arguments: ProviderFixture.all)
    func recoversFromInvalidArguments(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let agent = Agent<Void, String>(
            model: subject.model,
            systemPrompt: """
            You are a calculator assistant. Use the calculator tool.
            If you get an error about the operation, adjust your call.
            Valid operations are: add, subtract, multiply, divide.
            """,
            tools: [AnyAgentTool(E2ECalculatorTool())],
            maxIterations: 12
        )

        // Prompt intentionally uses ambiguous language that might cause LLM to use wrong operation
        let result = try await agent.run(
            "Use the calculator to compute 10 plus 5. Make sure to use the correct operation string.",
            deps: ()
        )

        #expect(result.output.contains("15"), "Should compute 10 + 5 = 15")
    }

    @Test(arguments: ProviderFixture.all)
    func recoversFromDivisionByZero(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let agent = Agent<Void, String>(
            model: subject.model,
            systemPrompt: """
            You are a calculator assistant. If division by zero is attempted,
            the tool will ask you to retry with a non-zero divisor.
            Report back what happened.
            """,
            tools: [AnyAgentTool(E2ECalculatorTool())],
            maxIterations: 12
        )

        let result = try await agent.run(
            "Try to divide 10 by 0. What happens?",
            deps: ()
        )

        // Agent should recognize the error
        #expect(result.output.lowercased().contains("zero") ||
                result.output.lowercased().contains("error") ||
                result.output.lowercased().contains("cannot") ||
                result.output.lowercased().contains("undefined"),
               "Should mention division by zero issue")
    }

    // MARK: - Multi-Turn Conversation Tests

    @Test(arguments: ProviderFixture.all)
    func maintainsContextAcrossTurns(fixture: ProviderFixture) async throws {
        let subject = fixture.subject

        // First turn: establish context
        let response1 = try await subject.model.complete(messages: [
            .system("You are a helpful assistant. Remember details the user tells you."),
            .user("My favorite number is 42. Remember this.")
        ])

        // Second turn: reference previous context
        let response2 = try await subject.model.complete(messages: [
            .system("You are a helpful assistant. Remember details the user tells you."),
            .user("My favorite number is 42. Remember this."),
            .assistant(response1.content ?? "I'll remember that."),
            .user("What is my favorite number?")
        ])

        #expect(response2.content?.contains("42") == true,
               "Should remember favorite number is 42, got: \(response2.content ?? "nil")")
    }

    @Test(arguments: ProviderFixture.all)
    func multiTurnWithToolUse(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let dataStore = E2EDataStoreTool(dataStore: [
            "price_apple": "2",
            "price_banana": "1",
            "price_orange": "3"
        ])

        let agent = Agent<Void, String>(
            model: subject.model,
            systemPrompt: """
            You are a shopping assistant. Use lookup_data to find prices.
            Use calculator to compute totals.
            Available items: apple, banana, orange. Keys are: price_apple, price_banana, price_orange
            """,
            tools: [
                AnyAgentTool(dataStore),
                AnyAgentTool(E2ECalculatorTool())
            ],
            maxIterations: 20
        )

        // Complex request requiring multiple lookups and calculations
        let result = try await agent.run(
            "I want to buy 3 apples and 2 bananas. First look up the price of each item, then calculate the total cost.",
            deps: ()
        )

        // 3 apples * $2 = $6, 2 bananas * $1 = $2, total = $8
        #expect(result.toolCallCount >= 3, "Should use tools multiple times for lookups and calculation")
        #expect(result.output.contains("8") || result.output.lowercased().contains("eight"),
               "Total should be 8")
    }

    // MARK: - Agent Loop Control Tests

    @Test(arguments: ProviderFixture.all)
    func iteratorExposesAllNodes(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let agent = Agent<Void, String>(
            model: subject.model,
            systemPrompt: "You are a calculator. Use the calculator tool to compute results.",
            tools: [AnyAgentTool(E2ECalculatorTool())],
            maxIterations: 10
        )

        var nodeTypes: [String] = []
        var toolCalls: [String] = []

        for try await node in agent.iter("What is 7 + 8? Use the calculator.", deps: ()) {
            switch node {
            case .userPrompt:
                nodeTypes.append("userPrompt")
            case .modelRequest:
                nodeTypes.append("modelRequest")
            case .modelResponse:
                nodeTypes.append("modelResponse")
            case .toolExecution(let calls):
                nodeTypes.append("toolExecution")
                toolCalls.append(contentsOf: calls.map { $0.name })
            case .toolResults:
                nodeTypes.append("toolResults")
            case .end:
                nodeTypes.append("end")
            }
        }

        // Verify node sequence
        #expect(nodeTypes.contains("userPrompt"), "Should have userPrompt node")
        #expect(nodeTypes.contains("modelRequest"), "Should have modelRequest node")
        #expect(nodeTypes.contains("modelResponse"), "Should have modelResponse node")
        #expect(nodeTypes.contains("toolExecution"), "Should have toolExecution node")
        #expect(nodeTypes.contains("end"), "Should have end node")
        #expect(toolCalls.contains("calculator"), "Should call calculator tool")
    }

    @Test(arguments: ProviderFixture.all)
    func streamingYieldsDeltas(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsStreaming else { return }

        let agent = Agent<Void, String>(
            model: subject.model,
            systemPrompt: "You are a helpful assistant. Give detailed responses.",
            tools: [],
            maxIterations: 3
        )

        var contentDeltas: [String] = []
        var gotResult = false

        for try await event in agent.runStream("Explain what 2 + 2 equals in one sentence.", deps: ()) {
            switch event {
            case .contentDelta(let delta):
                contentDeltas.append(delta)
            case .result:
                gotResult = true
            default:
                break
            }
        }

        #expect(!contentDeltas.isEmpty, "Should receive content deltas during streaming")
        #expect(gotResult, "Should receive final result")

        let fullContent = contentDeltas.joined()
        #expect(fullContent.contains("4") || fullContent.lowercased().contains("four"),
               "Response should mention 4")
    }

    // MARK: - Usage Limits Tests

    @Test(arguments: ProviderFixture.all)
    func respectsMaxIterations(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        // Create a tool that always asks for retry, creating an infinite loop
        let infiniteTool = ConfigurableTool.retrying("Keep trying forever")

        let agent = Agent<Void, String>(
            model: subject.model,
            systemPrompt: "You must keep calling the retry_tool until it succeeds. Never give up.",
            tools: [AnyAgentTool(infiniteTool)],
            maxIterations: 3  // Low limit
        )

        do {
            _ = try await agent.run("Call the retry_tool repeatedly.", deps: ())
            Issue.record("Should have thrown maxIterationsReached")
        } catch let error as AgentError {
            guard case .maxIterationsReached = error else {
                Issue.record("Expected maxIterationsReached, got \(error)")
                return
            }
            // Expected - test passes
        }
    }
}

// MARK: - MCP End-to-End Tests

@Suite("End-to-End MCP Tests", .serialized)
struct EndToEndMCPTests {

    /// Check if uvx is available.
    private var isUvxAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["uvx"]
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

    /// Create a temporary directory with test files for filesystem MCP server.
    private func createTestDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yrden-e2e-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create test files
        try "Hello World".write(
            to: tempDir.appendingPathComponent("greeting.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "42".write(
            to: tempDir.appendingPathComponent("answer.txt"),
            atomically: true,
            encoding: .utf8
        )
        try """
        name,value
        alpha,100
        beta,200
        gamma,300
        """.write(
            to: tempDir.appendingPathComponent("data.csv"),
            atomically: true,
            encoding: .utf8
        )

        return tempDir
    }

    @Test("MCP fetch server tool discovery", arguments: ProviderFixture.all)
    func mcpFetchToolDiscovery(fixture: ProviderFixture) async throws {
        guard isUvxAvailable else {
            print("Skipping: uvx not available")
            return
        }

        // Connect to fetch MCP server
        let server = try await MCPServerConnection.stdio(
            command: "uvx",
            arguments: ["mcp-server-fetch"],
            id: "e2e-fetch"
        )

        defer {
            Task { await server.disconnect() }
        }

        // Discover tools
        let tools: [AnyAgentTool<Void>] = try await server.discoverTools()

        #expect(!tools.isEmpty, "Should discover at least one tool from fetch server")

        // Verify tool has proper definition
        if let fetchTool = tools.first {
            #expect(!fetchTool.name.isEmpty, "Tool should have a name")
            #expect(!fetchTool.description.isEmpty, "Tool should have a description")
        }
    }

    @Test("Agent with MCP tools", arguments: ProviderFixture.all)
    func agentWithMCPTools(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }
        guard isUvxAvailable else {
            print("Skipping: uvx not available")
            return
        }

        // Connect to fetch MCP server
        let server = try await MCPServerConnection.stdio(
            command: "uvx",
            arguments: ["mcp-server-fetch"],
            id: "e2e-fetch"
        )

        defer {
            Task { await server.disconnect() }
        }

        // Discover MCP tools
        let mcpTools: [AnyAgentTool<Void>] = try await server.discoverTools()

        // Combine with local tools
        let allTools = [AnyAgentTool(E2ECalculatorTool())] + mcpTools

        let agent = Agent<Void, String>(
            model: subject.model,
            systemPrompt: """
            You are an assistant with access to a calculator and a fetch tool.
            Use the calculator for math operations.
            Use fetch to retrieve web content if needed.
            """,
            tools: allTools,
            maxIterations: 5
        )

        // Use local tool (MCP fetch might be slow or fail on CI)
        let result = try await agent.run(
            "What is 25 + 17? Use the calculator.",
            deps: ()
        )

        #expect(result.output.contains("42"), "Should compute 25 + 17 = 42")
    }

    @Test("Filesystem MCP server integration", arguments: ProviderFixture.all)
    func filesystemMCPIntegration(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }
        guard isNpxAvailable else {
            print("Skipping: npx not available")
            return
        }

        let testDir = try createTestDirectory()
        defer {
            try? FileManager.default.removeItem(at: testDir)
        }

        // Connect to filesystem MCP server
        let server: MCPServerConnection
        do {
            server = try await MCPServerConnection.stdio(
                command: "npx",
                arguments: ["-y", "@modelcontextprotocol/server-filesystem", testDir.path],
                id: "e2e-filesystem"
            )
        } catch {
            print("Skipping: Failed to connect to filesystem MCP server: \(error)")
            return
        }

        defer {
            Task { await server.disconnect() }
        }

        // Discover MCP tools
        let mcpTools: [AnyAgentTool<Void>] = try await server.discoverTools()

        let agent = Agent<Void, String>(
            model: subject.model,
            systemPrompt: """
            You are a file assistant. Use the available tools to read files.
            The allowed directory is: \(testDir.path)
            """,
            tools: mcpTools,
            maxIterations: 8
        )

        // Ask agent to read a file
        let result = try await agent.run(
            "Read the contents of the file named 'greeting.txt' and tell me what it says.",
            deps: ()
        )

        #expect(result.output.lowercased().contains("hello") ||
                result.output.lowercased().contains("world"),
               "Should have read the greeting file content")
    }

    @Test("MCP error recovery", arguments: ProviderFixture.all)
    func mcpErrorRecovery(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }
        guard isNpxAvailable else {
            print("Skipping: npx not available")
            return
        }

        let testDir = try createTestDirectory()
        defer {
            try? FileManager.default.removeItem(at: testDir)
        }

        let server: MCPServerConnection
        do {
            server = try await MCPServerConnection.stdio(
                command: "npx",
                arguments: ["-y", "@modelcontextprotocol/server-filesystem", testDir.path],
                id: "e2e-filesystem"
            )
        } catch {
            print("Skipping: Failed to connect to filesystem MCP server: \(error)")
            return
        }

        defer {
            Task { await server.disconnect() }
        }

        let mcpTools: [AnyAgentTool<Void>] = try await server.discoverTools()

        let agent = Agent<Void, String>(
            model: subject.model,
            systemPrompt: """
            You are a file assistant. If a file doesn't exist, report that clearly.
            Try to read files and report their contents or errors.
            The allowed directory is: \(testDir.path)
            """,
            tools: mcpTools,
            maxIterations: 8
        )

        // Ask for a file that doesn't exist
        let result = try await agent.run(
            "Try to read a file called 'nonexistent.txt'. What happens?",
            deps: ()
        )

        // Agent should handle the error gracefully
        #expect(result.output.lowercased().contains("not found") ||
                result.output.lowercased().contains("doesn't exist") ||
                result.output.lowercased().contains("does not exist") ||
                result.output.lowercased().contains("error") ||
                result.output.lowercased().contains("no such file") ||
                result.output.lowercased().contains("unable"),
               "Should report file not found error")
    }

    @Test("Multi-file MCP operations", arguments: ProviderFixture.all)
    func multiFileMCPOperations(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }
        guard isNpxAvailable else {
            print("Skipping: npx not available")
            return
        }

        let testDir = try createTestDirectory()
        defer {
            try? FileManager.default.removeItem(at: testDir)
        }

        let server: MCPServerConnection
        do {
            server = try await MCPServerConnection.stdio(
                command: "npx",
                arguments: ["-y", "@modelcontextprotocol/server-filesystem", testDir.path],
                id: "e2e-filesystem"
            )
        } catch {
            print("Skipping: Failed to connect to filesystem MCP server: \(error)")
            return
        }

        defer {
            Task { await server.disconnect() }
        }

        let mcpTools: [AnyAgentTool<Void>] = try await server.discoverTools()

        let agent = Agent<Void, String>(
            model: subject.model,
            systemPrompt: """
            You are a file analyst. Read multiple files and analyze their contents.
            The allowed directory is: \(testDir.path)
            """,
            tools: mcpTools,
            maxIterations: 12
        )

        // Ask agent to read multiple files
        let result = try await agent.run(
            "Read both 'greeting.txt' and 'answer.txt' and tell me their contents.",
            deps: ()
        )

        // Should have read both files
        #expect(result.toolCallCount >= 2, "Should read at least 2 files")
        #expect(result.output.lowercased().contains("hello") ||
                result.output.contains("42"),
               "Should report contents of files")
    }

    /// BUG REPRODUCTION TEST: Agent loop should NOT stop when MCP tool returns error.
    ///
    /// This test reproduces a real bug where:
    /// 1. LLM calls `list_allowed_directories` with empty arguments
    /// 2. MCP server returns validation error: "expected object, received undefined"
    /// 3. Agent loop STOPS with DecodingError instead of feeding error back to LLM
    ///
    /// Expected behavior: Agent should pass error back to LLM, let it retry or handle gracefully.
    @Test("Agent recovers from MCP tool validation error", arguments: ProviderFixture.all)
    func agentRecoversFromMCPToolError(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }
        guard isNpxAvailable else {
            print("Skipping: npx not available")
            return
        }

        // Connect to real filesystem MCP server
        let server: MCPServerConnection
        do {
            server = try await MCPServerConnection.stdio(
                command: "npx",
                arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
                id: "e2e-filesystem-error-test"
            )
        } catch {
            print("Skipping: Failed to connect to filesystem MCP server: \(error)")
            return
        }

        defer {
            Task { await server.disconnect() }
        }

        let mcpTools: [AnyAgentTool<Void>] = try await server.discoverTools()

        let agent = Agent<Void, String>(
            model: subject.model,
            systemPrompt: """
            You are a file assistant. You have access to filesystem tools.
            If a tool call fails or returns an error, report what happened.
            Do NOT give up - explain the error to the user.
            """,
            tools: mcpTools,
            maxIterations: 10
        )

        // This prompt triggers `list_allowed_directories` which may fail with empty args.
        // The agent should recover and respond, not crash.
        let result = try await agent.run(
            "What directories can you access? Use the list_allowed_directories tool.",
            deps: ()
        )

        // Agent should have responded (not crashed)
        #expect(!result.output.isEmpty, "Agent should produce output, not crash")
        // The response should mention either the directory or an error/issue
        #expect(
            result.output.lowercased().contains("tmp") ||
            result.output.lowercased().contains("error") ||
            result.output.lowercased().contains("allowed") ||
            result.output.lowercased().contains("directory") ||
            result.output.lowercased().contains("access"),
            "Agent should mention directories or explain the issue"
        )
    }
}

// MARK: - Stress Tests

@Suite("End-to-End Stress Tests", .serialized)
struct EndToEndStressTests {

    @Test("Deep tool call chain", arguments: ProviderFixture.all)
    func deepToolCallChain(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let agent = Agent<Void, E2ENumericResult>(
            model: subject.model,
            systemPrompt: """
            You are a step-by-step calculator.
            For each operation, use the calculator tool.
            Show all your work by making separate tool calls.
            Example: To compute (2+3)*4, first compute 2+3=5, then compute 5*4=20
            """,
            tools: [AnyAgentTool(E2ECalculatorTool())],
            maxIterations: 15,
            outputToolDescription: "Return the final numeric result with explanation"
        )

        // Problem: ((2 + 3) * 4) - 6 = 14
        // Requires at least 3 tool calls
        let result = try await agent.run(
            """
            Calculate step by step: First add 2 and 3. Then multiply the result by 4. \
            Finally subtract 6 from that result. Show each step using the calculator.
            """,
            deps: ()
        )

        #expect(result.output.value == 14, "Expected 14, got \(result.output.value)")
        #expect(result.toolCallCount >= 3, "Should use calculator at least 3 times")
    }

    @Test("Concurrent tool execution", arguments: ProviderFixture.all)
    func concurrentToolExecution(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        // Data store with multiple entries
        let dataStore = E2EDataStoreTool(dataStore: [
            "item_a": "10",
            "item_b": "20",
            "item_c": "30",
            "item_d": "40"
        ])

        let agent = Agent<Void, String>(
            model: subject.model,
            systemPrompt: """
            You are a data retrieval assistant. You can look up multiple items.
            If you need multiple values, you may call lookup_data multiple times.
            Then summarize all the values you found.
            """,
            tools: [AnyAgentTool(dataStore)],
            maxIterations: 10
        )

        let result = try await agent.run(
            "Look up all items: item_a, item_b, item_c, and item_d. Tell me their values.",
            deps: ()
        )

        // Should have found all 4 values
        #expect(result.toolCallCount >= 4, "Should look up at least 4 items")
        #expect(result.output.contains("10"), "Should find item_a value")
        #expect(result.output.contains("20"), "Should find item_b value")
        #expect(result.output.contains("30"), "Should find item_c value")
        #expect(result.output.contains("40"), "Should find item_d value")
    }
}
