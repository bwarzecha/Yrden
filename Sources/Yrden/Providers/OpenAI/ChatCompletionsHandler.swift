/// Shared handler for the OpenAI Chat Completions wire format.
///
/// Encapsulates encoding, decoding, HTTP, and streaming for the
/// `/v1/chat/completions` endpoint. Used by both `OpenAIModel` (with
/// OpenAI-specific settings) and `LocalModel` (with conservative defaults
/// for Ollama, LM Studio, vLLM, etc.).
///
/// This handler is parameterized to avoid model-name sniffing:
/// - `maxTokensParam`: Whether to use `max_tokens` or `max_completion_tokens`
/// - `toolChoiceStrategy`: Whether to force tool use on the first turn

import Foundation

// MARK: - Configuration

/// How to encode the max tokens parameter in Chat Completions requests.
enum MaxTokensParam: Sendable {
    /// Use `max_tokens` (legacy). Works with all OpenAI-compatible servers.
    case legacy
    /// Use `max_completion_tokens` (newer OpenAI models: gpt-5, o3, o1, gpt-4.1).
    case completionTokens
}

/// How to set `tool_choice` when tools are present.
enum ToolChoiceStrategy: Sendable {
    /// Always use `"auto"`. Safe for local servers that may not support `"required"`.
    case alwaysAuto
    /// Use `"required"` on the first turn (no tool results yet), `"auto"` on subsequent turns.
    /// This is OpenAI's aggressive mode that forces the model to call a tool.
    case requiredFirstTurn
}

// MARK: - ChatCompletionsHandler

/// Internal handler for the OpenAI Chat Completions API wire format.
///
/// Stores encoding configuration at init. Takes `provider` per-call for HTTP.
struct ChatCompletionsHandler: Sendable {
    let maxTokensParam: MaxTokensParam
    let toolChoiceStrategy: ToolChoiceStrategy
    let foreignThinkingBehavior: ForeignThinkingBehavior
    /// Default max tokens when not specified in request. Nil means omit (let server decide).
    let defaultMaxTokens: Int?
    /// Provider ID for thinking block handling (e.g., "openai", "local").
    let providerId: String

    // MARK: - Request Encoding

