/// Tests for Agent tool argument parsing and decoding.
///
/// Covers multi-field decoding, optional fields, invalid JSON, missing fields,
/// type mismatches, empty argument normalization, and recovery from bad args.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Schema(description: "Multi-field test arguments")
struct MultiFieldArgs {
    let name: String
    let count: Int
    let tags: [String]
    let optional_field: String?
}

@Suite("Agent - Tool Arguments")
struct AgentToolArgumentTests {

    @Test("valid multi-field JSON decoded correctly with optional absent")
    func validMultiFieldJSONDecodedCorrectly() async throws {
        let tool = FakeTool<MultiFieldArgs, String>(name: "multi_tool") { args in
            .success("name=\(args.name) count=\(args.count) tags=\(args.tags)")
        }

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "multi_tool",
                    arguments: #"{"name":"test","count":5,"tags":["a","b"]}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool)]
        )

        let result = try await agent.run("Go", deps: ())
        #expect(result.output == "Done")

        let calls = await tool.calls
        #expect(calls.count == 1)
        #expect(calls[0].name == "test")
        #expect(calls[0].count == 5)
        #expect(calls[0].tags == ["a", "b"])
        #expect(calls[0].optional_field == nil)
    }

    @Test("optional field decoded correctly when present")
    func optionalFieldPresentDecodedCorrectly() async throws {
        let tool = FakeTool<MultiFieldArgs, String>(name: "multi_tool") { args in
            .success("ok")
        }

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "multi_tool",
                    arguments: #"{"name":"test","count":1,"tags":[],"optional_field":"present"}"#,
                    id: "tc-1"
                )
            case 2:
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool)]
        )

        let result = try await agent.run("Go", deps: ())
        #expect(result.output == "Done")

        let calls = await tool.calls
        #expect(calls[0].optional_field == "present")
    }

    @Test("invalid JSON syntax sends error to model, tool never called")
    func invalidJSONSyntaxNotDeliveredToTool() async throws {
        let tool = ConfigurableTool.succeeding("should not appear", name: "test_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "test_tool",
                    arguments: "not json {",
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultError(for: "tc-1"))
                return MockResponse.text("Recovered")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool)]
        )

        let result = try await agent.run("Go", deps: ())
        #expect(result.output == "Recovered")
        #expect(result.requestCount == 2)
    }

    @Test("missing required fields sends error to model, tool never called")
    func missingRequiredFieldNotDeliveredToTool() async throws {
        let tool = FakeTool<MultiFieldArgs, String>(name: "multi_tool") { _ in
            .success("should not run")
        }

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "multi_tool",
                    arguments: #"{"name":"test"}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultError(for: "tc-1"))
                return MockResponse.text("Recovered")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool)]
        )

        let result = try await agent.run("Go", deps: ())
        #expect(result.output == "Recovered")

        let calls = await tool.calls
        #expect(calls.count == 0)
    }

    @Test("wrong type for field sends error to model, tool never called")
    func wrongTypeFieldNotDeliveredToTool() async throws {
        let tool = ConfigurableTool.succeeding("should not appear", name: "test_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                // input expects String, sending Int
                return MockResponse.toolCall(
                    name: "test_tool",
                    arguments: #"{"input":123}"#,
                    id: "tc-1"
                )
            case 2:
                #expect(try request.isToolResultError(for: "tc-1"))
                return MockResponse.text("Recovered")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool)]
        )

        let result = try await agent.run("Go", deps: ())
        #expect(result.output == "Recovered")
    }

    @Test("empty and whitespace-only arguments normalized to empty JSON object")
    func emptyStringArgumentsNormalizedToEmptyObject() {
        #expect(ToolCall(id: "x", name: "y", arguments: "").arguments == "{}")
        #expect(ToolCall(id: "x", name: "y", arguments: "   ").arguments == "{}")
        #expect(ToolCall(id: "x", name: "y", arguments: " \n\t ").arguments == "{}")
        #expect(ToolCall(id: "x", name: "y", arguments: "{}").arguments == "{}")
    }

    @Test("malformed args then correct args: model recovers on second attempt")
    func malformedArgsThenCorrectArgsRecovery() async throws {
        let tool = ConfigurableTool.succeeding("tool succeeded", name: "test_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { request in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "test_tool",
                    arguments: "broken json",
                    id: "tc-1"
                )
            case 2:
                // Model got parse error, tries again with correct args
                #expect(try request.isToolResultError(for: "tc-1"))
                return MockResponse.toolCall(
                    name: "test_tool",
                    arguments: #"{"input":"correct"}"#,
                    id: "tc-2"
                )
            case 3:
                #expect(try request.isToolResultSuccess(for: "tc-2"))
                return MockResponse.text("Done")
            default:
                throw LLMError.serverError("Unexpected call")
            }
        })

        let agent = try Agent<Void, String>(
            model: model,
            systemPrompt: "You are helpful.",
            tools: [AnyAgentTool(tool)]
        )

        let result = try await agent.run("Go", deps: ())
        #expect(result.output == "Done")
        #expect(result.requestCount == 3)
    }
}
