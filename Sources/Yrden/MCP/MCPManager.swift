/// MCP Manager for multi-server orchestration.
///
/// Manages multiple MCP server connections and aggregates their capabilities:
/// - Connect to multiple servers simultaneously
/// - Aggregate tools from all servers
/// - Route tool calls to the appropriate server
/// - Handle server lifecycle (connect, disconnect, reconnect)
///
/// ## Usage
/// ```swift
/// let manager = MCPManager()
///
/// // Connect to servers
/// try await manager.addServer(.stdio(
///     command: "uvx",
///     arguments: ["mcp-server-filesystem", "--root", "/tmp"],
///     name: "Filesystem"
/// ))
///
/// try await manager.addServer(.http(
///     url: URL(string: "https://api.example.com/mcp")!,
///     headers: ["Authorization": "Bearer ..."],
///     name: "Remote API"
/// ))
///
/// // Get all tools from all servers
/// let tools = await manager.allTools()
///
/// // Use with Agent
/// let agent = Agent<Void, String>(
///     model: model,
///     tools: tools,
///     systemPrompt: "You have access to filesystem and API tools."
/// )
/// ```

import Foundation
import MCP

// MARK: - MCPManager

/// Manages multiple MCP server connections.
///
/// Provides a unified interface for working with tools, resources, and prompts
/// from multiple MCP servers.
public actor MCPManager {
    /// Connected servers by ID.
    private var servers: [String: MCPServerConnection] = [:]

    /// Cached aggregated tools.
    private var toolCache: [String: AnyAgentTool<Void>]? = nil

    /// Create a new MCP manager.
    public init() {}

    // MARK: - Server Management

    /// Add and connect to an MCP server.
    ///
    /// - Parameter config: Server configuration
    /// - Returns: The connected server
    /// - Throws: If connection fails
    @discardableResult
    public func addServer(_ config: MCPServerConfig) async throws -> MCPServerConnection {
        let server = try await config.connect()

        if servers[server.id] != nil {
            // Disconnect existing server with same ID
            await servers[server.id]?.disconnect()
        }

        servers[server.id] = server
        toolCache = nil // Invalidate cache

        // Listen for tool changes
        await server.onToolsChanged { [weak self] in
            await self?.invalidateToolCache()
        }

        return server
    }

    /// Remove and disconnect a server.
    ///
    /// - Parameter id: Server ID
    public func removeServer(_ id: String) async {
        if let server = servers.removeValue(forKey: id) {
            await server.disconnect()
            toolCache = nil
        }
    }

    /// Get a connected server by ID.
    ///
    /// - Parameter id: Server ID
    /// - Returns: Server connection, or nil if not found
    public func server(_ id: String) -> MCPServerConnection? {
        servers[id]
    }

    /// All connected servers.
    public var connectedServers: [MCPServerConnection] {
        Array(servers.values)
    }

    /// Disconnect all servers.
    public func disconnectAll() async {
        for server in servers.values {
            await server.disconnect()
        }
        servers.removeAll()
        toolCache = nil
    }

    // MARK: - Tools

    /// Get all tools from all connected servers.
    ///
    /// Tools are cached and automatically refreshed when servers report changes.
    ///
    /// - Returns: Array of tools from all servers
    public func allTools<Deps: Sendable>() async throws -> [AnyAgentTool<Deps>] {
        var tools: [AnyAgentTool<Deps>] = []

        for server in servers.values {
            let serverTools: [AnyAgentTool<Deps>] = try await server.discoverTools()
            tools.append(contentsOf: serverTools)
        }

        return tools
    }

    /// Get tools from a specific server.
    ///
    /// - Parameter serverID: Server ID
    /// - Returns: Tools from that server, or empty if not found
    public func tools<Deps: Sendable>(from serverID: String) async throws -> [AnyAgentTool<Deps>] {
        guard let server = servers[serverID] else {
            return []
        }
        return try await server.discoverTools()
    }

    /// Refresh tools from all servers.
    public func refreshTools() async throws {
        toolCache = nil
        for server in servers.values {
            try await server.refreshTools()
        }
    }

    /// Invalidate the tool cache.
    private func invalidateToolCache() {
        toolCache = nil
    }

    // MARK: - Resources

    /// Get all resources from all connected servers.
    ///
    /// - Returns: Array of (serverID, resource) tuples
    public func allResources() async throws -> [(serverID: String, resource: Resource)] {
        var results: [(String, Resource)] = []

        for (id, server) in servers {
            let resources = try await server.listResources()
            results.append(contentsOf: resources.map { (id, $0) })
        }

        return results
    }

    /// Read a resource from a specific server.
    ///
    /// - Parameters:
    ///   - uri: Resource URI
    ///   - serverID: Server ID
    /// - Returns: Resource content
    public func readResource(uri: String, from serverID: String) async throws -> [Resource.Content] {
        guard let server = servers[serverID] else {
            throw MCPManagerError.serverNotFound(serverID)
        }
        return try await server.readResource(uri: uri)
    }

    // MARK: - Prompts

    /// Get all prompts from all connected servers.
    ///
    /// - Returns: Array of (serverID, prompt) tuples
    public func allPrompts() async throws -> [(serverID: String, prompt: Prompt)] {
        var results: [(String, Prompt)] = []

        for (id, server) in servers {
            let prompts = try await server.listPrompts()
            results.append(contentsOf: prompts.map { (id, $0) })
        }

        return results
    }

    /// Get a prompt from a specific server.
    ///
    /// - Parameters:
    ///   - name: Prompt name
    ///   - serverID: Server ID
    ///   - arguments: Prompt arguments
    /// - Returns: Prompt description and messages
    public func getPrompt(
        name: String,
        from serverID: String,
        arguments: [String: Value]? = nil
    ) async throws -> (description: String?, messages: [Prompt.Message]) {
        guard let server = servers[serverID] else {
            throw MCPManagerError.serverNotFound(serverID)
        }
        return try await server.getPrompt(name: name, arguments: arguments)
    }

    // MARK: - Health Check

    /// Check which servers are still connected.
    ///
    /// - Returns: Dictionary of server ID to connection status
    public func healthCheck() async -> [String: Bool] {
        var status: [String: Bool] = [:]
        for (id, server) in servers {
            status[id] = await server.isConnected
        }
        return status
    }
}

