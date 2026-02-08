/// OpenAI model implementation for both Chat Completions and Responses APIs.
///
/// Implements the `Model` protocol for OpenAI models (GPT-4, GPT-4o, GPT-5, o1, o3).
/// Routes requests between:
/// - **Chat Completions API** — via `ChatCompletionsHandler` (shared with `LocalModel`)
/// - **Responses API** — OpenAI-specific, used for GPT-5 family and simple requests
///
/// ## Usage
/// ```swift
/// let provider = OpenAIProvider(apiKey: "sk-...")
/// let model = OpenAIModel(name: "gpt-4o", provider: provider)
///
/// // Simple completion
/// let response = try await model.complete("What is Swift?")
///
/// // Streaming
/// for try await event in model.stream("Tell me a story") {
///     if case .contentDelta(let text) = event {
///         print(text, terminator: "")
///     }
/// }
/// ```

import Foundation

// MARK: - OpenAIModel

/// Model implementation for the OpenAI API.
public struct OpenAIModel: Model, Sendable {
    /// Provider identifier for cross-provider thinking block handling.
    public static let providerId = "openai"

    /// Model identifier (e.g., "gpt-4o", "o1-mini").
    public let name: String

    /// Capabilities of this model.
    public let capabilities: ModelCapabilities

    /// How to handle thinking blocks from other providers.
    public let foreignThinkingBehavior: ForeignThinkingBehavior

    /// Provider for authentication and connection.
    private let provider: any Provider & OpenAICompatibleProvider

    /// Default max tokens if not specified in request.
    private let defaultMaxTokens: Int

    /// Retry configuration for transient errors.
    private let retryConfig: RetryConfig

    /// Chat Completions wire format handler.
    private let handler: ChatCompletionsHandler

    /// Creates an OpenAI model.
    ///
    /// - Parameters:
    ///   - name: Model identifier (e.g., "gpt-4o", "o1-mini")
    ///   - provider: Provider for authentication
    ///   - defaultMaxTokens: Default max tokens (default: 16384)
    ///   - retryConfig: Retry configuration for transient errors (default: 2 retries)
    ///   - foreignThinkingBehavior: How to handle thinking blocks from other providers (default: .drop)
    public init(
        name: String,
        provider: any Provider & OpenAICompatibleProvider,
        defaultMaxTokens: Int = 16384,
        retryConfig: RetryConfig = .default,
        foreignThinkingBehavior: ForeignThinkingBehavior = .drop
    ) {
        self.name = name
        self.provider = provider
        self.defaultMaxTokens = defaultMaxTokens
        self.retryConfig = retryConfig
        self.foreignThinkingBehavior = foreignThinkingBehavior
        self.capabilities = Self.capabilities(for: name)
        self.handler = ChatCompletionsHandler(
            maxTokensParam: Self.maxTokensParam(for: name),
            toolChoiceStrategy: .requiredFirstTurn,
            foreignThinkingBehavior: foreignThinkingBehavior,
            defaultMaxTokens: defaultMaxTokens,
            providerId: Self.providerId
        )
    }

    // MARK: - Model Protocol

    public func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        try validateRequest(request)

