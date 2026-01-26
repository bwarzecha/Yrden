/// Shared test helpers for Agent tests.
///
/// Provides reusable test doubles that are simpler than production code.
/// Each test double should be <50 lines per the test quality guidelines.

import Foundation
@testable import Yrden

// MARK: - Configurable Test Tool

/// Arguments for the configurable test tool.
@Schema(description: "Configurable tool arguments")
struct ConfigurableToolArgs {
    let input: String
}

/// A generic test tool that can be configured to return any behavior.
/// Replaces ThrowingTool, FailingTool, RetryRequestingTool, and SimpleTool.
struct ConfigurableTool: AgentTool {
    typealias Deps = Void
    typealias Args = ConfigurableToolArgs

    /// The behavior to exhibit when called.
    enum Behavior: Sendable {
        case success(String)
        case failure(Error)
        case throwError(Error)
        case retry(String)
    }

    let toolName: String
    let toolDescription: String
    let behavior: Behavior

    var name: String { toolName }
    var description: String { toolDescription }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        switch behavior {
        case .success(let result):
            return .success(result)
        case .failure(let error):
            return .failure(error)
        case .throwError(let error):
            throw error
        case .retry(let message):
            return .retry(message: message)
        }
    }
}

// MARK: - Convenience Factories

extension ConfigurableTool {
    /// Creates a tool that always succeeds with the given result.
    static func succeeding(_ result: String = "Success", name: String = "test_tool") -> ConfigurableTool {
        ConfigurableTool(
            toolName: name,
            toolDescription: "A test tool that succeeds",
            behavior: .success(result)
        )
    }

    /// Creates a tool that always throws the given error.
    static func throwing(_ error: Error, name: String = "throwing_tool") -> ConfigurableTool {
        ConfigurableTool(
            toolName: name,
            toolDescription: "A test tool that throws errors",
            behavior: .throwError(error)
        )
    }

    /// Creates a tool that returns .failure with the given error.
    static func failing(_ error: Error, name: String = "failing_tool") -> ConfigurableTool {
        ConfigurableTool(
            toolName: name,
            toolDescription: "A test tool that returns failure",
            behavior: .failure(error)
        )
    }

    /// Creates a tool that returns .retry with the given message.
    static func retrying(_ message: String, name: String = "retry_tool") -> ConfigurableTool {
        ConfigurableTool(
            toolName: name,
            toolDescription: "A test tool that requests retry",
            behavior: .retry(message)
        )
    }
}

// MARK: - Test Errors

/// Common error types for testing.
enum TestToolError: Error, LocalizedError, Sendable {
    case generic(String)
    case crashed(String)
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .generic(let message): return message
        case .crashed(let message): return "Tool crashed: \(message)"
        case .processingFailed(let message): return "Failed to process: \(message)"
        }
    }
}

// MARK: - Retry Stateful Tool

/// A tool that tracks call count and changes behavior after N calls.
/// Useful for testing retry scenarios where tools fail then succeed.
/// Named RetryStatefulTool to avoid conflict with StatefulTool in AgentConcurrencyTests.
actor RetryStatefulTool: AgentTool {
    typealias Deps = Void
    typealias Args = ConfigurableToolArgs

    private var callCount = 0
    private let failUntilCall: Int
    private let failBehavior: ConfigurableTool.Behavior
    private let successResult: String

    nonisolated let name: String
    nonisolated let description: String

    init(
        name: String = "stateful_tool",
        failUntilCall: Int,
        failWith behavior: ConfigurableTool.Behavior = .retry("Try again"),
        successResult: String = "Success"
    ) {
        self.name = name
        self.description = "A stateful test tool"
        self.failUntilCall = failUntilCall
        self.failBehavior = behavior
        self.successResult = successResult
    }

    nonisolated func call(
        context: AgentContext<Void>,
        arguments: Args
    ) async throws -> ToolResult<String> {
        try await execute(arguments: arguments)
    }

    private func execute(arguments: Args) throws -> ToolResult<String> {
        callCount += 1

        if callCount <= failUntilCall {
            switch failBehavior {
            case .success(let result):
                return .success(result)
            case .failure(let error):
                return .failure(error)
            case .throwError(let error):
                throw error
            case .retry(let message):
                return .retry(message: "\(message) (attempt \(callCount))")
            }
        }
        return .success(successResult)
    }

    var currentCallCount: Int {
        get async { callCount }
    }

    func reset() {
        callCount = 0
    }
}

// MARK: - Slow Tool

/// A tool that takes a configurable amount of time to complete.
/// Useful for testing timeouts and cancellation.
struct SlowTool: AgentTool {
    typealias Deps = Void
    typealias Args = ConfigurableToolArgs

    let delay: Duration
    let result: String

    var name: String { "slow_tool" }
    var description: String { "A tool that takes time to complete" }

    init(delay: Duration, result: String = "Completed after delay") {
        self.delay = delay
        self.result = result
    }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        try await Task.sleep(for: delay)
        return .success("\(result): \(arguments.input)")
    }
}

// MARK: - Response Factories

