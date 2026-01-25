/// Test fixtures for MCP tests.
///
/// Provides factory methods for creating test data:
/// - MCP.Tool
/// - ServerSpec
/// - ConnectionState
/// - Snapshots

import Foundation
import MCP
@testable import Yrden

/// Common test fixtures for MCP tests.
public enum MCPTestFixtures {

    // MARK: - MCP Tool

    /// Create an MCP.Tool for testing mock clients.
    public static func makeMCPTool(
        name: String,
        description: String = "Test tool"
    ) -> MCP.Tool {
        MCP.Tool(
            name: name,
            description: description,
            inputSchema: .object([:])
        )
    }

    /// Create multiple MCP.Tool instances.
    public static func makeMCPTools(_ names: String...) -> [MCP.Tool] {
        names.map { makeMCPTool(name: $0) }
    }

    /// Create a ToolInfo for testing.
    public static func makeToolInfo(name: String, description: String = "Test tool") -> ToolInfo {
        ToolInfo(makeMCPTool(name: name, description: description))
    }

    /// Create multiple ToolInfo instances from names.
    public static func makeToolInfos(_ names: [String]) -> [ToolInfo] {
        names.map { makeToolInfo(name: $0) }
    }

    // MARK: - Server Spec

    /// Create a stdio ServerSpec for testing.
    public static func makeStdioSpec(
        id: String,
        command: String = "echo",
        arguments: [String] = ["test"]
    ) -> ServerSpec {
        .stdio(
            command: command,
            arguments: arguments,
            environment: nil,
            id: id,
            displayName: "Test Server: \(id)"
        )
    }

    /// Create an HTTP ServerSpec for testing.
    public static func makeHTTPSpec(
        id: String,
        url: String = "https://example.com/mcp"
    ) -> ServerSpec {
        .http(
            url: URL(string: url)!,
            headers: nil,
            id: id,
            displayName: "HTTP Server: \(id)"
        )
    }

    /// Create multiple ServerSpecs.
    public static func makeSpecs(_ ids: String...) -> [ServerSpec] {
        ids.map { makeStdioSpec(id: $0) }
    }

    // MARK: - Connection State

    /// Create a connected state with tool names.
    public static func makeConnectedState(toolNames: [String] = ["tool1", "tool2"]) -> ConnectionState {
        .connected(tools: makeToolInfos(toolNames))
    }

    /// Create a failed state.
    public static func makeFailedState(
        message: String = "Connection refused",
        retryCount: Int = 0
    ) -> ConnectionState {
        .failed(message: message, retryCount: retryCount)
    }

    // MARK: - Snapshots

    /// Create a ServerSnapshot.
    public static func makeServerSnapshot(
        id: String,
        state: ConnectionState? = nil,
        toolNames: [String] = []
    ) -> ServerSnapshot {
        let tools = makeToolInfos(toolNames)
        let actualState = state ?? .connected(tools: tools)
        return ServerSnapshot(id: id, state: actualState, tools: tools)
    }

    /// Create a CoordinatorSnapshot with connected servers.
    public static func makeConnectedSnapshot(
        serverID: String,
        toolNames: [String]
    ) -> CoordinatorSnapshot {
        CoordinatorSnapshot(servers: [
            serverID: makeServerSnapshot(id: serverID, toolNames: toolNames)
        ])
    }

    /// Create a CoordinatorSnapshot with multiple servers.
    public static func makeSnapshot(
        servers: [String: ConnectionState]
    ) -> CoordinatorSnapshot {
        var serverSnapshots: [String: ServerSnapshot] = [:]
        for (id, state) in servers {
            serverSnapshots[id] = ServerSnapshot(id: id, state: state, tools: state.tools)
        }
        return CoordinatorSnapshot(servers: serverSnapshots)
    }

    // MARK: - StartResult

    /// Create a successful StartResult.
    public static func makeSuccessResult(servers: [String]) -> StartResult {
        StartResult(connectedServers: servers, failedServers: [])
    }

    /// Create a StartResult with failures.
    public static func makeFailedResult(
        connected: [String] = [],
        failed: [(id: String, message: String)]
    ) -> StartResult {
        StartResult(
            connectedServers: connected,
            failedServers: failed.map { StartResult.FailedServer(serverID: $0.id, message: $0.message) }
        )
    }

    // MARK: - Log Entry

    /// Create a log entry.
    public static func makeLogEntry(
        level: LogLevel = .info,
        message: String = "Test log message"
    ) -> LogEntry {
        LogEntry(level: level, message: message)
    }
}

// MARK: - Common Test Errors

/// Common errors for testing.
public enum MCPTestError: Error, Equatable, Sendable {
    case connectionRefused
    case timeout
    case authFailed
    case toolFailed(String)
    case serverError(String)
}

extension MCPTestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectionRefused:
            return "Connection refused"
        case .timeout:
            return "Operation timed out"
        case .authFailed:
            return "Authentication failed"
        case .toolFailed(let reason):
            return "Tool failed: \(reason)"
        case .serverError(let message):
            return "Server error: \(message)"
        }
    }
}
