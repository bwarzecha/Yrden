/// Model extension for typed structured output generation.
///
/// This extension provides convenience methods that return decoded Swift types
/// directly, similar to PydanticAI's `result.output`. Two approaches are supported:
///
/// - **Native structured output** (`generate`): Uses OpenAI's `response_format` or
///   similar native JSON mode. Best for OpenAI models.
/// - **Tool-based structured output** (`generateWithTool`): Uses a tool call to
///   enforce the schema. Best for Anthropic models.
///
/// ## Example
/// ```swift
/// // Define a schema type
/// @Schema
/// struct PersonInfo {
///     let name: String
///     let age: Int
/// }
///
/// // OpenAI - native structured output
/// let openai = OpenAIModel(...)
/// let result = try await openai.generate(
///     "Extract: John is 30 years old",
///     as: PersonInfo.self
/// )
/// print(result.data.name)  // "John"
///
/// // Anthropic - tool-based structured output
/// let anthropic = AnthropicModel(...)
/// let result = try await anthropic.generateWithTool(
///     "Extract: John is 30 years old",
///     as: PersonInfo.self
/// )
/// print(result.data.name)  // "John"
/// ```

import Foundation

// MARK: - Typed Structured Output

extension Model {

    /// Generate structured output using native JSON mode.
    ///
    /// Uses the provider's native structured output feature (e.g., OpenAI's `response_format`).
    /// The model's response is constrained to valid JSON matching the schema.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt
    ///   - type: The SchemaType to decode the response into
    ///   - systemPrompt: Optional system prompt
    ///   - config: Completion configuration
    /// - Returns: TypedResponse containing the decoded data and metadata
    /// - Throws: `StructuredOutputError` for parsing failures, `LLMError` for provider errors
    ///
    /// ## Example
    /// ```swift
    /// let result = try await model.generate(
    ///     "Extract person: John is 30",
    ///     as: PersonInfo.self
    /// )
    /// print(result.data.name)  // "John"
    /// ```
    public func generate<T: SchemaType>(
        _ prompt: String,
        as type: T.Type,
        systemPrompt: String? = nil,
        config: CompletionConfig = .default
    ) async throws -> TypedResponse<T> {
        var messages: [Message] = []

        if let systemPrompt {
            messages.append(.system(systemPrompt))
        }
        messages.append(.user(prompt))

        let request = CompletionRequest(
            messages: messages,
            outputSchema: T.jsonSchema,
            config: config
        )

        let response = try await complete(request)
        return try extractAndDecode(from: response, as: type, expectToolCall: false)
    }

    /// Generate structured output using a tool call.
    ///
    /// Creates a tool with the schema and requests the model to call it.
    /// This is the preferred approach for Anthropic models which use `tool_use`
    /// for structured output.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt
    ///   - type: The SchemaType to decode the response into
    ///   - toolName: Name for the extraction tool (default: "extract")
    ///   - toolDescription: Description for the tool (auto-generated if nil)
    ///   - systemPrompt: Optional system prompt
    ///   - config: Completion configuration
    /// - Returns: TypedResponse containing the decoded data and metadata
    /// - Throws: `StructuredOutputError` for parsing failures, `LLMError` for provider errors
    ///
    /// ## Example
    /// ```swift
    /// let result = try await model.generateWithTool(
    ///     "Extract person: John is 30",
    ///     as: PersonInfo.self,
    ///     toolName: "extract_person"
    /// )
    /// print(result.data.name)  // "John"
    /// ```
    public func generateWithTool<T: SchemaType>(
        _ prompt: String,
        as type: T.Type,
        toolName: String = "extract",
        toolDescription: String? = nil,
        systemPrompt: String? = nil,
        config: CompletionConfig = .default
    ) async throws -> TypedResponse<T> {
        var messages: [Message] = []

        if let systemPrompt {
            messages.append(.system(systemPrompt))
        }
        messages.append(.user(prompt))

        // Create a tool with the schema
        let description = toolDescription ?? "Extract structured data from the input"
        let tool = ToolDefinition(
            name: toolName,
            description: description,
            inputSchema: T.jsonSchema
        )

        let request = CompletionRequest(
            messages: messages,
            tools: [tool],
            config: config
        )

        let response = try await complete(request)
        return try extractAndDecode(from: response, as: type, expectToolCall: true)
    }

