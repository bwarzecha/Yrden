/// Tool protocol and result types for agent execution.
///
/// Tools are the bridge between LLM requests and real-world actions.
/// The `AgentTool` protocol defines:
/// - Tool metadata (name, description)
/// - Typed arguments via `@Schema`
/// - Execution logic with context access
///
/// ## Creating a Tool
/// ```swift
/// struct WeatherTool: AgentTool {
///     typealias Deps = AppDeps
///
///     @Schema(description: "Weather query parameters")
///     struct Args: SchemaType {
///         @Guide(description: "City name")
///         let city: String
///     }
///
///     var name: String { "get_weather" }
///     var description: String { "Get current weather for a city" }
///
///     func call(
///         context: AgentContext<AppDeps>,
///         arguments: Args
///     ) async throws -> ToolResult<String> {
///         let weather = try await context.deps.weatherAPI.get(arguments.city)
///         return .success("Weather in \(arguments.city): \(weather.temp)°F")
///     }
/// }
/// ```

import Foundation

// MARK: - AgentTool Protocol

/// A tool that can be called by an agent.
///
/// Tools provide functionality that the LLM can invoke during execution.
/// The agent:
/// 1. Sends `ToolDefinition` (derived from this protocol) to the LLM
/// 2. Receives `ToolCall` when LLM wants to use the tool
/// 3. Parses arguments into `Args` type
/// 4. Calls this protocol's `call` method
/// 5. Handles the `ToolResult`
public protocol AgentTool<Deps>: Sendable {
    /// Type of dependencies this tool requires.
    /// Use `Void` for tools with no dependencies.
    associatedtype Deps: Sendable = Void

    /// Arguments type, must conform to SchemaType for JSON Schema generation.
    associatedtype Args: SchemaType

    /// Output type returned on success.
    associatedtype Output: Sendable = String

    /// Unique identifier for the tool.
    /// Must match regex `[a-zA-Z0-9_-]+`.
    var name: String { get }

    /// Description shown to the LLM.
    /// Should clearly explain when and how to use the tool.
    var description: String { get }

    /// Maximum retry attempts when tool returns `.retry`.
    /// After this many retries, the agent will use `.failure` instead.
    /// Default is 1 (allow one retry attempt).
    var maxRetries: Int { get }

    /// Execute the tool with the given arguments.
    ///
    /// - Parameters:
    ///   - context: Agent context with dependencies and run state
    ///   - arguments: Parsed and validated arguments from the LLM
    /// - Returns: Result of execution (success, retry, failure, or deferred)
    func call(
        context: AgentContext<Deps>,
        arguments: Args
    ) async throws -> ToolResult<Output>
}

// MARK: - Default Implementations

extension AgentTool {
    /// Default max retries is 1.
    public var maxRetries: Int { 1 }
}

// MARK: - Tool Definition Generation

extension AgentTool {
    /// Generate the `ToolDefinition` to send to the LLM.
    public var definition: ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            inputSchema: Args.jsonSchema
        )
    }
}

// MARK: - ToolResult

/// Result of a tool execution.
///
/// Tools return one of four outcomes:
/// - `.success`: Tool executed successfully with output
/// - `.retry`: Tool failed but LLM should retry with feedback
/// - `.failure`: Tool failed permanently
/// - `.deferred`: Tool needs external resolution (human approval, async operation)
public enum ToolResult<T: Sendable>: Sendable {
    /// Tool succeeded with output.
    case success(T)

    /// Tool failed, ask LLM to retry with feedback.
    /// The message is sent back to the LLM to help it correct its approach.
    case retry(message: String)

    /// Tool failed permanently with an error.
    case failure(Error)

    /// Tool is deferred - needs external resolution.
    /// Used for human-in-the-loop approval or async operations.
    case deferred(DeferredToolCall)
}

// MARK: - Convenience Initializers

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

// MARK: - DeferredToolCall

/// Information about a deferred tool call.
///
/// When a tool returns `.deferred`, the agent pauses and provides
/// this information for external resolution.
public struct DeferredToolCall: Sendable, Equatable, Hashable {
    /// Unique identifier for this deferred call.
    public let id: String

    /// Reason the tool was deferred.
    public let reason: String

    /// Type of deferral.
    public let kind: DeferralKind

    public init(id: String, reason: String, kind: DeferralKind = .approval) {
        self.id = id
        self.reason = reason
        self.kind = kind
    }
}

/// Type of tool deferral.
public enum DeferralKind: String, Sendable, Codable, Equatable, Hashable {
    /// Needs human approval before execution.
    case approval

    /// Waiting for external async operation.
    case external

    /// Custom deferral reason.
    case custom
}

// MARK: - Convenience Factory

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
    /// Custom error message.
    case custom(String)

    /// Failed to parse arguments.
    case argumentParsing(String)

    /// Tool not found.
    case toolNotFound(String)

    /// Maximum retries exceeded.
    case maxRetriesExceeded(toolName: String, attempts: Int)
}

extension ToolExecutionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .custom(let message):
            return message
        case .argumentParsing(let details):
            return "Failed to parse tool arguments: \(details)"
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .maxRetriesExceeded(let name, let attempts):
            return "Tool '\(name)' failed after \(attempts) retry attempts"
        }
    }
}

// MARK: - Type-Erased Tool Wrapper

/// Type-erased wrapper for heterogeneous tool collections.
///
/// Since tools have associated types, we need a wrapper to store
/// them in arrays. This wrapper handles:
/// - Definition generation
/// - Argument parsing
/// - Execution with type erasure
public struct AnyAgentTool<Deps: Sendable>: Sendable {
    public let name: String
    public let description: String
    public let maxRetries: Int
    public let definition: ToolDefinition

