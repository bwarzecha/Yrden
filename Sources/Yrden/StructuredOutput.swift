/// Typed response container for structured output.
///
/// `TypedResponse` wraps the decoded data along with metadata from the LLM response.
/// This provides a type-safe way to access structured output while preserving
/// usage statistics and stop reason information.
///
/// ## Example
/// ```swift
/// let result: TypedResponse<PersonInfo> = try await model.generate(
///     "Extract: John is 30 years old",
///     as: PersonInfo.self
/// )
///
/// // Access typed data directly
/// print(result.data.name)  // "John"
/// print(result.data.age)   // 30
///
/// // Access metadata
/// print(result.usage.totalTokens)  // Token count
/// print(result.stopReason)          // .endTurn
///
/// // Debug with raw JSON if needed
/// print(result.rawJSON)  // {"name": "John", "age": 30}
/// ```

import Foundation

// MARK: - TypedResponse

/// A typed response from structured output generation.
///
/// Contains the decoded data along with metadata from the LLM response.
/// The generic parameter `T` is constrained to `SchemaType` to ensure
/// the type has a JSON Schema representation.
public struct TypedResponse<T: SchemaType>: Sendable {
    /// The decoded typed data.
    /// This is the main result from structured output generation.
    public let data: T

    /// Token usage for this request.
    /// Use this for billing estimation and context window management.
    public let usage: Usage

    /// Why the model stopped generating.
    /// Typically `.endTurn` for successful completions.
    public let stopReason: StopReason

    /// Raw JSON string before decoding.
    /// Useful for debugging when decoding succeeds but data looks wrong.
    public let rawJSON: String

    public init(
        data: T,
        usage: Usage,
        stopReason: StopReason,
        rawJSON: String
    ) {
        self.data = data
        self.usage = usage
        self.stopReason = stopReason
        self.rawJSON = rawJSON
    }
}

// MARK: - Equatable

extension TypedResponse: Equatable where T: Equatable {
    public static func == (lhs: TypedResponse<T>, rhs: TypedResponse<T>) -> Bool {
        lhs.data == rhs.data &&
        lhs.usage == rhs.usage &&
        lhs.stopReason == rhs.stopReason &&
        lhs.rawJSON == rhs.rawJSON
    }
}

// MARK: - Hashable

extension TypedResponse: Hashable where T: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(data)
        hasher.combine(usage)
        hasher.combine(stopReason)
        hasher.combine(rawJSON)
    }
}
