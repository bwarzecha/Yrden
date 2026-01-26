/// AWS Bedrock model implementation using the Converse API.
///
/// Implements the `Model` protocol for models available through AWS Bedrock.
/// Handles:
/// - Request encoding (converting Yrden types to Bedrock Converse format)
/// - Response decoding (converting Bedrock Converse format to Yrden types)
/// - Streaming via ConverseStream
/// - Tool calling
///
/// ## Usage
/// ```swift
/// let provider = try BedrockProvider(region: "us-east-1", profile: "default")
/// let model = BedrockModel(
///     name: "anthropic.claude-haiku-4-5-20251001-v1:0",
///     provider: provider
/// )
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
@preconcurrency import AWSBedrockRuntime
import Smithy
import SmithyJSON
@_spi(SmithyDocumentImpl) import Smithy

// MARK: - BedrockModel

/// Model implementation for AWS Bedrock's Converse API.
public struct BedrockModel: Model, @unchecked Sendable {
    /// Model identifier (e.g., "anthropic.claude-haiku-4-5-20251001-v1:0").
    public let name: String

    /// Capabilities of this model.
    public let capabilities: ModelCapabilities

    /// Provider for authentication and API access.
    private let provider: BedrockProvider

    /// Default max tokens if not specified in request.
    private let defaultMaxTokens: Int

