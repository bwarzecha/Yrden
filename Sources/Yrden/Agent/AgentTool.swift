/// Tool protocol and result types for agent execution.
///
/// ## Protocol Hierarchy
/// ```
/// Tool                    ← base: JSON string → AnyToolResult, zero associated types
///   ├── TypedTool         ← adds Args + Output, auto-implements Tool.call()
///   ├── MCPToolProxy      ← raw Tool (schema from server)
///   ├── RetryingTool<T>   ← wraps any Tool, retries on .failed
///   ├── ApprovalRequired<T> ← overrides requiresApproval to true
///   └── ClosureTool<A,O>  ← inline closure definition (future)
/// ```
///
/// ## Creating a Tool
/// ```swift
/// struct SearchTool: TypedTool {
///     var name: String { "search" }
///     var description: String { "Search the web" }
///
///     func execute(
///         context: ToolContext,
///         arguments: SearchArgs
///     ) async throws -> ToolResult<String> {
///         .success("results for: \(arguments.query)")
///     }
/// }
///
/// // All tools in one array — no wrapping needed
/// let tools: [any Tool] = [SearchTool(), mcpProxy, flakyTool.withRetries(3)]
/// ```

import Foundation

// MARK: - Tool Protocol

/// Base tool protocol. The agent stores `[any Tool]`.
///
/// Zero associated types — enables heterogeneous arrays with no type parameter.
/// The call interface uses raw JSON strings and erased results.
public protocol Tool: Sendable {
    /// Unique identifier for the tool. Must match `[a-zA-Z0-9_-]+`.
    var name: String { get }

    /// Description shown to the LLM.
    var description: String { get }

    /// Full definition including JSON schema.
    var definition: ToolDefinition { get }

    /// Whether this tool requires human approval before execution.
    var requiresApproval: Bool { get }

    /// Execute the tool with JSON-encoded arguments.
    func call(context: ToolContext, argumentsJSON: String) async throws -> AnyToolResult
}

extension Tool {
    public var requiresApproval: Bool { false }
}

// MARK: - TypedTool Protocol

/// Typed tool with compile-time argument and output types.
///
/// Default `call()` decodes JSON → Args, calls `execute()`,
/// then erases Output → String via `ToolResult.erased()`.
///
/// Swift infers `Args` (and `Output` if defaulted) from the `execute()` signature:
/// ```swift
/// // Zero typealiases for the common case
/// struct SearchTool: TypedTool {
///     var name: String { "search" }
///     var description: String { "Search the web" }
///
///     func execute(context: ToolContext, arguments: SearchArgs) async throws -> ToolResult<String> {
///         .success("results for: \(arguments.query)")
///     }
/// }
/// ```
public protocol TypedTool: Tool {
    /// Arguments type with JSON Schema generation.
    associatedtype Args: SchemaType

    /// Output type returned on success. Defaults to `String`.
    associatedtype Output: Sendable = String

    /// Execute the tool with typed arguments.
    func execute(context: ToolContext, arguments: Args) async throws -> ToolResult<Output>
}

extension TypedTool {
    public var definition: ToolDefinition {
        ToolDefinition(name: name, description: description, inputSchema: Args.jsonSchema)
    }

    public func call(
        context: ToolContext,
        argumentsJSON: String
    ) async throws -> AnyToolResult {
        guard let data = argumentsJSON.data(using: .utf8) else {
            throw ToolExecutionError.argumentParsing("Invalid UTF-8 in arguments")
        }
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: data)
        } catch {
            throw ToolExecutionError.argumentParsing(error.localizedDescription)
        }
        let result = try await execute(context: context, arguments: args)
        return result.erased()
    }
}

// MARK: - ApprovalRequired

/// Wraps any tool and overrides `requiresApproval` to `true`.
public struct ApprovalRequired<Wrapped: Tool>: Tool {
    private let wrapped: Wrapped

    public var name: String { wrapped.name }
    public var description: String { wrapped.description }
    public var definition: ToolDefinition { wrapped.definition }
    public var requiresApproval: Bool { true }

    init(_ tool: Wrapped) { self.wrapped = tool }

    public func call(
        context: ToolContext, argumentsJSON: String
    ) async throws -> AnyToolResult {
        try await wrapped.call(context: context, argumentsJSON: argumentsJSON)
    }
}

extension Tool {
    /// Mark this tool as requiring human approval before execution.
    public func requireApproval() -> ApprovalRequired<Self> {
        ApprovalRequired(self)
    }
}

// MARK: - ToolResult

/// Result of a tool execution.
///
/// - `.success`: Tool executed successfully with typed output
/// - `.failure`: Tool failed, error sent to LLM for retry
/// - `.deferred`: Tool needs external resolution (human approval)
public enum ToolResult<T: Sendable>: Sendable {
    case success(T)
    case failure(Error)
    case deferred(DeferredToolCall)
}

extension ToolResult where T == String {
    /// Create a success result from a string literal.
    public static func text(_ value: String) -> ToolResult<String> {
        .success(value)
    }
}

extension ToolResult {
    /// Create a failure result from an error message.
    public static func error(_ message: String) -> ToolResult<T> {
        .failure(ToolExecutionError.custom(message))
    }
}

// MARK: - ToolResult Erasure

