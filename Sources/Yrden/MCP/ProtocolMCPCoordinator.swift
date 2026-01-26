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
    private let configuration: CoordinatorConfiguration

    // MARK: - State

    private var connections: [String: any ServerConnectionProtocol] = [:]
    private var connectionTasks: [String: Task<Void, Never>] = [:]
    private var serverSpecs: [String: ServerSpec] = [:]
    private var reconnectAttempts: [String: Int] = [:]
    private var healthCheckTask: Task<Void, Never>?

    // MARK: - Events

    nonisolated let events: AsyncStream<CoordinatorEvent>
    private let eventContinuation: AsyncStream<CoordinatorEvent>.Continuation

    // MARK: - Alerts

    nonisolated let alerts: AsyncStream<MCPAlert>
    private let alertContinuation: AsyncStream<MCPAlert>.Continuation

    // MARK: - Initialization

    init(
        connectionFactory: ServerConnectionFactory,
        configuration: CoordinatorConfiguration = .default
    ) {
        self.connectionFactory = connectionFactory
        self.configuration = configuration

        var eventCont: AsyncStream<CoordinatorEvent>.Continuation!
        self.events = AsyncStream { eventCont = $0 }
        self.eventContinuation = eventCont

        var alertCont: AsyncStream<MCPAlert>.Continuation!
        self.alerts = AsyncStream { alertCont = $0 }
        self.alertContinuation = alertCont
    }

    // MARK: - MCPCoordinatorProtocol

    func startAll(specs: [ServerSpec]) async {
        for spec in specs {
            serverSpecs[spec.id] = spec
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

        // Calculate max iterations from configuration
        let pollingInterval = configuration.pollingInterval
        let maxIterations = Int(configuration.connectionTimeout / pollingInterval)

        for spec in specs {
            guard let connection = connections[spec.id] else { continue }

            // Poll until terminal state
            var iterations = 0
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
                try? await Task.sleep(for: pollingInterval)
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
            do {
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
            } catch let error as MCPConnectionError {
                if case .toolTimeout = error {
                    alertContinuation.yield(.toolTimedOut(serverID: serverID, tool: name))
                }
                throw error
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
                servers[id] = ServerSnapshot(id: id, state: state, tools: state.tools)
            }

            return CoordinatorSnapshot(servers: servers)
        }
    }

    // MARK: - Resilience

    func triggerAutoReconnect(serverID: String) async {
        guard let connection = connections[serverID] else { return }

        let maxAttempts: Int
        let baseDelay: TimeInterval

        switch configuration.reconnectPolicy {
        case .none:
            return
        case .immediate(let max):
            maxAttempts = max
            baseDelay = 0
        case .exponentialBackoff(let max, let base):
            maxAttempts = max
            baseDelay = base
        }

        reconnectAttempts[serverID] = 0

        for attempt in 1...maxAttempts {
            reconnectAttempts[serverID] = attempt

            // Calculate delay with exponential backoff
            let delay = baseDelay * pow(2.0, Double(attempt - 1))
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }

            // Check if we're still supposed to reconnect
            let currentState = await connection.state
            if currentState.isConnected {
                alertContinuation.yield(.reconnected(serverID: serverID))
                return
            }

            // Emit reconnecting alert
            alertContinuation.yield(.reconnecting(serverID: serverID, attempt: attempt))

            // Mark as reconnecting
            await connection.markReconnecting(
                attempt: attempt,
                maxAttempts: maxAttempts,
                nextRetryAt: Date().addingTimeInterval(delay)
            )

            // Attempt reconnection
            await connection.connect()

            // Check result
            let newState = await connection.state
            if newState.isConnected {
                alertContinuation.yield(.reconnected(serverID: serverID))
                return
            }

            // If still not connected and not last attempt, continue loop
            if attempt >= maxAttempts {
                break
            }
        }
    }

    func startHealthChecks() async {
        guard let interval = configuration.healthCheckInterval else { return }

        // Cancel existing health check task
        healthCheckTask?.cancel()

        healthCheckTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)

                guard !Task.isCancelled else { break }

                // Check each connection
                for (serverID, connection) in connections {
                    let state = await connection.state
                    guard state.isConnected else { continue }

                    // Health check by attempting a tool call. We use a non-existent
                    // tool name since MCP doesn't define a ping mechanism. If the
                    // connection is alive, we get "tool not found"; if dead, we get
                    // a transport error which triggers reconnection.
                    do {
                        _ = try await connection.callTool(name: "__health_check__", arguments: nil)
                    } catch {
                        // Health check failed - mark as unhealthy
                        alertContinuation.yield(.serverUnhealthy(
                            serverID: serverID,
                            reason: error.localizedDescription
                        ))

                        // Trigger reconnection
                        await triggerAutoReconnect(serverID: serverID)
                    }
                }
            }
        }
    }

    func availableTools() async -> [AvailableTool] {
        var tools: [AvailableTool] = []

        for (serverID, connection) in connections {
            let state = await connection.state
            guard state.isConnected else { continue }

            for toolInfo in state.tools {
                tools.append(AvailableTool(serverID: serverID, toolInfo: toolInfo))
            }
        }

        return tools
    }

    func emitConnectionLost(serverID: String) async {
        alertContinuation.yield(.connectionLost(serverID: serverID))
    }

    // MARK: - Private Helpers

    private func forwardEvents(from connection: any ServerConnectionProtocol) async {
        for await event in connection.events {
            eventContinuation.yield(event)

            // Emit alerts based on events
            if case .stateChanged(let serverID, let from, let to) = event {
                if from.isConnected && to.isFailed {
                    alertContinuation.yield(.connectionLost(serverID: serverID))
                } else if !from.isConnected && to.isFailed {
                    if case .failed(let message, _) = to {
                        alertContinuation.yield(.connectionFailed(
                            serverID: serverID,
                            error: MCPConnectionError.connectionFailed(serverID: serverID, message: message)
                        ))
                    }
                }
            }
        }
    }
}