    private let _call: @Sendable (AgentContext<Deps>, String) async throws -> AnyToolResult

    /// Create a type-erased wrapper from a concrete tool.
    public init<T: AgentTool>(_ tool: T) where T.Deps == Deps {
        self.name = tool.name
        self.description = tool.description
        self.maxRetries = tool.maxRetries
        self.definition = tool.definition

        self._call = { context, argumentsJSON in
            // Parse arguments
            guard let data = argumentsJSON.data(using: .utf8) else {
                throw ToolExecutionError.argumentParsing("Invalid UTF-8 in arguments")
            }

            let args: T.Args
            do {
                args = try JSONDecoder().decode(T.Args.self, from: data)
            } catch {
                throw ToolExecutionError.argumentParsing(error.localizedDescription)
            }

            // Execute tool
            let result = try await tool.call(context: context, arguments: args)

            // Convert to AnyToolResult
            return result.erased()
        }
    }

    /// Execute the tool with JSON arguments.
    public func call(
        context: AgentContext<Deps>,
        argumentsJSON: String
    ) async throws -> AnyToolResult {
        try await _call(context, argumentsJSON)
    }

    /// Create a type-erased tool from components.
    ///
    /// This initializer is useful for creating tools from external sources
    /// like MCP servers where the schema is already defined.
    ///
    /// - Parameters:
    ///   - name: Tool name
    ///   - description: Tool description
    ///   - definition: Tool definition with schema
    ///   - maxRetries: Maximum retry attempts (default: 1)
    ///   - call: Execution closure that takes context and JSON arguments
    public init(
        name: String,
        description: String,
        definition: ToolDefinition,
        maxRetries: Int = 1,
        call: @escaping @Sendable (AgentContext<Deps>, String) async throws -> AnyToolResult
    ) {
        self.name = name
        self.description = description
        self.maxRetries = maxRetries
        self.definition = definition
        self._call = call
    }
}

// MARK: - AnyToolResult

/// Type-erased tool result.
public enum AnyToolResult: Sendable {
    /// Tool succeeded with string output.
    case success(String)

    /// Tool failed, ask LLM to retry with feedback.
    case retry(message: String)

    /// Tool failed permanently.
    case failure(Error)

    /// Tool is deferred.
    case deferred(DeferredToolCall)

    /// Convert to ToolOutput for sending back to LLM.
    public var toolOutput: ToolOutput {
        switch self {
        case .success(let value):
            return .text(value)
        case .retry(let message):
            return .error(message)
        case .failure(let error):
            return .error(error.localizedDescription)
        case .deferred(let call):
            return .error("Tool deferred: \(call.reason)")
        }
    }

    /// Whether this result requires retry.
    public var needsRetry: Bool {
        if case .retry = self { return true }
        return false
    }

    /// Whether this result is deferred.
    public var isDeferred: Bool {
        if case .deferred = self { return true }
        return false
    }
}

// MARK: - ToolResult Erasure

extension ToolResult {
    /// Convert to type-erased result.
    func erased() -> AnyToolResult {
        switch self {
        case .success(let value):
            // Convert output to string
            if let string = value as? String {
                return .success(string)
            } else if let jsonValue = value as? JSONValue {
                // Encode JSONValue to string
                if let data = try? JSONEncoder().encode(jsonValue),
                   let string = String(data: data, encoding: .utf8) {
                    return .success(string)
                }
                return .success(String(describing: value))
            } else if let encodable = value as? Encodable {
                // Try to encode as JSON
                if let data = try? JSONEncoder().encode(AnyEncodable(encodable)),
                   let string = String(data: data, encoding: .utf8) {
                    return .success(string)
                }
                return .success(String(describing: value))
            } else {
                return .success(String(describing: value))
            }
        case .retry(let message):
            return .retry(message: message)
        case .failure(let error):
            return .failure(error)
        case .deferred(let call):
            return .deferred(call)
        }
    }
}

// MARK: - AnyEncodable Helper

private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ encodable: Encodable) {
        self._encode = { encoder in
            try encodable.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

// MARK: - Deps Lifting

extension AnyAgentTool where Deps == Void {
    /// Lift a Void-deps tool to work with any deps type.
    ///
    /// This is useful for mixing MCP tools (which use Void deps) with
    /// local tools that require specific dependencies.
    ///
    /// ## Example
    /// ```swift
    /// // MCP tools use Void deps
    /// let mcpTools: [AnyAgentTool<Void>] = manager.allTools()
    ///
    /// // Local tools use custom deps
    /// let localTools: [AnyAgentTool<MyDeps>] = [myTool.erased()]
    ///
    /// // Lift MCP tools to match
    /// let allTools: [AnyAgentTool<MyDeps>] = mcpTools.lifted() + localTools
    /// ```
    ///
    /// - Returns: Tool that ignores deps and works with any deps type
    public func lifted<D: Sendable>() -> AnyAgentTool<D> {
        AnyAgentTool<D>(
            name: name,
            description: description,
            definition: definition,
            maxRetries: maxRetries
        ) { context, args in
            // Create a void context passing through the context metadata
            let voidContext = AgentContext<Void>(
                deps: (),
                model: context.model,
                usage: context.usage,
                retries: context.retries,
                toolCallID: context.toolCallID,
                toolName: context.toolName,
                runStep: context.runStep,
                runID: context.runID,
                messages: context.messages
            )
            return try await self.call(context: voidContext, argumentsJSON: args)
        }
    }
}

extension Array where Element == AnyAgentTool<Void> {
    /// Lift all Void-deps tools to work with any deps type.
    ///
    /// - Returns: Array of tools that work with the specified deps type
    public func lifted<D: Sendable>() -> [AnyAgentTool<D>] {
        map { $0.lifted() }
    }
}
