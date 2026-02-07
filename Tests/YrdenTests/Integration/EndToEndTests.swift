/// End-to-End Tests for Yrden Agent System.
///
/// These tests exercise the complete agent system with real LLMs:
/// - Full agent loops with multiple tool calls
/// - Multi-turn conversations
/// - Error recovery and retry handling
/// - Cross-provider compatibility
///
/// Run with: swift test --filter EndToEnd
///
/// Prerequisites:
/// - ANTHROPIC_API_KEY and/or OPENAI_API_KEY environment variables

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

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
private struct E2ECalculatorTool: TypedTool {
    typealias Args = E2ECalculatorArgs

    var name: String { "calculator" }
    var description: String { "Perform arithmetic operations. Use operation: add, subtract, multiply, divide" }

    func execute(context: ToolContext, arguments: Args) async throws -> ToolResult<String> {
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
                return .failure(ToolExecutionError.custom("Cannot divide by zero. Please use a non-zero divisor."))
            }
            result = arguments.a / arguments.b
        default:
            return .failure(ToolExecutionError.custom("Unknown operation '\(arguments.operation)'. Use: add, subtract, multiply, or divide."))
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
private struct E2EDataStoreTool: TypedTool {
    typealias Args = E2EDataLookupArgs

    let dataStore: [String: String]

    var name: String { "lookup_data" }
    var description: String { "Look up data by key. Available keys: \(dataStore.keys.joined(separator: ", "))" }

    func execute(context: ToolContext, arguments: Args) async throws -> ToolResult<String> {
        if let value = dataStore[arguments.key.lowercased()] {
            return .success(value)
        }
        return .failure(ToolExecutionError.custom("Key '\(arguments.key)' not found. Available keys: \(dataStore.keys.joined(separator: ", "))"))
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
private struct E2EStringTool: TypedTool {
    typealias Args = E2EStringToolArgs

    var name: String { "string_tool" }
    var description: String { "Manipulate strings. Operations: reverse, uppercase, lowercase, length" }

    func execute(context: ToolContext, arguments: Args) async throws -> ToolResult<String> {
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
            return .failure(ToolExecutionError.custom("Unknown operation '\(arguments.operation)'. Use: reverse, uppercase, lowercase, or length."))
        }
    }
}

/// Arguments for the flakey tool.
@Schema(description: "Flakey tool arguments")
private struct E2EFlakeyToolArgs {
    @Guide(description: "Input value")
    let input: String
}

/// A tool that fails a configurable number of times before succeeding.
/// Useful for testing error recovery.
private actor E2EFlakeyTool: Tool {
    private var callCount = 0
    private let failCount: Int
    private let successResult: String

    nonisolated let name: String = "flakey_service"
    nonisolated let description: String = "A service that sometimes fails. Keep trying if you get an error."

    nonisolated var definition: ToolDefinition {
        ToolDefinition(name: name, description: description, inputSchema: E2EFlakeyToolArgs.jsonSchema)
    }

    nonisolated var requiresApproval: Bool { false }

    init(failCount: Int, successResult: String = "Service completed successfully") {
        self.failCount = failCount
        self.successResult = successResult
    }

    nonisolated func call(context: ToolContext, argumentsJSON: String) async throws -> AnyToolResult {
        guard let data = argumentsJSON.data(using: .utf8) else {
            throw ToolExecutionError.argumentParsing("Invalid UTF-8 in arguments")
        }
        let args = try JSONDecoder().decode(E2EFlakeyToolArgs.self, from: data)
        let result = await execute(arguments: args)
        return result.erased()
    }

    private func execute(arguments: E2EFlakeyToolArgs) -> ToolResult<String> {
        callCount += 1
        if callCount <= failCount {
            return .failure(ToolExecutionError.custom("Service temporarily unavailable (attempt \(callCount)/\(failCount + 1)). Please try again."))
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

        let agent = try Agent<E2ENumericResult>(
            model: subject.model,
            systemPrompt: """
            You are a math assistant. When asked to calculate something:
            1. Break the problem into steps
            2. Use the calculator tool for each step
            3. Return the final result using final_result
            Show your work by calling the calculator multiple times if needed.
            """,
            tools: [E2ECalculatorTool()],
            maxIterations: 10
        )

        // Problem requires multiple steps: (10 + 5) * 3 = 45
        let run = try await agent.run(
            "Calculate: first add 10 and 5, then multiply that result by 3. Use the calculator for each step."
        )

        let output = try run.result()
        #expect(output.value == 45, "Expected 45, got \(output.value)")
        #expect(run.toolCallCount >= 2, "Should use calculator at least twice, used \(run.toolCallCount) times")
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

        let agent = try Agent<E2EDataAnalysisResult>(
            model: subject.model,
            systemPrompt: """
            You are a data analyst. Use the lookup_data tool to retrieve data.
            You must look up data before making calculations or summaries.
            After gathering data, use final_result to provide your analysis.
            """,
            tools: [dataStore, E2ECalculatorTool()],
            maxIterations: 10
        )

        let run = try await agent.run(
            "Look up the population of the US and UK, then tell me which is larger and by how much."
        )

        let output = try run.result()
        #expect(run.toolCallCount >= 2, "Should look up at least 2 values")
        #expect(!output.summary.isEmpty, "Should have a summary")
        #expect(!output.findings.isEmpty, "Should have findings")
    }

    @Test(arguments: ProviderFixture.all)
    func multiToolChaining(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let agent = try Agent<String>(
            model: subject.model,
            systemPrompt: """
            You are a helpful assistant with multiple tools.
            Use the appropriate tool for each operation.
            Chain tool calls as needed to solve problems.
            """,
            tools: [E2ECalculatorTool(), E2EStringTool()],
            maxIterations: 15
        )

        // Task requires using both tools
        let run = try await agent.run(
            "Take the word 'hello', reverse it, then tell me how many characters that is. Use the string_tool for both operations."
        )

        let output = try run.result()
        // "hello" reversed is "olleh" which has 5 characters
        #expect(run.toolCallCount >= 2, "Should use string_tool at least twice")
        #expect(output.contains("5") || output.lowercased().contains("five"),
               "Should mention length is 5")
    }

    // MARK: - Error Recovery Tests

    @Test(arguments: ProviderFixture.all)
    func recoversFromToolError(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        // Tool fails twice, then succeeds
        let flakeyTool = E2EFlakeyTool(failCount: 2, successResult: "Data retrieved")

        let agent = try Agent<String>(
            model: subject.model,
            systemPrompt: """
            You are a persistent assistant. If a tool fails, try again.
            The flakey_service may fail a few times before succeeding.
            Keep calling it until you get a successful result.
            """,
            tools: [flakeyTool],
            maxIterations: 15
        )

        let run = try await agent.run(
            "Call the flakey_service with input 'test'. It may fail - keep trying until it works."
        )

        let output = try run.result()
        let callCount = await flakeyTool.currentCallCount
        #expect(callCount >= 3, "Should have called tool at least 3 times (2 failures + 1 success), got \(callCount)")
        #expect(output.lowercased().contains("success") ||
                output.lowercased().contains("retrieved") ||
                output.lowercased().contains("completed"),
               "Should report success")
    }

