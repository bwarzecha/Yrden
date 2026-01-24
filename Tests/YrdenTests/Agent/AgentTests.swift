/// Tests for Agent functionality.

import Testing
import Foundation
@testable import Yrden

// MARK: - Test Tool

struct CalculatorTool: AgentTool {
    typealias Deps = Void

    @Schema(description: "Calculator arguments")
    struct Args {
        @Guide(description: "Mathematical expression")
        let expression: String
    }

    var name: String { "calculator" }
    var description: String { "Evaluate a mathematical expression and return the result" }

    func call(
        context: AgentContext<Void>,
        arguments: Args
    ) async throws -> ToolResult<String> {
        // Simple evaluation (just for testing)
        let expr = arguments.expression
        if expr.contains("+") {
            let parts = expr.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2,
               let a = Int(parts[0]),
               let b = Int(parts[1]) {
                return .success(String(a + b))
            }
        }
        if expr.contains("*") {
            let parts = expr.split(separator: "*").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2,
               let a = Int(parts[0]),
               let b = Int(parts[1]) {
                return .success(String(a * b))
            }
        }
        return .retry(message: "Could not evaluate expression: \(expr). Please use simple format like '2 + 3'")
    }
}

// MARK: - Output Types

@Schema(description: "Math result")
struct MathResult: Equatable {
    let expression: String
    let result: Int
}

// MARK: - Tests

@Suite("Agent - Core Functionality")
struct AgentCoreTests {

    @Test("Agent types compile and initialize correctly")
    func agentTypesCompile() throws {
        // Verify AgentContext can be created
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        let context = AgentContext<Void>(
            model: model,
            usage: Usage(inputTokens: 0, outputTokens: 0),
            retries: 0,
            runStep: 0
        )

        #expect(context.retries == 0)
        #expect(context.runStep == 0)
        #expect(!context.runID.isEmpty)
    }

    @Test("AnyAgentTool wraps tool correctly")
    func anyToolWrapping() throws {
        let tool = AnyAgentTool(CalculatorTool())

        #expect(tool.name == "calculator")
        #expect(tool.description.contains("mathematical"))
        #expect(tool.maxRetries == 1)

        // Verify definition is generated
        let def = tool.definition
        #expect(def.name == "calculator")
    }

    @Test("Agent initializes with tools")
    func agentInitialization() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        let agent = Agent<Void, MathResult>(
            model: model,
            systemPrompt: "You are a math assistant.",
            tools: [AnyAgentTool(CalculatorTool())],
            maxIterations: 5
        )

        // Verify agent is created (can't test run without API call)
        let maxIter = await agent.maxIterations
        #expect(maxIter == 5)
    }
}

@Suite("Agent - Integration", .serialized)
struct AgentIntegrationTests {

    @Test("Agent runs with tool and produces structured output")
    func agentWithToolAndStructuredOutput() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        let agent = Agent<Void, MathResult>(
            model: model,
            systemPrompt: """
            You are a math assistant. When asked to calculate something:
            1. Use the calculator tool to compute the result
            2. Then use the final_result tool to return the answer
            """,
            tools: [AnyAgentTool(CalculatorTool())],
            maxIterations: 5,
            outputToolDescription: "Return the math result"
        )

        let result = try await agent.run(
            "What is 5 + 3? Use the calculator tool first, then return the result.",
            deps: ()
        )

