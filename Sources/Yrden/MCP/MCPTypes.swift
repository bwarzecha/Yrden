/// Core MCP types for connection lifecycle management.
///
/// These types provide the foundation for the layered MCP architecture:
/// - ConnectionState: State machine for server connections
/// - ConnectionEvent: Events emitted during lifecycle
/// - CoordinatorEvent: Events from the coordinator layer
/// - Supporting types for tools, logs, and errors

import Foundation
import MCP

// MARK: - Connection State Machine

/// State of a single MCP server connection.
///
/// Represents the state machine for connection lifecycle:
/// ```
/// idle → connecting → connected
///           ↓            ↓
///        failed ← ← ← ← ←
///           ↓
///     reconnecting → connecting
///           ↓
///      disconnected
/// ```
public enum ConnectionState: Sendable {
    /// Initial state, not connected.
    case idle

    /// Attempting to establish connection.
    case connecting

    /// OAuth authentication in progress.
    case authenticating(progress: AuthProgress)

    /// Successfully connected with discovered tools.
    case connected(toolCount: Int, toolNames: [String])

    /// Connection failed.
    case failed(message: String, retryCount: Int)

    /// Waiting before retry attempt.
    case reconnecting(attempt: Int, maxAttempts: Int, nextRetryAt: Date?)

    /// Explicitly disconnected.
    case disconnected

    /// Whether the connection is active and ready for tool calls.
    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// Whether the connection has failed.
    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Whether the state is terminal (won't change without explicit action).
    public var isTerminal: Bool {
        switch self {
        case .connected, .failed, .disconnected: return true
        default: return false
        }
    }
}

// Explicit Equatable to handle complex associated values
extension ConnectionState: Equatable {
    public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.connecting, .connecting):
            return true
        case (.authenticating(let lp), .authenticating(let rp)):
            return lp == rp
        case (.connected(let lc, let ln), .connected(let rc, let rn)):
            return lc == rc && ln == rn
        case (.failed(let lm, let lr), .failed(let rm, let rr)):
            return lm == rm && lr == rr
        case (.reconnecting(let la, let lm, let lt), .reconnecting(let ra, let rm, let rt)):
            return la == ra && lm == rm && lt == rt
        case (.disconnected, .disconnected):
            return true
        default:
            return false
        }
    }
}

/// Progress during OAuth authentication.
public enum AuthProgress: Equatable, Sendable {
    case starting
    case openingBrowser(url: URL)
    case waitingForCallback
    case exchangingToken

    public var description: String {
        switch self {
        case .starting: return "Starting authentication..."
        case .openingBrowser: return "Opening browser..."
        case .waitingForCallback: return "Waiting for authorization..."
        case .exchangingToken: return "Completing authentication..."
        }
    }
}

// MARK: - Logging

/// Log entry from a server connection.
public struct LogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

/// Log severity level.
public enum LogLevel: String, Sendable, Equatable {
    case debug
    case info
    case warning
    case error
}

// MARK: - Connection Events

/// Events emitted by a server connection.
public enum ConnectionEvent: Sendable, Equatable {
    case stateChanged(serverID: String, from: ConnectionState, to: ConnectionState)
    case log(serverID: String, entry: LogEntry)
    case toolCallStarted(serverID: String, tool: String, requestId: String)
    case toolCallCompleted(requestId: String, duration: TimeInterval, success: Bool)
    case toolCallCancelled(requestId: String, reason: CancellationReason)
}

/// Reason for tool call cancellation.
public enum CancellationReason: Sendable, Equatable {
    case userRequested
    case timeout(Duration)
    case serverDisconnected
    case appShutdown
}

// MARK: - Coordinator Events

/// Events emitted by the coordinator.
public enum CoordinatorEvent: Sendable, Equatable {
    case serverStateChanged(serverID: String, from: ConnectionState, to: ConnectionState)
    case serverLog(serverID: String, entry: LogEntry)
    case toolCallStarted(serverID: String, tool: String, requestId: String)
    case toolCallCompleted(requestId: String, duration: TimeInterval, success: Bool)
    case toolCallCancelled(requestId: String, reason: CancellationReason)
}

