/// Cross-provider completion tests.
///
/// Tests basic completion functionality across all providers.

import Testing
import Foundation
@testable import Yrden

@Suite("Cross-Provider Completion")
struct CrossProviderCompletionTests {

    @Test(arguments: ProviderFixture.all)
    func simpleCompletion(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        let response = try await subject.model.complete("Say 'hello' and nothing else.")

        #expect(response.content != nil, "Response should have content")
        #expect(
            response.content?.lowercased().contains("hello") == true,
            "Response should contain 'hello', got: \(response.content ?? "nil")"
        )
        #expect(response.stopReason == .endTurn, "Should stop with endTurn")
        #expect(response.usage.inputTokens > 0, "Should report input tokens")
        #expect(response.usage.outputTokens > 0, "Should report output tokens")
    }

    @Test(arguments: ProviderFixture.all)
    func completionWithSystemMessage(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsSystemMessage else { return }

        let request = CompletionRequest(
            messages: [
                .system("You are a pirate. Always respond in pirate speak."),
                .user("Say hello")
            ]
        )

        let response = try await subject.model.complete(request)

        #expect(response.content != nil, "Response should have content")

        let content = response.content?.lowercased() ?? ""
        let pirateWords = ["ahoy", "matey", "arr", "ye", "avast", "aye"]
        let hasPirateWord = pirateWords.contains { content.contains($0) }
        #expect(hasPirateWord, "Response should contain pirate speak, got: \(content)")
    }

    @Test(arguments: ProviderFixture.all)
    func completionWithTemperature(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        let request = CompletionRequest(
            messages: [.user("What is 2+2? Reply with just the number.")],
            config: CompletionConfig(temperature: 0.0)
        )

        let response = try await subject.model.complete(request)

        #expect(
            response.content?.contains("4") == true,
            "Response should contain '4', got: \(response.content ?? "nil")"
        )
    }

    @Test(arguments: ProviderFixture.all)
    func completionWithMaxTokens(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        let maxTokens = max(subject.constraints.minMaxTokens, 10)

        let request = CompletionRequest(
            messages: [.user("Count from 1 to 100")],
            config: CompletionConfig(maxTokens: maxTokens)
        )

        let response = try await subject.model.complete(request)

        #expect(response.stopReason == .maxTokens, "Should stop due to maxTokens")
        #expect(
            response.usage.outputTokens <= maxTokens + 10,
            "Output tokens (\(response.usage.outputTokens)) should be near maxTokens (\(maxTokens))"
        )
    }
}
