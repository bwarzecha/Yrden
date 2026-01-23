/// Error types for typed structured output operations.
///
/// `StructuredOutputError` provides typed errors for common failure modes when
/// generating structured output from LLM providers. These are separate from
/// `LLMError` because they represent parsing/validation failures after
/// receiving a response, not provider/network errors.
///
/// ## Error Handling Example
/// ```swift
/// do {
///     let result = try await model.generate(prompt, as: PersonInfo.self)
///     print(result.data.name)
/// } catch let error as StructuredOutputError {
///     switch error {
///     case .modelRefused(let reason):
///         print("Model refused: \(reason)")
///     case .decodingFailed(let json, _):
///         print("Failed to decode JSON: \(json)")
///     case .incompleteResponse(let partial):
///         print("Response truncated: \(partial)")
///     default:
///         print("Structured output error: \(error)")
///     }
/// }
/// ```

import Foundation

// MARK: - StructuredOutputError

/// Errors that can occur when extracting typed structured output from LLM responses.
public enum StructuredOutputError: Error, Sendable {
    /// Model explicitly refused to generate structured output.
    /// This occurs when the model declines due to safety/policy reasons.
    /// - Parameter reason: The refusal explanation from the model.
    case modelRefused(reason: String)

    /// Model returned an empty response with no content or tool calls.
    case emptyResponse

    /// Expected tool call response but received text content.
    /// This indicates a mismatch between the request type and response.
    /// - Parameter content: The unexpected text content received.
    case unexpectedTextResponse(content: String)

    /// Expected native structured output but received a tool call.
    /// This indicates a mismatch between the request type and response.
    /// - Parameter toolName: Name of the unexpected tool call.
    case unexpectedToolCall(toolName: String)

    /// JSON decoding failed.
    /// The response was valid JSON but did not match the expected schema.
    /// - Parameters:
    ///   - json: The raw JSON string that failed to decode.
    ///   - underlyingError: The decoding error with details.
    case decodingFailed(json: String, underlyingError: Error)

    /// Response was truncated due to max tokens limit.
    /// The JSON may be incomplete and cannot be parsed.
    /// - Parameter partialJSON: The truncated JSON string.
    case incompleteResponse(partialJSON: String)
}

// MARK: - LocalizedError

extension StructuredOutputError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelRefused(let reason):
            return "Model refused to generate output: \(reason)"

        case .emptyResponse:
            return "Model returned empty response with no content or tool calls"

        case .unexpectedTextResponse(let content):
            let preview = content.prefix(100)
            let suffix = content.count > 100 ? "..." : ""
            return "Expected tool call but received text: \(preview)\(suffix)"

        case .unexpectedToolCall(let toolName):
            return "Expected native structured output but received tool call: \(toolName)"

        case .decodingFailed(let json, let error):
            let preview = json.prefix(200)
            let suffix = json.count > 200 ? "..." : ""
            return "Failed to decode JSON: \(error.localizedDescription). JSON: \(preview)\(suffix)"

        case .incompleteResponse(let partial):
            let preview = partial.suffix(100)
            let prefix = partial.count > 100 ? "..." : ""
            return "Response truncated (max tokens reached). Partial JSON ends with: \(prefix)\(preview)"
        }
    }
}

// MARK: - Equatable (partial)

extension StructuredOutputError: Equatable {
    public static func == (lhs: StructuredOutputError, rhs: StructuredOutputError) -> Bool {
        switch (lhs, rhs) {
        case (.modelRefused(let l), .modelRefused(let r)):
            return l == r
        case (.emptyResponse, .emptyResponse):
            return true
        case (.unexpectedTextResponse(let l), .unexpectedTextResponse(let r)):
            return l == r
        case (.unexpectedToolCall(let l), .unexpectedToolCall(let r)):
            return l == r
        case (.decodingFailed(let lJson, _), .decodingFailed(let rJson, _)):
            // Compare only JSON, not the underlying error (not Equatable)
            return lJson == rJson
        case (.incompleteResponse(let l), .incompleteResponse(let r)):
            return l == r
        default:
            return false
        }
    }
}
