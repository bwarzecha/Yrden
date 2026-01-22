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
@attached(member, names: named(jsonSchema))
@attached(extension, conformances: SchemaType)
public macro Schema() = #externalMacro(module: "YrdenMacros", type: "SchemaMacro")
