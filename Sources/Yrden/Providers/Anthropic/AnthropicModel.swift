/// Anthropic model implementation for the Messages API.
///
/// Implements the `Model` protocol for Claude models via the Anthropic API.
/// Handles:
/// - Request encoding (converting Yrden types to Anthropic format)
/// - Response decoding (converting Anthropic format to Yrden types)
/// - Streaming via SSE
/// - Error mapping
///
/// ## Usage
/// ```swift
/// let provider = AnthropicProvider(apiKey: "sk-ant-...")
/// let model = AnthropicModel(name: "claude-3-5-sonnet-20241022", provider: provider)
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

// MARK: - AnthropicModel

/// Model implementation for the Anthropic Messages API.
public struct AnthropicModel: Model, Sendable {
    /// Model identifier (e.g., "claude-3-5-sonnet-20241022").
    public let name: String

    /// Capabilities of this model.
    public let capabilities: ModelCapabilities

    /// Provider for authentication and connection.
    private let provider: AnthropicProvider

    /// Default max tokens if not specified in request.
    private let defaultMaxTokens: Int

    /// Creates an Anthropic model.
    ///
    /// - Parameters:
    ///   - name: Model identifier (e.g., "claude-3-5-sonnet-20241022")
    ///   - provider: Provider for authentication
    ///   - defaultMaxTokens: Default max tokens (default: 4096)
    public init(
        name: String,
        provider: AnthropicProvider,
        defaultMaxTokens: Int = 4096
    ) {
        self.name = name
        self.provider = provider
        self.defaultMaxTokens = defaultMaxTokens
        self.capabilities = Self.capabilities(for: name)
    }

    // MARK: - Model Protocol

