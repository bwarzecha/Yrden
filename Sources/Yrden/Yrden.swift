/// Yrden - PydanticAI for Swift
///
/// A production-grade Swift library for building AI agents with:
/// - Multi-provider support (Anthropic, OpenAI, OpenRouter, Bedrock, MLX)
/// - Type-safe structured outputs via Swift macros
/// - Agentic loop with full control
/// - MCP (Model Context Protocol) integration

/// Protocol for types that can generate JSON Schema representations.
public protocol SchemaType: Codable, Sendable {
    /// JSON Schema representation of this type.
    /// Uses JSONValue instead of [String: Any] for:
    /// - Sendable compliance (Swift 6 concurrency)
    /// - Codable support (serialization)
    /// - Type safety
    static var jsonSchema: JSONValue { get }
}

/// Macro that generates JSON Schema from Swift struct definitions.
///
/// Usage:
/// ```swift
/// @Schema
/// struct Person {
///     let name: String
///     let age: Int
/// }
///
/// @Schema(description: "User profile data")
/// struct UserProfile {
///     @Guide(description: "User's display name")
///     let name: String
/// }
/// ```
@attached(member, names: named(jsonSchema))
@attached(extension, conformances: SchemaType)
public macro Schema(description: String? = nil) = #externalMacro(module: "YrdenMacros", type: "SchemaMacro")

/// Macro that adds description and constraints to schema properties.
///
/// Usage:
/// ```swift
/// @Schema
/// struct SearchQuery {
///     @Guide(description: "Search terms")
///     let query: String
///
///     @Guide(description: "Max results", .range(1...100))
///     let limit: Int
/// }
/// ```
@attached(peer)
public macro Guide(description: String, _ constraints: SchemaConstraint...) = #externalMacro(module: "YrdenMacros", type: "GuideMacro")

/// Constraints for schema properties.
public enum SchemaConstraint: Sendable {
    /// Numeric range constraint (inclusive).
    case range(ClosedRange<Int>)
    /// Numeric range constraint for doubles (inclusive).
    case rangeDouble(ClosedRange<Double>)
    /// Minimum value constraint.
    case minimum(Int)
    /// Maximum value constraint.
    case maximum(Int)
    /// Array count constraint (inclusive).
    case count(ClosedRange<Int>)
    /// Exact array count.
    case exactCount(Int)
    /// String must be one of these options.
    case options([String])
    /// String must match this regex pattern.
    case pattern(String)
}

// MARK: - Built-in SchemaType Conformances

/// String conforms to SchemaType for simple text output.
extension String: SchemaType {
    public static var jsonSchema: JSONValue {
        ["type": "string"]
    }
}
