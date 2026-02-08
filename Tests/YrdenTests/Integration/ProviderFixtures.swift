/// Provider fixtures for integration tests.
///
/// All provider initialization flows through `ProviderFixture.all`, gated by env vars:
/// - `INTEGRATION=1`      → all providers (local only if running)
/// - `ANTHROPIC_TESTS=1`  → Anthropic only
/// - `OPENAI_TESTS=1`     → OpenAI only
/// - `BEDROCK_TESTS=1`    → Bedrock only
/// - `LOCAL_TESTS=1`      → Ollama/local only (crashes if Ollama not running)
/// - `LM_STUDIO_TESTS=1`  → LM Studio only (crashes if not running)
///
/// No env var set → `all` is empty → integration tests run 0 times.
/// Env var set but API key missing → `requireAPIKey` crashes with clear message.

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

// MARK: - Test Subject Protocol

/// Protocol that each provider's test fixture must implement.
protocol ModelTestSubject: Sendable {
    /// The primary model for testing (cost-effective, e.g., Haiku/GPT-4o-mini)
    var model: any Model { get }

    /// Model that supports vision (may be same as model)
    var visionModel: any Model { get }

    /// Test constraints derived from the model's built-in capabilities.
    var constraints: TestConstraints { get }

    /// Provider name for display in test output
    var providerName: String { get }
}

/// Test constraints that wrap the model's built-in `ModelCapabilities`.
///
/// Most capabilities come directly from the model (auto-detected from model identifier
/// via `model.capabilities`). Test-specific overrides handle API quirks not captured
/// in the model's capabilities (e.g., minimum maxTokens, stop sequence support).
struct TestConstraints: Sendable {
    /// The model's built-in capabilities (auto-detected from model identifier).
    private let capabilities: ModelCapabilities

    /// Minimum value for maxTokens (OpenAI Responses API requires >= 16).
    let minMaxTokens: Int

    /// Whether the model supports streaming. Most models do.
    let supportsStreaming: Bool

    /// Whether the model supports stop sequences.
    /// OpenAI's Responses API doesn't support stop sequences for some models.
    let supportsStopSequences: Bool

    // Forward model capabilities as convenience properties
    var supportsVision: Bool { capabilities.supportsVision }
    var supportsTools: Bool { capabilities.supportsTools }
    var supportsSystemMessage: Bool { capabilities.supportsSystemMessage }
    var supportsTemperature: Bool { capabilities.supportsTemperature }

    /// Standard constraints — suitable for Anthropic and Bedrock Claude models.
    static func standard(for model: any Model) -> TestConstraints {
        TestConstraints(
            capabilities: model.capabilities,
            minMaxTokens: 10,
            supportsStreaming: true,
            supportsStopSequences: true
        )
    }

    /// OpenAI-specific constraints — higher minMaxTokens, no stop sequences via Responses API.
    static func openAI(for model: any Model) -> TestConstraints {
        TestConstraints(
            capabilities: model.capabilities,
            minMaxTokens: 16,
            supportsStreaming: true,
            supportsStopSequences: false
        )
    }

    /// Local model constraints — conservative defaults for Ollama/LM Studio.
    static func local(for model: any Model) -> TestConstraints {
        TestConstraints(
            capabilities: model.capabilities,
            minMaxTokens: 10,
            supportsStreaming: true,
            supportsStopSequences: true
        )
    }
}

// MARK: - Provider Fixture (for parameterized tests)

/// Wrapper for test subjects that can be used in parameterized tests.
/// Conforms to CustomTestStringConvertible for nice test names.
struct ProviderFixture: Sendable, CustomTestStringConvertible {
    let subject: any ModelTestSubject

    var testDescription: String {
        subject.providerName
    }

    // MARK: - Env var gated fixture list

