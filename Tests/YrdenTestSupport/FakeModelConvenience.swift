@testable import Yrden

extension FakeModel {
    /// Convenience: model requests one tool call, verifies result comes back,
    /// then returns text.
    ///
    /// This is the most common agentic pattern. The returned FakeModel:
    /// 1. First complete() call: returns a tool call with the given ID
    /// 2. Second complete() call: verifies the agent sent back a toolResult
    ///    with the matching ID, then returns the final text
    ///
    /// ```swift
    /// let model = FakeModel.singleToolCall(
    ///     toolId: "s1", toolName: "search",
    ///     toolArguments: #"{"input":"swift"}"#,
    ///     finalText: "Found 3 results"
    /// )
    /// ```
    public static func singleToolCall(
        toolId: String,
        toolName: String,
        toolArguments: String,
        finalText: String,
        name: String = "fake-model",
        capabilities: ModelCapabilities = .claude35
    ) -> FakeModel {
        let counter = CallCounter()
        return FakeModel(
            name: name,
            capabilities: capabilities,
            onComplete: { request in
                switch await counter.increment() {
                case 1:
                    return MockResponse.toolCall(
                        name: toolName, arguments: toolArguments, id: toolId
                    )
                case 2:
                    guard request.hasToolResult(for: toolId) else {
                        throw LLMError.serverError(
                            "FakeModel.singleToolCall: expected toolResult "
                            + "for '\(toolId)', got IDs: \(request.toolResultIds)"
                        )
                    }
                    return MockResponse.text(finalText)
                default:
                    throw LLMError.serverError("Unexpected call")
                }
            }
        )
    }
}
