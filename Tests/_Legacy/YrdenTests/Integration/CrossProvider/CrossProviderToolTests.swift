/// Cross-provider tool calling tests.
///
/// Tests tool calling functionality across all providers.

import Testing
import Foundation
@testable import Yrden

@Suite("Cross-Provider Tools")
struct CrossProviderToolTests {

    @Test(arguments: ProviderFixture.all)
    func toolCall(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let weatherTool = ToolDefinition(
            name: "get_weather",
            description: "Get the current weather for a city",
            inputSchema: [
                "type": "object",
                "properties": [
                    "city": [
                        "type": "string",
                        "description": "The city name"
                    ]
                ],
                "required": ["city"]
            ]
        )

        let request = CompletionRequest(
            messages: [.user("What's the weather in Paris?")],
            tools: [weatherTool]
        )

        let response = try await subject.model.complete(request)

        #expect(response.stopReason == .toolUse, "Should stop for tool use")
        #expect(!response.toolCalls.isEmpty, "Should have tool calls")
        #expect(response.toolCalls[0].name == "get_weather", "Should call get_weather")

        let args = response.toolCalls[0].arguments.lowercased()
        #expect(args.contains("paris"), "Arguments should contain 'paris'")
    }

    @Test(arguments: ProviderFixture.all)
    func toolCallWithResult(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsTools else { return }

        let calculatorTool = ToolDefinition(
            name: "calculate",
            description: "Perform a calculation",
            inputSchema: [
                "type": "object",
                "properties": [
                    "expression": [
                        "type": "string",
                        "description": "Math expression to evaluate"
                    ]
                ],
                "required": ["expression"]
            ]
        )

        // First turn: model calls tool
        let request1 = CompletionRequest(
            messages: [.user("What is 15 * 7? Use the calculator.")],
            tools: [calculatorTool]
        )

        let response1 = try await subject.model.complete(request1)
        #expect(response1.stopReason == .toolUse, "Should request tool use")
        #expect(!response1.toolCalls.isEmpty, "Should have tool calls")

        // Second turn: provide tool result
        let toolCall = response1.toolCalls[0]
        let request2 = CompletionRequest(
            messages: [
                .user("What is 15 * 7? Use the calculator."),
                .assistant(response1.content ?? "", toolCalls: response1.toolCalls),
                .toolResult(toolCallId: toolCall.id, content: "105")
            ],
            tools: [calculatorTool]
        )

        let response2 = try await subject.model.complete(request2)

        #expect(response2.stopReason == .endTurn, "Should complete after tool result")
        #expect(
            response2.content?.contains("105") == true,
            "Response should include the result '105'"
        )
    }
}