    /// Creates a Bedrock model.
    ///
    /// - Parameters:
    ///   - name: Model identifier or inference profile ID
    ///   - provider: Provider for AWS authentication
    ///   - defaultMaxTokens: Default max tokens (default: 4096)
    public init(
        name: String,
        provider: BedrockProvider,
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

        let input = try encodeRequest(request)
        let output = try await provider.runtimeClient.converse(input: input)

        return try decodeResponse(output)
    }

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try validateRequest(request)
                    let input = try encodeStreamRequest(request)
                    try await streamRequest(input, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Request Encoding

    /// Common request components extracted from a CompletionRequest.
    private struct RequestComponents {
        let systemBlocks: [BedrockRuntimeClientTypes.SystemContentBlock]?
        let messages: [BedrockRuntimeClientTypes.Message]
        let inferenceConfig: BedrockRuntimeClientTypes.InferenceConfiguration
        let toolConfig: BedrockRuntimeClientTypes.ToolConfiguration?
    }

    /// Extracts common components from a CompletionRequest for both Converse and ConverseStream.
    private func extractRequestComponents(_ request: CompletionRequest) throws -> RequestComponents {
        // Extract system messages
        var systemBlocks: [BedrockRuntimeClientTypes.SystemContentBlock] = []
        var conversationMessages: [Message] = []

        for message in request.messages {
            if case .system(let text) = message {
                systemBlocks.append(.text(text))
            } else {
                conversationMessages.append(message)
            }
        }

        // Convert messages
        let bedrockMessages = try conversationMessages.map { try convertMessage($0) }

        // Build inference config
        let inferenceConfig = BedrockRuntimeClientTypes.InferenceConfiguration(
            maxTokens: request.config.maxTokens ?? defaultMaxTokens,
            stopSequences: request.config.stopSequences,
            temperature: request.config.temperature.map { Float($0) },
            topp: request.config.topP.map { Float($0) }
        )

        // Build tool config if tools are provided
        var toolConfig: BedrockRuntimeClientTypes.ToolConfiguration? = nil
        if let tools = request.tools, !tools.isEmpty {
            let toolSpecs = tools.map { convertToolDefinition($0) }
            toolConfig = BedrockRuntimeClientTypes.ToolConfiguration(
                toolChoice: .auto(.init()),
                tools: toolSpecs
            )
        }

        return RequestComponents(
            systemBlocks: systemBlocks.isEmpty ? nil : systemBlocks,
            messages: bedrockMessages,
            inferenceConfig: inferenceConfig,
            toolConfig: toolConfig
        )
    }

    private func encodeRequest(_ request: CompletionRequest) throws -> ConverseInput {
        let components = try extractRequestComponents(request)
        return ConverseInput(
            inferenceConfig: components.inferenceConfig,
            messages: components.messages,
            modelId: name,
            system: components.systemBlocks,
            toolConfig: components.toolConfig
        )
    }

    private func encodeStreamRequest(_ request: CompletionRequest) throws -> ConverseStreamInput {
        let components = try extractRequestComponents(request)
        return ConverseStreamInput(
            inferenceConfig: components.inferenceConfig,
            messages: components.messages,
            modelId: name,
            system: components.systemBlocks,
            toolConfig: components.toolConfig
        )
    }

    private func convertMessage(_ message: Message) throws -> BedrockRuntimeClientTypes.Message {
        switch message {
        case .system:
            // System messages are handled separately
            throw LLMError.invalidRequest("System messages should be extracted before conversion")

        case .user(let parts):
            let contentBlocks = try parts.map { try convertContentPart($0) }
            return BedrockRuntimeClientTypes.Message(
                content: contentBlocks,
                role: .user
            )

        case .assistant(let text, toolCalls: let toolCalls):
            var contentBlocks: [BedrockRuntimeClientTypes.ContentBlock] = []
            if !text.isEmpty {
                contentBlocks.append(.text(text))
            }
            for toolCall in toolCalls {
                // Parse arguments JSON to Document
                let argsDocument = try parseJSONToDocument(toolCall.arguments)
                let toolUseBlock = BedrockRuntimeClientTypes.ToolUseBlock(
                    input: argsDocument,
                    name: toolCall.name,
                    toolUseId: toolCall.id
                )
                contentBlocks.append(.tooluse(toolUseBlock))
            }
            // If no tool calls and no text, add empty text
            if contentBlocks.isEmpty {
                contentBlocks.append(.text(text))
            }
            return BedrockRuntimeClientTypes.Message(
                content: contentBlocks,
                role: .assistant
            )

        case .toolResult(toolCallId: let id, content: let result):
            // Tool results go in a user message with toolResult content
            let toolResultBlock = BedrockRuntimeClientTypes.ToolResultBlock(
                content: [.text(result)],
                toolUseId: id
            )
            return BedrockRuntimeClientTypes.Message(
                content: [.toolresult(toolResultBlock)],
                role: .user
            )

        case .toolResults(let results):
            // Multiple tool results in a single user message
            let blocks = results.map { entry -> BedrockRuntimeClientTypes.ContentBlock in
                let content: String
                let status: BedrockRuntimeClientTypes.ToolResultStatus?
                switch entry.output {
                case .text(let text):
                    content = text
                    status = nil
                case .json(let json):
                    content = (try? String(data: JSONEncoder().encode(json), encoding: .utf8)) ?? "{}"
                    status = nil
                case .error(let message):
                    content = message
                    status = .error
                }
                let toolResultBlock = BedrockRuntimeClientTypes.ToolResultBlock(
                    content: [.text(content)],
                    status: status,
                    toolUseId: entry.id
                )
                return .toolresult(toolResultBlock)
            }
            return BedrockRuntimeClientTypes.Message(
                content: blocks,
                role: .user
            )
        }
    }

    private func convertContentPart(_ part: ContentPart) throws -> BedrockRuntimeClientTypes.ContentBlock {
        switch part {
        case .text(let text):
            return .text(text)

        case .image(let data, let mimeType):
            let format: BedrockRuntimeClientTypes.ImageFormat
            switch mimeType.lowercased() {
            case "image/jpeg", "image/jpg":
                format = .jpeg
            case "image/png":
                format = .png
            case "image/gif":
                format = .gif
            case "image/webp":
                format = .webp
            default:
                throw LLMError.invalidRequest("Unsupported image format: \(mimeType)")
            }

            let imageBlock = BedrockRuntimeClientTypes.ImageBlock(
                format: format,
                source: .bytes(data)
            )
            return .image(imageBlock)
        }
    }

    private func convertToolDefinition(_ tool: ToolDefinition) -> BedrockRuntimeClientTypes.Tool {
        let schemaDocument = jsonValueToDocument(tool.inputSchema)

        let toolSpec = BedrockRuntimeClientTypes.ToolSpecification(
            description: tool.description,
            inputSchema: .json(schemaDocument),
            name: tool.name
        )
        return .toolspec(toolSpec)
    }

    // MARK: - Response Decoding

    private func decodeResponse(_ output: ConverseOutput) throws -> CompletionResponse {
        var textContent = ""
        var toolCalls: [ToolCall] = []

        if let message = output.output {
            switch message {
            case .message(let msg):
                for contentBlock in msg.content ?? [] {
                    switch contentBlock {
                    case .text(let text):
                        textContent += text

                    case .tooluse(let toolUse):
                        let argsString = documentToJSONString(toolUse.input)
                        toolCalls.append(ToolCall(
                            id: toolUse.toolUseId ?? UUID().uuidString,
                            name: toolUse.name ?? "unknown",
                            arguments: argsString
                        ))

                    default:
                        break
                    }
                }

            default:
                break
            }
        }

        let stopReason = convertStopReason(output.stopReason)
        let usage = Usage(
            inputTokens: output.usage?.inputTokens ?? 0,
            outputTokens: output.usage?.outputTokens ?? 0
        )

        return CompletionResponse(
            content: textContent.isEmpty ? nil : textContent,
            toolCalls: toolCalls,
            stopReason: stopReason,
            usage: usage
        )
    }

    private func convertStopReason(_ stopReason: BedrockRuntimeClientTypes.StopReason?) -> StopReason {
        guard let reason = stopReason else {
            return .endTurn
        }

        switch reason {
        case .endTurn:
            return .endTurn
        case .maxTokens:
            return .maxTokens
        case .toolUse:
            return .toolUse
        case .stopSequence:
            return .stopSequence
        case .guardrailIntervened, .contentFiltered:
            return .endTurn // Map to endTurn, error details in response
        default:
            return .endTurn
        }
    }

    // MARK: - Streaming

    private func streamRequest(
        _ input: ConverseStreamInput,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let output = try await provider.runtimeClient.converseStream(input: input)

        guard let stream = output.stream else {
            // No stream available - emit empty done event before finishing
            let emptyResponse = CompletionResponse(
                content: nil,
                toolCalls: [],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 0, outputTokens: 0)
            )
            continuation.yield(.done(emptyResponse))
            continuation.finish()
            return
        }

        var totalInputTokens = 0
        var totalOutputTokens = 0
        var currentToolCallId: String?
        var currentToolCallName: String?
        var currentToolCallArgs = ""

        // Track full content for final response
        var fullTextContent = ""
        var allToolCalls: [ToolCall] = []
        var finalStopReason: StopReason = .endTurn

        for try await event in stream {
            switch event {
            case .messagestart:
                // No corresponding StreamEvent - ignore
                break

            case .contentblockstart(let startEvent):
                if let start = startEvent.start {
                    switch start {
                    case .tooluse(let toolStart):
                        currentToolCallId = toolStart.toolUseId
                        currentToolCallName = toolStart.name
                        currentToolCallArgs = ""
                        continuation.yield(.toolCallStart(
                            id: toolStart.toolUseId ?? "",
                            name: toolStart.name ?? ""
                        ))
                    default:
                        break
                    }
                }

            case .contentblockdelta(let deltaEvent):
                if let delta = deltaEvent.delta {
                    switch delta {
                    case .text(let text):
                        fullTextContent += text
                        continuation.yield(.contentDelta(text))

                    case .tooluse(let toolDelta):
                        if let input = toolDelta.input {
                            currentToolCallArgs += input
                            continuation.yield(.toolCallDelta(argumentsDelta: input))
                        }

                    default:
                        break
                    }
                }

            case .contentblockstop:
                if let id = currentToolCallId, let name = currentToolCallName {
                    let toolCall = ToolCall(
                        id: id,
                        name: name,
                        arguments: currentToolCallArgs
                    )
                    allToolCalls.append(toolCall)
                    continuation.yield(.toolCallEnd(id: id))
                    currentToolCallId = nil
                    currentToolCallName = nil
                    currentToolCallArgs = ""
                }
                // No contentEnd event in StreamEvent - ignore for text blocks

            case .messagestop(let stopEvent):
                finalStopReason = convertStopReason(stopEvent.stopReason)

            case .metadata(let metadataEvent):
                if let usage = metadataEvent.usage {
                    totalInputTokens = usage.inputTokens ?? 0
                    totalOutputTokens = usage.outputTokens ?? 0
                }
                // No usage event in StreamEvent - we'll include it in the final response

            default:
                break
            }
        }

        // Build and emit final CompletionResponse
        let finalResponse = CompletionResponse(
            content: fullTextContent.isEmpty ? nil : fullTextContent,
            toolCalls: allToolCalls,
            stopReason: finalStopReason,
            usage: Usage(inputTokens: totalInputTokens, outputTokens: totalOutputTokens)
        )
        continuation.yield(.done(finalResponse))
        continuation.finish()
    }

