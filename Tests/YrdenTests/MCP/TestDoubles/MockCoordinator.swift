/// Mock coordinator for testing MCPManager.
///
/// Provides controllable behavior for:
/// - Starting/stopping servers
/// - Tool calls
/// - Snapshots
///
/// Emits events for UI state updates.

import Foundation
import MCP
@testable import Yrden

/// Mock coordinator for testing MCPManager.
public actor MockCoordinator: MCPCoordinatorProtocol {

    // MARK: - Events

    public nonisolated let events: AsyncStream<CoordinatorEvent>
    private let eventContinuation: AsyncStream<CoordinatorEvent>.Continuation

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

    // MARK: - Initialization

    public init() {
        var continuation: AsyncStream<CoordinatorEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
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

    // MARK: - Test Helpers

    /// Set the result to return from startAllAndWait.
    public func setStartResult(_ result: StartResult) {
        startResultToReturn = result
    }

    /// Set the snapshot to return.
    public func setSnapshot(_ snapshot: CoordinatorSnapshot) {
        snapshotToReturn = snapshot
    }

    /// Set the tool call result to return.
    public func setToolCallResult(_ result: String) {
        toolCallResult = result
    }

    /// Set an error to throw from tool calls.
    public func setToolCallError(_ error: Error) {
        toolCallError = error
    }

    /// Get the specs passed to startAll.
    public var startAllCalls: [[ServerSpec]] {
        startAllCalled ? [startAllSpecs] : []
    }

    /// Get the tool call history.
    public var callToolCalls: [(serverID: String, name: String, arguments: [String: Value]?)] {
        toolCalls
    }

    /// Emit an event (simulate coordinator activity).
    public func emit(_ event: CoordinatorEvent) {
        eventContinuation.yield(event)
    }

    /// Emit a state change event.
    public func emitStateChange(
        serverID: String,
        from: ConnectionState,
        to: ConnectionState
    ) {
        eventContinuation.yield(.serverStateChanged(serverID: serverID, from: from, to: to))
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
    }

    /// Check if reconnect was called for a specific server.
    public func wasReconnected(_ serverID: String) -> Bool {
        reconnectCalls.contains(serverID)
    }

    /// Check if a tool was called on a specific server.
    public func wasToolCalled(_ tool: String, on serverID: String) -> Bool {
        toolCalls.contains { $0.serverID == serverID && $0.name == tool }
    }
}
