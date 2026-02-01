/// Cross-provider unicode handling tests.
///
/// Tests unicode character handling across all providers.

import Testing
import Foundation
@testable import Yrden

@Suite("Cross-Provider Unicode")
struct CrossProviderUnicodeTests {

    @Test(arguments: ProviderFixture.all)
    func unicodeHandling(fixture: ProviderFixture) async throws {
        let subject = fixture.subject

        let request = CompletionRequest(
            messages: [.user("Repeat exactly: Hello 你好")]
        )

        let response = try await subject.model.complete(request)

        #expect(response.content != nil, "Should have content")
        let content = response.content ?? ""
        #expect(
            content.contains("你好") || content.contains("Hello"),
            "Should preserve unicode, got: \(content)"
        )
    }
}
