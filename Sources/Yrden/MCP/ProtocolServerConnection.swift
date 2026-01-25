/// Protocol-compliant ServerConnection implementation.
///
/// Uses dependency injection for testability:
/// - MCPClientProtocol for MCP operations
/// - MCPClientFactory for client creation
///
/// Manages connection lifecycle with state machine and event emission.

import Foundation
import MCP

/// Server connection that conforms to ServerConnectionProtocol.
///
/// This implementation uses injected dependencies for testability.
/// In production, use real MCP clients. In tests, use MockMCPClient.
///
/// - Note: Internal type. Use `mcpConnect()` for public API.
actor ProtocolServerConnection: ServerConnectionProtocol {

    // MARK: - Properties

    nonisolated let id: String
    private let spec: ServerSpec
    private let clientFactory: MCPClientFactory

    private var _state: ConnectionState = .idle
    var state: ConnectionState { _state }

    // MARK: - Events

    nonisolated let events: AsyncStream<ConnectionEvent>
    private let eventContinuation: AsyncStream<ConnectionEvent>.Continuation

    // MARK: - Internal State

    private var client: MCPClientProtocol?
    private var toolNames: [String] = []

    // MARK: - Initialization

    init(id: String, spec: ServerSpec, clientFactory: MCPClientFactory) {
        self.id = id
        self.spec = spec
        self.clientFactory = clientFactory

        var continuation: AsyncStream<ConnectionEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    // MARK: - ServerConnectionProtocol

    func connect() async {
        guard _state == .idle || _state.isFailed else { return }

        transition(to: .connecting)

        do {
            // Create client via factory
            let newClient = try await clientFactory.makeClient(spec: spec)
            self.client = newClient

            // List tools to verify connection works
            let result = try await newClient.listTools()
            toolNames = result.tools.map(\.name)

            transition(to: .connected(toolCount: toolNames.count, toolNames: toolNames))

        } catch {
            let message = error.localizedDescription
            let retryCount = currentRetryCount()
            transition(to: .failed(message: message, retryCount: retryCount))
        }
    }

    func disconnect() async {
        guard _state.isConnected else {
            transition(to: .disconnected)
            return
        }

        await client?.disconnect()
        client = nil
        toolNames = []
        transition(to: .disconnected)
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> String {
        guard let client = client, _state.isConnected else {
            throw MCPConnectionError.notConnected(serverID: id)
        }

        let requestId = UUID().uuidString
        eventContinuation.yield(.toolCallStarted(serverID: id, tool: name, requestId: requestId))

        let startTime = Date()

        do {
            let result = try await client.callTool(name: name, arguments: arguments)
            let duration = Date().timeIntervalSince(startTime)
            eventContinuation.yield(.toolCallCompleted(requestId: requestId, duration: duration, success: true))

            // Convert content to string
            return formatToolResult(result.content)

        } catch {
            let duration = Date().timeIntervalSince(startTime)
            eventContinuation.yield(.toolCallCompleted(requestId: requestId, duration: duration, success: false))
            throw error
        }
    }

    func cancelToolCall(requestId: String) async {
        do {
            try await client?.sendCancellation(requestId: requestId)
            eventContinuation.yield(.toolCallCancelled(requestId: requestId, reason: .userRequested))
        } catch {
            // Log but don't throw - cancellation is best-effort
            eventContinuation.yield(.log(serverID: id, entry: LogEntry(
                level: .warning,
                message: "Failed to send cancellation: \(error.localizedDescription)"
            )))
        }
    }

    func markReconnecting(attempt: Int, maxAttempts: Int, nextRetryAt: Date?) {
        transition(to: .reconnecting(attempt: attempt, maxAttempts: maxAttempts, nextRetryAt: nextRetryAt))
    }

    // MARK: - Private Helpers

    private func transition(to newState: ConnectionState) {
        let oldState = _state
        _state = newState
        eventContinuation.yield(.stateChanged(serverID: id, from: oldState, to: newState))
    }

    private func currentRetryCount() -> Int {
        switch _state {
        case .failed(_, let count): return count + 1
        case .reconnecting(let attempt, _, _): return attempt
        default: return 0
        }
    }

    private func formatToolResult(_ content: [MCP.Tool.Content]) -> String {
        content.compactMap { item -> String? in
            switch item {
            case .text(let text): return text
            case .image: return "[image]"
            case .audio: return "[audio]"
            case .resource: return "[resource]"
            }
        }.joined(separator: "\n")
    }
}

// MARK: - Factory

/// Factory for creating ProtocolServerConnection instances.
///
/// @unchecked Sendable is required because:
/// - MCPClientFactory protocol requires Sendable, but Swift can't verify
///   existential types (`any MCPClientFactory`) as Sendable at compile time
/// - This class is immutable (final with only `let` properties)
/// - The stored factory itself is guaranteed Sendable by protocol constraint
///
/// - Note: Internal type for testing infrastructure.
final class ProtocolServerConnectionFactory: ServerConnectionFactory, @unchecked Sendable {
    private let clientFactory: MCPClientFactory

    init(clientFactory: MCPClientFactory) {
        self.clientFactory = clientFactory
    }

    func makeConnection(id: String, spec: ServerSpec) -> any ServerConnectionProtocol {
        ProtocolServerConnection(id: id, spec: spec, clientFactory: clientFactory)
    }
}
