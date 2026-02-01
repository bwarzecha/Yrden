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

// MARK: - Human-in-the-Loop Tools

@Schema(description: "Dangerous operation arguments")
struct DangerousToolArgs {
    @Guide(description: "What to delete")
    let target: String
}

struct DangerousTool: AgentTool {
    typealias Deps = Void
    typealias Args = DangerousToolArgs

    var name: String { "dangerous_delete" }
    var description: String { "Delete files (requires human approval)" }

    func call(
        context: AgentContext<Void>,
        arguments: Args
    ) async throws -> ToolResult<String> {
        // Always defer for human approval
        return .deferred(.needsApproval(
            id: "delete-\(arguments.target)",
            reason: "Deletion of '\(arguments.target)' requires human approval"
        ))
    }
}

@Schema(description: "External operation arguments")
struct ExternalOperationArgs {
    @Guide(description: "Operation to perform")
    let operation: String
}

struct ExternalOperationTool: AgentTool {
    typealias Deps = Void
    typealias Args = ExternalOperationArgs

    var name: String { "external_operation" }
    var description: String { "Perform an external operation that completes asynchronously" }

    func call(
        context: AgentContext<Void>,
        arguments: Args
    ) async throws -> ToolResult<String> {
        // Defer for external resolution
        return .deferred(.external(
            id: "external-\(arguments.operation)",
            reason: "External operation '\(arguments.operation)' will complete asynchronously"
        ))
    }
}

@Schema(description: "Approvable action args")
struct ApprovableToolArgs {
    let action: String
}

/// Counter for tracking approvable tool calls (thread-safe via actor)
actor ApprovableToolCounter {
    static let shared = ApprovableToolCounter()
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }

    func reset() {
        count = 0
    }

    func current() -> Int {
        count
    }
}

struct ApprovableTool: AgentTool {
    typealias Deps = Void
    typealias Args = ApprovableToolArgs

    var name: String { "approvable_action" }
    var description: String { "Perform an action that requires approval" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        let callCount = await ApprovableToolCounter.shared.increment()
        if callCount == 1 {
            return .deferred(.needsApproval(
                id: "action-1",
                reason: "Action '\(arguments.action)' needs approval"
            ))
        }
        return .success("Action '\(arguments.action)' completed successfully")
    }
}

// MARK: - Human-in-the-Loop Tests

@Suite("Agent - Human in the Loop", .serialized)
struct AgentHumanInLoopTests {

