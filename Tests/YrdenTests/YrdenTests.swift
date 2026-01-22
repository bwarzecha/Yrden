import Testing
@testable import Yrden

@Suite("Yrden Tests")
struct YrdenTests {
    @Test("Package builds successfully")
    func packageBuilds() {
        // Placeholder test - package compiles
        #expect(true)
    }
}

@Suite("TestConfig")
struct TestConfigTests {
    @Test("apiKey returns nil for missing key")
    func apiKeyReturnsNilForMissing() {
        let key = TestConfig.apiKey("NONEXISTENT_KEY_12345")
        #expect(key == nil)
    }

    @Test("hasAnthropicAPIKey reflects availability")
    func hasKeyReflectsAvailability() {
        // This just verifies the check doesn't crash
        // Result depends on environment
        _ = TestConfig.hasAnthropicAPIKey
    }
}
