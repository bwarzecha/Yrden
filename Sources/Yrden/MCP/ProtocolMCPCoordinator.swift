/// Protocol-compliant MCPCoordinator implementation.
///
/// Uses dependency injection for testability:
/// - ServerConnectionFactory for creating connections
///
/// Manages multiple server connections with:
/// - Parallel connection startup
/// - Event aggregation from all connections
/// - Tool call routing
/// - State snapshots

import Foundation
import MCP

/// Coordinator that manages multiple MCP server connections.
///
/// This implementation uses injected dependencies for testability.
/// In production, use real ServerConnectionFactory. In tests, use MockServerConnectionFactory.
///
/// - Note: Internal type for testing infrastructure. Use `mcpConnect()` for public API.
actor ProtocolMCPCoordinator: MCPCoordinatorProtocol {

    // MARK: - Properties

    private let connectionFactory: ServerConnectionFactory

    // MARK: - State

    private var connections: [String: any ServerConnectionProtocol] = [:]
    private var connectionTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Events

    nonisolated let events: AsyncStream<CoordinatorEvent>
    private let eventContinuation: AsyncStream<CoordinatorEvent>.Continuation

    // MARK: - Initialization

    init(connectionFactory: ServerConnectionFactory) {
        self.connectionFactory = connectionFactory

        var continuation: AsyncStream<CoordinatorEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    // MARK: - MCPCoordinatorProtocol

    func startAll(specs: [ServerSpec]) async {
        for spec in specs {
            let connection = connectionFactory.makeConnection(id: spec.id, spec: spec)
            connections[spec.id] = connection

            // Start connection in background
            connectionTasks[spec.id] = Task {
                await self.forwardEvents(from: connection)
            }

            // Initiate connection
            await connection.connect()
        }
    }

    func startAllAndWait(specs: [ServerSpec]) async -> StartResult {
        // Start all connections
        await startAll(specs: specs)

        // Wait for all to reach terminal state
        var connected: [String] = []
        var failed: [StartResult.FailedServer] = []

        for spec in specs {
            guard let connection = connections[spec.id] else { continue }

            // Poll until terminal state
            var iterations = 0
            let maxIterations = 100 // 10 seconds max
            while iterations < maxIterations {
                let state = await connection.state
                if state.isTerminal {
                    switch state {
                    case .connected:
                        connected.append(spec.id)
                    case .failed(let message, _):
                        failed.append(StartResult.FailedServer(serverID: spec.id, message: message))
                    case .disconnected:
                        failed.append(StartResult.FailedServer(serverID: spec.id, message: "Disconnected"))
                    default:
                        break
                    }
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
                iterations += 1
            }

            // Timeout case
            if iterations >= maxIterations {
                failed.append(StartResult.FailedServer(serverID: spec.id, message: "Connection timeout"))
            }
        }

        return StartResult(connectedServers: connected, failedServers: failed)
    }

    func reconnect(serverID: String) async {
        guard let connection = connections[serverID] else { return }

        // Mark as reconnecting
        await connection.markReconnecting(attempt: 1, maxAttempts: 3, nextRetryAt: nil)

        // Reconnect
        await connection.connect()
    }

    func disconnect(serverID: String) async {
        guard let connection = connections[serverID] else { return }
        await connection.disconnect()
    }

    func cancelConnection(serverID: String) async {
        connectionTasks[serverID]?.cancel()
        connectionTasks[serverID] = nil

        // Mark as disconnected
        if let connection = connections[serverID] {
            await connection.disconnect()
        }
    }

    func stopAll() async {
        // Cancel all tasks
        for (_, task) in connectionTasks {
            task.cancel()
        }
        connectionTasks.removeAll()

        // Disconnect all connections
        for (_, connection) in connections {
            await connection.disconnect()
        }
    }

    func callTool(
        serverID: String,
        name: String,
        arguments: [String: Value]?,
        timeout: Duration?
    ) async throws -> String {
        guard let connection = connections[serverID] else {
            throw MCPConnectionError.unknownServer(serverID: serverID)
        }

        if let timeout = timeout {
            // Call with timeout
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await connection.callTool(name: name, arguments: arguments)
                }

                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw MCPConnectionError.toolTimeout(serverID: serverID, tool: name, timeout: timeout)
                }

                guard let result = try await group.next() else {
                    throw MCPConnectionError.internalError("Task group completed without result")
                }
                group.cancelAll()
                return result
            }
        } else {
            return try await connection.callTool(name: name, arguments: arguments)
        }
    }

    func cancelToolCall(requestId: String) async {
        // Send cancellation to all connections (we don't track which connection owns which request)
        for (_, connection) in connections {
            await connection.cancelToolCall(requestId: requestId)
        }
    }

    var snapshot: CoordinatorSnapshot {
        get async {
            var servers: [String: ServerSnapshot] = [:]

            for (id, connection) in connections {
                let state = await connection.state
                let toolNames: [String]
                if case .connected(_, let names) = state {
                    toolNames = names
                } else {
                    toolNames = []
                }
                servers[id] = ServerSnapshot(id: id, state: state, toolNames: toolNames)
            }

            return CoordinatorSnapshot(servers: servers)
        }
    }

    // MARK: - Private Helpers

    private func forwardEvents(from connection: any ServerConnectionProtocol) async {
        for await event in connection.events {
            let coordinatorEvent = mapToCoordinatorEvent(event)
            eventContinuation.yield(coordinatorEvent)
        }
    }

    private func mapToCoordinatorEvent(_ event: ConnectionEvent) -> CoordinatorEvent {
        switch event {
        case .stateChanged(let serverID, let from, let to):
            return .serverStateChanged(serverID: serverID, from: from, to: to)
        case .log(let serverID, let entry):
            return .serverLog(serverID: serverID, entry: entry)
        case .toolCallStarted(let serverID, let tool, let requestId):
            return .toolCallStarted(serverID: serverID, tool: tool, requestId: requestId)
        case .toolCallCompleted(let requestId, let duration, let success):
            return .toolCallCompleted(requestId: requestId, duration: duration, success: success)
        case .toolCallCancelled(let requestId, let reason):
            return .toolCallCancelled(requestId: requestId, reason: reason)
        }
    }
}