    @Test(arguments: ProviderFixture.all)
    func recoversFromInvalidArguments(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let agent = try Agent<String>(
            model: subject.model,
            systemPrompt: """
            You are a calculator assistant. Use the calculator tool.
            If you get an error about the operation, adjust your call.
            Valid operations are: add, subtract, multiply, divide.
            """,
            tools: [E2ECalculatorTool()],
            maxIterations: 12
        )

        // Prompt intentionally uses ambiguous language that might cause LLM to use wrong operation
        let run = try await agent.run(
            "Use the calculator to compute 10 plus 5. Make sure to use the correct operation string."
        )

        let output = try run.result()
        #expect(output.contains("15"), "Should compute 10 + 5 = 15")
    }

    @Test(arguments: ProviderFixture.all)
    func recoversFromDivisionByZero(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let agent = try Agent<String>(
            model: subject.model,
            systemPrompt: """
            You are a calculator assistant. If division by zero is attempted,
            the tool will return an error. Report back what happened.
            """,
            tools: [E2ECalculatorTool()],
            maxIterations: 12
        )

        let run = try await agent.run(
            "Try to divide 10 by 0. What happens?"
        )

        let output = try run.result()
        // Agent should recognize the error
        #expect(output.lowercased().contains("zero") ||
                output.lowercased().contains("error") ||
                output.lowercased().contains("cannot") ||
                output.lowercased().contains("undefined"),
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

        let agent = try Agent<String>(
            model: subject.model,
            systemPrompt: """
            You are a shopping assistant. Use lookup_data to find prices.
            Use calculator to compute totals.
            Available items: apple, banana, orange. Keys are: price_apple, price_banana, price_orange
            """,
            tools: [dataStore, E2ECalculatorTool()],
            maxIterations: 20
        )

        // Complex request requiring multiple lookups and calculations
        let run = try await agent.run(
            "I want to buy 3 apples and 2 bananas. First look up the price of each item, then calculate the total cost."
        )

        let output = try run.result()
        // 3 apples * $2 = $6, 2 bananas * $1 = $2, total = $8
        #expect(run.toolCallCount >= 3, "Should use tools multiple times for lookups and calculation")
        #expect(output.contains("8") || output.lowercased().contains("eight"),
               "Total should be 8")
    }

    // MARK: - Agent Loop Control Tests