    /// All enabled provider fixtures, gated by environment variables.
    ///
    /// - `INTEGRATION=1` enables all providers (local only if Ollama is running)
    /// - `ANTHROPIC_TESTS=1` enables Anthropic only
    /// - `OPENAI_TESTS=1` enables OpenAI only
    /// - `BEDROCK_TESTS=1` enables Bedrock only
    /// - `LOCAL_TESTS=1` enables Ollama/local only (crashes if not running)
    /// - `LM_STUDIO_TESTS=1` enables LM Studio only (crashes if not running)
    ///
    /// When a provider is enabled but its API key is missing, initialization
    /// crashes with a clear error message (via `requireAPIKey`).
    static let all: [ProviderFixture] = {
        let env = ProcessInfo.processInfo.environment
        let runAll = env["INTEGRATION"] != nil

        var fixtures: [ProviderFixture] = []

        if runAll || env["ANTHROPIC_TESTS"] != nil {
            fixtures.append(ProviderFixture(subject: AnthropicTestSubject()))
        }

        if runAll || env["OPENAI_TESTS"] != nil {
            fixtures.append(ProviderFixture(subject: OpenAITestSubject()))
        }

        if runAll || env["BEDROCK_TESTS"] != nil {
            // swiftlint:disable:next force_try
            fixtures.append(ProviderFixture(subject: try! BedrockTestSubject()))
        }

        if env["LOCAL_TESTS"] != nil {
            // Explicit request: crash if Ollama is not running
            fixtures.append(ProviderFixture(subject: OllamaTestSubject()))
        } else if runAll && TestConfig.isOllamaRunning {
            // INTEGRATION=1: include only if Ollama is detected running
            fixtures.append(ProviderFixture(subject: OllamaTestSubject()))
        }

        if env["LM_STUDIO_TESTS"] != nil {
            // Explicit request: crash if LM Studio is not running
            fixtures.append(ProviderFixture(subject: LMStudioTestSubject()))
        } else if runAll && TestConfig.isLMStudioRunning {
            // INTEGRATION=1: include only if LM Studio is detected running
            fixtures.append(ProviderFixture(subject: LMStudioTestSubject()))
        }

        return fixtures
    }()

    // MARK: - Per-provider accessors

    /// Anthropic fixture, if enabled.
    static var anthropic: ProviderFixture? {
        all.first { $0.subject is AnthropicTestSubject }
    }

    /// OpenAI fixture, if enabled.
    static var openAI: ProviderFixture? {
        all.first { $0.subject is OpenAITestSubject }
    }

    /// Bedrock fixture, if enabled.
    static var bedrock: ProviderFixture? {
        all.first { $0.subject is BedrockTestSubject }
    }

    /// Ollama/local fixture, if enabled.
    static var local: ProviderFixture? {
        all.first { $0.subject is OllamaTestSubject }
    }

    /// LM Studio fixture, if enabled.
    static var lmStudio: ProviderFixture? {
        all.first { $0.subject is LMStudioTestSubject }
    }
}

// MARK: - Provider Implementations

/// Anthropic test fixture
struct AnthropicTestSubject: ModelTestSubject {
    let model: any Model
    let visionModel: any Model
    let constraints: TestConstraints
    let providerName = "Anthropic"

    init() {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        let model = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)
        self.model = model
        self.visionModel = model
        self.constraints = .standard(for: model)
    }
}

/// OpenAI test fixture
struct OpenAITestSubject: ModelTestSubject {
    let model: any Model
    let visionModel: any Model
    let constraints: TestConstraints
    let providerName = "OpenAI"

    init() {
        let apiKey = TestConfig.openAIAPIKey
        let provider = OpenAIProvider(apiKey: apiKey)
        let model = OpenAIModel(name: "gpt-5-mini", provider: provider)
        self.model = model
        self.visionModel = model
        self.constraints = .openAI(for: model)
    }
}

/// Bedrock test fixture
struct BedrockTestSubject: ModelTestSubject {
    let model: any Model
    let visionModel: any Model
    let constraints: TestConstraints
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

        let model = BedrockModel(
            name: "us.anthropic.claude-haiku-4-5-20251001-v1:0",
            provider: provider
        )
        self.model = model
        self.visionModel = model
        self.constraints = .standard(for: model)
    }
}

/// Ollama/local test fixture
struct OllamaTestSubject: ModelTestSubject {
    let model: any Model
    let visionModel: any Model
    let constraints: TestConstraints
    let providerName = "Ollama"

    init() {
        let modelName = TestConfig.ollamaTestModel
        TestConfig.requireOllamaModel(modelName)

        let provider = LocalProvider.ollama(port: TestConfig.ollamaPort)
        let model = LocalModel(name: modelName, provider: provider)
        self.model = model
        self.visionModel = model
        self.constraints = .local(for: model)
    }
}

/// LM Studio test fixture
struct LMStudioTestSubject: ModelTestSubject {
    let model: any Model
    let visionModel: any Model
    let constraints: TestConstraints
    let providerName = "LM Studio"

    init() {
        let modelName = TestConfig.lmStudioTestModel
        TestConfig.requireLMStudioModel(modelName)

        let provider = LocalProvider.lmStudio(port: TestConfig.lmStudioPort)
        let model = LocalModel(name: modelName, provider: provider)
        self.model = model
        self.visionModel = model
        self.constraints = .local(for: model)
    }
}