    /// Generate structured output using messages array (native JSON mode).
    ///
    /// Like `generate(_:as:)` but takes a full message array instead of a simple prompt.
    ///
    /// - Parameters:
    ///   - messages: The conversation messages
    ///   - type: The SchemaType to decode the response into
    ///   - config: Completion configuration
    /// - Returns: TypedResponse containing the decoded data and metadata
    public func generate<T: SchemaType>(
        messages: [Message],
        as type: T.Type,
        config: CompletionConfig = .default
    ) async throws -> TypedResponse<T> {
        let request = CompletionRequest(
            messages: messages,
            outputSchema: T.jsonSchema,
            config: config
        )

        let response = try await complete(request)
        return try extractAndDecode(from: response, as: type, expectToolCall: false)
    }

    /// Generate structured output using messages array (tool-based).
    ///
    /// Like `generateWithTool(_:as:)` but takes a full message array.
    ///
    /// - Parameters:
    ///   - messages: The conversation messages
    ///   - type: The SchemaType to decode the response into
    ///   - toolName: Name for the extraction tool
    ///   - toolDescription: Description for the tool
    ///   - config: Completion configuration
    /// - Returns: TypedResponse containing the decoded data and metadata
    public func generateWithTool<T: SchemaType>(
        messages: [Message],
        as type: T.Type,
        toolName: String = "extract",
        toolDescription: String? = nil,
        config: CompletionConfig = .default
    ) async throws -> TypedResponse<T> {
        let description = toolDescription ?? "Extract structured data from the input"
        let tool = ToolDefinition(
            name: toolName,
            description: description,
            inputSchema: T.jsonSchema
        )

        let request = CompletionRequest(
            messages: messages,
            tools: [tool],
            config: config
        )

        let response = try await complete(request)
        return try extractAndDecode(from: response, as: type, expectToolCall: true)
    }
}

// MARK: - Streaming Structured Output

extension Model {

    /// Stream structured output generation using native JSON mode.
    ///
    /// Streams events during generation, then decodes the complete JSON at the end.
    /// The stream yields regular events (contentDelta, etc.) followed by a final
    /// `.done` event containing the complete response.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt
    ///   - type: The SchemaType to decode the response into
    ///   - systemPrompt: Optional system prompt
    ///   - config: Completion configuration
    /// - Returns: Stream of events, ending with `.done` containing the typed response
    ///
    /// ## Example
    /// ```swift
    /// var jsonPreview = ""
    /// for try await event in model.generateStream("Extract person", as: PersonInfo.self) {
    ///     switch event {
    ///     case .contentDelta(let delta):
    ///         jsonPreview += delta
    ///         print("Building JSON: \(jsonPreview)")
    ///     case .done(let response):
    ///         // Decode the final JSON
    ///         let result = try extractTypedResult(from: response, as: PersonInfo.self)
    ///         print("Final: \(result.data)")
    ///     default:
    ///         break
    ///     }
    /// }
    /// ```
    public func generateStream<T: SchemaType>(
        _ prompt: String,
        as type: T.Type,
        systemPrompt: String? = nil,
        config: CompletionConfig = .default
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        var messages: [Message] = []

        if let systemPrompt {
            messages.append(.system(systemPrompt))
        }
        messages.append(.user(prompt))

        let request = CompletionRequest(
            messages: messages,
            outputSchema: T.jsonSchema,
            config: config
        )

        return stream(request)
    }

