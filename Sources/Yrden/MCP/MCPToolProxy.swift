/// MCP Tool Proxy for routing tool calls through coordinator.
///
/// MCPToolProxy creates agent-compatible tools that route their execution
/// through the MCPCoordinator. This design ensures:
/// - Tools never hold stale connection references
/// - Reconnection is transparent to the caller
/// - Timeouts and cancellation are handled consistently
///
/// ## Usage
/// ```swift
/// let proxy = MCPToolProxy(
///     serverID: "filesystem",
///     toolInfo: toolInfo,
///     coordinator: coordinator
/// )
///
/// // Convert to AnyAgentTool for use with Agent
/// let tool: AnyAgentTool<Void> = proxy.asAnyAgentTool()
/// ```

import Foundation
import MCP

// MARK: - MCPToolProxy

/// Proxy that routes tool calls through the MCP coordinator.
///
/// This is the recommended way to expose MCP tools to agents.
/// The proxy doesn't hold connection state - it routes through
/// the coordinator which manages connection lifecycle.
/// - Note: Internal type for testing infrastructure.
struct MCPToolProxy: Sendable {
    /// Server ID this tool belongs to.
    let serverID: String

    /// Tool name.
    let name: String

    /// Tool description.
    let description: String

    /// Tool definition with JSON schema.
    let definition: ToolDefinition

    /// Maximum retry attempts (default: 1).
    let maxRetries: Int

    /// The coordinator to route calls through.
    private let coordinator: any MCPCoordinatorProtocol

    /// Timeout for this specific tool (nil uses coordinator default).
    let timeout: Duration?

    /// Create a tool proxy.
    ///
    /// - Parameters:
    ///   - serverID: ID of the server this tool belongs to
    ///   - toolInfo: Tool information from MCP
    ///   - coordinator: Coordinator to route calls through
    ///   - timeout: Optional timeout override
    ///   - maxRetries: Maximum retry attempts (default: 1)
    init(
        serverID: String,
        toolInfo: ToolInfo,
        coordinator: any MCPCoordinatorProtocol,
        timeout: Duration? = nil,
        maxRetries: Int = 1
    ) {
        self.serverID = serverID
        self.name = toolInfo.name
        self.description = toolInfo.description ?? "MCP tool: \(toolInfo.name)"
        self.definition = ToolDefinition(
            name: toolInfo.name,
            description: toolInfo.description ?? "",
            inputSchema: JSONValue(mcpValue: toolInfo.inputSchema)
        )
        self.coordinator = coordinator
        self.timeout = timeout
        self.maxRetries = maxRetries
    }

    /// Create a tool proxy from components.
    ///
    /// - Parameters:
    ///   - serverID: ID of the server this tool belongs to
    ///   - name: Tool name
    ///   - description: Tool description
    ///   - inputSchema: JSON schema for input
    ///   - coordinator: Coordinator to route calls through
    ///   - timeout: Optional timeout override
    ///   - maxRetries: Maximum retry attempts (default: 1)
    init(
        serverID: String,
        name: String,
        description: String,
        inputSchema: JSONValue,
        coordinator: any MCPCoordinatorProtocol,
        timeout: Duration? = nil,
        maxRetries: Int = 1
    ) {
        self.serverID = serverID
        self.name = name
        self.description = description
        self.definition = ToolDefinition(
            name: name,
            description: description,
            inputSchema: inputSchema
        )
        self.coordinator = coordinator
        self.timeout = timeout
        self.maxRetries = maxRetries
    }

    // MARK: - Tool Execution

    /// Call the tool with JSON arguments.
    ///
    /// Routes the call through the coordinator, which handles:
    /// - Connection state validation
    /// - Timeout enforcement
    /// - Error mapping
    ///
    /// - Parameter argumentsJSON: JSON-encoded arguments string
    /// - Returns: Tool result
    func call(argumentsJSON: String) async throws -> AnyToolResult {
        // Parse arguments from JSON string to MCP Value dictionary
        let arguments: [String: Value]?

        if argumentsJSON.isEmpty || argumentsJSON == "{}" {
            arguments = nil
        } else {
            guard let data = argumentsJSON.data(using: .utf8) else {
                return .failure(ToolExecutionError.argumentParsing("Invalid UTF-8 in arguments"))
            }

            do {
                let jsonValue = try JSONDecoder().decode(JSONValue.self, from: data)
                guard case .object(let obj) = jsonValue else {
                    return .failure(ToolExecutionError.argumentParsing("Arguments must be a JSON object"))
                }
                arguments = obj.asMCPValue
            } catch {
                return .failure(ToolExecutionError.argumentParsing(error.localizedDescription))
            }
        }

        // Route through coordinator
        do {
            let result = try await coordinator.callTool(
                serverID: serverID,
                name: name,
                arguments: arguments,
                timeout: timeout
            )
            return .success(result)

        } catch is CancellationError {
            // Propagate cancellation
            throw CancellationError()

        } catch let error as MCPConnectionError {
            return mapMCPError(error)

        } catch {
            return .failure(error)
        }
    }

    /// Map MCP errors to tool results.
    private func mapMCPError(_ error: MCPConnectionError) -> AnyToolResult {
        switch error {
        case .notConnected(let id):
            return .failure(MCPToolError.serverDisconnected(serverID: id))

        case .unknownServer(let id):
            return .failure(MCPToolError.serverDisconnected(serverID: id))

        case .toolTimeout(let id, let tool, let timeout):
            // Return retry on timeout - LLM can try simpler request
            return .retry(message: "Tool '\(tool)' on server '\(id)' timed out after \(timeout). Try a simpler request or break into steps.")

        case .toolCancelled(let id, let tool):
            return .failure(MCPToolError.toolCancelled(serverID: id, tool: tool))

        case .connectionFailed(let id, let message):
            return .failure(MCPToolError.executionFailed(
                name: name,
                server: id,
                message: message
            ))

        case .internalError(let message):
            return .failure(MCPToolError.executionFailed(
                name: name,
                server: serverID,
                message: "Internal error: \(message)"
            ))
        }
    }

    // MARK: - Conversion

    /// Convert to type-erased AnyAgentTool for use with Agent.
    ///
    /// The returned tool uses `Void` deps since MCP tools don't
    /// require local dependencies.
    ///
    /// - Returns: Type-erased agent tool
    func asAnyAgentTool() -> AnyAgentTool<Void> {
        AnyAgentTool<Void>(
            name: name,
            description: description,
            definition: definition,
            maxRetries: maxRetries
        ) { _, args in
            try await self.call(argumentsJSON: args)
        }
    }
}

// MARK: - Array Extension

extension Array where Element == MCPToolProxy {
    /// Convert all proxies to type-erased agent tools.
    func asAnyAgentTools() -> [AnyAgentTool<Void>] {
        map { $0.asAnyAgentTool() }
    }
}
