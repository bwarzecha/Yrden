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
}
