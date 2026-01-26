/// Protocols for MCP layer abstractions.
///
/// These protocols enable dependency injection for testing:
/// - MCPClientProtocol: Abstracts the MCP SDK client
/// - ServerConnectionProtocol: Abstracts a single server connection
/// - MCPCoordinatorProtocol: Abstracts the coordinator layer
/// - ClockProtocol: Abstracts time operations
///
/// - Note: Internal types for testing infrastructure. Use `mcpConnect()` for public API.

import Foundation
import MCP

// MARK: - MCP Result Types

/// Result of listing tools from MCP server.
struct MCPListToolsResult: Sendable {
    let tools: [MCP.Tool]
    let nextCursor: String?

    init(tools: [MCP.Tool], nextCursor: String? = nil) {
        self.tools = tools
        self.nextCursor = nextCursor
    }
}

/// Result of calling a tool on MCP server.
struct MCPCallToolResult: Sendable {
    let content: [MCP.Tool.Content]
    let isError: Bool?

    init(content: [MCP.Tool.Content], isError: Bool? = nil) {
        self.content = content
        self.isError = isError
    }
}

// MARK: - MCP Client Protocol

/// Protocol abstracting the MCP SDK Client.
///
/// ServerConnection uses this to interact with the MCP server.
/// In production: wraps real MCP SDK Client.
/// In tests: MockMCPClient provides controllable behavior.
protocol MCPClientProtocol: Sendable {
    /// List available tools from the server.
    func listTools() async throws -> MCPListToolsResult

    /// Call a tool with arguments.
    func callTool(name: String, arguments: [String: Value]?) async throws -> MCPCallToolResult

    /// Disconnect from the server.
    func disconnect() async

    /// Send a cancellation notification for a request.
    func sendCancellation(requestId: String) async throws
}

/// Factory for creating MCP clients.
protocol MCPClientFactory: Sendable {
    /// Create an MCP client for the given server spec.
    func makeClient(spec: ServerSpec) async throws -> MCPClientProtocol
}

// MARK: - Server Connection Protocol

/// Protocol abstracting a single server connection.
///
/// MCPCoordinator uses this to manage connections.
/// In production: real ServerConnection actor.
/// In tests: MockServerConnection with controllable behavior.
///
/// Note: This protocol requires Actor conformance to enable nonisolated properties.
protocol ServerConnectionProtocol: Sendable, Actor {
    /// Unique identifier for this connection (nonisolated for easy access).
    nonisolated var id: String { get }

    /// Current connection state.
    var state: ConnectionState { get async }

    /// Event stream for connection lifecycle (nonisolated for subscription).
    nonisolated var events: AsyncStream<ConnectionEvent> { get }

    /// Attempt to connect to the server.
    func connect() async

    /// Disconnect from the server.
    func disconnect() async

    /// Call a tool on this server.
    func callTool(name: String, arguments: [String: Value]?) async throws -> String

    /// Cancel a pending tool call.
    func cancelToolCall(requestId: String) async

    /// Mark the connection as reconnecting (called by coordinator).
    func markReconnecting(attempt: Int, maxAttempts: Int, nextRetryAt: Date?)
}

/// Factory for creating server connections.
protocol ServerConnectionFactory: Sendable {
    /// Create a connection for the given spec.
    func makeConnection(id: String, spec: ServerSpec) -> any ServerConnectionProtocol
}

// MARK: - Coordinator Protocol

/// Protocol abstracting the MCP coordinator.
///
/// MCPManager uses this to manage all connections.
/// In production: real MCPCoordinator actor.
/// In tests: MockCoordinator with controllable behavior.
protocol MCPCoordinatorProtocol: Sendable, Actor {
    /// Event stream for coordinator-level events (nonisolated for subscription).
    nonisolated var events: AsyncStream<CoordinatorEvent> { get }

    /// Alert stream for user-facing notifications (nonisolated for subscription).
    nonisolated var alerts: AsyncStream<MCPAlert> { get }

    /// Start all servers in parallel.
    func startAll(specs: [ServerSpec]) async

