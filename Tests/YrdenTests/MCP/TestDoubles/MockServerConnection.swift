/// Mock server connection for testing MCPCoordinator.
///
/// Provides controllable behavior for:
/// - Connection (success, failure, delay, hang)
/// - Tool calls (success, failure, delay, hang)
/// - State transitions
///
/// Emits events through the events stream for verification.

import Foundation
import MCP
@testable import Yrden

/// Mock server connection for testing MCPCoordinator.
public actor MockServerConnection: ServerConnectionProtocol {
    public nonisolated let id: String

    // MARK: - State

    private var _state: ConnectionState = .idle
    public var state: ConnectionState { _state }

    // MARK: - Events

    public nonisolated let events: AsyncStream<MCPEvent>
    private let eventContinuation: AsyncStream<MCPEvent>.Continuation

    // MARK: - Behavior Configuration

    /// Behavior when connect() is called.
    public var connectBehavior: ConnectBehavior = .succeed(toolNames: [])

    /// Behavior for specific tools.
    public var toolCallBehavior: [String: ToolCallBehavior] = [:]

    /// Default behavior for tools not in toolCallBehavior.
    public var defaultToolCallBehavior: ToolCallBehavior = .succeed(result: "mock result")

    public indirect enum ConnectBehavior: Sendable {
        case succeed(toolNames: [String])
        case fail(message: String)
        case hang
        case delay(Duration, then: ConnectBehavior)
    }

    public indirect enum ToolCallBehavior: Sendable {
        case succeed(result: String)
        case fail(error: Error)
        case hang
        case delay(Duration, then: ToolCallBehavior)
    }

    // MARK: - Recording

    /// Number of times connect() was called.
    public private(set) var connectCallCount = 0

    /// Number of times disconnect() was called.
    public private(set) var disconnectCallCount = 0

    /// History of tool calls: (name, arguments).
    public private(set) var toolCallHistory: [(name: String, arguments: [String: Value]?)] = []

    /// Request IDs for which cancellation was requested.
    public private(set) var cancelledToolCalls: [String] = []

    // MARK: - Initialization

    public init(id: String) {
        self.id = id
        var continuation: AsyncStream<MCPEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    // MARK: - ServerConnectionProtocol

    public func connect() async {
        connectCallCount += 1
        await executeBehavior(connectBehavior)
    }

    private func executeBehavior(_ behavior: ConnectBehavior) async {
        switch behavior {
        case .succeed(let toolNames):
            transition(to: .connecting)
            transition(to: .connected(toolCount: toolNames.count, toolNames: toolNames))

        case .fail(let message):
            transition(to: .connecting)
            transition(to: .failed(message: message, retryCount: connectCallCount - 1))

        case .hang:
            transition(to: .connecting)
            // Hang forever - for testing cancellation
            try? await Task.sleep(for: .seconds(3600))

        case .delay(let duration, let then):
            transition(to: .connecting)
            try? await Task.sleep(for: duration)
            if !Task.isCancelled {
                await executeBehavior(then)
            } else {
                transition(to: .idle)
            }
        }
    }

    public func disconnect() async {
        disconnectCallCount += 1
        transition(to: .disconnected)
    }

    public func callTool(name: String, arguments: [String: Value]?) async throws -> String {
        toolCallHistory.append((name, arguments))
        let behavior = toolCallBehavior[name] ?? defaultToolCallBehavior
        return try await executeToolBehavior(behavior)
    }

    private func executeToolBehavior(_ behavior: ToolCallBehavior) async throws -> String {
        switch behavior {
        case .succeed(let result):
            return result

        case .fail(let error):
            throw error

        case .hang:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()

        case .delay(let duration, let then):
            try await Task.sleep(for: duration)
            return try await executeToolBehavior(then)
        }
    }

    public func cancelToolCall(requestId: String) async {
        cancelledToolCalls.append(requestId)
        eventContinuation.yield(.toolCallCancelled(requestId: requestId, reason: .userRequested))
    }

    public func markReconnecting(attempt: Int, maxAttempts: Int, nextRetryAt: Date?) {
        transition(to: .reconnecting(attempt: attempt, maxAttempts: maxAttempts, nextRetryAt: nextRetryAt))
    }

    // MARK: - Test Helpers

    /// Manually transition state (for complex test scenarios).
    public func forceState(_ state: ConnectionState) {
        transition(to: state)
    }

    /// Manually emit an event.
    public func emit(_ event: MCPEvent) {
        eventContinuation.yield(event)
    }

    private func transition(to newState: ConnectionState) {
        let oldState = _state
        _state = newState
        eventContinuation.yield(.stateChanged(serverID: id, from: oldState, to: newState))
    }

    /// Reset all recorded state.
    public func reset() {
        connectCallCount = 0
        disconnectCallCount = 0
        toolCallHistory = []
        cancelledToolCalls = []
        _state = .idle
    }

    /// Check if a specific tool was called.
    public func wasCalled(_ tool: String) -> Bool {
        toolCallHistory.contains { $0.name == tool }
    }
}

// MARK: - Mock Connection Factory

/// Factory for mock connections.
public final class MockServerConnectionFactory: ServerConnectionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var _connections: [String: MockServerConnection] = [:]

    /// Pre-registered connections by ID.
    public var connections: [String: MockServerConnection] {
        get { lock.withLock { _connections } }
        set { lock.withLock { _connections = newValue } }
    }

    /// Connections created by the factory (for inspection).
    public private(set) var createdConnections: [String: MockServerConnection] = [:]

    public init() {}

    public func makeConnection(id: String, spec: ServerSpec) -> any ServerConnectionProtocol {
        lock.lock()
        defer { lock.unlock() }

        if let existing = _connections[id] {
            createdConnections[id] = existing
            return existing
        }

        let conn = MockServerConnection(id: id)
        createdConnections[id] = conn
        return conn
    }

    /// Pre-configure a connection before it's requested.
    public func register(_ conn: MockServerConnection, for id: String) {
        lock.withLock { _connections[id] = conn }
    }

    /// Get a connection that was created.
    public func connection(for id: String) -> MockServerConnection? {
        lock.withLock { createdConnections[id] }
    }
}

// MARK: - Test Setup Helpers

extension MockServerConnection {
    /// Set the connect behavior.
    public func setConnectBehavior(_ behavior: ConnectBehavior) async {
        connectBehavior = behavior
    }

    /// Set the default tool call behavior.
    public func setDefaultToolBehavior(_ behavior: ToolCallBehavior) async {
        defaultToolCallBehavior = behavior
    }

    /// Set behavior for a specific tool.
    public func setToolBehavior(_ tool: String, behavior: ToolCallBehavior) async {
        toolCallBehavior[tool] = behavior
    }
}