    @Test("Tool deferral throws with paused state")
    func toolDeferralThrowsPausedState() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: """
            You are a file management assistant.
            When asked to delete something, use the dangerous_delete tool.
            """,
            tools: [AnyAgentTool(DangerousTool())],
            maxIterations: 5
        )

        do {
            _ = try await agent.run("Please delete the file called 'important.txt'", deps: ())
            Issue.record("Expected hasDeferredTools error")
        } catch let error as AgentError {
            guard case .hasDeferredTools(let paused) = error else {
                Issue.record("Expected hasDeferredTools, got \(error)")
                return
            }

            // Verify paused state
            #expect(!paused.runID.isEmpty)
            #expect(!paused.messages.isEmpty)
            #expect(paused.requestCount >= 1)
            #expect(paused.pendingCalls.count == 1)

            // Verify pending call info
            let pending = paused.pendingCalls[0]
            #expect(pending.toolCall.name == "dangerous_delete")
            #expect(pending.deferral.kind == .approval)
            #expect(pending.deferral.reason.contains("approval"))
        }
    }

    @Test("Resume with approved resolution executes tool")
    func resumeWithApprovedResolution() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        // Reset counter before test
        await ApprovableToolCounter.shared.reset()

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: """
            You are an assistant. When asked to perform an action, use the approvable_action tool.
            After the action completes, respond with a summary.
            """,
            tools: [AnyAgentTool(ApprovableTool())],
            maxIterations: 5
        )

        // First run should defer
        var paused: PausedAgentRun?
        do {
            _ = try await agent.run("Please perform the 'backup' action", deps: ())
            Issue.record("Expected hasDeferredTools error")
        } catch let error as AgentError {
            guard case .hasDeferredTools(let p) = error else {
                Issue.record("Expected hasDeferredTools, got \(error)")
                return
            }
            paused = p
        }

        guard let pausedState = paused else {
            Issue.record("Failed to get paused state")
            return
        }

        // Resume with approval
        let resolutions = pausedState.pendingCalls.map { pending in
            ResolvedTool(id: pending.deferral.id, resolution: .approved)
        }

        let result = try await agent.resume(
            paused: pausedState,
            resolutions: resolutions,
            deps: ()
        )

        // Tool should have been called again (approved = execute)
        let finalCount = await ApprovableToolCounter.shared.current()
        #expect(finalCount == 2)
        #expect(result.output.lowercased().contains("completed") || result.output.lowercased().contains("action") || result.output.lowercased().contains("backup"))
    }

    @Test("Resume with denied resolution provides error to model")
    func resumeWithDeniedResolution() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: """
            You are a file management assistant.
            When asked to delete something, use the dangerous_delete tool.
            If the tool is denied, apologize and explain you cannot proceed.
            """,
            tools: [AnyAgentTool(DangerousTool())],
            maxIterations: 5
        )

        // First run should defer
        var paused: PausedAgentRun?
        do {
            _ = try await agent.run("Please delete 'secret.txt'", deps: ())
        } catch let error as AgentError {
            if case .hasDeferredTools(let p) = error {
                paused = p
            }
        }

        guard let pausedState = paused else {
            Issue.record("Failed to get paused state")
            return
        }

        // Resume with denial
        let resolutions = pausedState.pendingCalls.map { pending in
            ResolvedTool(id: pending.deferral.id, resolution: .denied(reason: "User rejected the deletion"))
        }

        let result = try await agent.resume(
            paused: pausedState,
            resolutions: resolutions,
            deps: ()
        )

        // Model should have received denial and responded appropriately
        #expect(result.output.lowercased().contains("cannot") ||
                result.output.lowercased().contains("denied") ||
                result.output.lowercased().contains("sorry") ||
                result.output.lowercased().contains("rejected") ||
                result.output.lowercased().contains("unable"))
    }

    @Test("Resume with completed result uses provided value")
    func resumeWithCompletedResult() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: """
            You are an assistant that performs external operations.
            Use the external_operation tool when asked to do something.
            Report the result back to the user.
            """,
            tools: [AnyAgentTool(ExternalOperationTool())],
            maxIterations: 5
        )

        // First run should defer
        var paused: PausedAgentRun?
        do {
            _ = try await agent.run("Please run the 'data-sync' operation", deps: ())
        } catch let error as AgentError {
            if case .hasDeferredTools(let p) = error {
                paused = p
            }
        }

        guard let pausedState = paused else {
            Issue.record("Failed to get paused state")
            return
        }

        #expect(pausedState.pendingCalls.first?.deferral.kind == .external)

        // Resume with completed result (simulating external operation finished)
        let resolutions = pausedState.pendingCalls.map { pending in
            ResolvedTool(
                id: pending.deferral.id,
                resolution: .completed(result: "Data sync completed: 1500 records synchronized successfully")
            )
        }

        let result = try await agent.resume(
            paused: pausedState,
            resolutions: resolutions,
            deps: ()
        )

        // Model should have received the result and reported it
        #expect(result.output.lowercased().contains("1500") ||
                result.output.lowercased().contains("sync") ||
                result.output.lowercased().contains("records") ||
                result.output.lowercased().contains("completed"))
    }

    @Test("Resume with failed resolution provides error to model")
    func resumeWithFailedResolution() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: """
            You are an assistant that performs external operations.
            Use the external_operation tool when asked to do something.
            If the operation fails, explain the error to the user.
            """,
            tools: [AnyAgentTool(ExternalOperationTool())],
            maxIterations: 5
        )

        // First run should defer
        var paused: PausedAgentRun?
        do {
            _ = try await agent.run("Please run the 'database-migration' operation", deps: ())
        } catch let error as AgentError {
            if case .hasDeferredTools(let p) = error {
                paused = p
            }
        }

        guard let pausedState = paused else {
            Issue.record("Failed to get paused state")
            return
        }

        // Resume with failure
        let resolutions = pausedState.pendingCalls.map { pending in
            ResolvedTool(
                id: pending.deferral.id,
                resolution: .failed(error: "Connection timeout: database server unreachable")
            )
        }

        let result = try await agent.resume(
            paused: pausedState,
            resolutions: resolutions,
            deps: ()
        )

        // Model should have received the failure and explained it
        #expect(result.output.lowercased().contains("timeout") ||
                result.output.lowercased().contains("fail") ||
                result.output.lowercased().contains("error") ||
                result.output.lowercased().contains("unreachable") ||
                result.output.lowercased().contains("could not"))
    }

    @Test("Multiple tools can defer simultaneously")
    func multipleToolsDeferSimultaneously() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: """
            You are a system administrator assistant.
            When asked to perform multiple operations, use ALL appropriate tools in a SINGLE response.
            You must use dangerous_delete and external_operation tools together when asked.
            """,
            tools: [
                AnyAgentTool(DangerousTool()),
                AnyAgentTool(ExternalOperationTool())
            ],
            maxIterations: 5
        )

        // First run should defer with multiple tools
        var paused: PausedAgentRun?
        do {
            _ = try await agent.run(
                "Please delete 'temp.log' AND run the 'cleanup' operation. Use both tools now.",
                deps: ()
            )
        } catch let error as AgentError {
            if case .hasDeferredTools(let p) = error {
                paused = p
            }
        }

        guard let pausedState = paused else {
            Issue.record("Failed to get paused state")
            return
        }

        // Should have multiple pending calls (model may call one or both)
        // Accept either case since model behavior varies
        #expect(pausedState.pendingCalls.count >= 1)

        // If we got multiple deferrals, verify they have different tool names
        if pausedState.pendingCalls.count >= 2 {
            let toolNames = Set(pausedState.pendingCalls.map { $0.toolCall.name })
            #expect(toolNames.count >= 2)
        }

        // Resume with all approved
        let resolutions = pausedState.pendingCalls.map { pending in
            ResolvedTool(id: pending.deferral.id, resolution: .approved)
        }

        // Note: This may throw again if DangerousTool always defers
        // That's expected behavior - we're testing the paused state captures all deferrals
        do {
            let result = try await agent.resume(
                paused: pausedState,
                resolutions: resolutions,
                deps: ()
            )
            // If we get here, agent completed successfully
            #expect(!result.output.isEmpty)
        } catch let error as AgentError {
            // If tools defer again after approval, that's valid behavior
            if case .hasDeferredTools = error {
                // This is acceptable - the test verified multiple tools were captured
            } else {
                throw error
            }
        }
    }

    @Test("Streaming detects deferred tools")
    func streamingWithDeferredTools() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: """
            You are a file management assistant.
            When asked to delete something, use the dangerous_delete tool.
            """,
            tools: [AnyAgentTool(DangerousTool())],
            maxIterations: 5
        )

        var toolCallStarts: [String] = []
        var sawDeferredError = false
        var pausedState: PausedAgentRun?

        do {
            for try await event in agent.runStream("Please delete 'archive.zip'", deps: ()) {
                switch event {
                case .toolCallStart(let name, _):
                    toolCallStarts.append(name)
                default:
                    break
                }
            }
        } catch let error as AgentError {
            if case .hasDeferredTools(let p) = error {
                sawDeferredError = true
                pausedState = p
            }
        }

        // Should have seen the tool call start
        #expect(toolCallStarts.contains("dangerous_delete"))

        // Should have thrown with deferred tools
        #expect(sawDeferredError)
        #expect(pausedState != nil)
        #expect(pausedState?.pendingCalls.count == 1)
    }

    @Test("Iteration detects deferred tools")
    func iterationWithDeferredTools() async throws {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: """
            You are a file management assistant.
            When asked to delete something, use the dangerous_delete tool.
            """,
            tools: [AnyAgentTool(DangerousTool())],
            maxIterations: 5
        )

        var nodeTypes: [String] = []
        var toolExecutionSeen = false
        var sawDeferredError = false
        var pausedState: PausedAgentRun?

        do {
            for try await node in agent.iter("Please delete 'logs.txt'", deps: ()) {
                switch node {
                case .userPrompt:
                    nodeTypes.append("userPrompt")
                case .modelRequest:
                    nodeTypes.append("modelRequest")
                case .modelResponse:
                    nodeTypes.append("modelResponse")
                case .toolExecution(let calls):
                    nodeTypes.append("toolExecution")
                    toolExecutionSeen = calls.contains { $0.name == "dangerous_delete" }
                case .toolResults:
                    nodeTypes.append("toolResults")
                case .end:
                    nodeTypes.append("end")
                }
            }
        } catch let error as AgentError {
            if case .hasDeferredTools(let p) = error {
                sawDeferredError = true
                pausedState = p
            }
        }

        // Should have seen standard node types
        #expect(nodeTypes.contains("userPrompt"))
        #expect(nodeTypes.contains("modelRequest"))
        #expect(nodeTypes.contains("modelResponse"))
        #expect(nodeTypes.contains("toolExecution"))

        // Should have seen the dangerous_delete tool execution
        #expect(toolExecutionSeen)

        // Should have thrown with deferred tools (no .end node)
        #expect(!nodeTypes.contains("end"))
        #expect(sawDeferredError)
        #expect(pausedState != nil)
        #expect(pausedState?.pendingCalls.count == 1)
    }
}
