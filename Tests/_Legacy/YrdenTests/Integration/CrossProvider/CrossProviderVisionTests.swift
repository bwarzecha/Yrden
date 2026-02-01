/// Cross-provider vision tests.
///
/// Tests image input functionality across all providers.

import Testing
import Foundation
@testable import Yrden

@Suite("Cross-Provider Vision")
struct CrossProviderVisionTests {

    @Test(arguments: ProviderFixture.all)
    func imageInput(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsVision else { return }

        let redPNG = createTestPNG(color: (255, 0, 0))

        let request = CompletionRequest(
            messages: [
                .user([
                    .text("What color is this image? Reply with just the color name."),
                    .image(redPNG, mimeType: "image/png")
                ])
            ],
            config: CompletionConfig(temperature: 0.0)
        )

        let response = try await subject.visionModel.complete(request)

        #expect(response.content != nil, "Should have content")
        let content = response.content?.lowercased() ?? ""
        #expect(content.contains("red"), "Should identify red color, got: \(content)")
    }
}