// MARK: - Snapshots

/// Snapshot of coordinator state for UI.
public struct CoordinatorSnapshot: Sendable, Equatable {
    public let servers: [String: ServerSnapshot]

    public init(servers: [String: ServerSnapshot]) {
        self.servers = servers
    }
}

/// Snapshot of a single server's state.
public struct ServerSnapshot: Sendable, Equatable {
    public let id: String
    public let state: ConnectionState
    public let toolNames: [String]

    public init(id: String, state: ConnectionState, toolNames: [String] = []) {
        self.id = id
        self.state = state
        self.toolNames = toolNames
    }

    /// Number of available tools.
    public var toolCount: Int { toolNames.count }
}

/// Result of starting all servers.
public struct StartResult: Sendable, Equatable {
    public let connectedServers: [String]
    public let failedServers: [FailedServer]

    public var allSucceeded: Bool { failedServers.isEmpty }

    public init(connectedServers: [String], failedServers: [FailedServer]) {
        self.connectedServers = connectedServers
        self.failedServers = failedServers
    }

    public struct FailedServer: Sendable, Equatable {
        public let serverID: String
        public let message: String

        public init(serverID: String, message: String) {
            self.serverID = serverID
            self.message = message
        }
    }
}

// MARK: - Server Specification

/// Specification for an MCP server connection.
public enum ServerSpec: Sendable, Equatable, Identifiable {
    /// Local server via stdio (subprocess).
    case stdio(command: String, arguments: [String], environment: [String: String]?, id: String, displayName: String)

    /// Remote server via HTTP.
    case http(url: URL, headers: [String: String]?, id: String, displayName: String)

    /// Remote server with OAuth authentication.
    case oauth(url: URL, config: OAuthConfigSpec, id: String, displayName: String)

    /// Remote server with auto-discovery OAuth.
    case autoAuth(url: URL, redirectScheme: String, clientName: String, id: String, displayName: String)

    public var id: String {
        switch self {
        case .stdio(_, _, _, let id, _): return id
        case .http(_, _, let id, _): return id
        case .oauth(_, _, let id, _): return id
        case .autoAuth(_, _, _, let id, _): return id
        }
    }

    public var displayName: String {
        switch self {
        case .stdio(_, _, _, _, let name): return name
        case .http(_, _, _, let name): return name
        case .oauth(_, _, _, let name): return name
        case .autoAuth(_, _, _, _, let name): return name
        }
    }
}

/// OAuth configuration for ServerSpec.
public struct OAuthConfigSpec: Sendable, Equatable {
    public let clientId: String
    public let authorizationURL: URL
    public let tokenURL: URL
    public let scopes: [String]
    public let redirectScheme: String

    public init(
        clientId: String,
        authorizationURL: URL,
        tokenURL: URL,
        scopes: [String],
        redirectScheme: String
    ) {
        self.clientId = clientId
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
        self.scopes = scopes
        self.redirectScheme = redirectScheme
    }
}

// MARK: - MCP Errors

/// Errors specific to MCP operations.
public enum MCPConnectionError: Error, Sendable, Equatable {
    case notConnected(serverID: String)
    case unknownServer(serverID: String)
    case toolTimeout(serverID: String, tool: String, timeout: Duration)
    case toolCancelled(serverID: String, tool: String)
    case connectionFailed(serverID: String, message: String)
    case internalError(String)
}

extension MCPConnectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected(let id):
            return "Server '\(id)' is not connected"
        case .unknownServer(let id):
            return "Unknown server: \(id)"
        case .toolTimeout(let id, let tool, let timeout):
            return "Tool '\(tool)' on server '\(id)' timed out after \(timeout)"
        case .toolCancelled(let id, let tool):
            return "Tool '\(tool)' on server '\(id)' was cancelled"
        case .connectionFailed(let id, let message):
            return "Connection to '\(id)' failed: \(message)"
        case .internalError(let message):
            return "Internal error: \(message)"
        }
    }
}
