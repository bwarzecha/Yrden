/// MCP Tool wrapper for Yrden Agent integration.
///
/// Wraps an MCP server tool as a Yrden `AnyAgentTool`, enabling MCP tools
/// to be used seamlessly in Agent workflows.
///
/// ## Usage
/// ```swift
/// let server = try await MCPServerConnection.stdio(
///     command: "uvx",
///     arguments: ["mcp-server-filesystem", "--root", "/tmp"]
/// )
///
/// let tools = try await server.discoverTools()
/// let agent = Agent<Void, String>(
///     model: model,
///     tools: tools,  // MCPTools work like any other tool
///     systemPrompt: "You can read and write files."
/// )
/// ```

import Foundation
import MCP

// MARK: - MCPTool

/// A wrapper that exposes an MCP tool as a Yrden AgentTool.
///
/// MCPTool handles:
/// - Converting the MCP tool schema to Yrden's format
/// - Executing tool calls via the MCP client
/// - Converting arguments and results between formats
///
/// - Note: Deprecated. Use `MCPToolProxy` with `MCPCoordinator` instead
///   for proper connection lifecycle management.
@available(*, deprecated, message: "Use MCPToolProxy with MCPCoordinator instead")
public struct MCPTool<Deps: Sendable>: Sendable {
    /// The MCP tool metadata.
    public let mcpTool: MCP.Tool

    /// The MCP client used to execute the tool.
    private let client: Client

    /// Server identifier for error messages.
    private let serverID: String

    /// Create an MCPTool wrapping an MCP server tool.
    ///
    /// - Parameters:
    ///   - tool: The MCP tool metadata from `listTools()`
    ///   - client: The MCP client to use for execution
    ///   - serverID: Identifier for the server (for error messages)
    public init(tool: MCP.Tool, client: Client, serverID: String) {
        self.mcpTool = tool
        self.client = client
        self.serverID = serverID
    }

    /// Tool name (from MCP).
    public var name: String { mcpTool.name }

    /// Tool description (from MCP).
    public var description: String { mcpTool.description ?? "MCP tool: \(mcpTool.name)" }

    /// Maximum retries (MCP tools default to 1).
    public var maxRetries: Int { 1 }

    /// Generate the ToolDefinition for the agent.
    public var definition: ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            inputSchema: JSONValue(mcpValue: mcpTool.inputSchema)
        )
    }

    /// Execute the MCP tool with JSON arguments.
    ///
    /// - Parameters:
    ///   - context: Agent context (not used for MCP tools, but required by protocol)
    ///   - argumentsJSON: JSON string of arguments from the LLM
    /// - Returns: Tool result
    public func call(
        context: AgentContext<Deps>,
        argumentsJSON: String
    ) async throws -> AnyToolResult {
        // Parse arguments using shared helper
        let arguments: [String: Value]?
        switch parseMCPArguments(argumentsJSON) {
        case .success(let args):
            arguments = args
        case .error(let error):
            return .failure(error)
        }

        // Call the MCP tool
        do {
            let result = try await client.callTool(name: name, arguments: arguments)

            // Check for error response
            if result.isError == true {
                let errorText = result.content.compactMap { content -> String? in
                    if case .text(let text) = content {
                        return text
                    }
                    return nil
                }.joined(separator: "\n")
                return .failure(MCPToolError.toolReturnedError(name: name, message: errorText))
            }

            // Convert content to string result
            let resultText = result.content.map { content -> String in
                switch content {
                case .text(let text):
                    return text
                case .image(let data, let mimeType, _):
                    return "[Image: \(mimeType), \(data.count) bytes]"
                case .audio(let data, let mimeType):
                    return "[Audio: \(mimeType), \(data.count) bytes]"
                case .resource(let uri, let mimeType, let text):
                    if let text = text {
                        return text
                    }
                    return "[Resource: \(uri), \(mimeType)]"
                }
            }.joined(separator: "\n")

            return .success(resultText)
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

// MARK: - Type-Erased Wrapper

extension MCPTool {
    /// Convert to AnyAgentTool for use in heterogeneous tool collections.
    public func asAnyAgentTool() -> AnyAgentTool<Deps> {
        // Capture self for the closure
        let tool = self
        return AnyAgentTool<Deps>(
            name: name,
            description: description,
            definition: definition,
            maxRetries: maxRetries,
            call: { context, argumentsJSON in
                try await tool.call(context: context, argumentsJSON: argumentsJSON)
            }
        )
    }
}