    public func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        try validateRequest(request)
        let anthropicRequest = try encodeRequest(request, stream: false)
        let data = try await sendRequest(anthropicRequest)
        return try decodeResponse(data)
    }

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try validateRequest(request)
                    let anthropicRequest = try encodeRequest(request, stream: true)
                    try await streamRequest(anthropicRequest, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Request Encoding

    private func encodeRequest(_ request: CompletionRequest, stream: Bool) throws -> AnthropicRequest {
        // Extract system message
        var systemText: String?
        var messagesWithoutSystem: [Message] = []

        for message in request.messages {
            if case .system(let text) = message {
                systemText = text
            } else {
                messagesWithoutSystem.append(message)
            }
        }

        // Convert messages
        let anthropicMessages = try messagesWithoutSystem.map { try convertMessage($0) }

        // Convert tools
        let anthropicTools: [AnthropicTool]? = request.tools?.isEmpty == false
            ? request.tools?.map { convertTool($0) }
            : nil

        return AnthropicRequest(
            model: name,
            max_tokens: request.config.maxTokens ?? defaultMaxTokens,
            messages: anthropicMessages,
            system: systemText,
            tools: anthropicTools,
            temperature: request.config.temperature,
            stop_sequences: request.config.stopSequences,
            stream: stream ? true : nil
        )
    }

    private func convertMessage(_ message: Message) throws -> AnthropicMessage {
        switch message {
        case .system:
            // Should have been extracted already
            throw LLMError.invalidRequest("System message should be extracted")

        case .user(let parts):
            let blocks = try parts.map { try convertContentPart($0) }
            return AnthropicMessage(role: MessageRole.user, content: blocks)

        case .assistant(let text, let toolCalls):
            var blocks: [AnthropicContentBlock] = []

            if !text.isEmpty {
                blocks.append(.text(text))
            }

            for toolCall in toolCalls {
                let input = try parseToolArguments(toolCall.arguments)
                blocks.append(.toolUse(id: toolCall.id, name: toolCall.name, input: input))
            }

            if blocks.isEmpty {
                blocks.append(.text(""))
            }

            return AnthropicMessage(role: MessageRole.assistant, content: blocks)

        case .toolResult(let toolCallId, let content):
            return AnthropicMessage(
                role: MessageRole.user,
                content: [.toolResult(toolUseId: toolCallId, content: content, isError: nil)]
            )

        case .toolResults(let results):
            let blocks = results.map { entry -> AnthropicContentBlock in
                let content: String
                let isError: Bool
                switch entry.output {
                case .text(let text):
                    content = text
                    isError = false
                case .json(let json):
                    content = (try? String(data: JSONEncoder().encode(json), encoding: .utf8)) ?? "{}"
                    isError = false
                case .error(let message):
                    content = message
                    isError = true
                }
                return .toolResult(toolUseId: entry.id, content: content, isError: isError)
            }
            return AnthropicMessage(role: MessageRole.user, content: blocks)
        }
    }

    private func convertContentPart(_ part: ContentPart) throws -> AnthropicContentBlock {
        switch part {
        case .text(let text):
            return .text(text)

        case .image(let data, let mimeType):
            let base64 = data.base64EncodedString()
            return .image(base64: base64, mediaType: mimeType)
        }
    }

    private func convertTool(_ tool: ToolDefinition) -> AnthropicTool {
        AnthropicTool(
            name: tool.name,
            description: tool.description,
            input_schema: tool.inputSchema
        )
    }

    private func parseToolArguments(_ arguments: String) throws -> JSONValue {
        guard let data = arguments.data(using: .utf8) else {
            throw LLMError.decodingError("Invalid UTF-8 in tool arguments")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: - Response Decoding

    private func decodeResponse(_ data: Data) throws -> CompletionResponse {
        let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)

        // Extract text content
        var textContent: String?
        var toolCalls: [ToolCall] = []

        for block in response.content {
            switch block.type {
            case AnthropicBlockType.text:
                if let text = block.text {
                    if textContent == nil {
                        textContent = text
                    } else {
                        textContent! += text
                    }
                }

            case AnthropicBlockType.toolUse:
                if let id = block.id, let name = block.name, let input = block.input {
                    let arguments = try encodeToolInput(input)
                    toolCalls.append(ToolCall(id: id, name: name, arguments: arguments))
                }

            default:
                break
            }
        }

        let stopReason = mapStopReason(response.stop_reason)
        let usage = Usage(
            inputTokens: response.usage.input_tokens,
            outputTokens: response.usage.output_tokens
        )

        return CompletionResponse(
            content: textContent,
            toolCalls: toolCalls,
            stopReason: stopReason,
            usage: usage
        )
    }

    private func encodeToolInput(_ input: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(input)
        guard let string = String(data: data, encoding: .utf8) else {
            throw LLMError.decodingError("Failed to encode tool input as UTF-8")
        }
        return string
    }

    private func mapStopReason(_ reason: String?) -> StopReason {
        switch reason {
        case AnthropicStopReason.endTurn:
            return .endTurn
        case AnthropicStopReason.toolUse:
            return .toolUse
        case AnthropicStopReason.maxTokens:
            return .maxTokens
        case AnthropicStopReason.stopSequence:
            return .stopSequence
        default:
            return .endTurn
        }
    }

    // MARK: - HTTP

    private func sendRequest(_ request: AnthropicRequest) async throws -> Data {
        let url = provider.baseURL.appendingPathComponent(AnthropicEndpoint.messages)
        let (data, http) = try await HTTPClient.sendJSONPOST(
            url: url,
            body: request,
            configure: provider.authenticate
        )
        try handleHTTPStatus(http.statusCode, data: data)
        return data
    }

    private func handleHTTPStatus(_ statusCode: Int, data: Data) throws {
        switch statusCode {
        case 200..<300:
            return

        case 401:
            throw LLMError.invalidAPIKey

        case 429:
            throw LLMError.rateLimited(retryAfter: nil)

        case 400:
            let message = parseErrorMessage(data)
            throw LLMError.invalidRequest(message)

        case 404:
            throw LLMError.modelNotFound(name)

        default:
            let message = parseErrorMessage(data)
            throw LLMError.networkError("HTTP \(statusCode): \(message)")
        }
    }

    private func parseErrorMessage(_ data: Data) -> String {
        if let error = try? JSONDecoder().decode(AnthropicError.self, from: data) {
            return error.error.message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }

    // MARK: - Streaming

    private func streamRequest(
        _ request: AnthropicRequest,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let url = provider.baseURL.appendingPathComponent(AnthropicEndpoint.messages)
        let (bytes, http) = try await HTTPClient.streamJSONPOST(
            url: url,
            body: request,
            configure: provider.authenticate
        )

        if http.statusCode != 200 {
            let errorData = try await HTTPClient.collectErrorData(from: bytes)
            try handleHTTPStatus(http.statusCode, data: errorData)
            return
        }

        var currentEvent: String?
        var currentData = ""
        var accumulatedContent = ""
        var accumulatedToolCalls: [ToolCallAccumulator] = []
        var inputTokens = 0
        var outputTokens = 0

        for try await line in bytes.lines {
            if line.hasPrefix(SSE.eventPrefix) {
                currentEvent = String(line.dropFirst(SSE.eventPrefixLength))
                currentData = ""
            } else if line.hasPrefix(SSE.dataPrefix) {
                currentData = String(line.dropFirst(SSE.dataPrefixLength))

                guard let eventType = currentEvent else { continue }

                let sseEvent = AnthropicSSEEvent(event: eventType, data: currentData)

                do {
                    let streamEvent = try sseEvent.parse()
                    try processStreamEvent(
                        streamEvent,
                        continuation: continuation,
                        accumulatedContent: &accumulatedContent,
                        accumulatedToolCalls: &accumulatedToolCalls,
                        inputTokens: &inputTokens,
                        outputTokens: &outputTokens
                    )
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
            }
        }
    }

    private func processStreamEvent(
        _ event: AnthropicStreamEvent,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        accumulatedContent: inout String,
        accumulatedToolCalls: inout [ToolCallAccumulator],
        inputTokens: inout Int,
        outputTokens: inout Int
    ) throws {
        switch event {
        case .messageStart(let response):
            inputTokens = response.usage.input_tokens
            outputTokens = response.usage.output_tokens

        case .contentBlockStart(let index, let block):
            if block.type == AnthropicBlockType.toolUse, let id = block.id, let name = block.name {
                continuation.yield(.toolCallStart(id: id, name: name))
                accumulatedToolCalls.append(ToolCallAccumulator(id: id, name: name, blockIndex: index))
            }

        case .contentBlockDelta(_, let delta):
            switch delta {
            case .textDelta(let text):
                accumulatedContent += text
                continuation.yield(.contentDelta(text))

            case .inputJsonDelta(let json):
                if var lastToolCall = accumulatedToolCalls.last {
                    lastToolCall.arguments += json
                    accumulatedToolCalls[accumulatedToolCalls.count - 1] = lastToolCall
                    continuation.yield(.toolCallDelta(argumentsDelta: json))
                }
            }

        case .contentBlockStop(let index):
            // Find the tool call with this block index
            if let toolCall = accumulatedToolCalls.first(where: { $0.blockIndex == index }) {
                continuation.yield(.toolCallEnd(id: toolCall.id))
            }

        case .messageDelta(let delta, let usage):
            outputTokens = usage.output_tokens
            let stopReason = mapStopReason(delta.stop_reason)

            // Build final response
            let toolCalls = accumulatedToolCalls.map { acc in
                ToolCall(id: acc.id, name: acc.name, arguments: acc.arguments)
            }

            let response = CompletionResponse(
                content: accumulatedContent.isEmpty ? nil : accumulatedContent,
                toolCalls: toolCalls,
                stopReason: stopReason,
                usage: Usage(inputTokens: inputTokens, outputTokens: outputTokens)
            )

            continuation.yield(.done(response))

        case .messageStop:
            continuation.finish()

        case .ping:
            break

        case .error(let message):
            continuation.finish(throwing: LLMError.networkError(message))
        }
    }

    // MARK: - Capabilities

    private static func capabilities(for modelName: String) -> ModelCapabilities {
        // Claude 3.5 Sonnet, Claude 3 Opus, Claude 3 Sonnet
        if modelName.contains("claude-3") {
            return .claude35
        }

        // Claude 3 Haiku
        if modelName.contains("haiku") {
            return .claude3Haiku
        }

        // Default to full capabilities
        return ModelCapabilities(
            supportsTemperature: true,
            supportsTools: true,
            supportsVision: true,
            supportsStructuredOutput: true,
            supportsSystemMessage: true,
            maxContextTokens: 200_000
        )
    }
}

// MARK: - Tool Call Accumulator

/// Helper for accumulating streaming tool call data.
private struct ToolCallAccumulator {
    let id: String
    let name: String
    let blockIndex: Int
    var arguments: String = ""
}