    @Test(arguments: ProviderFixture.all)
    func iteratorExposesAllNodes(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let agent = try Agent<String>(
            model: subject.model,
            systemPrompt: "You are a calculator. Use the calculator tool to compute results.",
            tools: [E2ECalculatorTool()],
            maxIterations: 10
        )

        var nodeTypes: [String] = []

        for try await node in agent.iter("What is 7 + 8? Use the calculator.") {
            switch node {
            case .beforeModel:
                nodeTypes.append("beforeModel")
            case .afterModel:
                nodeTypes.append("afterModel")
            case .beforeTools(let ctx):
                nodeTypes.append("beforeTools")
                for pending in ctx.pendingCalls {
                    ctx.approve(pending.call)
                }
            case .afterTools:
                nodeTypes.append("afterTools")
            case .finished:
                nodeTypes.append("finished")
            }
        }

        // Verify node sequence
        #expect(nodeTypes.contains("beforeModel"), "Should have beforeModel node")
        #expect(nodeTypes.contains("afterModel"), "Should have afterModel node")
        #expect(nodeTypes.contains("beforeTools"), "Should have beforeTools node")
        #expect(nodeTypes.contains("afterTools"), "Should have afterTools node")
        #expect(nodeTypes.contains("finished"), "Should have finished node")
    }

    @Test(arguments: ProviderFixture.all)
    func streamingYieldsDeltas(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsStreaming else { return }

        let agent = try Agent<String>(
            model: subject.model,
            systemPrompt: "You are a helpful assistant. Give detailed responses.",
            tools: [],
            maxIterations: 3
        )

        var contentDeltas: [String] = []
        var gotFinished = false

        for try await event in agent.runStream("Explain what 2 + 2 equals in one sentence.") {
            switch event {
            case .contentDelta(let delta, _):
                contentDeltas.append(delta)
            case .finished:
                gotFinished = true
            default:
                break
            }
        }

        #expect(!contentDeltas.isEmpty, "Should receive content deltas during streaming")
        #expect(gotFinished, "Should receive finished event")

        let fullContent = contentDeltas.joined()
        #expect(fullContent.contains("4") || fullContent.lowercased().contains("four"),
               "Response should mention 4")
    }

    // MARK: - Usage Limits Tests

    @Test(arguments: ProviderFixture.all)
    func respectsMaxIterations(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        // Create a tool that always fails, creating an infinite loop
        let infiniteTool = ConfigurableTool.failing(
            TestToolError.generic("Keep trying forever"),
            name: "retry_tool"
        )

        let agent = try Agent<String>(
            model: subject.model,
            systemPrompt: "You must keep calling the retry_tool until it succeeds. Never give up.",
            tools: [infiniteTool],
            maxIterations: 3
        )

        let run = try await agent.run("Call the retry_tool repeatedly.")

        if case .iterationLimitReached = run.status {
            // Expected — test passes
        } else if case .completed = run.status {
            // Some models may give up and produce text output before hitting the limit
            // This is acceptable behavior
        } else {
            Issue.record("Expected iterationLimitReached or completed, got \(run.status)")
        }
    }
}

// MARK: - Stress Tests

@Suite("End-to-End Stress Tests", .serialized)
struct EndToEndStressTests {

    @Test("Deep tool call chain", arguments: ProviderFixture.all)
    func deepToolCallChain(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let agent = try Agent<E2ENumericResult>(
            model: subject.model,
            systemPrompt: """
            You are a step-by-step calculator.
            For each operation, use the calculator tool.
            Show all your work by making separate tool calls.
            Example: To compute (2+3)*4, first compute 2+3=5, then compute 5*4=20
            """,
            tools: [E2ECalculatorTool()],
            maxIterations: 15
        )

        // Problem: ((2 + 3) * 4) - 6 = 14
        // Requires at least 3 tool calls
        let run = try await agent.run(
            """
            Calculate step by step: First add 2 and 3. Then multiply the result by 4. \
            Finally subtract 6 from that result. Show each step using the calculator.
            """
        )

        let output = try run.result()
        #expect(output.value == 14, "Expected 14, got \(output.value)")
        #expect(run.toolCallCount >= 3, "Should use calculator at least 3 times")
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

        let agent = try Agent<String>(
            model: subject.model,
            systemPrompt: """
            You are a data retrieval assistant. You can look up multiple items.
            If you need multiple values, you may call lookup_data multiple times.
            Then summarize all the values you found.
            """,
            tools: [dataStore],
            maxIterations: 10
        )

        let run = try await agent.run(
            "Look up all items: item_a, item_b, item_c, and item_d. Tell me their values."
        )

        let output = try run.result()
        // Should have found all 4 values
        #expect(run.toolCallCount >= 4, "Should look up at least 4 items")
        #expect(output.contains("10"), "Should find item_a value")
        #expect(output.contains("20"), "Should find item_b value")
        #expect(output.contains("30"), "Should find item_c value")
        #expect(output.contains("40"), "Should find item_d value")
    }
}