    // MARK: - Capability Detection

    static func capabilities(for modelId: String) -> ModelCapabilities {
        // Strip inference profile prefix if present
        let baseId: String
        if modelId.hasPrefix("us.") || modelId.hasPrefix("eu.") ||
           modelId.hasPrefix("apac.") || modelId.hasPrefix("global.") {
            // Strip the region prefix
            if let dotIndex = modelId.firstIndex(of: ".") {
                baseId = String(modelId[modelId.index(after: dotIndex)...])
            } else {
                baseId = modelId
            }
        } else {
            baseId = modelId
        }

        // Detect by model family
        if baseId.contains("claude") {
            return .claude35 // Claude models have full capabilities
        } else if baseId.contains("nova") {
            // Nova models have full capabilities
            return ModelCapabilities(
                supportsTemperature: true,
                supportsTools: true,
                supportsVision: true,
                supportsStructuredOutput: true, // Via tool forcing
                supportsSystemMessage: true,
                maxContextTokens: 300_000
            )
        } else if baseId.contains("llama") {
            // Llama has limited capabilities
            return ModelCapabilities(
                supportsTemperature: true,
                supportsTools: true, // Limited
                supportsVision: false,
                supportsStructuredOutput: true, // Via tool forcing
                supportsSystemMessage: true,
                maxContextTokens: 128_000
            )
        } else if baseId.contains("mistral") {
            return ModelCapabilities(
                supportsTemperature: true,
                supportsTools: true,
                supportsVision: false,
                supportsStructuredOutput: true, // Via tool forcing
                supportsSystemMessage: true,
                maxContextTokens: 32_000
            )
        }

        // Default conservative capabilities
        return ModelCapabilities(
            supportsTemperature: true,
            supportsTools: false,
            supportsVision: false,
            supportsStructuredOutput: false,
            supportsSystemMessage: true,
            maxContextTokens: nil
        )
    }

