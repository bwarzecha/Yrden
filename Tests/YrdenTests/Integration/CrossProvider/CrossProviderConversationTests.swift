/// Cross-provider conversation tests.
///
/// Tests multi-turn conversation functionality across all providers.

import Testing
import Foundation
@testable import Yrden

@Suite("Cross-Provider Conversation")
struct CrossProviderConversationTests {

    @Test(arguments: ProviderFixture.all)
    func multiTurnConversation(fixture: ProviderFixture) async throws {
        let subject = fixture.subject

        // Turn 1
        let response1 = try await subject.model.complete(messages: [
            .user("My name is Alice. Remember it.")
        ])

        #expect(response1.content != nil, "Should have response")

        // Turn 2 - should remember context
        let response2 = try await subject.model.complete(messages: [
            .user("My name is Alice. Remember it."),
            .assistant(response1.content ?? ""),
            .user("What's my name?")
        ])

        #expect(
            response2.content?.contains("Alice") == true,
            "Should remember name 'Alice', got: \(response2.content ?? "nil")"
        )
    }
}