        #expect(result.output.expression.contains("5") || result.output.expression.contains("8"))
        #expect(result.output.result == 8)
        #expect(result.requestCount >= 1)
        #expect(result.toolCallCount >= 1)
    }

    @Test("Agent handles simple text output for String type")
    func agentWithStringOutput() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        // String output uses text response directly
        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are a helpful assistant. Respond briefly.",
            tools: [],
            maxIterations: 3
        )

        let result = try await agent.run(
            "Say 'Hello World' and nothing else.",
            deps: ()
        )

        #expect(result.output.lowercased().contains("hello"))
        #expect(result.requestCount == 1)
    }

    @Test("Agent streams content deltas for String output")
    func agentStreamingStringOutput() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are a helpful assistant. Respond briefly.",
            tools: [],
            maxIterations: 3
        )

        var contentDeltas: [String] = []
        var usageEvents: [Usage] = []
        var finalResult: AgentResult<String>?

        for try await event in agent.runStream("Say 'Hello World' and nothing else.", deps: ()) {
            switch event {
            case .contentDelta(let delta):
                contentDeltas.append(delta)
            case .usage(let usage):
                usageEvents.append(usage)
            case .result(let result):
                finalResult = result
            default:
                break
            }
        }

        // Should have received content deltas
        #expect(!contentDeltas.isEmpty)

        // Accumulated content should match final result
        let accumulatedContent = contentDeltas.joined()
        #expect(accumulatedContent.lowercased().contains("hello"))

        // Should have received usage event
        #expect(!usageEvents.isEmpty)

        // Should have final result
        #expect(finalResult != nil)
        #expect(finalResult!.output.lowercased().contains("hello"))
    }

    @Test("Agent streams tool events during execution")
    func agentStreamingWithTools() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        let agent = Agent<Void, MathResult>(
            model: model,
            systemPrompt: """
            You are a math assistant. When asked to calculate something:
            1. Use the calculator tool to compute the result
            2. Then use the final_result tool to return the answer
            """,
            tools: [AnyAgentTool(CalculatorTool())],
            maxIterations: 5,
            outputToolDescription: "Return the math result"
        )

        var toolCallStarts: [(name: String, id: String)] = []
        var toolResults: [(id: String, result: String)] = []
        var finalResult: AgentResult<MathResult>?

        for try await event in agent.runStream(
            "What is 5 + 3? Use the calculator tool first, then return the result.",
            deps: ()
        ) {
            switch event {
            case .toolCallStart(let name, let id):
                toolCallStarts.append((name: name, id: id))
            case .toolResult(let id, let result):
                toolResults.append((id: id, result: result))
            case .result(let result):
                finalResult = result
            default:
                break
            }
        }

        // Should have received tool call starts (calculator and/or final_result)
        #expect(!toolCallStarts.isEmpty)

        // Should have received tool results
        #expect(!toolResults.isEmpty)

        // Should have final result
        #expect(finalResult != nil)
        #expect(finalResult!.output.result == 8)
    }

    @Test("Agent.iter() yields nodes for each execution step")
    func agentIterationBasic() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are a helpful assistant. Respond briefly.",
            tools: [],
            maxIterations: 3
        )

        var nodes: [String] = []  // Track node types
        var finalResult: AgentResult<String>?

        for try await node in agent.iter("Say 'Hello' and nothing else.", deps: ()) {
            switch node {
            case .userPrompt:
                nodes.append("userPrompt")
            case .modelRequest:
                nodes.append("modelRequest")
            case .modelResponse:
                nodes.append("modelResponse")
            case .toolExecution:
                nodes.append("toolExecution")
            case .toolResults:
                nodes.append("toolResults")
            case .end(let result):
                nodes.append("end")
                finalResult = result
            }
        }

        // Should have proper node sequence
        #expect(nodes.contains("userPrompt"))
        #expect(nodes.contains("modelRequest"))
        #expect(nodes.contains("modelResponse"))
        #expect(nodes.contains("end"))

        // Should have final result
        #expect(finalResult != nil)
        #expect(finalResult!.output.lowercased().contains("hello"))
    }

    @Test("Agent.iter() yields tool execution nodes")
    func agentIterationWithTools() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        let agent = Agent<Void, MathResult>(
            model: model,
            systemPrompt: """
            You are a math assistant. When asked to calculate something:
            1. Use the calculator tool to compute the result
            2. Then use the final_result tool to return the answer
            """,
            tools: [AnyAgentTool(CalculatorTool())],
            maxIterations: 5,
            outputToolDescription: "Return the math result"
        )

        var toolExecutionCalls: [[ToolCall]] = []
        var toolResultsReceived: [[ToolCallResult]] = []
        var finalResult: AgentResult<MathResult>?

        for try await node in agent.iter(
            "What is 5 + 3? Use the calculator tool first, then return the result.",
            deps: ()
        ) {
            switch node {
            case .toolExecution(let calls):
                toolExecutionCalls.append(calls)
            case .toolResults(let results):
                toolResultsReceived.append(results)
            case .end(let result):
                finalResult = result
            default:
                break
            }
        }

        // Should have executed tools
        #expect(!toolExecutionCalls.isEmpty)

        // Should have received tool results
        #expect(!toolResultsReceived.isEmpty)

        // Should have final result
        #expect(finalResult != nil)
        #expect(finalResult!.output.result == 8)
    }
}

// MARK: - Output Validator Types

@Schema(description: "Report with sections")
struct Report {
    let title: String
    let sections: [String]
}

// MARK: - Output Validator Tests

@Suite("Agent - Output Validators", .serialized)
struct AgentOutputValidatorTests {

    @Test("Output validator can transform output")
    func outputValidatorTransform() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        // Validator that uppercases the output
        let uppercaseValidator = OutputValidator<Void, String> { _, output in
            return output.uppercased()
        }

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are a helpful assistant. Respond with exactly one word.",
            tools: [],
            outputValidators: [uppercaseValidator],
            maxIterations: 3
        )

        let result = try await agent.run("Say 'hello' and nothing else.", deps: ())

        // Output should be uppercased by validator
        #expect(result.output == result.output.uppercased())
        #expect(result.output.contains("HELLO"))
    }

    @Test("Output validator can request retry with feedback")
    func outputValidatorRetry() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        // Validator that requires at least 2 sections
        let sectionValidator = OutputValidator<Void, Report> { _, report in
            if report.sections.count < 2 {
                throw ValidationRetry("Report must have at least 2 sections. Please add more content.")
            }
            return report
        }

        let agent = Agent<Void, Report>(
            model: model,
            systemPrompt: """
            You are a report writer. When asked to write a report:
            1. Use the final_result tool to submit your report
            2. The report must have a title and multiple sections
            3. If validation fails, read the feedback and try again with more sections
            """,
            tools: [],
            outputValidators: [sectionValidator],
            maxIterations: 5,
            outputToolName: "submit_report",
            outputToolDescription: "Submit the completed report"
        )

        let result = try await agent.run(
            "Write a brief report about Swift programming with at least 2 sections.",
            deps: ()
        )

        // Should have gotten a valid result with required sections
        #expect(result.output.sections.count >= 2)
        #expect(!result.output.title.isEmpty)
    }
}