// MARK: - MCPServerConfig

/// Configuration for connecting to an MCP server.
public enum MCPServerConfig: Sendable {
    /// Local server via stdio subprocess.
    case stdio(
        command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        id: String? = nil,
        name: String? = nil
    )

    /// Remote server via HTTP.
    case http(
        url: URL,
        headers: [String: String]? = nil,
        id: String? = nil,
        name: String? = nil
    )

    /// Connect using this configuration.
    func connect() async throws -> MCPServerConnection {
        switch self {
        case .stdio(let command, let arguments, let environment, let id, let name):
            return try await MCPServerConnection.stdio(
                command: command,
                arguments: arguments,
                environment: environment,
                id: id,
                name: name
            )

        case .http(let url, let headers, let id, let name):
            return try await MCPServerConnection.http(
                url: url,
                headers: headers,
                id: id,
                name: name
            )
        }
    }
}

// MARK: - MCPManagerError

/// Errors from MCPManager operations.
public enum MCPManagerError: Error, Sendable {
    /// Server with given ID was not found.
    case serverNotFound(String)

    /// Failed to connect to server.
    case connectionFailed(serverID: String, underlying: Error)

    /// Server does not support requested capability.
    case capabilityNotSupported(serverID: String, capability: String)
}

extension MCPManagerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .serverNotFound(let id):
            return "MCP server '\(id)' not found"
        case .connectionFailed(let id, let error):
            return "Failed to connect to MCP server '\(id)': \(error.localizedDescription)"
        case .capabilityNotSupported(let id, let capability):
            return "MCP server '\(id)' does not support \(capability)"
        }
    }
}