    /// Start all servers and wait until all reach terminal state.
    func startAllAndWait(specs: [ServerSpec]) async -> StartResult

    /// Reconnect a specific server.
    func reconnect(serverID: String) async

    /// Disconnect a specific server.
    func disconnect(serverID: String) async

    /// Cancel an in-progress connection attempt.
    func cancelConnection(serverID: String) async

    /// Stop all connections.
    func stopAll() async

    /// Call a tool on a specific server.
    func callTool(
        serverID: String,
        name: String,
        arguments: [String: Value]?,
        timeout: Duration?
    ) async throws -> String

    /// Cancel a specific tool call.
    func cancelToolCall(requestId: String) async

    /// Get current state snapshot.
    var snapshot: CoordinatorSnapshot { get async }

    /// Trigger auto-reconnect for a failed server.
    func triggerAutoReconnect(serverID: String) async

    /// Start periodic health checks for all connections.
    func startHealthChecks() async

    /// Get tools from connected servers only.
    func availableTools() async -> [AvailableTool]

    /// Emit a connection lost alert (for testing).
    func emitConnectionLost(serverID: String) async
}

// MARK: - Clock Protocol

/// Protocol for time operations.
///
/// Enables tests to control time without real delays.
/// In production: RealClock uses Task.sleep.
/// In tests: TestClock allows manual time advancement.
protocol ClockProtocol: Sendable {
    /// Sleep for a duration.
    func sleep(for duration: Duration) async throws

    /// Get current time.
    func now() -> Date
}

/// Real clock using system time.
struct RealClock: ClockProtocol, Sendable {
    init() {}

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    func now() -> Date {
        Date()
    }
}

// MARK: - Available Tool

/// Tool available from a connected server.
struct AvailableTool: Sendable {
    /// Server ID this tool belongs to.
    let serverID: String

    /// Tool name.
    let name: String

    /// Tool description.
    let description: String?

    /// Tool input schema.
    let inputSchema: JSONValue

    init(serverID: String, toolInfo: ToolInfo) {
        self.serverID = serverID
        self.name = toolInfo.name
        self.description = toolInfo.description
        self.inputSchema = JSONValue(mcpValue: toolInfo.inputSchema)
    }
}

// MARK: - Duration Extension

extension Duration {
    /// Convert Duration to TimeInterval.
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = self.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

// MARK: - Coordinator Configuration

/// Configuration for MCPCoordinator.
struct CoordinatorConfiguration: Sendable {
    /// Timeout for tool calls.
    var toolTimeout: Duration

    /// Timeout for initial connection (used in startAllAndWait).
    var connectionTimeout: Duration

    /// Timeout for OAuth flows.
    var oauthTimeout: Duration

    /// Reconnection policy on failure.
    var reconnectPolicy: ReconnectPolicy

    /// Interval for health checks (nil disables).
    var healthCheckInterval: Duration?

    /// Polling interval for checking connection state.
    var pollingInterval: Duration

    init(
        toolTimeout: Duration = .seconds(30),
        connectionTimeout: Duration = .seconds(10),
        oauthTimeout: Duration = .seconds(120),
        reconnectPolicy: ReconnectPolicy = .exponentialBackoff(maxAttempts: 5, baseDelay: 1.0),
        healthCheckInterval: Duration? = .seconds(30),
        pollingInterval: Duration = .milliseconds(100)
    ) {
        self.toolTimeout = toolTimeout
        self.connectionTimeout = connectionTimeout
        self.oauthTimeout = oauthTimeout
        self.reconnectPolicy = reconnectPolicy
        self.healthCheckInterval = healthCheckInterval
        self.pollingInterval = pollingInterval
    }

    /// Default configuration.
    static var `default`: CoordinatorConfiguration { .init() }
}

/// Policy for reconnecting after failure.
enum ReconnectPolicy: Sendable, Equatable {
    /// Don't reconnect.
    case none

    /// Reconnect immediately up to N times.
    case immediate(maxAttempts: Int)

    /// Reconnect with exponential backoff.
    case exponentialBackoff(maxAttempts: Int, baseDelay: TimeInterval)
}
