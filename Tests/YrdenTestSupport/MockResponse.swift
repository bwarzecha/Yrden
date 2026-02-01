@testable import Yrden

/// Factory methods for creating CompletionResponse instances with less boilerplate.
public enum MockResponse {
    /// Default usage for test responses.
    public static let defaultUsage = Usage(inputTokens: 10, outputTokens: 10)

    /// Creates a simple text response.
    public static func text(
        _ content: String,
        usage: Usage = defaultUsage
    ) -> CompletionResponse {
        CompletionResponse(
            content: content,
            refusal: nil,
            toolCalls: [],
            stopReason: .endTurn,
            usage: usage
        )
    }

    /// Creates a tool call response.
    /// `id` is required — no default. Tool call IDs flow through the system
    /// and must be explicitly tracked in tests.
    public static func toolCall(
        name: String,
        arguments: String,
        id: String,
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
    public static func toolCalls(
        _ calls: [ToolCall],
        usage: Usage = defaultUsage
    ) -> CompletionResponse {
        CompletionResponse(
            content: nil,
            refusal: nil,
            toolCalls: calls,
            stopReason: .toolUse,
            usage: usage
        )
    }

    /// Creates a max tokens truncated response.
    public static func maxTokens(_ partialContent: String) -> CompletionResponse {
        CompletionResponse(
            content: partialContent,
            refusal: nil,
            toolCalls: [],
            stopReason: .maxTokens,
            usage: Usage(inputTokens: 10, outputTokens: 4096)
        )
    }

    /// Creates a content filtered response.
    public static func contentFiltered() -> CompletionResponse {
        CompletionResponse(
            content: nil,
            refusal: nil,
            toolCalls: [],
            stopReason: .contentFiltered,
            usage: Usage(inputTokens: 10, outputTokens: 0)
        )
    }

    /// Creates a refusal response.
    public static func refusal(_ reason: String) -> CompletionResponse {
        CompletionResponse(
            content: nil,
            refusal: reason,
            toolCalls: [],
            stopReason: .endTurn,
            usage: defaultUsage
        )
    }

    /// Creates an empty response (no content, no tool calls).
    public static func empty() -> CompletionResponse {
        CompletionResponse(
            content: nil,
            refusal: nil,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 0)
        )
    }
}