/// Factory methods for creating CompletionResponse instances with less boilerplate.
enum MockResponse {
    /// Default usage for test responses.
    static let defaultUsage = Usage(inputTokens: 10, outputTokens: 10)

    /// Creates a simple text response.
    static func text(_ content: String, usage: Usage = defaultUsage) -> CompletionResponse {
        CompletionResponse(
            content: content,
            refusal: nil,
            toolCalls: [],
            stopReason: .endTurn,
            usage: usage
        )
    }

    /// Creates a tool call response.
    static func toolCall(
        name: String,
        arguments: String,
        id: String = "call-1",
        usage: Usage = defaultUsage
    ) -> CompletionResponse {
        CompletionResponse(
            content: nil,
            refusal: nil,
            toolCalls: [ToolCall(id: id, name: name, arguments: arguments)],
            stopReason: .toolUse,
            usage: usage
        )
    }

    /// Creates a multi-tool call response.
    static func toolCalls(_ calls: [ToolCall], usage: Usage = defaultUsage) -> CompletionResponse {
        CompletionResponse(
            content: nil,
            refusal: nil,
            toolCalls: calls,
            stopReason: .toolUse,
            usage: usage
        )
    }

    /// Creates a max tokens truncated response.
    static func maxTokens(_ partialContent: String) -> CompletionResponse {
        CompletionResponse(
            content: partialContent,
            refusal: nil,
            toolCalls: [],
            stopReason: .maxTokens,
            usage: Usage(inputTokens: 10, outputTokens: 4096)
        )
    }

    /// Creates a content filtered response.
    static func contentFiltered() -> CompletionResponse {
        CompletionResponse(
            content: nil,
            refusal: nil,
            toolCalls: [],
            stopReason: .contentFiltered,
            usage: Usage(inputTokens: 10, outputTokens: 0)
        )
    }

    /// Creates a refusal response.
    static func refusal(_ reason: String) -> CompletionResponse {
        CompletionResponse(
            content: nil,
            refusal: reason,
            toolCalls: [],
            stopReason: .endTurn,
            usage: defaultUsage
        )
    }

    /// Creates an empty response (no content, no tool calls).
    static func empty() -> CompletionResponse {
        CompletionResponse(
            content: nil,
            refusal: nil,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 0)
        )
    }
}

// MARK: - Test Mock Model

/// A controllable model for testing agent behavior.
/// Simpler alternative: use convenience factories in MockResponse.
actor TestMockModel: Model {
    nonisolated let name: String = "test-mock-model"
    nonisolated let capabilities = ModelCapabilities.claude35

    private var responses: [CompletionResponse] = []
    private var errorToThrow: Error?
    private(set) var callCount: Int = 0

    /// Initialize with a sequence of responses to return.
    init(responses: [CompletionResponse] = []) {
        self.responses = responses
    }

    /// Initialize with a single response.
    init(response: CompletionResponse) {
        self.responses = [response]
    }

    /// Initialize with an error to throw.
    init(error: Error) {
        self.errorToThrow = error
    }

    /// Set responses to return in order.
    func setResponses(_ responses: [CompletionResponse]) {
        self.responses = responses
    }

    /// Set error to throw on next call.
    func setError(_ error: Error?) {
        self.errorToThrow = error
    }

    nonisolated func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        try await nextResponse()
    }

    private func nextResponse() throws -> CompletionResponse {
        callCount += 1

        if let error = errorToThrow {
            throw error
        }

        guard !responses.isEmpty else {
            throw LLMError.serverError("TestMockModel: No responses configured")
        }

        return responses.removeFirst()
    }

    nonisolated func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await self.complete(request)
                    if let content = response.content {
                        continuation.yield(.contentDelta(content))
                    }
                    for call in response.toolCalls {
                        continuation.yield(.toolCallStart(id: call.id, name: call.name))
                        continuation.yield(.toolCallDelta(argumentsDelta: call.arguments))
                        continuation.yield(.toolCallEnd(id: call.id))
                    }
                    continuation.yield(.done(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Reset the model state.
    func reset() {
        responses = []
        errorToThrow = nil
        callCount = 0
    }
}

// MARK: - TestMockModel Convenience Methods

extension TestMockModel {
    /// Configure model to return a text response.
    func setTextResponse(_ text: String) {
        responses = [MockResponse.text(text)]
    }

    /// Configure model to call a tool.
    func setToolCall(name: String, arguments: String, id: String = "call-1") {
        responses = [MockResponse.toolCall(name: name, arguments: arguments, id: id)]
    }

    /// Configure model to call a tool then return text.
    func setToolCallThenText(toolName: String, toolArgs: String, finalText: String) {
        responses = [
            MockResponse.toolCall(name: toolName, arguments: toolArgs),
            MockResponse.text(finalText)
        ]
    }

    /// Configure model to return maxTokens stop reason.
    func setMaxTokensResponse(_ partialContent: String) {
        responses = [MockResponse.maxTokens(partialContent)]
    }

    /// Configure model to return content filtered.
    func setContentFilteredResponse() {
        responses = [MockResponse.contentFiltered()]
    }

    /// Configure model to return a refusal.
    func setRefusalResponse(_ reason: String) {
        responses = [MockResponse.refusal(reason)]
    }
}
