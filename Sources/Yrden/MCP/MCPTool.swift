/// MCP tool types for Yrden Agent integration.

import Foundation
import MCP

// MARK: - MCPServerTool

/// A tool wrapper that calls an MCP server connection directly.
///
/// Use this when working with `MCPServerConnection` directly (not through a coordinator).
/// For coordinator-managed connections, use `MCPToolProxy` instead.
///
/// Created via `MCPServerConnection.tools()`.
public struct MCPServerTool: Tool, Sendable {
    public let name: String
    public let description: String
    public let definition: ToolDefinition
    public var requiresApproval: Bool { false }

    private let server: MCPServerConnection
    private let serverID: String

    init(toolInfo: ToolInfo, server: MCPServerConnection, serverID: String) {
        self.name = toolInfo.name
        self.description = toolInfo.description ?? "MCP tool: \(toolInfo.name)"
        self.definition = ToolDefinition(
            name: toolInfo.name,
            description: toolInfo.description ?? "MCP tool: \(toolInfo.name)",
            inputSchema: JSONValue(mcpValue: toolInfo.inputSchema)
        )
        self.server = server
        self.serverID = serverID
    }

    public func call(
        context: ToolContext,
        argumentsJSON: String
    ) async throws -> AnyToolResult {
        let arguments: [String: Value]?
        switch parseMCPArguments(argumentsJSON) {
        case .success(let args):
            arguments = args
        case .error(let error):
            return .failure(error)
        }

        do {
            let result = try await server.callTool(name: name, arguments: arguments)
            let text = formatMCPToolResult(result.content, isError: result.isError)
            if result.isError == true {
                return .failure(MCPToolError.toolReturnedError(name: name, message: text))
            }
            return .success(text)
        } catch {
            return .failure(MCPToolError.executionFailed(
                name: name,
                server: serverID,
                message: error.localizedDescription
            ))
        }
    }
}

// MARK: - MCPToolError

/// Errors specific to MCP tool execution.
public enum MCPToolError: Error, Sendable, Equatable {
    /// The MCP tool returned an error response.
    case toolReturnedError(name: String, message: String)

    /// Tool execution failed.
    case executionFailed(name: String, server: String, message: String)

    /// Server disconnected during execution.
    case serverDisconnected(serverID: String)

    /// Tool execution was cancelled.
    case toolCancelled(serverID: String, tool: String)
}

extension MCPToolError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .toolReturnedError(let name, let message):
            return "MCP tool '\(name)' returned error: \(message)"
        case .executionFailed(let name, let server, let message):
            return "MCP tool '\(name)' from server '\(server)' failed: \(message)"
        case .serverDisconnected(let serverID):
            return "MCP server '\(serverID)' disconnected"
        case .toolCancelled(let serverID, let tool):
            return "Tool '\(tool)' on server '\(serverID)' was cancelled"
        }
    }
}
