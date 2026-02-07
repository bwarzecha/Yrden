/// OpenAI model implementation for the Chat Completions API.
///
/// Implements the `Model` protocol for OpenAI models (GPT-4, GPT-4o, o1, o3).
/// Handles:
/// - Request encoding (converting Yrden types to OpenAI format)
/// - Response decoding (converting OpenAI format to Yrden types)
/// - Streaming via SSE
/// - Error mapping
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

/// Model implementation for the OpenAI Chat Completions API.
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

    /// Creates an OpenAI model.
    ///
    /// - Parameters:
    ///   - name: Model identifier (e.g., "gpt-4o", "o1-mini")
    ///   - provider: Provider for authentication
    ///   - defaultMaxTokens: Default max tokens (default: 4096)
    ///   - retryConfig: Retry configuration for transient errors (default: 2 retries)
    ///   - foreignThinkingBehavior: How to handle thinking blocks from other providers (default: .drop)
    public init(
        name: String,
        provider: any Provider & OpenAICompatibleProvider,
        defaultMaxTokens: Int = 4096,
        retryConfig: RetryConfig = .default,
        foreignThinkingBehavior: ForeignThinkingBehavior = .drop
    ) {
        self.name = name
        self.provider = provider
        self.defaultMaxTokens = defaultMaxTokens
        self.retryConfig = retryConfig
        self.foreignThinkingBehavior = foreignThinkingBehavior
        self.capabilities = Self.capabilities(for: name)
    }

    // MARK: - Model Protocol

    public func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        try validateRequest(request)

        // Use Responses API for simple requests, Chat Completions for complex multi-turn with tool results
        // The Responses API requires previous_response_id for tool result handling, which we don't track
        return try await retryConfig.execute {
            if shouldUseResponsesAPI(request) {
                let responsesRequest = try encodeResponsesRequest(request, stream: false)
                let data = try await sendResponsesRequest(responsesRequest)
                return try decodeResponsesResponse(data)
            } else {
                let openAIRequest = try encodeRequest(request, stream: false)
                let data = try await sendRequest(openAIRequest)
                return try decodeResponse(data, stopSequences: request.config.stopSequences)
            }
        }
    }

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try validateRequest(request)

                    // Retry the entire stream on transient errors
                    try await retryConfig.execute {
                        if shouldUseResponsesAPI(request) {
                            let responsesRequest = try encodeResponsesRequest(request, stream: true)
                            try await streamResponsesRequest(responsesRequest, continuation: continuation)
                        } else {
                            let openAIRequest = try encodeRequest(request, stream: true)
                            try await streamRequest(
                                openAIRequest,
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
    /// Whether the request contains tool results from previous tool calls.
    /// Used to determine API routing and tool_choice behavior.
    private func requestHasToolResults(_ request: CompletionRequest) -> Bool {
        request.messages.contains { message in
            switch message {
            case .toolResult, .toolResults: return true
            default: return false
            }
        }
    }

    private func shouldUseResponsesAPI(_ request: CompletionRequest) -> Bool {
        let hasToolResults = requestHasToolResults(request)

        // Check if request has assistant messages with tool calls
        let hasAssistantToolCalls = request.messages.contains { message in
            if case .assistant(let blocks) = message {
                return blocks.contains { block in
                    if case .toolUse = block { return true }
                    return false
                }
            }
            return false
        }

        // Check if request uses stop sequences - not supported by Responses API
        let hasStopSequences = !(request.config.stopSequences?.isEmpty ?? true)

        // Use Responses API only for simple tool-calling scenarios (first turn)
        // Complex multi-turn with tool results should use Chat Completions
        // Stop sequences also require Chat Completions API
        if hasToolResults || hasAssistantToolCalls || hasStopSequences {
            return false
        }

        // For GPT-5 family, prefer Responses API for better tool calling
        // For other models, also use Responses API for consistency (better caching)
        return true
    }

    // MARK: - Chat Completions Request Encoding (for non-GPT-5 models)

    private func encodeRequest(_ request: CompletionRequest, stream: Bool) throws -> OpenAIRequest {
        // Convert tools
        let openAITools: [OpenAITool]? = request.tools?.isEmpty == false
            ? request.tools?.map { convertTool($0) }
            : nil

        // Convert messages (expanding toolResults into individual messages)
        let openAIMessages = try request.messages.flatMap { try convertMessages($0) }

        let maxTokens = request.config.maxTokens ?? defaultMaxTokens

        // Newer models (gpt-5.x, o3, o1, gpt-4.1) use max_completion_tokens instead of max_tokens
        let usesMaxCompletionTokens = name.hasPrefix("gpt-5") ||
                                      name.hasPrefix("o3") ||
                                      name.hasPrefix("o1") ||
                                      name.hasPrefix("gpt-4.1")

        // Convert output schema to response format
        let responseFormat: OpenAIResponseFormat? = request.outputSchema.map { schema in
            .jsonSchema(name: "response", schema: schema, strict: true)
        }

        // Determine tool_choice:
        // - Use .required when tools are provided and no tool results yet (forces tool use)
        // - Use .auto when conversation already has tool results (let model respond naturally)
        let toolChoice: OpenAIToolChoice? = openAITools != nil
            ? (requestHasToolResults(request) ? .auto : .required)
            : nil

        // Build request (no reasoning_effort for Chat Completions - that's for Responses API)
        return OpenAIRequest(
            model: name,
            messages: openAIMessages,
            max_tokens: usesMaxCompletionTokens ? nil : maxTokens,
            max_completion_tokens: usesMaxCompletionTokens ? maxTokens : nil,
            temperature: request.config.temperature,
            stop: request.config.stopSequences,
            tools: openAITools,
            tool_choice: toolChoice,
            response_format: responseFormat,
            stream: stream ? true : nil,
            stream_options: stream ? OpenAIStreamOptions(include_usage: true) : nil,
            reasoning_effort: nil
        )
    }

    private func convertMessage(_ message: Message) throws -> OpenAIMessage {
        switch message {
        case .system(let text):
            return OpenAIMessage(
                role: MessageRole.system,
                content: .text(text)
            )

        case .user(let parts):
            if parts.count == 1, case .text(let text) = parts[0] {
                // Simple text - use string content
                return OpenAIMessage(
                    role: MessageRole.user,
                    content: .text(text)
                )
            } else {
                // Multimodal - use parts array
                let openAIParts = try parts.map { try convertContentPart($0) }
                return OpenAIMessage(
                    role: MessageRole.user,
                    content: .parts(openAIParts)
                )
            }

        case .assistant(let blocks):
            var textContent = ""
            var toolCalls: [OpenAIToolCall] = []

            for block in blocks {
                switch block {
                case .text(let text):
                    textContent += text
                case .thinking(let thinkingBlock):
                    // Handle thinking blocks based on provider
                    if thinkingBlock.provider == Self.providerId {
                        // Native OpenAI thinking - no special handling needed
                        if let content = thinkingBlock.content, !content.isEmpty {
                            textContent += content
                        }
                    } else {
                        // Foreign thinking block
                        switch foreignThinkingBehavior {
                        case .drop:
                            // Skip entirely
                            break
                        case .convertToText:
                            if let content = thinkingBlock.content, !content.isEmpty {
                                textContent += content
                            }
                        }
                    }
                case .toolUse(let call):
                    toolCalls.append(OpenAIToolCall(
                        id: call.id,
                        type: ToolType.function,
                        function: OpenAIFunctionCall(name: call.name, arguments: call.arguments)
                    ))
                }
            }

            return OpenAIMessage(
                role: MessageRole.assistant,
                content: textContent.isEmpty ? nil : .text(textContent),
                tool_calls: toolCalls.isEmpty ? nil : toolCalls
            )

        case .toolResult(let toolCallId, let content):
            return OpenAIMessage(
                role: MessageRole.tool,
                content: .text(content),
                tool_call_id: toolCallId
            )

        case .toolResults:
            // Handled by convertMessages
            throw LLMError.invalidRequest("toolResults should use convertMessages")
        }
    }

    /// Convert a message to OpenAI format, expanding toolResults into multiple messages.
    private func convertMessages(_ message: Message) throws -> [OpenAIMessage] {
        switch message {
        case .toolResults(let results):
            // OpenAI uses separate tool messages for each result
            return results.map { entry in
                let content: String
                switch entry.output {
                case .text(let text):
                    content = text
                case .json:
                    content = entry.output.jsonString ?? "{}"
                case .error(let message):
                    content = "Error: \(message)"
                }
                return OpenAIMessage(
                    role: MessageRole.tool,
                    content: .text(content),
                    tool_call_id: entry.id
                )
            }
        default:
            return [try convertMessage(message)]
        }
    }

    private func convertContentPart(_ part: ContentPart) throws -> OpenAIContentPart {
        switch part {
        case .text(let text):
            return .text(text)

        case .image(let data, let mimeType):
            // OpenAI uses data URLs for inline images
            let base64 = data.base64EncodedString()
            let dataURL = "data:\(mimeType);base64,\(base64)"
            return .imageURL(url: dataURL, detail: nil)
        }
    }

    private func convertTool(_ tool: ToolDefinition) -> OpenAITool {
        OpenAITool(
            function: OpenAIFunction(
                name: tool.name,
                description: tool.description,
                parameters: tool.inputSchema,
                strict: nil  // Strict mode requires all properties in 'required'
            )
        )
    }

    // MARK: - Response Decoding

    private func decodeResponse(_ data: Data, stopSequences: [String]? = nil) throws -> CompletionResponse {
        let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)

        guard let choice = response.choices.first else {
            throw LLMError.decodingError("No choices in response")
        }

        // Build content blocks preserving order
        var contentBlocks: [AssistantContentBlock] = []

        if let content = choice.message.content, !content.isEmpty {
            contentBlocks.append(.text(content))
        }

        if let toolCalls = choice.message.tool_calls {
            for call in toolCalls {
                contentBlocks.append(.toolUse(ToolCall(
                    id: call.id,
                    name: call.function.name,
                    arguments: call.function.arguments
                )))
            }
        }

        let hasStopSequences = stopSequences?.isEmpty == false
        let stopReason = StopReason.from(openAIReason: choice.finish_reason, hasStopSequences: hasStopSequences)
        let usage = Usage(
            inputTokens: response.usage?.prompt_tokens ?? 0,
            outputTokens: response.usage?.completion_tokens ?? 0
        )

        return CompletionResponse(
            contentBlocks: contentBlocks,
            stopReason: stopReason,
            usage: usage
        )
    }

    // MARK: - HTTP

    private func sendRequest(_ request: OpenAIRequest) async throws -> Data {
        let url = provider.baseURL.appendingPathComponent(OpenAIEndpoint.chatCompletions)
        let (data, http) = try await HTTPClient.sendJSONPOST(
            url: url,
            body: request,
            configure: provider.authenticate
        )
        try handleHTTPStatus(http.statusCode, data: data, retryAfterHeader: http.value(forHTTPHeaderField: HTTPHeaderField.retryAfter))
        return data
    }

    private func handleHTTPStatus(_ statusCode: Int, data: Data, retryAfterHeader: String? = nil) throws {
        switch statusCode {
        case 200..<300:
            return

        case 401:
            throw LLMError.invalidAPIKey

        case 400:
            let message = parseErrorMessage(data)
            // Check for context length error
            if message.contains("maximum context length") {
                throw LLMError.contextLengthExceeded(maxTokens: capabilities.maxContextTokens ?? 0)
            }
            throw LLMError.invalidRequest(message)

        case 404:
            throw LLMError.modelNotFound(name)

        default:
            let message = parseErrorMessage(data)
            let underlyingError = LLMError.networkError("HTTP \(statusCode): \(message)")

            // Check if this is a retriable error (408, 409, 429, 500+)
            if isRetriableStatusCode(statusCode) {
                let retryAfter = HTTPClient.parseRetryAfter(retryAfterHeader)
                throw RetriableError(
                    underlyingError: underlyingError,
                    retryAfter: retryAfter,
                    statusCode: statusCode
                )
            }

            throw underlyingError
        }
    }

    private func parseErrorMessage(_ data: Data) -> String {
        if let error = try? JSONDecoder().decode(OpenAIError.self, from: data) {
            return error.error.message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }

    // MARK: - Streaming (Chat Completions)

    private func streamRequest(
        _ request: OpenAIRequest,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        stopSequences: [String]? = nil
    ) async throws {
        let url = provider.baseURL.appendingPathComponent(OpenAIEndpoint.chatCompletions)
        let (bytes, http) = try await HTTPClient.streamJSONPOST(
            url: url,
            body: request,
            configure: provider.authenticate
        )

        if http.statusCode != 200 {
            let errorData = try await HTTPClient.collectErrorData(from: bytes)
            try handleHTTPStatus(http.statusCode, data: errorData, retryAfterHeader: http.value(forHTTPHeaderField: HTTPHeaderField.retryAfter))
            return
        }

        var accumulatedContent = ""
        var accumulatedToolCalls: [ToolCallAccumulator] = []
        var inputTokens = 0
        var outputTokens = 0
        var lastFinishReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix(SSE.dataPrefix) else { continue }
            let data = String(line.dropFirst(SSE.dataPrefixLength))

            // Check for stream end
            if data == SSE.done {
                break
            }

            guard let jsonData = data.data(using: .utf8) else { continue }

            let chunk: OpenAIStreamChunk
            do {
                chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: jsonData)
            } catch {
                // Skip malformed chunks
                continue
            }

            // Process the chunk
            if let choice = chunk.choices.first {
                // Content delta
                if let content = choice.delta.content {
                    accumulatedContent += content
                    continuation.yield(.contentDelta(content))
                }

                // Tool call deltas
                if let toolCalls = choice.delta.tool_calls {
                    for tc in toolCalls {
                        processToolCallDelta(
                            tc,
                            continuation: continuation,
                            accumulatedToolCalls: &accumulatedToolCalls
                        )
                    }
                }

                // Finish reason
                if let reason = choice.finish_reason {
                    lastFinishReason = reason
                }
            }

            // Usage (only in final chunk with stream_options.include_usage)
            if let usage = chunk.usage {
                inputTokens = usage.prompt_tokens
                outputTokens = usage.completion_tokens
            }
        }

        // Emit toolCallEnd for any remaining tool calls
        for toolCall in accumulatedToolCalls where !toolCall.ended {
            continuation.yield(.toolCallEnd(id: toolCall.id))
        }

        // Build final response with content blocks
        var contentBlocks: [AssistantContentBlock] = []
        if !accumulatedContent.isEmpty {
            contentBlocks.append(.text(accumulatedContent))
        }
        for acc in accumulatedToolCalls {
            contentBlocks.append(.toolUse(ToolCall(id: acc.id, name: acc.name, arguments: acc.arguments)))
        }

        let hasStopSequences = stopSequences?.isEmpty == false
        let completionResponse = CompletionResponse(
            contentBlocks: contentBlocks,
            stopReason: StopReason.from(openAIReason: lastFinishReason, hasStopSequences: hasStopSequences),
            usage: Usage(inputTokens: inputTokens, outputTokens: outputTokens)
        )

        continuation.yield(.done(completionResponse))
        continuation.finish()
    }

    private func processToolCallDelta(
        _ delta: OpenAIStreamToolCall,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        accumulatedToolCalls: inout [ToolCallAccumulator]
    ) {
        let index = delta.index

        // Ensure we have an accumulator for this index
        while accumulatedToolCalls.count <= index {
            accumulatedToolCalls.append(ToolCallAccumulator())
        }

        var acc = accumulatedToolCalls[index]

        // First chunk has id and name
        if let id = delta.id {
            acc.id = id
        }
        if let function = delta.function {
            if let name = function.name {
                acc.name = name
                // Emit toolCallStart when we have both id and name
                if !acc.id.isEmpty && !acc.name.isEmpty && !acc.started {
                    acc.started = true
                    continuation.yield(.toolCallStart(id: acc.id, name: acc.name))
                }
            }
            if let args = function.arguments {
                acc.arguments += args
                continuation.yield(.toolCallDelta(argumentsDelta: args))
            }
        }

        accumulatedToolCalls[index] = acc
    }

    // MARK: - Responses API (GPT-5 Family)

    private func encodeResponsesRequest(_ request: CompletionRequest, stream: Bool) throws -> ResponsesAPIRequest {
        // Convert tools to Responses API format
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

        // Convert messages to Responses API input format
        let inputItems = try request.messages.compactMap { message -> ResponsesInputItem? in
            switch message {
            case .system:
                // System message becomes instructions, not input
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
                // For assistant messages, use output_text content type
                // Tool calls are implicit in the conversation flow
                var textContent = ""
                for block in blocks {
                    switch block {
                    case .text(let text):
                        textContent += text
                    case .thinking(let thinkingBlock):
                        // Handle foreign thinking for Responses API
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
                        // Tool calls are implicit in the conversation flow
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
                // This shouldn't happen for Responses API - it should use Chat Completions
                return nil
            }
        }

        // Extract system message as instructions
        let instructions: String? = request.messages.compactMap { message in
            if case .system(let text) = message {
                return text
            }
            return nil
        }.first

        // Determine tool_choice
        let toolChoice: ResponsesToolChoice? = responsesTools != nil
            ? (requestHasToolResults(request) ? .auto : .required)
            : nil

        // Configure output format for structured output
        let textFormat: ResponsesTextFormat? = request.outputSchema.map { schema in
            ResponsesTextFormat(format: .jsonSchema(name: "response", schema: schema, strict: true))
        }

        // Don't set reasoning effort - let the API use its default

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
        try handleHTTPStatus(http.statusCode, data: data, retryAfterHeader: http.value(forHTTPHeaderField: HTTPHeaderField.retryAfter))
        return data
    }

    private func decodeResponsesResponse(_ data: Data) throws -> CompletionResponse {
        let response = try JSONDecoder().decode(ResponsesAPIResponse.self, from: data)

        // Check for errors
        if let error = response.error {
            throw LLMError.invalidRequest(error.message)
        }

        // Build content blocks preserving order
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
                // Extract reasoning summary as thinking block
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

        // Determine stop reason from response status and incomplete_details
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

        // Extract detailed usage including cached and reasoning tokens
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
            try handleHTTPStatus(http.statusCode, data: errorData, retryAfterHeader: http.value(forHTTPHeaderField: HTTPHeaderField.retryAfter))
            return
        }

        var accumulatedContent = ""
        var accumulatedRefusal = ""
        // Map from call_id -> (name, arguments) for final response
        var accumulatedToolCalls: [String: (name: String, arguments: String)] = [:]
        // Map from item_id -> call_id (to resolve delta events)
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

            // Check for stream end
            if data == SSE.done {
                break
            }

            guard let jsonData = data.data(using: .utf8) else { continue }

            // Parse streaming event
            guard let event = try? JSONDecoder().decode(ResponsesStreamEvent.self, from: jsonData) else {
                continue
            }

            switch event.type {
            // Text content events
            case "response.text.delta", "response.output_text.delta":
                if let delta = event.delta {
                    accumulatedContent += delta
                    continuation.yield(.contentDelta(delta))
                }

            // Refusal events
            case "response.refusal.delta":
                if let delta = event.delta {
                    accumulatedRefusal += delta
                }

            // Function call argument events - uses item_id to reference the tool call
            case "response.function_call_arguments.delta":
                if let delta = event.delta {
                    // Look up call_id from item_id
                    let itemId = event.item_id ?? event.item?.id
                    if let itemId = itemId, let callId = itemIdToCallId[itemId] {
                        var existing = accumulatedToolCalls[callId] ?? (name: "", arguments: "")
                        existing.arguments += delta
                        accumulatedToolCalls[callId] = existing
                        continuation.yield(.toolCallDelta(argumentsDelta: delta))
                    }
                }

            // Output item added - capture the item_id -> call_id mapping
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

        // Build final response with content blocks
        var contentBlocks: [AssistantContentBlock] = []
        if !accumulatedContent.isEmpty {
            contentBlocks.append(.text(accumulatedContent))
        }
        for (callId, data) in accumulatedToolCalls {
            contentBlocks.append(.toolUse(ToolCall(id: callId, name: data.name, arguments: data.arguments)))
        }

        // Determine stop reason from response status and incomplete_details
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

    private static func capabilities(for modelName: String) -> ModelCapabilities {
        // GPT-5.x family - flagship models with full capabilities
        // 400K context, 128K max output
        if modelName.hasPrefix("gpt-5") {
            return .gpt5
        }

        // GPT-4.1 family - 1M context, 32K max output
        if modelName.hasPrefix("gpt-4.1") {
            return .gpt41
        }

        // GPT-4o and GPT-4o-mini - 128K context, 16K max output
        if modelName.hasPrefix("gpt-4o") {
            return .gpt4o
        }

        // GPT-4 Turbo - 128K context
        if modelName.hasPrefix("gpt-4-turbo") || modelName == "gpt-4-1106-preview" || modelName == "gpt-4-0125-preview" {
            return .gpt4Turbo
        }

        // o4 family - 200K context, 100K max output
        if modelName.hasPrefix("o4") {
            return .o4
        }

        // o3 family - 200K context, 100K max output (has tools and vision)
        if modelName.hasPrefix("o3") {
            return .o3
        }

        // o1 family - 200K context, 100K max output (significant limitations)
        if modelName.hasPrefix("o1") {
            return .o1
        }

        // GPT-4 base (older, less capable than turbo/o)
        if modelName.hasPrefix("gpt-4") {
            return .gpt4Turbo
        }

        // GPT-3.5 Turbo - 16K context
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

// MARK: - Tool Call Accumulator

/// Helper for accumulating streaming tool call data.
private struct ToolCallAccumulator {
    var id: String = ""
    var name: String = ""
    var arguments: String = ""
    var started: Bool = false
    var ended: Bool = false
}