        return try await retryConfig.execute {
            if shouldUseResponsesAPI(request) {
                let responsesRequest = try encodeResponsesRequest(request, stream: false)
                let data = try await sendResponsesRequest(responsesRequest)
                return try decodeResponsesResponse(data)
            } else {
                let openAIRequest = try handler.encodeRequest(request, modelName: name, stream: false)
                let data = try await handler.sendRequest(openAIRequest, provider: provider, modelName: name)
                return try handler.decodeResponse(data, stopSequences: request.config.stopSequences)
            }
        }
    }

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try validateRequest(request)

                    try await retryConfig.execute {
                        if shouldUseResponsesAPI(request) {
                            let responsesRequest = try encodeResponsesRequest(request, stream: true)
                            try await streamResponsesRequest(responsesRequest, continuation: continuation)
                        } else {
                            let openAIRequest = try handler.encodeRequest(request, modelName: name, stream: true)
                            try await handler.streamRequest(
                                openAIRequest,
                                provider: provider,
                                modelName: name,
                                continuation: continuation,
                                stopSequences: request.config.stopSequences
                            )
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - API Routing

    /// Whether this model is in the GPT-5 family (uses reasoning).
    private var isGPT5Family: Bool {
        name.hasPrefix("gpt-5")
    }

    /// Determines whether to use the Responses API or Chat Completions API.
    ///
    /// We use Responses API for:
    /// - GPT-5 family models (better tool calling with reasoning)
    /// - Simple requests without tool results
    ///
    /// We use Chat Completions for:
    /// - Requests with tool results (Responses API requires previous_response_id tracking)
    /// - Multi-turn conversations with complex history
    ///
    /// ## Known Limitations
    ///
    /// The Responses API has a known issue where it doesn't reliably produce multiple
    /// parallel tool calls in a single response, even with `parallel_tool_calls: true`.
    /// This is an OpenAI API limitation, not a client issue.
    /// See: https://community.openai.com/t/chatcompletions-vs-responses-api-difference-in-parallel-tool-call-behaviour-observed/1369663
    private func shouldUseResponsesAPI(_ request: CompletionRequest) -> Bool {
        let hasToolResults = ChatCompletionsHandler.requestHasToolResults(request)

        let hasAssistantToolCalls = request.messages.contains { message in
            if case .assistant(let blocks) = message {
                return blocks.contains { block in
                    if case .toolUse = block { return true }
                    return false
                }
            }
            return false
        }

        let hasStopSequences = !(request.config.stopSequences?.isEmpty ?? true)

        // Use Responses API only for simple tool-calling scenarios (first turn)
        if hasToolResults || hasAssistantToolCalls || hasStopSequences {
            return false
        }

        return true
    }

    // MARK: - Responses API

    private func encodeResponsesRequest(_ request: CompletionRequest, stream: Bool) throws -> ResponsesAPIRequest {
        let responsesTools: [ResponsesAPITool]? = request.tools?.isEmpty == false
            ? request.tools?.map { tool in
                ResponsesAPITool(
                    name: tool.name,
                    description: tool.description,
                    parameters: tool.inputSchema,
                    strict: nil
                )
            }
            : nil

        let inputItems = try request.messages.compactMap { message -> ResponsesInputItem? in
            switch message {
            case .system:
                return nil

            case .user(let parts):
                let contentParts = parts.map { part -> ResponsesContentPart in
                    switch part {
                    case .text(let text):
                        return .inputText(text)
                    case .image(let data, let mimeType):
                        let base64 = data.base64EncodedString()
                        let dataURL = "data:\(mimeType);base64,\(base64)"
                        return .inputImage(url: dataURL)
                    }
                }
                return .message(role: MessageRole.user, content: contentParts)

            case .assistant(let blocks):
                var textContent = ""
                for block in blocks {
                    switch block {
                    case .text(let text):
                        textContent += text
                    case .thinking(let thinkingBlock):
                        if thinkingBlock.provider != Self.providerId {
                            switch foreignThinkingBehavior {
                            case .drop:
                                break
                            case .convertToText:
                                if let content = thinkingBlock.content, !content.isEmpty {
                                    textContent += content
                                }
                            }
                        } else if let content = thinkingBlock.content, !content.isEmpty {
                            textContent += content
                        }
                    case .toolUse:
                        break
                    }
                }
                if !textContent.isEmpty {
                    return .message(role: MessageRole.assistant, content: [.outputText(textContent)])
                }
                return nil

            case .toolResult(let toolCallId, let content):
                return .functionCallOutput(callId: toolCallId, output: content)

            case .toolResults:
                return nil
            }
        }

        let instructions: String? = request.messages.compactMap { message in
            if case .system(let text) = message {
                return text
            }
            return nil
        }.first

        let toolChoice: ResponsesToolChoice? = responsesTools != nil
            ? (ChatCompletionsHandler.requestHasToolResults(request) ? .auto : .required)
            : nil

        let textFormat: ResponsesTextFormat? = request.outputSchema.map { schema in
            ResponsesTextFormat(format: .jsonSchema(name: "response", schema: schema, strict: true))
        }

        let maxTokens = request.config.maxTokens ?? defaultMaxTokens

        return ResponsesAPIRequest(
            model: name,
            input: inputItems.isEmpty ? .text("") : .items(inputItems),
            instructions: instructions,
            tools: responsesTools,
            tool_choice: toolChoice,
            parallel_tool_calls: responsesTools != nil ? true : nil,
            temperature: request.config.temperature,
            top_p: request.config.topP,
            max_output_tokens: maxTokens,
            reasoning: nil,
            text: textFormat,
            stream: stream ? true : nil,
            store: request.config.store,
            prompt_cache_key: request.config.promptCacheKey,
            prompt_cache_retention: request.config.promptCacheRetention?.rawValue
        )
    }

    private func sendResponsesRequest(_ request: ResponsesAPIRequest) async throws -> Data {
        let url = provider.baseURL.appendingPathComponent(OpenAIEndpoint.responses)
        let (data, http) = try await HTTPClient.sendJSONPOST(
            url: url,
            body: request,
            configure: provider.authenticate
        )
        try handler.handleHTTPStatus(
            http.statusCode,
            data: data,
            modelName: name,
            maxContextTokens: capabilities.maxContextTokens,
            retryAfterHeader: http.value(forHTTPHeaderField: HTTPHeaderField.retryAfter)
        )
        return data
    }

    private func decodeResponsesResponse(_ data: Data) throws -> CompletionResponse {
        let response = try JSONDecoder().decode(ResponsesAPIResponse.self, from: data)

        if let error = response.error {
            throw LLMError.invalidRequest(error.message)
        }

        var contentBlocks: [AssistantContentBlock] = []
        var refusal: String?

        for item in response.output {
            switch item {
            case .message(_, _, let contentItems):
                for contentItem in contentItems {
                    switch contentItem {
                    case .outputText(let text, _):
                        if !text.isEmpty {
                            contentBlocks.append(.text(text))
                        }
                    case .refusal(let text):
                        refusal = (refusal ?? "") + text
                    case .unknown:
                        break
                    }
                }

            case .functionCall(_, let callId, let name, let arguments):
                contentBlocks.append(.toolUse(ToolCall(id: callId, name: name, arguments: arguments)))

            case .reasoning(_, _, let summary):
                if let summaryTexts = summary {
                    let combinedSummary = summaryTexts.joined(separator: "\n")
                    if !combinedSummary.isEmpty {
                        contentBlocks.append(.thinking(ThinkingBlock(
                            content: combinedSummary,
                            providerData: nil,
                            provider: Self.providerId
                        )))
                    }
                }

            case .unknown:
                break
            }
        }

        let stopReason: StopReason
        if contentBlocks.contains(where: { if case .toolUse = $0 { return true } else { return false } }) {
            stopReason = .toolUse
        } else if response.status == "incomplete" {
            if response.incomplete_details?.reason == OpenAIIncompleteReason.maxOutputTokens {
                stopReason = .maxTokens
            } else if response.incomplete_details?.reason == OpenAIIncompleteReason.contentFilter {
                stopReason = .contentFiltered
            } else {
                stopReason = .endTurn
            }
        } else {
            stopReason = .endTurn
        }

        let usage = Usage(
            inputTokens: response.usage?.input_tokens ?? 0,
            outputTokens: response.usage?.output_tokens ?? 0,
            cachedTokens: response.usage?.input_tokens_details?.cached_tokens,
            reasoningTokens: response.usage?.output_tokens_details?.reasoning_tokens
        )

        return CompletionResponse(
            contentBlocks: contentBlocks,
            refusal: refusal,
            stopReason: stopReason,
            usage: usage
        )
    }

    private func streamResponsesRequest(
        _ request: ResponsesAPIRequest,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let url = provider.baseURL.appendingPathComponent(OpenAIEndpoint.responses)
        let (bytes, http) = try await HTTPClient.streamJSONPOST(
            url: url,
            body: request,
            configure: provider.authenticate
        )

        if http.statusCode != 200 {
            let errorData = try await HTTPClient.collectErrorData(from: bytes)
            try handler.handleHTTPStatus(
                http.statusCode,
                data: errorData,
                modelName: name,
                maxContextTokens: capabilities.maxContextTokens,
                retryAfterHeader: http.value(forHTTPHeaderField: HTTPHeaderField.retryAfter)
            )
            return
        }

        var accumulatedContent = ""
        var accumulatedRefusal = ""
        var accumulatedToolCalls: [String: (name: String, arguments: String)] = [:]
        var itemIdToCallId: [String: String] = [:]
        var inputTokens = 0
        var outputTokens = 0
        var cachedTokens: Int?
        var reasoningTokens: Int?
        var responseStatus: String?
        var incompleteReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix(SSE.dataPrefix) else { continue }
            let data = String(line.dropFirst(SSE.dataPrefixLength))

            if data == SSE.done {
                break
            }

            guard let jsonData = data.data(using: .utf8) else { continue }

            guard let event = try? JSONDecoder().decode(ResponsesStreamEvent.self, from: jsonData) else {
                continue
            }

            switch event.type {
            case "response.text.delta", "response.output_text.delta":
                if let delta = event.delta {
                    accumulatedContent += delta
                    continuation.yield(.contentDelta(delta))
                }

            case "response.refusal.delta":
                if let delta = event.delta {
                    accumulatedRefusal += delta
                }

            case "response.function_call_arguments.delta":
                if let delta = event.delta {
                    let itemId = event.item_id ?? event.item?.id
                    if let itemId = itemId, let callId = itemIdToCallId[itemId] {
                        var existing = accumulatedToolCalls[callId] ?? (name: "", arguments: "")
                        existing.arguments += delta
                        accumulatedToolCalls[callId] = existing
                        continuation.yield(.toolCallDelta(argumentsDelta: delta))
                    }
                }

            case "response.output_item.added":
                if let item = event.item, item.type == ResponsesOutputType.functionCall {
                    if let itemId = item.id, let callId = item.call_id, let name = item.name {
                        itemIdToCallId[itemId] = callId
                        accumulatedToolCalls[callId] = (name: name, arguments: "")
                        continuation.yield(.toolCallStart(id: callId, name: name))
                    }
                }

            case "response.output_item.done":
                if let item = event.item, item.type == ResponsesOutputType.functionCall {
                    let itemId = item.id
                    if let itemId = itemId, let callId = itemIdToCallId[itemId] {
                        continuation.yield(.toolCallEnd(id: callId))
                    }
                }

            case "response.completed":
                if let resp = event.response {
                    responseStatus = resp.status
                    incompleteReason = resp.incomplete_details?.reason
                    if let usage = resp.usage {
                        inputTokens = usage.input_tokens
                        outputTokens = usage.output_tokens
                        cachedTokens = usage.input_tokens_details?.cached_tokens
                        reasoningTokens = usage.output_tokens_details?.reasoning_tokens
                    }
                }

            default:
                break
            }
        }

        var contentBlocks: [AssistantContentBlock] = []
        if !accumulatedContent.isEmpty {
            contentBlocks.append(.text(accumulatedContent))
        }
        for (callId, data) in accumulatedToolCalls {
            contentBlocks.append(.toolUse(ToolCall(id: callId, name: data.name, arguments: data.arguments)))
        }

        let stopReason: StopReason
        if !accumulatedToolCalls.isEmpty {
            stopReason = .toolUse
        } else if responseStatus == "incomplete" {
            if incompleteReason == OpenAIIncompleteReason.maxOutputTokens {
                stopReason = .maxTokens
            } else if incompleteReason == OpenAIIncompleteReason.contentFilter {
                stopReason = .contentFiltered
            } else {
                stopReason = .endTurn
            }
        } else {
            stopReason = .endTurn
        }

        let completionResponse = CompletionResponse(
            contentBlocks: contentBlocks,
            refusal: accumulatedRefusal.isEmpty ? nil : accumulatedRefusal,
            stopReason: stopReason,
            usage: Usage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedTokens: cachedTokens,
                reasoningTokens: reasoningTokens
            )
        )

        continuation.yield(.done(completionResponse))
        continuation.finish()
    }

    // MARK: - Capabilities

    /// Determine max tokens parameter style for a given model name.
    private static func maxTokensParam(for modelName: String) -> MaxTokensParam {
        if modelName.hasPrefix("gpt-5") ||
           modelName.hasPrefix("o3") ||
           modelName.hasPrefix("o1") ||
           modelName.hasPrefix("gpt-4.1") {
            return .completionTokens
        }
        return .legacy
    }

    private static func capabilities(for modelName: String) -> ModelCapabilities {
        if modelName.hasPrefix("gpt-5") {
            return .gpt5
        }
        if modelName.hasPrefix("gpt-4.1") {
            return .gpt41
        }
        if modelName.hasPrefix("gpt-4o") {
            return .gpt4o
        }
        if modelName.hasPrefix("gpt-4-turbo") || modelName == "gpt-4-1106-preview" || modelName == "gpt-4-0125-preview" {
            return .gpt4Turbo
        }
        if modelName.hasPrefix("o4") {
            return .o4
        }
        if modelName.hasPrefix("o3") {
            return .o3
        }
        if modelName.hasPrefix("o1") {
            return .o1
        }
        if modelName.hasPrefix("gpt-4") {
            return .gpt4Turbo
        }
        if modelName.hasPrefix("gpt-3.5") {
            return ModelCapabilities(
                supportsTemperature: true,
                supportsTools: true,
                supportsVision: false,
                supportsStructuredOutput: true,
                supportsSystemMessage: true,
                maxContextTokens: 16_385
            )
        }
        // Default to GPT-5 capabilities for unknown models
        return .gpt5
    }
}
