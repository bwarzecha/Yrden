/// Tests for Agent tool routing, selection, and name validation.
///
/// Covers correct tool selection from multiple registered tools, unknown tool names,
/// output tool name collision avoidance, duplicate tool name rejection,
/// tool definition inclusion in model requests, and extra field handling.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Schema(description: "Simple output")
private struct SimpleOutput: Equatable {
    let answer: String
    let confidence: Int
}

@Suite("Agent - Tool Routing")
struct AgentToolRoutingTests {

    @Test("correct tool selected when multiple are registered")
    func correctToolSelectedFromMultiple() async throws {
        let alphaTool = FakeTool<ConfigurableToolArgs, String>(name: "alpha") { _ in
            .success("alpha result")
        }
        let betaTool = FakeTool<ConfigurableToolArgs, String>(name: "beta") { _ in
            .success("beta result")
        }
        let gammaTool = FakeTool<ConfigurableToolArgs, String>(name: "gamma") { _ in
            .success("gamma result")
        }

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "beta",
                    arguments: #"{"input":"test"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultSuccess(for: "tc-1"))
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(alphaTool), AnyAgentTool(betaTool), AnyAgentTool(gammaTool)]
        )

        let result = try await agent.run("Call beta", deps: ())
        #expect(result.output == "Done")

        let alphaCalls = await alphaTool.calls
        #expect(alphaCalls.count == 0)
        let betaCalls = await betaTool.calls
        #expect(betaCalls.count == 1)
        let gammaCalls = await gammaTool.calls
        #expect(gammaCalls.count == 0)
    }

    @Test("unknown tool name returns error result to model and agent recovers")
    func unknownToolNameReturnsErrorToModel() async throws {
        let realTool = FakeTool<ConfigurableToolArgs, String>(name: "real_tool") { _ in
            .success("should not run")
        }

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "nonexistent",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultError(for: "tc-1"))
                return MockResponse.text("Recovered")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(realTool)]
        )

        let result = try await agent.run("Go", deps: ())
        #expect(result.output == "Recovered")
        #expect(result.requestCount == 2)

        let realCalls = await realTool.calls
        #expect(realCalls.count == 0)
    }

    // DRIVES FIX: Default outputToolName should be dynamically generated
    // to avoid collision with user tool names.
    // Currently fails because outputToolName defaults to "final_result"
    // which collides with the user's tool of the same name.
    @Test("default output tool name does not collide with user tools named final_result")
    func defaultOutputToolNameDoesNotCollideWithUserTools() async throws {
        let userTool = ConfigurableTool.succeeding("user tool result", name: "final_result")

        let model = FakeModel(responses: [])

        let agent = Agent<Void, SimpleOutput>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(userTool)]
        )

        let outputName = await agent.outputToolName
        #expect(outputName != "final_result",
                "outputToolName should not collide with user's 'final_result' tool")
        #expect(outputName.hasPrefix("final_result_"),
                "outputToolName should keep 'final_result' as base with a suffix")
    }

    // DRIVES FIX: Agent.init should reject explicit outputToolName that
    // collides with a registered tool name.
    // Currently fails because Agent.init doesn't validate names.
    @Test("explicit outputToolName matching a registered tool name is rejected")
    func explicitOutputToolNameRejectsCollisionWithRegisteredTool() async throws {
        let tool = ConfigurableTool.succeeding("ok", name: "my_output")

        // Currently Agent.init doesn't validate, so this succeeds.
        // Once Agent.init becomes throwing, this test should use #expect(throws:).
        let _ = Agent<Void, SimpleOutput>(
            model: FakeModel(responses: []),
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool)],
            outputToolName: "my_output"
        )

        Issue.record("DRIVES FIX: Agent.init should reject outputToolName collision with registered tool name")
    }

    // DRIVES FIX: Agent.init should reject duplicate tool names.
    // Currently fails because Agent.init doesn't validate names.
    @Test("init rejects duplicate tool names")
    func initRejectsDuplicateToolNames() async throws {
        let tool1 = ConfigurableTool.succeeding("first", name: "duplicate_tool")
        let tool2 = ConfigurableTool.succeeding("second", name: "duplicate_tool")

        // Currently Agent.init doesn't validate, so this succeeds.
        // Once Agent.init becomes throwing, this test should use #expect(throws:).
        let _ = Agent<Void, String>(
            model: FakeModel(responses: []),
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool1), AnyAgentTool(tool2)]
        )

        Issue.record("DRIVES FIX: Agent.init should reject duplicate tool names")
    }

    @Test("tool definitions are included in model request")
    func toolDefinitionsIncludedInModelRequest() async throws {
        let tool = ConfigurableTool.succeeding("ok", name: "my_tool")

        let model = FakeModel(onComplete: { request in
            let tools = try #require(request.tools)
            #expect(tools.contains { $0.name == "my_tool" })
            return MockResponse.text("Done")
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool)]
        )

        let result = try await agent.run("Go", deps: ())
        #expect(result.output == "Done")
    }

    @Test("extra fields in arguments JSON are ignored by decoder")
    func extraFieldsInArgumentsIgnoredByDecoder() async throws {
        let tool = ConfigurableTool.succeeding("ok", name: "test_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "test_tool",
                    arguments: #"{"input":"hello","unexpected_field":"should be ignored"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultSuccess(for: "tc-1"))
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool)]
        )

        let result = try await agent.run("Go", deps: ())
        #expect(result.output == "Done")
    }
}
