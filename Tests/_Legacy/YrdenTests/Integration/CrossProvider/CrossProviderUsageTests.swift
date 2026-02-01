/// Cross-provider usage tracking tests.
///
/// Tests token usage reporting across all providers.

import Testing
import Foundation
@testable import Yrden

@Suite("Cross-Provider Usage")
struct CrossProviderUsageTests {

    @Test(arguments: ProviderFixture.all)
    func usageTracking(fixture: ProviderFixture) async throws {
        let subject = fixture.subject

        let response = try await subject.model.complete("Hi")

        #expect(response.usage.inputTokens > 0, "Should have input tokens")
        #expect(response.usage.outputTokens > 0, "Should have output tokens")
        #expect(
            response.usage.totalTokens == response.usage.inputTokens + response.usage.outputTokens,
            "Total should equal input + output"
        )
    }
}