extension ToolResult {
    /// Convert typed result to erased result for the agent loop.
    func erased() -> AnyToolResult {
        switch self {
        case .success(let value):
            if let string = value as? String {
                return .success(string)
            } else if let jsonValue = value as? JSONValue {
                if let data = try? JSONEncoder().encode(jsonValue),
                   let string = String(data: data, encoding: .utf8) {
                    return .success(string)
                }
                return .success(String(describing: value))
            } else if let encodable = value as? Encodable {
                if let data = try? JSONEncoder().encode(AnyEncodable(encodable)),
                   let string = String(data: data, encoding: .utf8) {
                    return .success(string)
                }
                return .success(String(describing: value))
            } else {
                return .success(String(describing: value))
            }
        case .failure(let error):
            return .failed(error)
        case .deferred(let call):
            return .deferred(call)
        }
    }
}

// MARK: - AnyEncodable Helper

private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init(_ encodable: Encodable) {
        self._encode = { try encodable.encode(to: $0) }
    }
    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

// MARK: - DeferredToolCall

/// Information about a deferred tool call.
public struct DeferredToolCall: Sendable, Codable, Equatable, Hashable {
    public let id: String
    public let reason: String
    public let kind: DeferralKind

    public init(id: String, reason: String, kind: DeferralKind = .approval) {
        self.id = id
        self.reason = reason
        self.kind = kind
    }
}

/// Type of tool deferral.
public enum DeferralKind: String, Sendable, Codable, Equatable, Hashable {
    case approval
    case external
    case custom
}

extension DeferredToolCall {
    /// Create a deferral for approval.
    public static func needsApproval(
        id: String = UUID().uuidString,
        reason: String
    ) -> DeferredToolCall {
        DeferredToolCall(id: id, reason: reason, kind: .approval)
    }

    /// Create a deferral for external operation.
    public static func external(
        id: String = UUID().uuidString,
        reason: String
    ) -> DeferredToolCall {
        DeferredToolCall(id: id, reason: reason, kind: .external)
    }
}

// MARK: - ToolExecutionError

/// Errors that can occur during tool execution.
public enum ToolExecutionError: Error, Sendable, Equatable {
    case custom(String)
    case argumentParsing(String)
    case argumentValidation(String)
    case toolNotFound(String)
}

extension ToolExecutionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .custom(let message): return message
        case .argumentParsing(let details): return "Failed to parse tool arguments: \(details)"
        case .argumentValidation(let details): return "Tool argument validation failed: \(details)"
        case .toolNotFound(let name): return "Tool not found: \(name)"
        }
    }
}

// MARK: - AnyToolResult

/// Type-erased tool result used by the agent loop.
public enum AnyToolResult: Sendable {
    /// Tool succeeded with string output.
    case success(String)

    /// Tool was denied by user with message.
    case denied(String)

    /// Tool result was replaced with synthetic value.
    case replaced(String)

    /// Tool failed permanently.
    case failed(Error)

    /// Legacy alias for `.failed` — use `.failed` instead.
    @available(*, deprecated, message: "Use .failed instead")
    case failure(Error)

    /// Tool is deferred.
    case deferred(DeferredToolCall)

    /// Convert to ToolOutput for sending back to LLM.
    public var toolOutput: ToolOutput {
        switch self {
        case .success(let value): return .text(value)
        case .denied(let message): return .error("Tool denied: \(message)")
        case .replaced(let result): return .text(result)
        case .failed(let error), .failure(let error):
            return .error("Tool failed: \(error.localizedDescription)")
        case .deferred(let call): return .error("Tool deferred: \(call.reason)")
        }
    }

    /// The output string regardless of result type.
    public var output: String {
        switch self {
        case .success(let value): return value
        case .denied(let message): return "Tool denied: \(message)"
        case .replaced(let result): return result
        case .failed(let error), .failure(let error):
            return "Tool failed: \(error.localizedDescription)"
        case .deferred(let call): return "Tool deferred: \(call.reason)"
        }
    }

    /// Whether this result is deferred.
    public var isDeferred: Bool {
        if case .deferred = self { return true }
        return false
    }
}

// MARK: - AnyToolResult Codable

private struct SerializedError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension AnyToolResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, value, message, error, deferred
    }

    private enum ResultType: String, Codable {
        case success, denied, replaced, failed, deferred, failure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ResultType.self, forKey: .type)
        switch type {
        case .success:
            self = .success(try container.decode(String.self, forKey: .value))
        case .denied:
            self = .denied(try container.decode(String.self, forKey: .message))
        case .replaced:
            self = .replaced(try container.decode(String.self, forKey: .value))
        case .failed, .failure:
            self = .failed(SerializedError(
                message: try container.decode(String.self, forKey: .error)
            ))
        case .deferred:
            self = .deferred(try container.decode(DeferredToolCall.self, forKey: .deferred))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let value):
            try container.encode(ResultType.success, forKey: .type)
            try container.encode(value, forKey: .value)
        case .denied(let message):
            try container.encode(ResultType.denied, forKey: .type)
            try container.encode(message, forKey: .message)
        case .replaced(let value):
            try container.encode(ResultType.replaced, forKey: .type)
            try container.encode(value, forKey: .value)
        case .failed(let error), .failure(let error):
            try container.encode(ResultType.failed, forKey: .type)
            try container.encode(error.localizedDescription, forKey: .error)
        case .deferred(let call):
            try container.encode(ResultType.deferred, forKey: .type)
            try container.encode(call, forKey: .deferred)
        }
    }
}