    // MARK: - JSON Helpers

    private func parseJSONToDocument(_ json: String) throws -> Smithy.Document {
        guard let data = json.data(using: .utf8) else {
            return Document(NullDocument())
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return jsonValueToDocument(value)
    }

    private func jsonValueToDocument(_ value: JSONValue) -> Smithy.Document {
        switch value {
        case .null:
            return Document(NullDocument())
        case .bool(let b):
            return Document(BooleanDocument(value: b))
        case .int(let i):
            return Document(IntegerDocument(value: i))
        case .double(let d):
            return Document(DoubleDocument(value: d))
        case .string(let s):
            return Document(StringDocument(value: s))
        case .array(let arr):
            return Document(ListDocument(value: arr.map { jsonValueToDocument($0) as! Document }))
        case .object(let obj):
            let converted = obj.mapValues { jsonValueToDocument($0) as! Document }
            return Document(StringMapDocument(value: converted))
        }
    }

    private func documentToJSONString(_ document: Smithy.Document?) -> String {
        guard let doc = document else {
            return "{}"
        }
        let jsonValue = documentToJSONValue(doc)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(jsonValue),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    private func documentToJSONValue(_ document: Smithy.Document) -> JSONValue {
        switch document.type {
        case .structure:
            // Null documents have structure type
            return .null
        case .boolean:
            return .bool((try? document.asBoolean()) ?? false)
        case .byte, .short, .integer, .long, .bigInteger:
            return .int((try? document.asInteger()) ?? 0)
        case .float, .double, .bigDecimal:
            return .double((try? document.asDouble()) ?? 0.0)
        case .string:
            return .string((try? document.asString()) ?? "")
        case .list:
            let list = (try? document.asList()) ?? []
            return .array(list.map { documentToJSONValue(Document($0)) })
        case .map:
            let map = (try? document.asStringMap()) ?? [:]
            var result: [String: JSONValue] = [:]
            for (key, value) in map {
                result[key] = documentToJSONValue(Document(value))
            }
            return .object(result)
        default:
            return .null
        }
    }
}
