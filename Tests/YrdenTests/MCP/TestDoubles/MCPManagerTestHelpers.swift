/// Test helpers for MCPManager tests.
///
/// Provides a test-friendly MCPManager that uses injected coordinator.

import Foundation
import MCP
@testable import Yrden

// MARK: - Test MCPManager

/// Test-friendly MCPManager that uses injected coordinator.
actor TestMCPManager {
    private let coordinator: MockCoordinator

    init(coordinator: MockCoordinator) {
        self.coordinator = coordinator
    }

    var events: AsyncStream<CoordinatorEvent> {
        get async { coordinator.events }
    }

    func addServers(_ specs: [ServerSpec]) async throws -> StartResult {
        let result = await coordinator.startAllAndWait(specs: specs)
        // Throw if ALL servers failed (no successful connections)
        if result.connectedServers.isEmpty && !result.failedServers.isEmpty {
            throw MCPConnectionError.connectionFailed(
                serverID: result.failedServers.first?.serverID ?? "unknown",
                message: "All servers failed to connect"
            )
        }
        return result
    }

    func allTools() async -> [TestToolInfo] {
        let snapshot = await coordinator.snapshot
        return snapshot.servers.values.flatMap { server in
            server.toolNames.map { TestToolInfo(name: $0, serverID: server.id) }
        }
    }

    func tools(from serverID: String) async -> [TestToolInfo] {
        let snapshot = await coordinator.snapshot
        guard let server = snapshot.servers[serverID] else { return [] }
        return server.toolNames.map { TestToolInfo(name: $0, serverID: serverID) }
    }

    func callTool(
        serverID: String,
        name: String,
        arguments: [String: Value]?
    ) async throws -> String {
        try await coordinator.callTool(
            serverID: serverID,
            name: name,
            arguments: arguments,
            timeout: nil
        )
    }

    func serverStatuses() async -> [String: ConnectionState] {
        let snapshot = await coordinator.snapshot
        return snapshot.servers.mapValues(\.state)
    }

    func connectedServers() async -> [String] {
        let snapshot = await coordinator.snapshot
        return snapshot.servers.values
            .filter { $0.state.isConnected }
            .map(\.id)
    }

    func reconnect(serverID: String) async {
        await coordinator.reconnect(serverID: serverID)
    }

    func disconnect(serverID: String) async {
        await coordinator.disconnect(serverID: serverID)
    }

    func disconnectAll() async {
        await coordinator.stopAll()
    }
}

// MARK: - TestToolInfo for Tests

/// Simple tool info struct for tests (renamed to avoid conflict with Yrden.ToolInfo).
struct TestToolInfo: Equatable {
    let name: String
    let serverID: String
}
