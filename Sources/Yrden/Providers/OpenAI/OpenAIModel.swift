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
    /// Model identifier (e.g., "gpt-4o", "o1-mini").
    public let name: String

    /// Capabilities of this model.
    public let capabilities: ModelCapabilities

    /// Provider for authentication and connection.
    private let provider: any Provider & OpenAICompatibleProvider

    /// Default max tokens if not specified in request.
    private let defaultMaxTokens: Int

    /// Creates an OpenAI model.
    ///
    /// - Parameters:
    ///   - name: Model identifier (e.g., "gpt-4o", "o1-mini")
    ///   - provider: Provider for authentication
    ///   - defaultMaxTokens: Default max tokens (default: 4096)
    public init(
        name: String,
        provider: any Provider & OpenAICompatibleProvider,
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
        let openAIRequest = try encodeRequest(request, stream: false)
        let data = try await sendRequest(openAIRequest)
        return try decodeResponse(data)
    }

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try validateRequest(request)
                    let openAIRequest = try encodeRequest(request, stream: true)
                    try await streamRequest(openAIRequest, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Request Encoding

    private func encodeRequest(_ request: CompletionRequest, stream: Bool) throws -> OpenAIRequest {
        // Convert messages (system stays in array for OpenAI)
        let openAIMessages = try request.messages.map { try convertMessage($0) }

        // Convert tools
        let openAITools: [OpenAITool]? = request.tools?.isEmpty == false
            ? request.tools?.map { convertTool($0) }
            : nil

        let maxTokens = request.config.maxTokens ?? defaultMaxTokens

        // Newer models (GPT-5.x, o3, o1) use max_completion_tokens instead of max_tokens
        let usesMaxCompletionTokens = name.hasPrefix("gpt-5") ||
                                      name.hasPrefix("o3") ||
                                      name.hasPrefix("o1") ||
                                      name.hasPrefix("gpt-4.1")

        // Convert output schema to response format
        let responseFormat: OpenAIResponseFormat? = request.outputSchema.map { schema in
            .jsonSchema(name: "response", schema: schema, strict: true)
        }

        // Build request
        return OpenAIRequest(
            model: name,
            messages: openAIMessages,
            max_tokens: usesMaxCompletionTokens ? nil : maxTokens,
            max_completion_tokens: usesMaxCompletionTokens ? maxTokens : nil,
            temperature: request.config.temperature,
            stop: request.config.stopSequences,
            tools: openAITools,
            tool_choice: openAITools != nil ? .auto : nil,
            response_format: responseFormat,
            stream: stream ? true : nil,
            stream_options: stream ? OpenAIStreamOptions(include_usage: true) : nil
        )
    }

    private func convertMessage(_ message: Message) throws -> OpenAIMessage {
        switch message {
        case .system(let text):
            return OpenAIMessage(
                role: "system",
                content: .text(text)
            )

        case .user(let parts):
            if parts.count == 1, case .text(let text) = parts[0] {
                // Simple text - use string content
                return OpenAIMessage(
                    role: "user",
                    content: .text(text)
                )
            } else {
                // Multimodal - use parts array
                let openAIParts = try parts.map { try convertContentPart($0) }
                return OpenAIMessage(
                    role: "user",
                    content: .parts(openAIParts)
                )
            }

        case .assistant(let text, let toolCalls):
            let openAIToolCalls: [OpenAIToolCall]? = toolCalls.isEmpty ? nil : toolCalls.map { call in
                OpenAIToolCall(
                    id: call.id,
                    type: "function",
                    function: OpenAIFunctionCall(name: call.name, arguments: call.arguments)
                )
            }
            return OpenAIMessage(
                role: "assistant",
                content: text.isEmpty ? nil : .text(text),
                tool_calls: openAIToolCalls
            )

        case .toolResult(let toolCallId, let content):
            return OpenAIMessage(
                role: "tool",
                content: .text(content),
                tool_call_id: toolCallId
            )
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
                strict: nil
            )
        )
    }

    // MARK: - Response Decoding

    private func decodeResponse(_ data: Data) throws -> CompletionResponse {
        let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)

        guard let choice = response.choices.first else {
            throw LLMError.decodingError("No choices in response")
        }

        // Extract content and tool calls
        let content = choice.message.content
        let toolCalls = choice.message.tool_calls?.map { call in
            ToolCall(
                id: call.id,
                name: call.function.name,
                arguments: call.function.arguments
            )
        } ?? []

        let stopReason = mapStopReason(choice.finish_reason)
        let usage = Usage(
            inputTokens: response.usage?.prompt_tokens ?? 0,
            outputTokens: response.usage?.completion_tokens ?? 0
        )

        return CompletionResponse(
            content: content,
            toolCalls: toolCalls,
            stopReason: stopReason,
            usage: usage
        )
    }

    private func mapStopReason(_ reason: String?) -> StopReason {
        switch reason {
        case "stop":
            return .endTurn
        case "tool_calls":
            return .toolUse
        case "length":
            return .maxTokens
        case "content_filter":
            return .contentFiltered
        default:
            return .endTurn
        }
    }

    // MARK: - HTTP

    private func sendRequest(_ request: OpenAIRequest) async throws -> Data {
        var urlRequest = URLRequest(url: provider.baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        try await provider.authenticate(&urlRequest)
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try handleHTTPResponse(response, data: data)
        return data
    }

    private func handleHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError("Invalid response type")
        }

        switch http.statusCode {
        case 200..<300:
            return

        case 401:
            throw LLMError.invalidAPIKey

        case 429:
            let retryAfter = parseRetryAfter(http)
            throw LLMError.rateLimited(retryAfter: retryAfter)

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
            throw LLMError.networkError("HTTP \(http.statusCode): \(message)")
        }
    }

    private func parseRetryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(retryAfter) {
            return seconds
        }
        return nil
    }

    private func parseErrorMessage(_ data: Data) -> String {
        if let error = try? JSONDecoder().decode(OpenAIError.self, from: data) {
            return error.error.message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }

    // MARK: - Streaming

    private func streamRequest(
        _ request: OpenAIRequest,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        var urlRequest = URLRequest(url: provider.baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        try await provider.authenticate(&urlRequest)
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError("Invalid response type")
        }

        if http.statusCode != 200 {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            try handleHTTPResponse(response, data: errorData)
            return
        }

        var accumulatedContent = ""
        var accumulatedToolCalls: [ToolCallAccumulator] = []
        var inputTokens = 0
        var outputTokens = 0
        var lastFinishReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let data = String(line.dropFirst(6))

            // Check for stream end
            if data == "[DONE]" {
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

        // Build final response
        let toolCalls = accumulatedToolCalls.map { acc in
            ToolCall(id: acc.id, name: acc.name, arguments: acc.arguments)
        }

        let completionResponse = CompletionResponse(
            content: accumulatedContent.isEmpty ? nil : accumulatedContent,
            toolCalls: toolCalls,
            stopReason: mapStopReason(lastFinishReason),
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

    // MARK: - Capabilities

    private static func capabilities(for modelName: String) -> ModelCapabilities {
        // GPT-5.x family - flagship models with full capabilities
        // GPT-5: 400K context, GPT-5.2: 400K context, 128K max output
        if modelName.hasPrefix("gpt-5") {
            return .gpt5
        }

        // GPT-4.1 family - similar to GPT-4o but newer
        if modelName.hasPrefix("gpt-4.1") {
            return .gpt4o
        }

        // GPT-4o and GPT-4o-mini
        if modelName.hasPrefix("gpt-4o") {
            return .gpt4o
        }

        // GPT-4 Turbo
        if modelName.hasPrefix("gpt-4-turbo") || modelName == "gpt-4-1106-preview" || modelName == "gpt-4-0125-preview" {
            return .gpt4Turbo
        }

        // o1 family (significant limitations - no temp, no system, no tools)
        if modelName.hasPrefix("o1") {
            return .o1
        }

        // o3 family (no temp, no system, but has tools and vision)
        if modelName.hasPrefix("o3") {
            return .o3
        }

        // GPT-4 base (older, less capable than turbo/o)
        if modelName.hasPrefix("gpt-4") {
            return .gpt4Turbo
        }

        // GPT-3.5 Turbo
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
