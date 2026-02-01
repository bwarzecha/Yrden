import Foundation
@testable import Yrden

/// Minimal fake provider for testing.
///
/// A simple struct matching real provider patterns (AnthropicProvider, OpenAIProvider).
/// Use the callback to control auth behavior or inject errors.
///
/// ```swift
/// let provider = FakeProvider()
/// var request = URLRequest(url: URL(string: "https://test.com")!)
/// try await provider.authenticate(&request)
/// ```
public struct FakeProvider: Provider, Sendable {
    public let baseURL: URL

    /// Test controls auth behavior. Default: succeeds silently (does nothing).
    public var onAuthenticate: (@Sendable (inout URLRequest) async throws -> Void)?

    /// Models returned by listModels().
    public var models: [ModelInfo]

    public init(
        baseURL: URL = URL(string: "https://fake.test")!,
        models: [ModelInfo] = [ModelInfo(id: "fake-model", displayName: "Fake Model")]
    ) {
        self.baseURL = baseURL
        self.models = models
    }

    public func authenticate(_ request: inout URLRequest) async throws {
        try await onAuthenticate?(&request)
    }

    public func listModels() -> AsyncThrowingStream<ModelInfo, Error> {
        let captured = self.models
        return AsyncThrowingStream { continuation in
            for model in captured { continuation.yield(model) }
            continuation.finish()
        }
    }
}