    /// Stream structured output generation using tool-based approach.
    ///
    /// Streams events during generation. Tool arguments arrive via
    /// `toolCallDelta` events. The complete JSON is available in the
    /// final `.done` response's `toolCalls[0].arguments`.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt
    ///   - type: The SchemaType to decode the response into
    ///   - toolName: Name for the extraction tool
    ///   - toolDescription: Description for the tool
    ///   - systemPrompt: Optional system prompt
    ///   - config: Completion configuration
    /// - Returns: Stream of events
    public func generateStreamWithTool<T: SchemaType>(
        _ prompt: String,
        as type: T.Type,
        toolName: String = "extract",
        toolDescription: String? = nil,
        systemPrompt: String? = nil,
        config: CompletionConfig = .default
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        var messages: [Message] = []

        if let systemPrompt {
            messages.append(.system(systemPrompt))
        }
        messages.append(.user(prompt))

        let description = toolDescription ?? "Extract structured data from the input"
        let tool = ToolDefinition(
            name: toolName,
            description: description,
            inputSchema: T.jsonSchema
        )

        let request = CompletionRequest(
            messages: messages,
            tools: [tool],
            config: config
        )

        return stream(request)
    }
}

// MARK: - Extraction Helpers

extension Model {

    /// Extract and decode typed data from a completion response.
    ///
    /// This is the core extraction logic that handles both native and tool-based
    /// structured output paths.
    ///
    /// - Parameters:
    ///   - response: The completion response
    ///   - type: The type to decode into
    ///   - expectToolCall: Whether to extract from tool call (true) or content (false)
    /// - Returns: TypedResponse with decoded data
    /// - Throws: StructuredOutputError for extraction/decoding failures
    public func extractAndDecode<T: SchemaType>(
        from response: CompletionResponse,
        as type: T.Type,
        expectToolCall: Bool
    ) throws -> TypedResponse<T> {
        // 1. Check for refusal
        if let refusal = response.refusal {
            throw StructuredOutputError.modelRefused(reason: refusal)
        }

        // 2. Check for truncation (may have incomplete JSON)
        if response.stopReason == .maxTokens {
            let partial = response.content ?? response.toolCalls.first?.arguments ?? ""
            throw StructuredOutputError.incompleteResponse(partialJSON: partial)
        }

        // 3. Extract JSON based on expected path
        let json: String
        if expectToolCall {
            guard let toolCall = response.toolCalls.first else {
                if let content = response.content, !content.isEmpty {
                    throw StructuredOutputError.unexpectedTextResponse(content: content)
                }
                throw StructuredOutputError.emptyResponse
            }
            json = toolCall.arguments
        } else {
            guard let content = response.content, !content.isEmpty else {
                if !response.toolCalls.isEmpty {
                    throw StructuredOutputError.unexpectedToolCall(
                        toolName: response.toolCalls[0].name
                    )
                }
                throw StructuredOutputError.emptyResponse
            }
            json = content
        }

        // 4. Decode JSON to typed struct
        return try decodeJSON(json, as: type, response: response)
    }

    /// Decode JSON string into a typed response.
    ///
    /// - Parameters:
    ///   - json: The JSON string to decode
    ///   - type: The type to decode into
    ///   - response: The original response for metadata
    /// - Returns: TypedResponse with decoded data
    private func decodeJSON<T: SchemaType>(
        _ json: String,
        as type: T.Type,
        response: CompletionResponse
    ) throws -> TypedResponse<T> {
        guard let jsonData = json.data(using: .utf8) else {
            throw StructuredOutputError.decodingFailed(
                json: json,
                underlyingError: DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "Invalid UTF-8 in JSON string"
                    )
                )
            )
        }

        do {
            let decoder = JSONDecoder()
            let data = try decoder.decode(T.self, from: jsonData)
            return TypedResponse(
                data: data,
                usage: response.usage,
                stopReason: response.stopReason,
                rawJSON: json
            )
        } catch {
            throw StructuredOutputError.decodingFailed(json: json, underlyingError: error)
        }
    }
}