    func encodeRequest(
        _ request: CompletionRequest,
        modelName: String,
        stream: Bool
    ) throws -> OpenAIRequest {
        // Convert tools
        let openAITools: [OpenAITool]? = request.tools?.isEmpty == false
            ? request.tools?.map { convertTool($0) }
            : nil

        // Convert messages (expanding toolResults into individual messages)
        let openAIMessages = try request.messages.flatMap { try convertMessages($0) }

        let maxTokens: Int?
        if let explicit = request.config.maxTokens {
            maxTokens = explicit
        } else {
            maxTokens = defaultMaxTokens
        }

        // Convert output schema to response format
        let responseFormat: OpenAIResponseFormat? = request.outputSchema.map { schema in
            .jsonSchema(name: "response", schema: schema, strict: true)
        }

        // Determine tool_choice based on strategy
        let toolChoice: OpenAIToolChoice?
        if let _ = openAITools {
            switch toolChoiceStrategy {
            case .alwaysAuto:
                toolChoice = .auto
            case .requiredFirstTurn:
                toolChoice = Self.requestHasToolResults(request) ? .auto : .required
            }
        } else {
            toolChoice = nil
        }

        return OpenAIRequest(
            model: modelName,
            messages: openAIMessages,
            max_tokens: maxTokensParam == .completionTokens ? nil : maxTokens,
            max_completion_tokens: maxTokensParam == .completionTokens ? maxTokens : nil,
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

    // MARK: - Response Decoding

    func decodeResponse(_ data: Data, stopSequences: [String]? = nil) throws -> CompletionResponse {
        let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)

        guard let choice = response.choices.first else {
            throw LLMError.decodingError("No choices in response")
        }

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

    func sendRequest(
        _ request: OpenAIRequest,
        provider: any Provider & OpenAICompatibleProvider,
        modelName: String
    ) async throws -> Data {
        let url = provider.baseURL.appendingPathComponent(OpenAIEndpoint.chatCompletions)
        let (data, http) = try await HTTPClient.sendJSONPOST(
            url: url,
            body: request,
            configure: provider.authenticate
        )
        try handleHTTPStatus(
            http.statusCode,
            data: data,
            modelName: modelName,
            maxContextTokens: nil,
            retryAfterHeader: http.value(forHTTPHeaderField: HTTPHeaderField.retryAfter)
        )
        return data
    }

    func handleHTTPStatus(
        _ statusCode: Int,
        data: Data,
        modelName: String,
        maxContextTokens: Int?,
        retryAfterHeader: String? = nil
    ) throws {
        switch statusCode {
        case 200..<300:
            return

        case 401:
            throw LLMError.invalidAPIKey

        case 400:
            let message = parseErrorMessage(data)
            if message.contains("maximum context length") {
                throw LLMError.contextLengthExceeded(maxTokens: maxContextTokens ?? 0)
            }
            throw LLMError.invalidRequest(message)

        case 404:
            throw LLMError.modelNotFound(modelName)

        default:
            let message = parseErrorMessage(data)
            let underlyingError = LLMError.networkError("HTTP \(statusCode): \(message)")

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

    func parseErrorMessage(_ data: Data) -> String {
        if let error = try? JSONDecoder().decode(OpenAIError.self, from: data) {
            return error.error.message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }

    // MARK: - Streaming

    func streamRequest(
        _ request: OpenAIRequest,
        provider: any Provider & OpenAICompatibleProvider,
        modelName: String,
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
            try handleHTTPStatus(
                http.statusCode,
                data: errorData,
                modelName: modelName,
                maxContextTokens: nil,
                retryAfterHeader: http.value(forHTTPHeaderField: HTTPHeaderField.retryAfter)
            )
            return
        }

        var accumulatedContent = ""
        var accumulatedToolCalls: [OpenAIToolCallAccumulator] = []
        var inputTokens = 0
        var outputTokens = 0
        var lastFinishReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix(SSE.dataPrefix) else { continue }
            let data = String(line.dropFirst(SSE.dataPrefixLength))

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

            if let choice = chunk.choices.first {
                if let content = choice.delta.content {
                    accumulatedContent += content
                    continuation.yield(.contentDelta(content))
                }

                if let toolCalls = choice.delta.tool_calls {
                    for tc in toolCalls {
                        processToolCallDelta(
                            tc,
                            continuation: continuation,
                            accumulatedToolCalls: &accumulatedToolCalls
                        )
                    }
                }

                if let reason = choice.finish_reason {
                    lastFinishReason = reason
                }
            }

            if let usage = chunk.usage {
                inputTokens = usage.prompt_tokens
                outputTokens = usage.completion_tokens
            }
        }

        // Emit toolCallEnd for any remaining tool calls
        for toolCall in accumulatedToolCalls where !toolCall.ended {
            continuation.yield(.toolCallEnd(id: toolCall.id))
        }

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

    // MARK: - Message Conversion

    func convertMessage(_ message: Message) throws -> OpenAIMessage {
        switch message {
        case .system(let text):
            return OpenAIMessage(
                role: MessageRole.system,
                content: .text(text)
            )

        case .user(let parts):
            if parts.count == 1, case .text(let text) = parts[0] {
                return OpenAIMessage(
                    role: MessageRole.user,
                    content: .text(text)
                )
            } else {
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
                    if thinkingBlock.provider == providerId {
                        if let content = thinkingBlock.content, !content.isEmpty {
                            textContent += content
                        }
                    } else {
                        switch foreignThinkingBehavior {
                        case .drop:
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
            throw LLMError.invalidRequest("toolResults should use convertMessages")
        }
    }

    func convertMessages(_ message: Message) throws -> [OpenAIMessage] {
        switch message {
        case .toolResults(let results):
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

    func convertContentPart(_ part: ContentPart) throws -> OpenAIContentPart {
        switch part {
        case .text(let text):
            return .text(text)

        case .image(let data, let mimeType):
            let base64 = data.base64EncodedString()
            let dataURL = "data:\(mimeType);base64,\(base64)"
            return .imageURL(url: dataURL, detail: nil)
        }
    }

    func convertTool(_ tool: ToolDefinition) -> OpenAITool {
        OpenAITool(
            function: OpenAIFunction(
                name: tool.name,
                description: tool.description,
                parameters: tool.inputSchema,
                strict: nil
            )
        )
    }

    // MARK: - Tool Call Streaming

    func processToolCallDelta(
        _ delta: OpenAIStreamToolCall,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        accumulatedToolCalls: inout [OpenAIToolCallAccumulator]
    ) {
        // Default to 0 when index is missing (Ollama omits it)
        let index = delta.index ?? 0

        while accumulatedToolCalls.count <= index {
            accumulatedToolCalls.append(OpenAIToolCallAccumulator())
        }

        var acc = accumulatedToolCalls[index]

        if let id = delta.id {
            acc.id = id
        }
        if let function = delta.function {
            if let name = function.name {
                acc.name = name
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

    // MARK: - Utilities

    /// Whether the request contains tool results from previous tool calls.
    static func requestHasToolResults(_ request: CompletionRequest) -> Bool {
        request.messages.contains { message in
            switch message {
            case .toolResult, .toolResults: return true
            default: return false
            }
        }
    }
}

// MARK: - Tool Call Accumulator

/// Helper for accumulating streaming tool call data in OpenAI format.
struct OpenAIToolCallAccumulator {
    var id: String = ""
    var name: String = ""
    var arguments: String = ""
    var started: Bool = false
    var ended: Bool = false
}
