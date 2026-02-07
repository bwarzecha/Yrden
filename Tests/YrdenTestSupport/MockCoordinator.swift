/// Mock coordinator for testing.
///
/// Provides controllable behavior for:
/// - Starting/stopping servers
/// - Tool calls
/// - Snapshots
///
/// Emits events for state updates.

import Foundation
import MCP
@testable import Yrden

/// Mock coordinator for testing.
public actor MockCoordinator: MCPCoordinatorProtocol {

    // MARK: - Events

    public nonisolated let events: AsyncStream<MCPEvent>
    private let eventContinuation: AsyncStream<MCPEvent>.Continuation

    // MARK: - Alerts

    public nonisolated let alerts: AsyncStream<MCPAlert>
    private let alertContinuation: AsyncStream<MCPAlert>.Continuation

    // MARK: - Behavior Configuration

    /// Snapshot to return from snapshot property.
    public var snapshotToReturn: CoordinatorSnapshot = CoordinatorSnapshot(servers: [:])

    /// Result to return from startAllAndWait.
    public var startResultToReturn: StartResult = StartResult(connectedServers: [], failedServers: [])

    /// Result to return from tool calls.
    public var toolCallResult: String = "mock result"

    /// Error to throw from tool calls.
    public var toolCallError: Error?

    // MARK: - Recording

    /// Whether startAll was called.
    public private(set) var startAllCalled = false

    /// Specs passed to startAll.
    public private(set) var startAllSpecs: [ServerSpec] = []

    /// Server IDs passed to reconnect.
    public private(set) var reconnectCalls: [String] = []

    /// Server IDs passed to disconnect.
    public private(set) var disconnectCalls: [String] = []

    /// Server IDs passed to cancelConnection.
    public private(set) var cancelConnectionCalls: [String] = []

    /// Whether stopAll was called.
    public private(set) var stopAllCalled = false

    /// Tool calls: (serverID, name, arguments).
    public private(set) var toolCalls: [(serverID: String, name: String, arguments: [String: Value]?)] = []

    /// Request IDs passed to cancelToolCall.
    public private(set) var cancelToolCallCalls: [String] = []

    /// Available tools to return.
    public var availableToolsToReturn: [AvailableTool] = []

    /// Recording for auto-reconnect calls.
    public private(set) var triggerAutoReconnectCalls: [String] = []
    public private(set) var startHealthChecksCalled = false
    public private(set) var emitConnectionLostCalls: [String] = []

    // MARK: - Initialization

    public init() {
        var eventCont: AsyncStream<MCPEvent>.Continuation!
        self.events = AsyncStream { eventCont = $0 }
        self.eventContinuation = eventCont

        var alertCont: AsyncStream<MCPAlert>.Continuation!
        self.alerts = AsyncStream { alertCont = $0 }
        self.alertContinuation = alertCont
    }

    // MARK: - MCPCoordinatorProtocol

    public func startAll(specs: [ServerSpec]) async {
        startAllCalled = true
        startAllSpecs = specs
    }

    public func startAllAndWait(specs: [ServerSpec]) async -> StartResult {
        startAllCalled = true
        startAllSpecs = specs
        return startResultToReturn
    }

    public func reconnect(serverID: String) async {
        reconnectCalls.append(serverID)
    }

    public func disconnect(serverID: String) async {
        disconnectCalls.append(serverID)
    }

    public func cancelConnection(serverID: String) async {
        cancelConnectionCalls.append(serverID)
    }

    public func stopAll() async {
        stopAllCalled = true
    }

    public func callTool(
        serverID: String,
        name: String,
        arguments: [String: Value]?,
        timeout: Duration?
    ) async throws -> String {
        toolCalls.append((serverID, name, arguments))

        if let error = toolCallError {
            throw error
        }

        return toolCallResult
    }

    public func cancelToolCall(requestId: String) async {
        cancelToolCallCalls.append(requestId)
    }

    public var snapshot: CoordinatorSnapshot {
        get async { snapshotToReturn }
    }

    public func triggerAutoReconnect(serverID: String) async {
        triggerAutoReconnectCalls.append(serverID)
    }

    public func startHealthChecks() async {
        startHealthChecksCalled = true
    }

    public func availableTools() async -> [AvailableTool] {
        availableToolsToReturn
    }

    public func emitConnectionLost(serverID: String) async {
        emitConnectionLostCalls.append(serverID)
        alertContinuation.yield(.connectionLost(serverID: serverID))
    }

    // MARK: - Test Helpers

    /// Emit an alert (simulate coordinator activity).
    public func emitAlert(_ alert: MCPAlert) {
        alertContinuation.yield(alert)
    }

    /// Emit an event (simulate coordinator activity).
    public func emit(_ event: MCPEvent) {
        eventContinuation.yield(event)
    }

    /// Emit a state change event.
    public func emitStateChange(
        serverID: String,
        from: ConnectionState,
        to: ConnectionState
    ) {
        eventContinuation.yield(.stateChanged(serverID: serverID, from: from, to: to))
    }

    /// Set the result to return from tool calls.
    public func setToolCallResult(_ result: String) {
        toolCallResult = result
    }

    /// Set the error to throw from tool calls.
    public func setToolCallError(_ error: Error) {
        toolCallError = error
    }

    /// Reset all recorded state.
    public func reset() {
        startAllCalled = false
        startAllSpecs = []
        reconnectCalls = []
        disconnectCalls = []
        cancelConnectionCalls = []
        stopAllCalled = false
        toolCalls = []
        cancelToolCallCalls = []
        toolCallError = nil
        triggerAutoReconnectCalls = []
        startHealthChecksCalled = false
        emitConnectionLostCalls = []
    }
}
