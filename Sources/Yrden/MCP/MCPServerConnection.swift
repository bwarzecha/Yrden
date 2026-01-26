/// MCP Server Connection management.
///
/// Manages a connection to a single MCP server, providing:
/// - Connection lifecycle (connect, disconnect)
/// - Tool discovery and execution
/// - Resource access
/// - Prompt retrieval
///
/// ## Usage
/// ```swift
/// // Connect to a local MCP server via stdio
/// let server = try await MCPServerConnection.stdio(
///     command: "uvx",
///     arguments: ["mcp-server-filesystem", "--root", "/tmp"]
/// )
///
/// // Discover and use tools
/// let tools = try await server.discoverTools()
/// for tool in tools {
///     print("Found tool: \(tool.name)")
/// }
///
/// // Disconnect when done
/// await server.disconnect()
/// ```

import Foundation
import MCP
import Logging

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

#if canImport(Darwin)
    import Darwin.POSIX
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

// MARK: - MCPServerConnection

/// Manages a connection to an MCP server.
///
/// Wraps the MCP SDK's `Client` with a simpler interface for Yrden integration.
/// Handles connection lifecycle and provides typed access to server capabilities.
public actor MCPServerConnection {
    /// Unique identifier for this server connection.
    public let id: String

    /// Human-readable name for the server.
    public let name: String

    /// The underlying MCP client.
    private let client: Client

    /// The transport used for communication.
    private let transport: any Transport

    /// Server capabilities discovered during initialization.
    private var serverCapabilities: Server.Capabilities?

    /// Whether the connection is active.
    public private(set) var isConnected: Bool = false

    /// Cached tools from the server.
    private var cachedTools: [MCP.Tool]?

    // MARK: - Initialization

    /// Create a server connection with an existing client and transport.
    ///
    /// - Parameters:
    ///   - id: Unique identifier
    ///   - name: Human-readable name
    ///   - client: MCP client instance
    ///   - transport: Transport for communication
    private init(id: String, name: String, client: Client, transport: any Transport) {
        self.id = id
        self.name = name
        self.client = client
        self.transport = transport
    }

    // MARK: - Factory Methods

    /// Connect to a local MCP server via stdio.
    ///
    /// Spawns a subprocess and communicates via stdin/stdout.
    ///
    /// - Parameters:
    ///   - command: The command to run (e.g., "uvx", "npx")
    ///   - arguments: Command arguments (e.g., ["mcp-server-filesystem"])
    ///   - environment: Additional environment variables
    ///   - id: Optional server ID (defaults to command name)
    ///   - name: Optional display name (defaults to command)
    ///   - logCallback: Optional callback for logging subprocess events
    /// - Returns: Connected server instance
    /// - Throws: If connection fails
    public static func stdio(
        command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        id: String? = nil,
        name: String? = nil,
        logCallback: (@Sendable (String) -> Void)? = nil
    ) async throws -> MCPServerConnection {
        let serverID = id ?? command
        let serverName = name ?? "\(command) \(arguments.joined(separator: " "))"

        // Create the MCP client
        let client = Client(name: "Yrden", version: "1.0.0")

        // Create subprocess transport
        let transport = try SubprocessStdioTransport(
            command: command,
            arguments: arguments,
            environment: environment,
            logCallback: logCallback
        )

        let connection = MCPServerConnection(
            id: serverID,
            name: serverName,
            client: client,
            transport: transport
        )

        try await connection.connect()
        return connection
    }

    /// Connect to a local MCP server via stdio with a single command string.
    ///
    /// Parses the command string and spawns a subprocess. This is the simplest
    /// way to connect to a local MCP server.
    ///
    /// ## Example
    /// ```swift
    /// // Simple command
    /// let server = try await MCPServerConnection.stdio("uvx mcp-server-fetch")
    ///
    /// // Command with arguments
    /// let server = try await MCPServerConnection.stdio(
    ///     "npx -y @modelcontextprotocol/server-filesystem /tmp"
    /// )
    ///
    /// // With environment variables (KEY=VALUE per line)
    /// let server = try await MCPServerConnection.stdio(
    ///     "npx mcp-server-github",
    ///     environment: "GITHUB_TOKEN=ghp_xxx"
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - commandLine: Full command line (e.g., "uvx mcp-server-fetch")
    ///   - environment: Environment variables as "KEY=VALUE" lines
    ///   - id: Optional server ID (defaults to first word of command)
    ///   - name: Optional display name (defaults to full command)
    ///   - logCallback: Optional callback for logging subprocess events
    /// - Returns: Connected server instance
    /// - Throws: If connection fails or command is empty
    public static func stdio(
        _ commandLine: String,
        environment: String? = nil,
        id: String? = nil,
        name: String? = nil,
        logCallback: (@Sendable (String) -> Void)? = nil
    ) async throws -> MCPServerConnection {
        let (command, arguments) = parseCommandLine(commandLine)
        let env = parseEnvironment(environment)

        return try await stdio(
            command: command,
            arguments: arguments,
            environment: env,
            id: id ?? command,
            name: name ?? commandLine,
            logCallback: logCallback
        )
    }

    /// Connect to a remote MCP server via HTTP.
    ///
    /// Uses Server-Sent Events for real-time communication.
    ///
    /// - Parameters:
    ///   - url: The server URL
    ///   - headers: Optional HTTP headers (e.g., for authentication)
    ///   - id: Optional server ID (defaults to host)
    ///   - name: Optional display name (defaults to URL)
    /// - Returns: Connected server instance
    /// - Throws: If connection fails
    public static func http(
        url: URL,
        headers: [String: String]? = nil,
        id: String? = nil,
        name: String? = nil
    ) async throws -> MCPServerConnection {
        let serverID = id ?? url.host ?? "remote"
        let serverName = name ?? url.absoluteString

        // Create the MCP client
        let client = Client(name: "Yrden", version: "1.0.0")

        // Create HTTP transport
        let transport = HTTPClientTransport(endpoint: url, requestModifier: { request in
            var modifiedRequest = request
            if let headers = headers {
                for (key, value) in headers {
                    modifiedRequest.setValue(value, forHTTPHeaderField: key)
                }
            }
            return modifiedRequest
        })

        let connection = MCPServerConnection(
            id: serverID,
            name: serverName,
            client: client,
            transport: transport
        )

        try await connection.connect()
        return connection
    }

    /// Connect to a remote MCP server with OAuth authentication.
    ///
    /// Uses OAuth 2.0 authorization code flow with PKCE for secure
    /// authentication. The delegate is responsible for opening the
    /// authorization URL in a browser and handling the callback.
    ///
    /// ## Usage
    /// ```swift
    /// let config = MCPOAuthConfig(
    ///     clientId: "your-client-id",
    ///     authorizationURL: URL(string: "https://auth.example.com/authorize")!,
    ///     tokenURL: URL(string: "https://auth.example.com/token")!,
    ///     scopes: ["mcp:read", "mcp:write"],
    ///     redirectScheme: "myapp"
    /// )
    ///
    /// let server = try await MCPServerConnection.oauthHTTP(
    ///     url: URL(string: "https://mcp.example.com")!,
    ///     oauthConfig: config,
    ///     storage: KeychainTokenStorage(service: "com.myapp.mcp"),
    ///     delegate: myOAuthDelegate
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - url: The MCP server URL
    ///   - oauthConfig: OAuth configuration (client ID, endpoints, etc.)
    ///   - storage: Token storage (Keychain, file, or in-memory)
    ///   - delegate: OAuth delegate for UI interactions
    ///   - id: Optional server ID (defaults to host)
    ///   - name: Optional display name (defaults to URL)
    /// - Returns: Connected server instance with authenticated transport
    /// - Throws: If connection or authentication fails
    public static func oauthHTTP(
        url: URL,
        oauthConfig: MCPOAuthConfig,
        storage: any MCPTokenStorage,
        delegate: (any MCPOAuthDelegate)?,
        id: String? = nil,
        name: String? = nil
    ) async throws -> MCPServerConnection {
        let serverID = id ?? url.host ?? "remote-oauth"
        let serverName = name ?? url.absoluteString

        // Create OAuth flow
        let oauthFlow = MCPOAuthFlow(
            config: oauthConfig,
            storage: storage,
            serverID: serverID
        )

        // Create authenticated transport
        let transport = AuthenticatedHTTPTransport(
            endpoint: url,
            oauthFlow: oauthFlow,
            delegate: delegate
        )

        // Create MCP client
        let client = Client(name: "Yrden", version: "1.0.0")

        let connection = MCPServerConnection(
            id: serverID,
            name: serverName,
            client: client,
            transport: transport
        )

        try await connection.connect()
        return connection
    }

    /// Get the authenticated transport if this connection uses OAuth.
    ///
    /// Returns nil if the connection uses a different transport type.
    public var authenticatedTransport: AuthenticatedHTTPTransport? {
        transport as? AuthenticatedHTTPTransport
    }

    /// Get the auto-auth transport if this connection uses auto OAuth discovery.
    ///
    /// Returns nil if the connection uses a different transport type.
    public var autoAuthTransport: MCPAutoAuthTransport? {
        transport as? MCPAutoAuthTransport
    }

    /// Connect using a pre-created transport.
    ///
    /// Use this when you need to hold a reference to the transport before
    /// the connection is established (e.g., for OAuth callback routing).
    ///
    /// - Parameters:
    ///   - transport: Pre-configured transport instance
    ///   - id: Optional server ID
    ///   - name: Optional display name
    /// - Returns: Connected server instance
    /// - Throws: If connection fails
    public static func withTransport(
        transport: any Transport,
        id: String? = nil,
        name: String? = nil
    ) async throws -> MCPServerConnection {
        let serverID = id ?? "custom-transport"
        let serverName = name ?? "Custom Transport"

        let client = Client(name: "Yrden", version: "1.0.0")

        let connection = MCPServerConnection(
            id: serverID,
            name: serverName,
            client: client,
            transport: transport
        )

        try await connection.connect()
        return connection
    }

    /// Connect to a remote MCP server with automatic OAuth discovery.
    ///
    /// This is the recommended way to connect to remote MCP servers that
    /// require authentication. The transport automatically:
    /// - Discovers authorization endpoints via protected resource metadata
    /// - Performs dynamic client registration (RFC 7591)
    /// - Initiates OAuth with PKCE
    /// - Handles token storage and refresh
    ///
    /// ## Usage
    /// ```swift
    /// let server = try await MCPServerConnection.autoAuth(
    ///     url: URL(string: "https://ai.todoist.net/mcp")!,
    ///     storage: KeychainTokenStorage(service: "com.myapp.mcp"),
    ///     delegate: myOAuthDelegate,
    ///     redirectScheme: "myapp"
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - url: The MCP server URL
    ///   - storage: Token storage (Keychain, file, or in-memory)
    ///   - delegate: OAuth delegate for UI interactions (opening browser)
    ///   - redirectScheme: Custom URL scheme for OAuth callback
    ///   - clientName: Client name for dynamic registration
    ///   - id: Optional server ID (defaults to host)
    ///   - name: Optional display name (defaults to URL)
    /// - Returns: Connected server instance
    /// - Throws: If connection or authentication fails
    public static func autoAuth(
        url: URL,
        storage: any MCPTokenStorage = InMemoryTokenStorage(),
        delegate: (any MCPOAuthDelegate)?,
        redirectScheme: String = "yrden-mcp",
        clientName: String = "Yrden MCP Client",
        id: String? = nil,
        name: String? = nil
    ) async throws -> MCPServerConnection {
        let serverID = id ?? url.host ?? "remote-autoauth"
        let serverName = name ?? url.absoluteString

        // Create auto-auth transport
        let transport = MCPAutoAuthTransport(
            serverURL: url,
            storage: storage,
            serverID: serverID,
            delegate: delegate,
            redirectScheme: redirectScheme,
            clientName: clientName
        )

        // Create MCP client
        let client = Client(name: "Yrden", version: "1.0.0")

        let connection = MCPServerConnection(
            id: serverID,
            name: serverName,
            client: client,
            transport: transport
        )

        try await connection.connect()
        return connection
    }

    // MARK: - Connection Lifecycle

    /// Connect to the server.
    private func connect() async throws {
        guard !isConnected else { return }

        let result = try await client.connect(transport: transport)
        serverCapabilities = result.capabilities
        isConnected = true
    }

    /// Disconnect from the server.
    public func disconnect() async {
        guard isConnected else { return }
        await client.disconnect()
        isConnected = false
        cachedTools = nil
    }

    // MARK: - Tools

    /// Discover all tools available from this server.
    ///
    /// Results are cached after the first call. Use `refreshTools()` to update.
    ///
    /// - Returns: Array of MCP tools
    /// - Throws: If tool discovery fails
    public func listTools() async throws -> [MCP.Tool] {
        if let cached = cachedTools {
            return cached
        }

        var allTools: [MCP.Tool] = []
        var cursor: String? = nil

        repeat {
            let result = try await client.listTools(cursor: cursor)
            allTools.append(contentsOf: result.tools)
            cursor = result.nextCursor
        } while cursor != nil

        cachedTools = allTools
        return allTools
    }

    /// Refresh the cached tools list.
    ///
    /// - Returns: Updated array of MCP tools
    /// - Throws: If tool discovery fails
    @discardableResult
    public func refreshTools() async throws -> [MCP.Tool] {
        cachedTools = nil
        return try await listTools()
    }

    /// Discover tools and wrap them as Yrden AgentTools.
    ///
    /// - Returns: Array of type-erased agent tools
    /// - Throws: If tool discovery fails
    ///
    /// - Note: Deprecated. Use `MCPCoordinator` and `MCPToolProxy` instead
    ///   for proper connection lifecycle management.
    @available(*, deprecated, message: "Use MCPCoordinator with MCPToolProxy instead")
    public func discoverTools<Deps: Sendable>() async throws -> [AnyAgentTool<Deps>] {
        let mcpTools = try await listTools()
        return mcpTools.map { tool in
            MCPTool<Deps>(tool: tool, client: client, serverID: id).asAnyAgentTool()
        }
    }

    /// Call a tool by name.
    ///
    /// - Parameters:
    ///   - name: Tool name
    ///   - arguments: Tool arguments
    /// - Returns: Tool result content
    /// - Throws: If tool execution fails
    public func callTool(
        name: String,
        arguments: [String: Value]? = nil
    ) async throws -> (content: [MCP.Tool.Content], isError: Bool?) {
        try await client.callTool(name: name, arguments: arguments)
    }

    // MARK: - Resources

    /// List all resources available from this server.
    ///
    /// - Returns: Array of resources with optional pagination cursor
    /// - Throws: If resource listing fails
    public func listResources() async throws -> [Resource] {
        var allResources: [Resource] = []
        var cursor: String? = nil

        repeat {
            let result = try await client.listResources(cursor: cursor)
            allResources.append(contentsOf: result.resources)
            cursor = result.nextCursor
        } while cursor != nil

        return allResources
    }

    /// Read a resource by URI.
    ///
    /// - Parameter uri: Resource URI
    /// - Returns: Resource content
    /// - Throws: If resource read fails
    public func readResource(uri: String) async throws -> [Resource.Content] {
        try await client.readResource(uri: uri)
    }

    /// Subscribe to resource updates.
    ///
    /// - Parameter uri: Resource URI to watch
    /// - Throws: If subscription fails
    public func subscribeToResource(uri: String) async throws {
        try await client.subscribeToResource(uri: uri)
    }

    // MARK: - Prompts

    /// List all prompts available from this server.
    ///
    /// - Returns: Array of prompts
    /// - Throws: If prompt listing fails
    public func listPrompts() async throws -> [Prompt] {
        var allPrompts: [Prompt] = []
        var cursor: String? = nil

        repeat {
            let result = try await client.listPrompts(cursor: cursor)
            allPrompts.append(contentsOf: result.prompts)
            cursor = result.nextCursor
        } while cursor != nil

        return allPrompts
    }

    /// Get a prompt by name with arguments.
    ///
    /// - Parameters:
    ///   - name: Prompt name
    ///   - arguments: Prompt arguments
    /// - Returns: Prompt description and messages
    /// - Throws: If prompt retrieval fails
    public func getPrompt(
        name: String,
        arguments: [String: Value]? = nil
    ) async throws -> (description: String?, messages: [Prompt.Message]) {
        try await client.getPrompt(name: name, arguments: arguments)
    }

    // MARK: - Notifications

    /// Register a handler for tool list changes.
    ///
    /// - Parameter handler: Callback when tools change
    public func onToolsChanged(_ handler: @escaping @Sendable () async -> Void) async {
        await client.onNotification(ToolListChangedNotification.self) { _ in
            await handler()
        }
    }

    /// Register a handler for resource updates.
    ///
    /// - Parameter handler: Callback when a resource is updated
    public func onResourceUpdated(_ handler: @escaping @Sendable (String) async -> Void) async {
        await client.onNotification(ResourceUpdatedNotification.self) { message in
            await handler(message.params.uri)
        }
    }

    // MARK: - Server Info

    /// Check if the server supports tools.
    public var supportsTools: Bool {
        serverCapabilities?.tools != nil
    }

    /// Check if the server supports resources.
    public var supportsResources: Bool {
        serverCapabilities?.resources != nil
    }

    /// Check if the server supports prompts.
    public var supportsPrompts: Bool {
        serverCapabilities?.prompts != nil
    }
}
