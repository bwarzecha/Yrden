/// Test subject protocol and provider fixtures for cross-provider tests.
///
/// To add a new provider, simply add it to `ProviderFixture.all`.

import Testing
import Foundation
@testable import Yrden

// MARK: - Test Subject Protocol

/// Protocol that each provider's test fixture must implement.
protocol ModelTestSubject: Sendable {
    /// The primary model for testing (cost-effective, e.g., Haiku/GPT-4o-mini)
    var model: any Model { get }

    /// Model that supports vision (may be same as model)
    var visionModel: any Model { get }

    /// Provider-specific capabilities and constraints
    var constraints: ProviderConstraints { get }

    /// Provider name for display in test output
    var providerName: String { get }
}

/// Provider-specific constraints that affect test parameters.
struct ProviderConstraints: Sendable {
    /// Minimum value for maxTokens (OpenAI Responses API requires >= 16)
    let minMaxTokens: Int

    /// Whether the model supports vision/images
    let supportsVision: Bool

    /// Whether the model supports tool calling
    let supportsTools: Bool

    /// Whether the model supports streaming
    let supportsStreaming: Bool

    /// Whether the model supports system messages
    let supportsSystemMessage: Bool

    /// Whether the model supports stop sequences
    let supportsStopSequences: Bool

    static let standard = ProviderConstraints(
        minMaxTokens: 10,
        supportsVision: true,
        supportsTools: true,
        supportsStreaming: true,
        supportsSystemMessage: true,
        supportsStopSequences: true
    )

    static let openAI = ProviderConstraints(
        minMaxTokens: 16,  // OpenAI Responses API minimum
        supportsVision: true,
        supportsTools: true,
        supportsStreaming: true,
        supportsSystemMessage: true,
        supportsStopSequences: true
    )
}

// MARK: - Provider Fixture (for parameterized tests)

/// Wrapper for test subjects that can be used in parameterized tests.
/// Conforms to CustomTestStringConvertible for nice test names.
struct ProviderFixture: Sendable, CustomTestStringConvertible {
    let subject: any ModelTestSubject

    var testDescription: String {
        subject.providerName
    }

    /// All provider fixtures - ADD NEW PROVIDERS HERE
    static let all: [ProviderFixture] = {
        var fixtures: [ProviderFixture] = [
            ProviderFixture(subject: AnthropicTestSubject()),
            ProviderFixture(subject: OpenAITestSubject()),
        ]

        // Bedrock requires credentials, add if available
        if let bedrock = try? BedrockTestSubject() {
            fixtures.append(ProviderFixture(subject: bedrock))
        }

        return fixtures
    }()
}

// MARK: - Provider Implementations

/// Anthropic test fixture
struct AnthropicTestSubject: ModelTestSubject {
    let model: any Model
    let visionModel: any Model
    let constraints = ProviderConstraints.standard
    let providerName = "Anthropic"

    init() {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)
        self.model = model
        self.visionModel = model
    }
}

/// OpenAI test fixture
struct OpenAITestSubject: ModelTestSubject {
    let model: any Model
    let visionModel: any Model
    let constraints = ProviderConstraints.openAI
    let providerName = "OpenAI"

    init() {
        let apiKey = TestConfig.openAIAPIKey
        let provider = OpenAIProvider(apiKey: apiKey)
        let model = OpenAIModel(name: "gpt-4o-mini", provider: provider)
        self.model = model
        self.visionModel = model
    }
}

/// Bedrock test fixture
struct BedrockTestSubject: ModelTestSubject {
    let model: any Model
    let visionModel: any Model
    let constraints = ProviderConstraints.standard
    let providerName = "Bedrock"

    init() throws {
        let provider: BedrockProvider
        if let accessKey = TestConfig.awsAccessKeyId,
           let secretKey = TestConfig.awsSecretAccessKey,
           !accessKey.isEmpty && !secretKey.isEmpty {
            provider = try BedrockProvider(
                region: TestConfig.awsRegion,
                accessKeyId: accessKey,
                secretAccessKey: secretKey,
                sessionToken: TestConfig.awsSessionToken
            )
        } else {
            provider = try BedrockProvider(
                region: TestConfig.awsRegion,
                profile: TestConfig.awsProfile
            )
        }

        self.model = BedrockModel(
            name: "us.anthropic.claude-3-5-haiku-20241022-v1:0",
            provider: provider
        )
        // Haiku 3.5 doesn't support vision, use Sonnet
        self.visionModel = BedrockModel(
            name: "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
            provider: provider
        )
    }
}
