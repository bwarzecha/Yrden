import Foundation
@testable import Yrden

/// Minimal fake model for testing.
///
/// Two independent paths:
/// - `complete()`: uses `responses` queue or `onComplete` callback
/// - `stream()`: uses `streamEventSequences` queue or `onStream` callback
///
/// Callback takes priority over queue if both are set.
///
/// ## Queue mode (text-only, no tools)
/// ```swift
/// let model = FakeModel(responses: [MockResponse.text("Hello")])
/// ```
///
/// ## Callback mode (tool flows — REQUIRED for any tool interaction)
/// ```swift
/// let counter = CallCounter()
/// let model = FakeModel(onComplete: { request in
///     switch await counter.increment() {
///     case 1:
///         return MockResponse.toolCall(name: "search", arguments: "{}", id: "s1")
///     case 2:
///         return MockResponse.text("Done")
///     default:
///         throw LLMError.serverError("Unexpected call")
///     }
/// })
/// ```
public actor FakeModel: Model {
    public static let providerId = "fake"

    public nonisolated let name: String
    public nonisolated let capabilities: ModelCapabilities

    /// Every request received (both complete and stream), in order.
    public private(set) var requests: [CompletionRequest] = []

    /// Number of complete() calls received.
    public private(set) var completeCallCount: Int = 0

    /// Number of stream() calls received.
    public private(set) var streamCallCount: Int = 0

    // --- complete() path ---
    private var responses: [CompletionResponse]
    private var responseIndex: Int = 0
    private let onComplete: (@Sendable (CompletionRequest) async throws -> CompletionResponse)?

    // --- stream() path ---
    private var streamEventSequences: [[StreamEvent]]
    private var streamIndex: Int = 0
    private let onStream: (@Sendable (CompletionRequest) async throws -> [StreamEvent])?

    public init(
        name: String = "fake-model",
        capabilities: ModelCapabilities = .claude35,
        responses: [CompletionResponse] = [],
        streamEventSequences: [[StreamEvent]] = [],
        onComplete: (@Sendable (CompletionRequest) async throws -> CompletionResponse)? = nil,
        onStream: (@Sendable (CompletionRequest) async throws -> [StreamEvent])? = nil
    ) {
        self.name = name
        self.capabilities = capabilities
        self.responses = responses
        self.streamEventSequences = streamEventSequences
        self.onComplete = onComplete
        self.onStream = onStream
    }

    public nonisolated func complete(
        _ request: CompletionRequest
    ) async throws -> CompletionResponse {
        try await _complete(request)
    }

    private func _complete(
        _ request: CompletionRequest
    ) async throws -> CompletionResponse {
        completeCallCount += 1
        requests.append(request)

        if let onComplete {
            return try await onComplete(request)
        }

        guard responseIndex < responses.count else {
            throw LLMError.serverError(
                "FakeModel.complete(): no more responses "
                + "(\(completeCallCount) calls, \(responses.count) available)"
            )
        }
        defer { responseIndex += 1 }
        return responses[responseIndex]
    }

    public nonisolated func stream(
        _ request: CompletionRequest
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let events = try await self._nextStreamEvents(request)
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func _nextStreamEvents(
        _ request: CompletionRequest
    ) async throws -> [StreamEvent] {
        streamCallCount += 1
        requests.append(request)

        if let onStream {
            return try await onStream(request)
        }

        guard streamIndex < streamEventSequences.count else {
            throw LLMError.serverError(
                "FakeModel.stream(): no more event sequences "
                + "(\(streamIndex) exhausted)"
            )
        }
        defer { streamIndex += 1 }
        return streamEventSequences[streamIndex]
    }
}
