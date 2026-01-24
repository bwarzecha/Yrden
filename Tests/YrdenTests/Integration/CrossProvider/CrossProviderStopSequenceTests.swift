/// Cross-provider stop sequence tests.
///
/// Tests stop sequence functionality across all providers.

import Testing
import Foundation
@testable import Yrden

@Suite("Cross-Provider Stop Sequences")
struct CrossProviderStopSequenceTests {

    @Test(arguments: ProviderFixture.all)
    func stopSequences(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsStopSequences else { return }

        let request = CompletionRequest(
            messages: [.user("Output only numbers 1 through 20, one per line, no other text.")],
            config: CompletionConfig(stopSequences: ["8"])
        )

        let response = try await subject.model.complete(request)

        #expect(response.stopReason == .stopSequence, "Should stop at sequence")
        let content = response.content ?? ""
        #expect(content.contains("1"), "Should contain '1'")
        #expect(content.contains("5"), "Should contain '5'")
        #expect(!content.contains("12"), "Should NOT contain '12'")
        #expect(!content.contains("15"), "Should NOT contain '15'")
    }
}
