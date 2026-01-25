# MCP + Agent Integration: Final Design

## Problem Statement

The goal is to **load MCP tools into an Agent so the LLM can use them** with:
- Simple API for direct tool usage
- Per-server lifecycle management (connect, retry, logs)
- UI feedback for connection status and failures
- Tool modes/profiles for filtering tools across servers
- Reactive agent rebuilding when tools change
- Robust cancellation and timeout handling

---

## Design Principles

1. **Each server connection is independent** - failures are isolated
2. **Tools flow directly to Agent** - no manual wrapping
3. **Tools are proxies, not snapshots** - route through coordinator, never stale
4. **Layered architecture** - UI state separate from I/O
5. **Actor isolation** - no race conditions
6. **State machines** - explicit, validated transitions
7. **Event-driven** - state changes flow as events
8. **Cancellation everywhere** - user can stop any operation

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                      UI Layer (SwiftUI)                              │
│  - Binds to MCPManager (@Published)                                 │
│  - Triggers actions via MCPManager                                  │
│  - Shows server status, logs, alerts                                │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│                 MCPManager (@MainActor, ObservableObject)            │
│  - ONLY holds UI state (@Published servers, tools, alerts)          │
│  - ONLY forwards actions to coordinator                             │
│  - ONLY subscribes to events and updates state                      │
│  - Does NO I/O                                                       │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │ events ↑  │ actions ↓
                                  ▼            │
┌─────────────────────────────────────────────────────────────────────┐
│                 MCPCoordinator (actor)                               │
│  - Manages all server connections                                   │
│  - Runs I/O off main thread                                         │
│  - Publishes events stream                                          │
│  - Handles reconnection policy                                      │
│  - Routes tool calls to live connections                            │
│  - Enforces timeouts and cancellation                               │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
              ┌───────────────────┼───────────────────┐
              ▼                   ▼                   ▼
┌─────────────────────┐ ┌─────────────────────┐ ┌─────────────────────┐
│  ServerConnection   │ │  ServerConnection   │ │  ServerConnection   │
│  (actor)            │ │  (actor)            │ │  (actor)            │
│  - State machine    │ │  - State machine    │ │  - State machine    │
│  - Owns MCP client  │ │  - Owns MCP client  │ │  - Owns MCP client  │
│  - Emits events     │ │  - Emits events     │ │  - Emits events     │
└─────────────────────┘ └─────────────────────┘ └─────────────────────┘
```

---

## Layer 1: ServerConnection (Actor with State Machine)

Each connection is an isolated actor with explicit state machine. No external code can cause race conditions.

```swift
/// A single MCP server connection with state machine lifecycle.
public actor ServerConnection {
    public let id: String
    public let spec: ServerSpec

    // MARK: - State Machine

    public private(set) var state: ConnectionState = .idle

    public enum ConnectionState: Equatable, Sendable {
        case idle
        case connecting
        case authenticating(progress: AuthProgress)
        case connected(tools: [ToolInfo])
        case failed(message: String, retryCount: Int)
        case reconnecting(attempt: Int, maxAttempts: Int, nextRetryAt: Date?)
        case disconnected

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        public var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }

        public var isTerminal: Bool {
            switch self {
            case .connected, .failed, .disconnected: return true
            default: return false
            }
        }
    }

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

    // MARK: - Events

    public let events: AsyncStream<ConnectionEvent>
    private let eventContinuation: AsyncStream<ConnectionEvent>.Continuation

    // MARK: - Internal State

    private var client: Client?
    private var pendingToolCalls: [String: PendingToolCall] = [:]
    private var logs: [LogEntry] = []
    private let maxLogs = 1000

    struct PendingToolCall {
        let id: String
        let toolName: String
        let startedAt: Date
    }

    // MARK: - Initialization

    public init(id: String, spec: ServerSpec) {
        self.id = id
        self.spec = spec

        var continuation: AsyncStream<ConnectionEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    // MARK: - Lifecycle

    /// Connect to the server. Only valid from idle, failed, or disconnected states.
    public func connect() async {
        guard state == .idle || state.isFailed || state == .disconnected else {
            log(.warning, "Cannot connect from state: \(state)")
            return
        }

        transition(to: .connecting)

        do {
            client = try await performConnection()
            let tools = try await discoverTools()
            transition(to: .connected(tools: tools))
        } catch is CancellationError {
            transition(to: .idle)
        } catch {
            transition(to: .failed(message: error.localizedDescription, retryCount: 0))
        }
    }

    /// Disconnect from the server.
    public func disconnect() async {
        guard case .connected = state else { return }

        await client?.disconnect()
        client = nil
        transition(to: .disconnected)
    }

    /// Mark as reconnecting (called by coordinator).
    public func markReconnecting(attempt: Int, maxAttempts: Int, nextRetryAt: Date?) {
        transition(to: .reconnecting(attempt: attempt, maxAttempts: maxAttempts, nextRetryAt: nextRetryAt))
    }

    // MARK: - Tool Calls

    /// Call a tool on this server.
    public func callTool(name: String, arguments: [String: Value]?) async throws -> String {
        guard case .connected = state else {
            throw MCPError.notConnected(serverID: id)
        }

        let requestId = UUID().uuidString
        pendingToolCalls[requestId] = PendingToolCall(id: requestId, toolName: name, startedAt: Date())
        defer { pendingToolCalls.removeValue(forKey: requestId) }

        eventContinuation.yield(.toolCallStarted(serverID: id, tool: name, requestId: requestId))
        let startTime = Date()

        do {
            let result = try await withTaskCancellationHandler {
                try await client!.callTool(name: name, arguments: arguments)
            } onCancel: {
                Task { [weak self] in
                    await self?.sendCancellation(requestId: requestId, tool: name)
                }
            }

            let duration = Date().timeIntervalSince(startTime)
            eventContinuation.yield(.toolCallCompleted(requestId: requestId, duration: duration, success: true))

            return formatToolResult(result)

        } catch {
            let duration = Date().timeIntervalSince(startTime)
            eventContinuation.yield(.toolCallCompleted(requestId: requestId, duration: duration, success: false))
            throw error
        }
    }

    /// Cancel a pending tool call.
    public func cancelToolCall(requestId: String) async {
        guard pendingToolCalls[requestId] != nil else { return }
        await sendCancellation(requestId: requestId, tool: pendingToolCalls[requestId]?.toolName ?? "unknown")
    }

    private func sendCancellation(requestId: String, tool: String) async {
        log(.info, "Cancelling tool call: \(tool)")
        eventContinuation.yield(.toolCallCancelled(requestId: requestId, reason: .userRequested))

        // Send MCP cancellation notification (server may ignore)
        try? await client?.sendCancellation(requestId: requestId)
    }

    // MARK: - State Transitions

    private func transition(to newState: ConnectionState) {
        let oldState = state
        state = newState

        log(.info, "State: \(oldState) → \(newState)")
        eventContinuation.yield(.stateChanged(serverID: id, from: oldState, to: newState))
    }

    // MARK: - Logging

    private func log(_ level: LogLevel, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        logs.append(entry)

        // Retention policy
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }

        eventContinuation.yield(.log(serverID: id, entry: entry))
    }

    // MARK: - Private Helpers

    private func performConnection() async throws -> Client {
        // Implementation depends on ServerSpec.kind
        // - .stdio: spawn process, connect via stdio
        // - .http: connect to URL
        // - .oauth: perform OAuth flow, then connect
        fatalError("Implementation required")
    }

    private func discoverTools() async throws -> [ToolInfo] {
        guard let client = client else { throw MCPError.notConnected(serverID: id) }
        let mcpTools = try await client.listTools()
        return mcpTools.tools.map { ToolInfo(from: $0) }
    }

    private func formatToolResult(_ result: CallToolResult) -> String {
        result.content.map { content -> String in
            switch content {
            case .text(let text): return text
            case .image(let data, let mimeType, _): return "[Image: \(mimeType), \(data.count) bytes]"
            case .audio(let data, let mimeType): return "[Audio: \(mimeType), \(data.count) bytes]"
            case .resource(let uri, let mimeType, let text): return text ?? "[Resource: \(uri)]"
            }
        }.joined(separator: "\n")
    }
}

// MARK: - Connection Events

public enum ConnectionEvent: Sendable {
    case stateChanged(serverID: String, from: ConnectionState, to: ConnectionState)
    case log(serverID: String, entry: LogEntry)
    case toolCallStarted(serverID: String, tool: String, requestId: String)
    case toolCallCompleted(requestId: String, duration: TimeInterval, success: Bool)
    case toolCallCancelled(requestId: String, reason: CancellationReason)
}

public enum CancellationReason: Sendable {
    case userRequested
    case timeout(Duration)
    case serverDisconnected
    case appShutdown
}

// MARK: - Supporting Types

public struct ToolInfo: Identifiable, Sendable {
    public let id: String  // tool name
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    init(from mcpTool: MCP.Tool) {
        self.id = mcpTool.name
        self.name = mcpTool.name
        self.description = mcpTool.description ?? ""
        self.inputSchema = JSONValue(mcpValue: mcpTool.inputSchema)
    }
}

public struct LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let level: LogLevel
    public let message: String
}

public enum LogLevel: String, Sendable {
    case debug, info, warning, error
}

public enum MCPError: Error, Sendable {
    case notConnected(serverID: String)
    case unknownServer(serverID: String)
    case toolTimeout(serverID: String, tool: String, timeout: Duration)
    case toolCancelled(serverID: String, tool: String)
    case connectionFailed(serverID: String, message: String)
}
```

---

## Layer 2: MCPCoordinator (Actor)

Coordinates all connections, handles policies, routes tool calls with timeout/cancellation.

```swift
/// Coordinates all MCP server connections.
public actor MCPCoordinator {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var toolTimeout: Duration = .seconds(30)
        public var connectionTimeout: Duration = .seconds(10)
        public var oauthTimeout: Duration = .seconds(120)
        public var reconnectPolicy: ReconnectPolicy = .exponentialBackoff(maxAttempts: 5, baseDelay: 1.0)
        public var healthCheckInterval: Duration? = .seconds(30)

        public init() {}
    }

    public enum ReconnectPolicy: Sendable {
        case none
        case immediate(maxAttempts: Int)
        case exponentialBackoff(maxAttempts: Int, baseDelay: TimeInterval)
    }

    private let configuration: Configuration

    // MARK: - State

    private var connections: [String: ServerConnection] = [:]
    private var connectionTasks: [String: Task<Void, Never>] = [:]
    private var eventSubscriptions: [String: Task<Void, Never>] = [:]
    private var healthCheckTask: Task<Void, Never>?

    // MARK: - Events

    public let events: AsyncStream<CoordinatorEvent>
    private let eventContinuation: AsyncStream<CoordinatorEvent>.Continuation

    // MARK: - Initialization

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration

        var continuation: AsyncStream<CoordinatorEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    // MARK: - Lifecycle

    /// Start all configured servers in parallel.
    public func startAll(specs: [ServerSpec]) async {
        for spec in specs {
            let connection = ServerConnection(id: spec.id, spec: spec)
            connections[spec.id] = connection
            subscribeToConnection(connection)

            connectionTasks[spec.id] = Task {
                await connection.connect()
            }
        }

        // Start health checks if configured
        if let interval = configuration.healthCheckInterval {
            startHealthChecks(interval: interval)
        }
    }

    /// Start all servers and wait until all reach terminal state.
    public func startAllAndWait(specs: [ServerSpec]) async -> StartResult {
        await startAll(specs: specs)

        // Wait for all to reach terminal state
        while true {
            let allTerminal = await withTaskGroup(of: Bool.self) { group in
                for conn in connections.values {
                    group.addTask {
                        await conn.state.isTerminal
                    }
                }
                return await group.allSatisfy { $0 }
            }

            if allTerminal { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Collect results
        var connected: [String] = []
        var failed: [(serverID: String, message: String)] = []

        for (id, conn) in connections {
            let state = await conn.state
            if state.isConnected {
                connected.append(id)
            } else if case .failed(let msg, _) = state {
                failed.append((id, msg))
            }
        }

        return StartResult(
            connectedServers: connected,
            failedServers: failed
        )
    }

    /// Connect a single server.
    public func connect(serverID: String) async {
        guard let connection = connections[serverID] else { return }

        connectionTasks[serverID]?.cancel()
        connectionTasks[serverID] = Task {
            await connection.connect()
        }
    }

    /// Reconnect a failed server.
    public func reconnect(serverID: String) async {
        guard let connection = connections[serverID] else { return }

        // Cancel any existing connection attempt
        connectionTasks[serverID]?.cancel()

        connectionTasks[serverID] = Task {
            await connection.connect()
        }
    }

    /// Disconnect a server.
    public func disconnect(serverID: String) async {
        connectionTasks[serverID]?.cancel()
        connectionTasks.removeValue(forKey: serverID)
        await connections[serverID]?.disconnect()
    }

    /// Cancel a connection attempt (e.g., stuck OAuth).
    public func cancelConnection(serverID: String) async {
        connectionTasks[serverID]?.cancel()
        connectionTasks.removeValue(forKey: serverID)
        // Connection will transition to idle when task is cancelled
    }

    /// Stop all connections.
    public func stopAll() async {
        healthCheckTask?.cancel()

        for (id, task) in connectionTasks {
            task.cancel()
        }
        connectionTasks.removeAll()

        for conn in connections.values {
            await conn.disconnect()
        }

        for task in eventSubscriptions.values {
            task.cancel()
        }
        eventSubscriptions.removeAll()
    }

    // MARK: - Tool Calls

    /// Call a tool with timeout.
    public func callTool(
        serverID: String,
        name: String,
        arguments: [String: Value]?,
        timeout: Duration? = nil
    ) async throws -> String {
        guard let connection = connections[serverID] else {
            throw MCPError.unknownServer(serverID: serverID)
        }

        let effectiveTimeout = timeout ?? configuration.toolTimeout

        // Race between tool call and timeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await connection.callTool(name: name, arguments: arguments)
            }

            group.addTask {
                try await Task.sleep(for: effectiveTimeout)
                throw MCPError.toolTimeout(serverID: serverID, tool: name, timeout: effectiveTimeout)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Cancel a specific tool call.
    public func cancelToolCall(requestId: String) async {
        for conn in connections.values {
            await conn.cancelToolCall(requestId: requestId)
        }
    }

    // MARK: - Snapshots

    /// Get current state of all servers (for UI).
    public var snapshot: CoordinatorSnapshot {
        get async {
            var serverStates: [String: ServerSnapshot] = [:]

            for (id, conn) in connections {
                let state = await conn.state
                let tools: [ToolInfo]
                if case .connected(let t) = state {
                    tools = t
                } else {
                    tools = []
                }

                serverStates[id] = ServerSnapshot(
                    id: id,
                    state: state,
                    tools: tools
                )
            }

            return CoordinatorSnapshot(servers: serverStates)
        }
    }

    // MARK: - Private

    private func subscribeToConnection(_ connection: ServerConnection) {
        eventSubscriptions[connection.id] = Task { [weak self] in
            for await event in connection.events {
                await self?.handleConnectionEvent(event)
            }
        }
    }

    private func handleConnectionEvent(_ event: ConnectionEvent) async {
        switch event {
        case .stateChanged(let id, let from, let to):
            // Forward to coordinator events
            eventContinuation.yield(.serverStateChanged(
                serverID: id,
                from: from,
                to: to
            ))

            // Handle reconnection on failure
            if case .failed(_, let retryCount) = to {
                await maybeReconnect(serverID: id, retryCount: retryCount)
            }

        case .log(let id, let entry):
            eventContinuation.yield(.serverLog(serverID: id, entry: entry))

        case .toolCallStarted(let serverID, let tool, let requestId):
            eventContinuation.yield(.toolCallStarted(serverID: serverID, tool: tool, requestId: requestId))

        case .toolCallCompleted(let requestId, let duration, let success):
            eventContinuation.yield(.toolCallCompleted(requestId: requestId, duration: duration, success: success))

        case .toolCallCancelled(let requestId, let reason):
            eventContinuation.yield(.toolCallCancelled(requestId: requestId, reason: reason))
        }
    }

    private func maybeReconnect(serverID: String, retryCount: Int) async {
        switch configuration.reconnectPolicy {
        case .none:
            return

        case .immediate(let maxAttempts):
            guard retryCount < maxAttempts else { return }
            await connections[serverID]?.markReconnecting(attempt: retryCount + 1, maxAttempts: maxAttempts, nextRetryAt: nil)
            await connect(serverID: serverID)

        case .exponentialBackoff(let maxAttempts, let baseDelay):
            guard retryCount < maxAttempts else { return }

            let delay = baseDelay * pow(2.0, Double(retryCount))
            let nextRetry = Date().addingTimeInterval(delay)

            await connections[serverID]?.markReconnecting(
                attempt: retryCount + 1,
                maxAttempts: maxAttempts,
                nextRetryAt: nextRetry
            )

            connectionTasks[serverID] = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await connections[serverID]?.connect()
            }
        }
    }

    private func startHealthChecks(interval: Duration) {
        healthCheckTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await checkAllServerHealth()
            }
        }
    }

    private func checkAllServerHealth() async {
        for (id, conn) in connections {
            let state = await conn.state
            guard case .connected = state else { continue }

            // Simple ping - try to list tools
            // If it fails, the connection event will trigger
            // Could be enhanced with actual MCP ping
        }
    }
}

// MARK: - Coordinator Events

public enum CoordinatorEvent: Sendable {
    case serverStateChanged(serverID: String, from: ConnectionState, to: ConnectionState)
    case serverLog(serverID: String, entry: LogEntry)
    case toolCallStarted(serverID: String, tool: String, requestId: String)
    case toolCallCompleted(requestId: String, duration: TimeInterval, success: Bool)
    case toolCallCancelled(requestId: String, reason: CancellationReason)
}

// MARK: - Snapshots

public struct CoordinatorSnapshot: Sendable {
    public let servers: [String: ServerSnapshot]
}

public struct ServerSnapshot: Sendable {
    public let id: String
    public let state: ConnectionState
    public let tools: [ToolInfo]
}

public struct StartResult: Sendable {
    public let connectedServers: [String]
    public let failedServers: [(serverID: String, message: String)]

    public var allSucceeded: Bool { failedServers.isEmpty }
}
```

---

## Layer 3: MCPManager (MainActor, UI State)

Thin layer that subscribes to coordinator events and maintains @Published state. Does NO I/O.

```swift
/// Manages MCP state for UI binding. Does no I/O.
@MainActor
public final class MCPManager: ObservableObject {

    // MARK: - Published State

    /// All server states (for UI binding).
    @Published public private(set) var servers: [String: ServerStateView] = [:]

    /// All available tools from connected servers.
    @Published public private(set) var availableTools: [String: ToolEntryView] = [:]

    /// Active tool calls in progress.
    @Published public private(set) var activeToolCalls: [ActiveToolCall] = []

    /// Pending alerts for user attention.
    @Published public private(set) var pendingAlerts: [MCPAlert] = []

    // MARK: - Configuration

    /// Server specifications to connect to.
    public var serverSpecs: [ServerSpec] = []

    /// Token storage for OAuth.
    public var tokenStorage: MCPTokenStorage = KeychainTokenStorage()

    /// Coordinator configuration.
    public var configuration: MCPCoordinator.Configuration = .init()

    // MARK: - Internal

    private let coordinator: MCPCoordinator
    private var eventSubscription: Task<Void, Never>?

    // MARK: - Initialization

    public init() {
        self.coordinator = MCPCoordinator(configuration: configuration)
        subscribeToEvents()
    }

    public init(coordinator: MCPCoordinator) {
        self.coordinator = coordinator
        subscribeToEvents()
    }

    deinit {
        eventSubscription?.cancel()
    }

    private func subscribeToEvents() {
        eventSubscription = Task { [weak self] in
            guard let coordinator = self?.coordinator else { return }
            for await event in coordinator.events {
                await self?.handleEvent(event)
            }
        }
    }

    // MARK: - Lifecycle Actions

    /// Start all configured servers in parallel.
    public func startAll() async {
        // Initialize server views
        for spec in serverSpecs {
            servers[spec.id] = ServerStateView(
                id: spec.id,
                displayName: spec.displayName,
                status: .idle,
                toolCount: 0,
                logs: []
            )
        }

        await coordinator.startAll(specs: serverSpecs)
    }

    /// Start all servers and wait for completion.
    public func startAllAndWait() async -> StartResult {
        for spec in serverSpecs {
            servers[spec.id] = ServerStateView(
                id: spec.id,
                displayName: spec.displayName,
                status: .idle,
                toolCount: 0,
                logs: []
            )
        }

        return await coordinator.startAllAndWait(specs: serverSpecs)
    }

    /// Reconnect a server.
    public func reconnect(serverID: String) async {
        await coordinator.reconnect(serverID: serverID)
    }

    /// Reconnect all failed servers.
    public func reconnectFailed() async {
        let failed = servers.values.filter { $0.status.isFailed }
        for server in failed {
            await coordinator.reconnect(serverID: server.id)
        }
    }

    /// Cancel a connection attempt (e.g., stuck OAuth).
    public func cancelConnection(serverID: String) async {
        await coordinator.cancelConnection(serverID: serverID)
    }

    /// Disconnect a server.
    public func disconnect(serverID: String) async {
        await coordinator.disconnect(serverID: serverID)
    }

    /// Stop all servers.
    public func stopAll() async {
        await coordinator.stopAll()
    }

    // MARK: - Tool Access

    /// Get all tools from connected servers.
    /// Returns PROXIES that route through coordinator (never stale).
    public func allTools() -> [AnyAgentTool<Void>] {
        availableTools.values.map { entry in
            MCPToolProxy(
                serverID: entry.serverID,
                name: entry.name,
                definition: entry.definition,
                coordinator: coordinator
            ).asAnyAgentTool()
        }
    }

    /// Get tools filtered by predicate.
    public func tools(matching predicate: (ToolEntryView) -> Bool) -> [AnyAgentTool<Void>] {
        availableTools.values
            .filter(predicate)
            .map { entry in
                MCPToolProxy(
                    serverID: entry.serverID,
                    name: entry.name,
                    definition: entry.definition,
                    coordinator: coordinator
                ).asAnyAgentTool()
            }
    }

    /// Get tools for a specific mode.
    public func tools(for mode: ToolMode) -> [AnyAgentTool<Void>] {
        tools(matching: { mode.filter.matches($0) })
    }

    // MARK: - Tool Call Management

    /// Cancel a specific tool call.
    public func cancelToolCall(requestId: String) async {
        await coordinator.cancelToolCall(requestId: requestId)
    }

    // MARK: - Alert Management

    /// Dismiss an alert.
    public func dismissAlert(_ alert: MCPAlert) {
        pendingAlerts.removeAll { $0.id == alert.id }
    }

    /// Dismiss all alerts.
    public func dismissAllAlerts() {
        pendingAlerts.removeAll()
    }

    // MARK: - Computed Properties

    public var hasFailures: Bool {
        servers.values.contains { $0.status.isFailed }
    }

    public var failedServers: [ServerStateView] {
        Array(servers.values.filter { $0.status.isFailed })
    }

    public var connectedCount: Int {
        servers.values.filter { $0.status.isConnected }.count
    }

    public var totalCount: Int {
        servers.count
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: CoordinatorEvent) {
        switch event {
        case .serverStateChanged(let id, _, let to):
            updateServerState(id: id, state: to)

        case .serverLog(let id, let entry):
            appendLog(serverID: id, entry: entry)

        case .toolCallStarted(let serverID, let tool, let requestId):
            activeToolCalls.append(ActiveToolCall(
                id: requestId,
                serverID: serverID,
                toolName: tool,
                startedAt: Date()
            ))

        case .toolCallCompleted(let requestId, _, _):
            activeToolCalls.removeAll { $0.id == requestId }

        case .toolCallCancelled(let requestId, _):
            activeToolCalls.removeAll { $0.id == requestId }
        }
    }

    private func updateServerState(id: String, state: ConnectionState) {
        guard var view = servers[id] else { return }

        switch state {
        case .idle:
            view.status = .idle

        case .connecting:
            view.status = .connecting

        case .authenticating(let progress):
            view.status = .authenticating(progress.description)

        case .connected(let tools):
            view.status = .connected
            view.toolCount = tools.count
            updateAvailableTools(serverID: id, tools: tools)

        case .failed(let message, _):
            view.status = .failed(message: message)
            view.lastErrorMessage = message
            removeToolsForServer(serverID: id)
            addAlert(serverID: id, kind: .connectionFailed, message: message)

        case .reconnecting(let attempt, let max, let nextRetry):
            view.status = .reconnecting(attempt: attempt, maxAttempts: max)

        case .disconnected:
            view.status = .disconnected
            removeToolsForServer(serverID: id)
        }

        servers[id] = view
    }

    private func updateAvailableTools(serverID: String, tools: [ToolInfo]) {
        // Remove old tools for this server
        removeToolsForServer(serverID: serverID)

        // Add new tools
        for tool in tools {
            let entry = ToolEntryView(
                serverID: serverID,
                name: tool.name,
                description: tool.description,
                definition: ToolDefinition(
                    name: tool.name,
                    description: tool.description,
                    inputSchema: tool.inputSchema
                )
            )
            availableTools[entry.id] = entry
        }
    }

    private func removeToolsForServer(serverID: String) {
        availableTools = availableTools.filter { $0.value.serverID != serverID }
    }

    private func appendLog(serverID: String, entry: LogEntry) {
        guard var view = servers[serverID] else { return }
        view.logs.append(entry)

        // Retention policy
        if view.logs.count > 1000 {
            view.logs.removeFirst(view.logs.count - 1000)
        }

        servers[serverID] = view
    }

    private func addAlert(serverID: String, kind: MCPAlert.AlertKind, message: String) {
        pendingAlerts.append(MCPAlert(
            id: UUID(),
            serverID: serverID,
            kind: kind,
            message: message,
            timestamp: Date()
        ))
    }
}

// MARK: - UI View Types

public struct ServerStateView: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public var status: ConnectionStatusView
    public var toolCount: Int
    public var logs: [LogEntry]
    public var lastErrorMessage: String?
}

public enum ConnectionStatusView: Equatable, Sendable {
    case idle
    case connecting
    case authenticating(String)
    case connected
    case failed(message: String)
    case reconnecting(attempt: Int, maxAttempts: Int)
    case disconnected

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .idle: return "Not started"
        case .connecting: return "Connecting..."
        case .authenticating(let msg): return msg
        case .connected: return "Connected"
        case .failed(let msg): return msg
        case .reconnecting(let n, let max): return "Reconnecting (\(n)/\(max))..."
        case .disconnected: return "Disconnected"
        }
    }
}

public struct ToolEntryView: Identifiable, Sendable {
    public var id: String { "\(serverID).\(name)" }
    public let serverID: String
    public let name: String
    public let description: String
    public let definition: ToolDefinition
}

public struct ActiveToolCall: Identifiable, Sendable {
    public let id: String
    public let serverID: String
    public let toolName: String
    public let startedAt: Date
}

public struct MCPAlert: Identifiable, Sendable {
    public let id: UUID
    public let serverID: String
    public let kind: AlertKind
    public let message: String
    public let timestamp: Date

    public enum AlertKind: Sendable {
        case connectionFailed
        case authExpired
        case disconnected
        case authRequired
    }
}
```

---

## Layer 4: Tool Proxies

Tools don't capture connections - they route through coordinator. Never stale.

```swift
/// Tool proxy that routes calls through the coordinator.
/// Never holds stale connection references.
struct MCPToolProxy: Sendable {
    let serverID: String
    let name: String
    let definition: ToolDefinition
    let coordinator: MCPCoordinator

    func call(argumentsJSON: String) async throws -> AnyToolResult {
        // Parse arguments
        let arguments: [String: Value]?
        if argumentsJSON.isEmpty || argumentsJSON == "{}" {
            arguments = nil
        } else {
            guard let data = argumentsJSON.data(using: .utf8),
                  let json = try? JSONValue(jsonData: data),
                  case .object(let obj) = json else {
                return .failure(ToolExecutionError.argumentParsing("Invalid JSON arguments"))
            }
            arguments = obj.asMCPValue
        }

        do {
            let result = try await coordinator.callTool(
                serverID: serverID,
                name: name,
                arguments: arguments
            )
            return .success(result)

        } catch is CancellationError {
            throw CancellationError()

        } catch let error as MCPError {
            switch error {
            case .notConnected(let id):
                return .failure(MCPToolError.serverDisconnected(serverID: id))

            case .toolTimeout(let id, let tool, let timeout):
                return .retry(message: "Tool '\(tool)' on server '\(id)' timed out after \(timeout.description). Try a simpler request or break into steps.")

            case .toolCancelled:
                throw CancellationError()

            case .unknownServer(let id):
                return .failure(MCPToolError.serverDisconnected(serverID: id))

            case .connectionFailed(let id, let msg):
                return .failure(MCPToolError.executionFailed(name: name, server: id, underlying: NSError(domain: "MCP", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])))
            }

        } catch {
            return .failure(error)
        }
    }

    func asAnyAgentTool() -> AnyAgentTool<Void> {
        AnyAgentTool<Void>(
            name: name,
            description: definition.description,
            definition: definition,
            maxRetries: 1
        ) { _, args in
            try await self.call(argumentsJSON: args)
        }
    }
}
```

---

## Server Specification

```swift
/// Specification for connecting to an MCP server.
public struct ServerSpec: Identifiable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let kind: ServerKind

    public enum ServerKind: Codable, Sendable {
        case stdio(command: String, arguments: [String], environment: [String: String]?)
        case http(url: URL)
        case oauth(url: URL, redirectScheme: String)
    }

    // MARK: - Convenience Initializers

    public static func stdio(
        _ command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        id: String,
        displayName: String? = nil
    ) -> ServerSpec {
        ServerSpec(
            id: id,
            displayName: displayName ?? id,
            kind: .stdio(command: command, arguments: arguments, environment: environment)
        )
    }

    public static func http(_ url: URL, id: String, displayName: String? = nil) -> ServerSpec {
        ServerSpec(
            id: id,
            displayName: displayName ?? id,
            kind: .http(url: url)
        )
    }

    public static func oauth(
        _ url: URL,
        redirectScheme: String,
        id: String,
        displayName: String? = nil
    ) -> ServerSpec {
        ServerSpec(
            id: id,
            displayName: displayName ?? id,
            kind: .oauth(url: url, redirectScheme: redirectScheme)
        )
    }
}
```

---

## Tool Modes

```swift
/// Defines which tools are available in a given mode.
public struct ToolMode: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let icon: String
    public let filter: ToolFilter

    public static let fullAccess = ToolMode(
        id: "full",
        name: "Full Access",
        icon: "square.grid.3x3.fill",
        filter: .all
    )
}

/// Filter criteria for selecting tools.
public enum ToolFilter: Codable, Sendable {
    case all
    case servers([String])
    case tools([String])
    case toolIDs([String])
    case pattern(String)
    case and([ToolFilter])
    case or([ToolFilter])
    case not(ToolFilter)

    public func matches(_ entry: ToolEntryView) -> Bool {
        switch self {
        case .all:
            return true
        case .servers(let ids):
            return ids.contains(entry.serverID)
        case .tools(let names):
            return names.contains(entry.name)
        case .toolIDs(let ids):
            return ids.contains(entry.id)
        case .pattern(let regex):
            return entry.name.range(of: regex, options: .regularExpression) != nil
        case .and(let filters):
            return filters.allSatisfy { $0.matches(entry) }
        case .or(let filters):
            return filters.contains { $0.matches(entry) }
        case .not(let filter):
            return !filter.matches(entry)
        }
    }
}
```

---

## Deps Integration

MCP tools use `Void` deps. For mixing with local tools, use lifting.

```swift
extension AnyAgentTool where Deps == Void {
    /// Lift a Void-deps tool to work with any deps type.
    public func lifted<D: Sendable>() -> AnyAgentTool<D> {
        AnyAgentTool<D>(
            name: name,
            description: description,
            definition: definition,
            maxRetries: maxRetries
        ) { context, args in
            let voidContext = AgentContext<Void>(
                deps: (),
                toolCallCount: context.toolCallCount,
                retryCount: context.retryCount,
                usageState: context.usageState
            )
            return try await self.call(context: voidContext, argumentsJSON: args)
        }
    }
}

extension Array where Element == AnyAgentTool<Void> {
    public func lifted<D: Sendable>() -> [AnyAgentTool<D>] {
        map { $0.lifted() }
    }
}
```

---

## UI Components

### Server List

```swift
struct ServerListView: View {
    @EnvironmentObject var mcp: MCPManager

    var body: some View {
        List {
            ForEach(Array(mcp.servers.values)) { server in
                ServerRow(server: server)
            }
        }
        .toolbar {
            if mcp.hasFailures {
                Button("Reconnect Failed") {
                    Task { await mcp.reconnectFailed() }
                }
            }
        }
    }
}

struct ServerRow: View {
    let server: ServerStateView
    @EnvironmentObject var mcp: MCPManager
    @State private var showingLogs = false

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading) {
                Text(server.displayName)
                    .font(.headline)
                Text(server.status.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if server.status.isConnected {
                Text("\(server.toolCount)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(8)
            }

            Menu {
                if server.status.isFailed {
                    Button("Retry") {
                        Task { await mcp.reconnect(serverID: server.id) }
                    }
                }
                if case .connecting = server.status {
                    Button("Cancel") {
                        Task { await mcp.cancelConnection(serverID: server.id) }
                    }
                }
                if case .authenticating = server.status {
                    Button("Cancel") {
                        Task { await mcp.cancelConnection(serverID: server.id) }
                    }
                }
                if server.status.isConnected {
                    Button("Disconnect") {
                        Task { await mcp.disconnect(serverID: server.id) }
                    }
                }
                Divider()
                Button("View Logs") {
                    showingLogs = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .sheet(isPresented: $showingLogs) {
            ServerLogsView(server: server)
        }
    }

    var statusColor: Color {
        switch server.status {
        case .connected: return .green
        case .connecting, .authenticating, .reconnecting: return .yellow
        case .failed: return .red
        case .disconnected, .idle: return .gray
        }
    }
}
```

### Tool Progress with Cancel

```swift
struct ActiveToolCallsView: View {
    @EnvironmentObject var mcp: MCPManager

    var body: some View {
        if !mcp.activeToolCalls.isEmpty {
            VStack(spacing: 8) {
                ForEach(mcp.activeToolCalls) { call in
                    ToolProgressRow(call: call)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
    }
}

struct ToolProgressRow: View {
    let call: ActiveToolCall
    @EnvironmentObject var mcp: MCPManager

    var body: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.8)

            VStack(alignment: .leading) {
                Text(call.toolName)
                    .font(.caption.bold())
                Text("on \(call.serverID) • \(call.startedAt, style: .relative)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Cancel") {
                Task { await mcp.cancelToolCall(requestId: call.id) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
```

### Status Indicator

```swift
struct MCPStatusIndicator: View {
    @EnvironmentObject var mcp: MCPManager

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text("\(mcp.connectedCount)/\(mcp.totalCount)")
                .font(.caption.monospacedDigit())
        }
        .help("\(mcp.connectedCount) of \(mcp.totalCount) servers connected")
    }

    var statusColor: Color {
        if mcp.connectedCount == mcp.totalCount && mcp.totalCount > 0 {
            return .green
        } else if mcp.connectedCount > 0 {
            return .yellow
        } else {
            return .red
        }
    }
}
```

---

## Complete App Example

```swift
import SwiftUI
import Yrden

@main
struct MyAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var mcp = MCPManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mcp)
                .task {
                    mcp.serverSpecs = [
                        .stdio("uvx", arguments: ["mcp-server-filesystem", "/tmp"], id: "filesystem", displayName: "Filesystem"),
                        .stdio("uvx", arguments: ["mcp-server-memory"], id: "memory", displayName: "Memory"),
                        .oauth(URL(string: "https://mcp.linear.app")!, redirectScheme: "myapp", id: "linear", displayName: "Linear")
                    ]

                    await mcp.startAll()
                }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ app: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            mcpHandleCallback(url)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var mcp: MCPManager
    @StateObject private var chat = ChatViewModel()
    @State private var selectedMode: ToolMode = .fullAccess
    @State private var showingAlert = false

    var body: some View {
        NavigationSplitView {
            List {
                Section("Servers") {
                    ForEach(Array(mcp.servers.values)) { server in
                        ServerRow(server: server)
                    }
                }

                Section("Modes") {
                    ForEach([ToolMode.fullAccess]) { mode in
                        Button {
                            selectedMode = mode
                            chat.setMode(mode)
                        } label: {
                            Label(mode.name, systemImage: mode.icon)
                        }
                    }
                }
            }
        } detail: {
            VStack {
                ChatView(viewModel: chat)
                ActiveToolCallsView()
            }
        }
        .toolbar {
            MCPStatusIndicator()
        }
        .onAppear {
            chat.mcp = mcp
            setupToolObserver()
        }
        .onChange(of: mcp.pendingAlerts) { _, alerts in
            showingAlert = !alerts.isEmpty
        }
        .alert("Server Issue", isPresented: $showingAlert) {
            if let alert = mcp.pendingAlerts.first {
                Button("Retry") {
                    Task { await mcp.reconnect(serverID: alert.serverID) }
                    mcp.dismissAlert(alert)
                }
                Button("Dismiss", role: .cancel) {
                    mcp.dismissAlert(alert)
                }
            }
        } message: {
            if let alert = mcp.pendingAlerts.first {
                Text("\(alert.serverID): \(alert.message)")
            }
        }
    }

    private func setupToolObserver() {
        // Rebuild agent when tools change
        // (In real app, use Combine publisher)
    }
}

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isRunning = false

    var mcp: MCPManager?
    private var currentMode: ToolMode = .fullAccess
    private var currentRun: Task<Void, Never>?

    func setMode(_ mode: ToolMode) {
        currentMode = mode
    }

    func send(_ message: String) {
        guard let mcp = mcp else { return }

        currentRun?.cancel()
        isRunning = true

        currentRun = Task {
            defer { isRunning = false }

            messages.append(.user(message))

            let tools = mcp.tools(for: currentMode)
            let agent = Agent<Void, String>(
                provider: Anthropic(apiKey: "..."),
                tools: tools,
                systemPrompt: "You are helpful."
            )

            do {
                let response = try await agent.run(message, deps: ())
                messages.append(.assistant(response))
            } catch is CancellationError {
                messages.append(.system("Cancelled"))
            } catch {
                messages.append(.error(error.localizedDescription))
            }
        }
    }

    func stop() {
        currentRun?.cancel()
    }
}
```

---

## Event Flow Summary

| Event | Flow |
|-------|------|
| **App launch** | `startAll()` → parallel `ServerConnection.connect()` → events flow to MCPManager |
| **Server connects** | `transition(.connected)` → event → MCPManager updates `servers`, `availableTools` |
| **Server fails** | `transition(.failed)` → event → MCPManager updates status, adds alert |
| **User clicks Retry** | `MCPManager.reconnect()` → `MCPCoordinator.reconnect()` → `ServerConnection.connect()` |
| **User clicks Cancel** | `MCPManager.cancelConnection()` → task cancelled → state returns to idle |
| **Tool call starts** | Agent calls tool → proxy routes to coordinator → event → MCPManager adds to `activeToolCalls` |
| **Tool call timeout** | Coordinator timeout fires → throws `MCPError.toolTimeout` → proxy returns `.retry` |
| **User clicks Stop** | `ChatViewModel.stop()` → task cancelled → cancellation propagates to tool call |
| **Server disconnects** | state transition → tools removed from `availableTools` → UI updates |

---

## Implementation Checklist

### Layer 1: ServerConnection
- [ ] State machine with explicit transitions
- [ ] Event stream via `AsyncStream`
- [ ] `connect()`, `disconnect()` lifecycle
- [ ] `callTool()` with cancellation handler
- [ ] Logging with retention policy

### Layer 2: MCPCoordinator
- [ ] Manages all `ServerConnection` instances
- [ ] `startAll()`, `startAllAndWait()`
- [ ] `reconnect()` with policy (exponential backoff)
- [ ] `callTool()` with timeout
- [ ] `cancelToolCall()`
- [ ] Event forwarding
- [ ] Health checks (optional)

### Layer 3: MCPManager
- [x] `@Published` state properties
- [x] Event subscription
- [x] State update from events
- [x] `allTools()` returns proxies
- [x] `tools(for: ToolMode)` filtering
- [ ] Alert management

### Layer 4: Tool Proxies
- [x] `MCPToolProxy` routes through coordinator
- [x] Handles `CancellationError`
- [x] Returns `.retry` on timeout
- [x] `asAnyAgentTool()` conversion

### Deps Lifting
- [x] `AnyAgentTool<Void>.lifted<D>()`
- [x] Array extension

### Supporting Types
- [x] `ServerSpec` with convenience initializers
- [x] `ToolMode` and `ToolFilter`
- [ ] `MCPAlert`
- [ ] View types (`ServerStateView`, `ToolEntryView`, etc.)

---

## Design Decisions Summary

| Decision | Rationale |
|----------|-----------|
| **Actor per connection** | Isolation prevents race conditions |
| **State machine** | Explicit transitions, no invalid states |
| **Events, not callbacks** | Decoupled, observable, testable |
| **Tool proxies** | Never stale, transparent reconnection |
| **MCPManager does no I/O** | Safe for @MainActor, clean separation |
| **Timeout at coordinator** | Consistent policy, single implementation |
| **Cancellation via Task** | Swift structured concurrency handles propagation |

---

## Testing Strategy

### Principle: Test Harness First

**Build the test infrastructure BEFORE implementing the actual code.**

This ensures:
1. Every component is testable from day one
2. Protocols/interfaces are designed for testability
3. No "we'll add tests later" technical debt
4. Confidence when refactoring

### Implementation Order

```
1. Protocols & Test Doubles     ← START HERE
2. Test Utilities (event collection, assertions)
3. Layer tests (with mocks)
4. Actual implementation
5. E2E tests
```

---

## Test Infrastructure

### Core Protocols (For Dependency Injection)

Every boundary gets a protocol so we can inject test doubles:

```swift
// MARK: - MCP Client Protocol

/// What ServerConnection needs from MCP SDK.
/// Real: wraps MCP SDK Client. Test: MockMCPClient.
public protocol MCPClientProtocol: Sendable {
    func listTools() async throws -> ListToolsResult
    func callTool(name: String, arguments: [String: Value]?) async throws -> CallToolResult
    func disconnect() async
    func sendCancellation(requestId: String) async throws
}

/// Factory for creating MCP clients.
public protocol MCPClientFactory: Sendable {
    func makeClient(spec: ServerSpec) async throws -> MCPClientProtocol
}

// MARK: - Server Connection Protocol

/// What MCPCoordinator needs from connections.
public protocol ServerConnectionProtocol: Sendable {
    var id: String { get }
    var state: ConnectionState { get async }
    var events: AsyncStream<ConnectionEvent> { get }

    func connect() async
    func disconnect() async
    func callTool(name: String, arguments: [String: Value]?) async throws -> String
    func cancelToolCall(requestId: String) async
    func markReconnecting(attempt: Int, maxAttempts: Int, nextRetryAt: Date?)
}

/// Factory for creating server connections.
public protocol ServerConnectionFactory: Sendable {
    func makeConnection(id: String, spec: ServerSpec) -> any ServerConnectionProtocol
}

// MARK: - Coordinator Protocol

/// What MCPManager needs from coordinator.
public protocol MCPCoordinatorProtocol: Sendable {
    var events: AsyncStream<CoordinatorEvent> { get }

    func startAll(specs: [ServerSpec]) async
    func startAllAndWait(specs: [ServerSpec]) async -> StartResult
    func reconnect(serverID: String) async
    func disconnect(serverID: String) async
    func cancelConnection(serverID: String) async
    func stopAll() async
    func callTool(serverID: String, name: String, arguments: [String: Value]?, timeout: Duration?) async throws -> String
    func cancelToolCall(requestId: String) async
    var snapshot: CoordinatorSnapshot { get async }
}

// MARK: - Clock Protocol (Time Control)

/// Protocol for time operations. Allows tests to control time.
public protocol ClockProtocol: Sendable {
    func sleep(for duration: Duration) async throws
    func now() -> Date
}

/// Real clock using Task.sleep
public struct RealClock: ClockProtocol {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    public func now() -> Date { Date() }
}
```

### Test Clock (Time Control)

```swift
/// Test clock that can be manually advanced.
/// Essential for testing timeouts without waiting real time.
public actor TestClock: ClockProtocol {
    private var currentTime: Date
    private var waiters: [(deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []

    public init(start: Date = Date()) {
        self.currentTime = start
    }

    public nonisolated func now() -> Date {
        // Note: This is a simplification. In real impl, need synchronization.
        Date()
    }

    public func sleep(for duration: Duration) async throws {
        let deadline = currentTime.addingTimeInterval(duration.timeInterval)

        return try await withCheckedThrowingContinuation { continuation in
            waiters.append((deadline, continuation))
            waiters.sort { $0.deadline < $1.deadline }
        }
    }

    /// Advance time and wake any sleepers whose deadline has passed.
    public func advance(by duration: Duration) {
        currentTime = currentTime.addingTimeInterval(duration.timeInterval)
        wakeEligibleWaiters()
    }

    /// Advance to a specific time.
    public func advance(to time: Date) {
        guard time > currentTime else { return }
        currentTime = time
        wakeEligibleWaiters()
    }

    private func wakeEligibleWaiters() {
        while let first = waiters.first, first.deadline <= currentTime {
            waiters.removeFirst()
            first.continuation.resume()
        }
    }

    /// Cancel all pending sleeps (for test cleanup).
    public func cancelAll() {
        for waiter in waiters {
            waiter.continuation.resume(throwing: CancellationError())
        }
        waiters.removeAll()
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = self.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
```

---

## Test Doubles

### MockMCPClient

```swift
/// Mock MCP client for testing ServerConnection.
public actor MockMCPClient: MCPClientProtocol {

    // MARK: - Configuration (set before test)

    public var toolsToReturn: [MCP.Tool] = []
    public var toolResults: [String: CallToolResult] = [:]  // tool name → result
    public var defaultToolResult: CallToolResult = CallToolResult(content: [.text("mock")])
    public var errorToThrow: Error?
    public var toolCallDelay: Duration?
    public var shouldHang: Bool = false

    // MARK: - Recording (check after test)

    public private(set) var listToolsCalled = false
    public private(set) var toolCallHistory: [(name: String, arguments: [String: Value]?)] = []
    public private(set) var disconnectCalled = false
    public private(set) var cancellationsSent: [String] = []

    public init() {}

    // MARK: - MCPClientProtocol

    public func listTools() async throws -> ListToolsResult {
        listToolsCalled = true
        if let error = errorToThrow { throw error }
        return ListToolsResult(tools: toolsToReturn)
    }

    public func callTool(name: String, arguments: [String: Value]?) async throws -> CallToolResult {
        toolCallHistory.append((name, arguments))

        if shouldHang {
            try await Task.sleep(for: .seconds(3600))
        }

        if let delay = toolCallDelay {
            try await Task.sleep(for: delay)
        }

        try Task.checkCancellation()

        if let error = errorToThrow { throw error }
        return toolResults[name] ?? defaultToolResult
    }

    public func disconnect() async {
        disconnectCalled = true
    }

    public func sendCancellation(requestId: String) async throws {
        cancellationsSent.append(requestId)
    }

    // MARK: - Test Helpers

    public func reset() {
        listToolsCalled = false
        toolCallHistory = []
        disconnectCalled = false
        cancellationsSent = []
        errorToThrow = nil
    }
}

/// Factory that returns pre-configured mock clients.
public final class MockMCPClientFactory: MCPClientFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var _clients: [String: MockMCPClient] = [:]
    private var _defaultClient: MockMCPClient?
    private var _errorToThrow: Error?

    public var clients: [String: MockMCPClient] {
        get { lock.withLock { _clients } }
        set { lock.withLock { _clients = newValue } }
    }

    public var defaultClient: MockMCPClient? {
        get { lock.withLock { _defaultClient } }
        set { lock.withLock { _defaultClient = newValue } }
    }

    public var errorToThrow: Error? {
        get { lock.withLock { _errorToThrow } }
        set { lock.withLock { _errorToThrow = newValue } }
    }

    public init() {}

    public func makeClient(spec: ServerSpec) async throws -> MCPClientProtocol {
        if let error = errorToThrow { throw error }
        if let client = clients[spec.id] { return client }
        if let client = defaultClient { return client }
        return MockMCPClient()
    }
}
```

### MockServerConnection

```swift
/// Mock server connection for testing MCPCoordinator.
public actor MockServerConnection: ServerConnectionProtocol {
    public let id: String

    // MARK: - State

    private var _state: ConnectionState = .idle
    public var state: ConnectionState { _state }

    // MARK: - Events

    public let events: AsyncStream<ConnectionEvent>
    private let eventContinuation: AsyncStream<ConnectionEvent>.Continuation

    // MARK: - Behavior Configuration

    public var connectBehavior: ConnectBehavior = .succeed(tools: [])
    public var toolCallBehavior: [String: ToolCallBehavior] = [:]
    public var defaultToolCallBehavior: ToolCallBehavior = .succeed(result: "mock")

    public enum ConnectBehavior: Sendable {
        case succeed(tools: [ToolInfo])
        case fail(message: String)
        case hang
        case delay(Duration, then: ConnectBehavior)
    }

    public enum ToolCallBehavior: Sendable {
        case succeed(result: String)
        case fail(error: Error)
        case hang
        case delay(Duration, then: ToolCallBehavior)
    }

    // MARK: - Recording

    public private(set) var connectCallCount = 0
    public private(set) var disconnectCallCount = 0
    public private(set) var toolCallHistory: [(name: String, arguments: [String: Value]?)] = []

    // MARK: - Init

    public init(id: String) {
        self.id = id
        var continuation: AsyncStream<ConnectionEvent>.Continuation!
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
        case .succeed(let tools):
            transition(to: .connecting)
            transition(to: .connected(tools: tools))

        case .fail(let message):
            transition(to: .connecting)
            transition(to: .failed(message: message, retryCount: connectCallCount - 1))

        case .hang:
            transition(to: .connecting)
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
    public func emit(_ event: ConnectionEvent) {
        eventContinuation.yield(event)
    }

    private func transition(to newState: ConnectionState) {
        let oldState = _state
        _state = newState
        eventContinuation.yield(.stateChanged(serverID: id, from: oldState, to: newState))
    }

    public func reset() {
        connectCallCount = 0
        disconnectCallCount = 0
        toolCallHistory = []
        _state = .idle
    }
}

/// Factory for mock connections.
public final class MockServerConnectionFactory: ServerConnectionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var _connections: [String: MockServerConnection] = [:]

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
    public func setConnection(_ conn: MockServerConnection, for id: String) {
        lock.withLock { _connections[id] = conn }
    }
}
```

### MockCoordinator

```swift
/// Mock coordinator for testing MCPManager.
public actor MockCoordinator: MCPCoordinatorProtocol {

    // MARK: - Events

    public let events: AsyncStream<CoordinatorEvent>
    private let eventContinuation: AsyncStream<CoordinatorEvent>.Continuation

    // MARK: - Configuration

    public var snapshotToReturn: CoordinatorSnapshot = CoordinatorSnapshot(servers: [:])
    public var toolCallResult: String = "mock result"
    public var toolCallError: Error?

    // MARK: - Recording

    public private(set) var startAllCalled = false
    public private(set) var startAllSpecs: [ServerSpec] = []
    public private(set) var reconnectCalls: [String] = []
    public private(set) var disconnectCalls: [String] = []
    public private(set) var cancelConnectionCalls: [String] = []
    public private(set) var stopAllCalled = false
    public private(set) var toolCalls: [(serverID: String, name: String, arguments: [String: Value]?)] = []
    public private(set) var cancelToolCallCalls: [String] = []

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
        return StartResult(connectedServers: specs.map(\.id), failedServers: [])
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

    public func callTool(serverID: String, name: String, arguments: [String: Value]?, timeout: Duration?) async throws -> String {
        toolCalls.append((serverID, name, arguments))
        if let error = toolCallError { throw error }
        return toolCallResult
    }

    public func cancelToolCall(requestId: String) async {
        cancelToolCallCalls.append(requestId)
    }

    public var snapshot: CoordinatorSnapshot {
        get async { snapshotToReturn }
    }

    // MARK: - Test Helpers

    /// Emit an event (simulate coordinator activity).
    public func emit(_ event: CoordinatorEvent) {
        eventContinuation.yield(event)
    }

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
}
```

---

## Test Utilities

### Event Collection

```swift
/// Collect events from an async stream with timeout.
public func collectEvents<E: Sendable>(
    from stream: AsyncStream<E>,
    count: Int,
    timeout: Duration,
    during action: () async throws -> Void
) async throws -> [E] {
    var collected: [E] = []
    let collectionTask = Task {
        for await event in stream {
            collected.append(event)
            if collected.count >= count { break }
        }
    }

    // Run action
    try await action()

    // Wait with timeout
    let timeoutTask = Task {
        try await Task.sleep(for: timeout)
    }

    // Wait for either collection complete or timeout
    _ = await Task {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await collectionTask.value }
            group.addTask { try? await timeoutTask.value }
            await group.next()
            group.cancelAll()
        }
    }.value

    collectionTask.cancel()
    timeoutTask.cancel()

    return collected
}

/// Wait for a condition with timeout.
public func waitFor(
    timeout: Duration,
    condition: @escaping () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout.timeInterval)

    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }

    return false
}

/// Assert eventually - retry until condition passes or timeout.
public func assertEventually(
    timeout: Duration = .seconds(1),
    message: String = "Condition not met",
    file: StaticString = #file,
    line: UInt = #line,
    condition: @escaping () async -> Bool
) async {
    let passed = await waitFor(timeout: timeout, condition: condition)
    XCTAssertTrue(passed, message, file: file, line: line)
}
```

### Test Fixtures

```swift
/// Common test fixtures.
enum TestFixtures {

    static func makeToolInfo(name: String, description: String = "Test tool") -> ToolInfo {
        ToolInfo(
            id: name,
            name: name,
            description: description,
            inputSchema: ["type": "object", "properties": [:]]
        )
    }

    static func makeMCPTool(name: String, description: String = "Test tool") -> MCP.Tool {
        MCP.Tool(
            name: name,
            description: description,
            inputSchema: .object([:])
        )
    }

    static func makeServerSpec(id: String) -> ServerSpec {
        .stdio("echo", arguments: ["test"], id: id, displayName: id)
    }

    static func makeConnectedSnapshot(serverID: String, tools: [String]) -> CoordinatorSnapshot {
        CoordinatorSnapshot(servers: [
            serverID: ServerSnapshot(
                id: serverID,
                state: .connected(tools: tools.map { makeToolInfo(name: $0) }),
                tools: tools.map { makeToolInfo(name: $0) }
            )
        ])
    }

    @MainActor
    static func makeVoidContext() -> AgentContext<Void> {
        AgentContext(deps: (), toolCallCount: 0, retryCount: 0, usageState: UsageState())
    }
}

/// Common test errors.
enum TestError: Error, Equatable {
    case connectionRefused
    case timeout
    case authFailed
    case toolFailed(String)
}
```

---

## Layer Tests

### ServerConnection Tests

```swift
final class ServerConnectionTests: XCTestCase {

    var clientFactory: MockMCPClientFactory!
    var mockClient: MockMCPClient!

    override func setUp() async throws {
        clientFactory = MockMCPClientFactory()
        mockClient = MockMCPClient()
        clientFactory.defaultClient = mockClient
    }

    // MARK: - State Machine Tests

    func testInitialStateIsIdle() async {
        let conn = ServerConnection(
            id: "test",
            spec: TestFixtures.makeServerSpec(id: "test"),
            clientFactory: clientFactory
        )

        let state = await conn.state
        XCTAssertEqual(state, .idle)
    }

    func testConnectTransitionsConnectingThenConnected() async throws {
        await mockClient.toolsToReturn = [TestFixtures.makeMCPTool(name: "tool1")]

        let conn = ServerConnection(
            id: "test",
            spec: TestFixtures.makeServerSpec(id: "test"),
            clientFactory: clientFactory
        )

        let events = try await collectEvents(from: conn.events, count: 2, timeout: .seconds(1)) {
            await conn.connect()
        }

        // Verify transitions
        XCTAssertEqual(events.count, 2)

        if case .stateChanged(_, let from1, let to1) = events[0] {
            XCTAssertEqual(from1, .idle)
            XCTAssertEqual(to1, .connecting)
        } else {
            XCTFail("Expected stateChanged event")
        }

        if case .stateChanged(_, let from2, let to2) = events[1] {
            XCTAssertEqual(from2, .connecting)
            XCTAssertTrue(to2.isConnected)
        } else {
            XCTFail("Expected stateChanged event")
        }
    }

    func testConnectFromConnectedIsIgnored() async throws {
        await mockClient.toolsToReturn = []

        let conn = ServerConnection(
            id: "test",
            spec: TestFixtures.makeServerSpec(id: "test"),
            clientFactory: clientFactory
        )

        // First connect
        await conn.connect()
        let state1 = await conn.state
        XCTAssertTrue(state1.isConnected)

        // Try to connect again - should be ignored
        let events = try await collectEvents(from: conn.events, count: 0, timeout: .milliseconds(100)) {
            await conn.connect()
        }

        XCTAssertTrue(events.isEmpty, "Should not emit events when already connected")
    }

    func testConnectionFailureTransitionsToFailed() async throws {
        clientFactory.errorToThrow = TestError.connectionRefused

        let conn = ServerConnection(
            id: "test",
            spec: TestFixtures.makeServerSpec(id: "test"),
            clientFactory: clientFactory
        )

        let events = try await collectEvents(from: conn.events, count: 2, timeout: .seconds(1)) {
            await conn.connect()
        }

        if case .stateChanged(_, _, let finalState) = events.last {
            XCTAssertTrue(finalState.isFailed)
        } else {
            XCTFail("Expected failed state")
        }
    }

    // MARK: - Tool Call Tests

    func testToolCallWhenNotConnectedThrows() async {
        let conn = ServerConnection(
            id: "test",
            spec: TestFixtures.makeServerSpec(id: "test"),
            clientFactory: clientFactory
        )

        do {
            _ = try await conn.callTool(name: "test", arguments: nil)
            XCTFail("Expected error")
        } catch let error as MCPError {
            if case .notConnected(let id) = error {
                XCTAssertEqual(id, "test")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testToolCallEmitsStartAndCompleteEvents() async throws {
        await mockClient.toolsToReturn = [TestFixtures.makeMCPTool(name: "test_tool")]

        let conn = ServerConnection(
            id: "test",
            spec: TestFixtures.makeServerSpec(id: "test"),
            clientFactory: clientFactory
        )

        await conn.connect()

        // Drain connect events
        try await Task.sleep(for: .milliseconds(50))

        // Now collect tool call events
        var toolEvents: [ConnectionEvent] = []
        let task = Task {
            for await event in conn.events {
                if case .toolCallStarted = event { toolEvents.append(event) }
                if case .toolCallCompleted = event { toolEvents.append(event); break }
            }
        }

        _ = try await conn.callTool(name: "test_tool", arguments: nil)

        await waitFor(timeout: .seconds(1)) { toolEvents.count >= 2 }
        task.cancel()

        XCTAssertEqual(toolEvents.count, 2)
        if case .toolCallStarted(_, let tool, _) = toolEvents[0] {
            XCTAssertEqual(tool, "test_tool")
        }
        if case .toolCallCompleted(_, _, let success) = toolEvents[1] {
            XCTAssertTrue(success)
        }
    }

    // MARK: - Cancellation Tests

    func testCancellationDuringConnectReturnsToIdle() async throws {
        // Client that hangs
        await mockClient.shouldHang = true

        let conn = ServerConnection(
            id: "test",
            spec: TestFixtures.makeServerSpec(id: "test"),
            clientFactory: clientFactory
        )

        let task = Task {
            await conn.connect()
        }

        // Wait for connecting state
        await assertEventually {
            let state = await conn.state
            return state == .connecting
        }

        // Cancel
        task.cancel()
        await task.value

        // Should be back to idle
        let finalState = await conn.state
        XCTAssertEqual(finalState, .idle)
    }
}
```

### MCPCoordinator Tests

```swift
final class MCPCoordinatorTests: XCTestCase {

    var connectionFactory: MockServerConnectionFactory!
    var clock: TestClock!

    override func setUp() async throws {
        connectionFactory = MockServerConnectionFactory()
        clock = TestClock()
    }

    // MARK: - Startup Tests

    func testStartAllCreatesConnectionsForAllSpecs() async {
        let coordinator = MCPCoordinator(
            configuration: .init(),
            connectionFactory: connectionFactory,
            clock: clock
        )

        let specs = [
            TestFixtures.makeServerSpec(id: "server1"),
            TestFixtures.makeServerSpec(id: "server2"),
        ]

        await coordinator.startAll(specs: specs)

        // Wait for connections to be created
        await assertEventually {
            self.connectionFactory.createdConnections.count == 2
        }

        XCTAssertNotNil(connectionFactory.createdConnections["server1"])
        XCTAssertNotNil(connectionFactory.createdConnections["server2"])
    }

    func testStartAllAndWaitBlocksUntilAllComplete() async {
        let conn1 = MockServerConnection(id: "server1")
        conn1.connectBehavior = .succeed(tools: [])

        let conn2 = MockServerConnection(id: "server2")
        conn2.connectBehavior = .delay(.milliseconds(100), then: .succeed(tools: []))

        connectionFactory.setConnection(conn1, for: "server1")
        connectionFactory.setConnection(conn2, for: "server2")

        let coordinator = MCPCoordinator(
            configuration: .init(),
            connectionFactory: connectionFactory,
            clock: RealClock()  // Use real clock for this test
        )

        let start = Date()
        let result = await coordinator.startAllAndWait(specs: [
            TestFixtures.makeServerSpec(id: "server1"),
            TestFixtures.makeServerSpec(id: "server2"),
        ])
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThan(elapsed, 0.08)  // Should have waited
        XCTAssertEqual(result.connectedServers.sorted(), ["server1", "server2"])
        XCTAssertTrue(result.failedServers.isEmpty)
    }

    // MARK: - Timeout Tests

    func testToolCallTimeoutReturnsError() async throws {
        let conn = MockServerConnection(id: "server1")
        conn.connectBehavior = .succeed(tools: [TestFixtures.makeToolInfo(name: "slow")])
        conn.defaultToolCallBehavior = .hang

        connectionFactory.setConnection(conn, for: "server1")

        var config = MCPCoordinator.Configuration()
        config.toolTimeout = .milliseconds(100)

        let coordinator = MCPCoordinator(
            configuration: config,
            connectionFactory: connectionFactory,
            clock: RealClock()
        )

        await coordinator.startAll(specs: [TestFixtures.makeServerSpec(id: "server1")])
        await assertEventually { await conn.state.isConnected }

        do {
            _ = try await coordinator.callTool(serverID: "server1", name: "slow", arguments: nil)
            XCTFail("Expected timeout")
        } catch let error as MCPError {
            if case .toolTimeout(let id, let tool, _) = error {
                XCTAssertEqual(id, "server1")
                XCTAssertEqual(tool, "slow")
            } else {
                XCTFail("Wrong error: \(error)")
            }
        }
    }

    // MARK: - Reconnection Tests

    func testReconnectionPolicyExponentialBackoff() async {
        var connectAttempts = 0
        let conn = MockServerConnection(id: "server1")
        conn.connectBehavior = .custom {
            connectAttempts += 1
            if connectAttempts < 3 {
                await conn.forceState(.failed(message: "retry", retryCount: connectAttempts - 1))
            } else {
                await conn.forceState(.connected(tools: []))
            }
        }

        connectionFactory.setConnection(conn, for: "server1")

        var config = MCPCoordinator.Configuration()
        config.reconnectPolicy = .exponentialBackoff(maxAttempts: 5, baseDelay: 0.01)

        let coordinator = MCPCoordinator(
            configuration: config,
            connectionFactory: connectionFactory,
            clock: RealClock()
        )

        await coordinator.startAll(specs: [TestFixtures.makeServerSpec(id: "server1")])

        // Wait for eventual success
        await assertEventually(timeout: .seconds(2)) {
            await conn.state.isConnected
        }

        XCTAssertEqual(connectAttempts, 3)
    }

    // MARK: - Race Condition Tests

    func testConcurrentReconnectOnlyConnectsOnce() async {
        let conn = MockServerConnection(id: "server1")
        conn.connectBehavior = .delay(.milliseconds(50), then: .succeed(tools: []))

        connectionFactory.setConnection(conn, for: "server1")

        let coordinator = MCPCoordinator(
            configuration: .init(),
            connectionFactory: connectionFactory,
            clock: RealClock()
        )

        await coordinator.startAll(specs: [TestFixtures.makeServerSpec(id: "server1")])

        // Force failed state
        await conn.forceState(.failed(message: "test", retryCount: 0))

        // Fire many concurrent reconnects
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await coordinator.reconnect(serverID: "server1")
                }
            }
        }

        // Wait for settle
        try? await Task.sleep(for: .milliseconds(200))

        // Should not have connected many times
        let attempts = await conn.connectCallCount
        XCTAssertLessThanOrEqual(attempts, 3, "Too many connect attempts: \(attempts)")
    }
}
```

### MCPManager Tests

```swift
@MainActor
final class MCPManagerTests: XCTestCase {

    var mockCoordinator: MockCoordinator!
    var manager: MCPManager!

    override func setUp() async throws {
        mockCoordinator = MockCoordinator()
        manager = MCPManager(coordinator: mockCoordinator)
    }

    // MARK: - State Update Tests

    func testServerConnectedEventUpdatesState() async {
        manager.serverSpecs = [TestFixtures.makeServerSpec(id: "server1")]
        await manager.startAll()

        // Emit connected event
        await mockCoordinator.emit(.serverStateChanged(
            serverID: "server1",
            from: .connecting,
            to: .connected(tools: [TestFixtures.makeToolInfo(name: "tool1")])
        ))

        // Wait for event processing
        await assertEventually {
            self.manager.servers["server1"]?.status.isConnected == true
        }

        XCTAssertEqual(manager.servers["server1"]?.toolCount, 1)
        XCTAssertEqual(manager.availableTools.count, 1)
    }

    func testServerFailedEventCreatesAlert() async {
        manager.serverSpecs = [TestFixtures.makeServerSpec(id: "server1")]
        await manager.startAll()

        await mockCoordinator.emit(.serverStateChanged(
            serverID: "server1",
            from: .connecting,
            to: .failed(message: "Connection refused", retryCount: 0)
        ))

        await assertEventually {
            self.manager.pendingAlerts.count == 1
        }

        XCTAssertEqual(manager.pendingAlerts[0].serverID, "server1")
        XCTAssertEqual(manager.pendingAlerts[0].kind, .connectionFailed)
    }

    // MARK: - Tool Proxy Tests

    func testAllToolsReturnsProxiesThatRouteToCoordinator() async throws {
        manager.serverSpecs = [TestFixtures.makeServerSpec(id: "server1")]
        await manager.startAll()

        // Simulate connected with tools
        await mockCoordinator.emit(.serverStateChanged(
            serverID: "server1",
            from: .connecting,
            to: .connected(tools: [TestFixtures.makeToolInfo(name: "test_tool")])
        ))

        await assertEventually { self.manager.availableTools.count == 1 }

        let tools = manager.allTools()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].name, "test_tool")

        // Call tool - should route to coordinator
        await mockCoordinator.toolCallResult = "proxied!"

        let result = try await tools[0].call(
            context: TestFixtures.makeVoidContext(),
            argumentsJSON: "{}"
        )

        if case .success(let output) = result {
            XCTAssertEqual(output, "proxied!")
        } else {
            XCTFail("Expected success")
        }

        // Verify coordinator received the call
        let calls = await mockCoordinator.toolCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "test_tool")
    }

    // MARK: - Alert Management Tests

    func testDismissAlertRemovesFromPending() async {
        manager.serverSpecs = [TestFixtures.makeServerSpec(id: "server1")]
        await manager.startAll()

        await mockCoordinator.emit(.serverStateChanged(
            serverID: "server1",
            from: .connecting,
            to: .failed(message: "error", retryCount: 0)
        ))

        await assertEventually { self.manager.pendingAlerts.count == 1 }

        let alert = manager.pendingAlerts[0]
        manager.dismissAlert(alert)

        XCTAssertTrue(manager.pendingAlerts.isEmpty)
    }
}
```

---

## E2E Tests

### With Real MCP Server

```swift
final class E2ETests: XCTestCase {

    /// Integration test with real filesystem MCP server.
    func testRealFilesystemServer() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_E2E_TESTS"] == "1",
            "Set RUN_E2E_TESTS=1 to run"
        )

        let manager = MCPManager()
        manager.serverSpecs = [
            .stdio("uvx", arguments: ["mcp-server-filesystem", "/tmp"], id: "fs")
        ]

        let result = await manager.startAllAndWait()
        XCTAssertTrue(result.allSucceeded, "Failures: \(result.failedServers)")

        let tools = manager.allTools()
        XCTAssertGreaterThan(tools.count, 0)

        // Find and call list_directory
        guard let listDir = tools.first(where: { $0.name == "list_directory" }) else {
            XCTFail("list_directory tool not found")
            return
        }

        let callResult = try await listDir.call(
            context: TestFixtures.makeVoidContext(),
            argumentsJSON: #"{"path":"/tmp"}"#
        )

        if case .success(let output) = callResult {
            XCTAssertFalse(output.isEmpty)
        } else {
            XCTFail("Tool call failed: \(callResult)")
        }

        await manager.stopAll()
    }
}
```

---

## Race Condition Tests

```swift
final class RaceConditionTests: XCTestCase {

    func testConcurrentToolCallsDoNotCorruptState() async throws {
        let conn = MockServerConnection(id: "server1")
        conn.connectBehavior = .succeed(tools: [
            TestFixtures.makeToolInfo(name: "tool1"),
            TestFixtures.makeToolInfo(name: "tool2"),
        ])
        conn.defaultToolCallBehavior = .delay(.milliseconds(5), then: .succeed(result: "ok"))

        let factory = MockServerConnectionFactory()
        factory.setConnection(conn, for: "server1")

        let coordinator = MCPCoordinator(
            configuration: .init(),
            connectionFactory: factory,
            clock: RealClock()
        )

        await coordinator.startAll(specs: [TestFixtures.makeServerSpec(id: "server1")])
        await assertEventually { await conn.state.isConnected }

        // Fire 100 concurrent tool calls
        let results = await withTaskGroup(of: Result<String, Error>.self) { group in
            for i in 0..<100 {
                group.addTask {
                    do {
                        let r = try await coordinator.callTool(
                            serverID: "server1",
                            name: "tool\((i % 2) + 1)",
                            arguments: nil
                        )
                        return .success(r)
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var results: [Result<String, Error>] = []
            for await r in group { results.append(r) }
            return results
        }

        let successes = results.filter { if case .success = $0 { return true }; return false }
        XCTAssertEqual(successes.count, 100, "All calls should succeed")
    }

    func testRapidConnectDisconnectCycles() async {
        let factory = MockServerConnectionFactory()
        let coordinator = MCPCoordinator(
            configuration: .init(),
            connectionFactory: factory,
            clock: RealClock()
        )

        for _ in 0..<50 {
            await coordinator.startAll(specs: [TestFixtures.makeServerSpec(id: "server1")])
            try? await Task.sleep(for: .milliseconds(2))
            await coordinator.stopAll()
        }

        // Should complete without crash or deadlock
    }
}
```

---

## Implementation Checklist - Test Harness First

### Phase 1: Protocols & Factories
- [x] `MCPClientProtocol`
- [x] `MCPClientFactory`
- [x] `ServerConnectionProtocol` (with `: Actor` requirement)
- [x] `ServerConnectionFactory`
- [x] `MCPCoordinatorProtocol` (with `: Actor` requirement)
- [ ] `ClockProtocol`
- [ ] `RealClock`

### Phase 2: Test Doubles
- [x] `MockMCPClient`
- [x] `MockMCPClientFactory`
- [x] `MockServerConnection`
- [x] `MockServerConnectionFactory`
- [x] `MockCoordinator`
- [ ] `TestClock`

### Phase 3: Test Utilities
- [x] `collectEvents()` helper
- [x] `waitFor()` helper
- [x] `assertEventually()` helper
- [x] `MCPTestFixtures` enum
- [x] `MCPTestError` enum

### Phase 4: Layer Test Skeletons
- [x] `ServerConnectionTests` (14 tests)
- [x] `MCPCoordinatorTests` (13 tests)
- [x] `MCPManagerTests` (14 tests)
- [x] `MCPToolProxyTests` (proxy, filter, mode, array extensions)
- [ ] `RaceConditionTests`

### Phase 5: Actual Implementation
- [x] `ProtocolServerConnection` (real impl with MCPClientFactory injection)
- [x] `ProtocolMCPCoordinator` (real impl with ServerConnectionFactory injection)
- [x] `ProtocolMCPManager` (@MainActor ObservableObject)
- [x] `MCPToolProxy` (routes calls, error mapping, AnyAgentTool conversion)
- [x] `MCPToolMode` (ToolMode, ToolFilter, ToolEntry)

### Phase 6: E2E Tests
- [ ] Mock MCP server process
- [x] Real MCP server tests (MCPIntegrationTests with uvx mcp-server-git)

---

## Critical Lessons Learned

### Protocols Abstracting Actors MUST Inherit from `: Actor`

**Problem:** When you define a protocol to abstract an actor, the protocol alone does NOT provide actor isolation guarantees. The protocol only defines the shape/API.

**Wrong:**
```swift
// ❌ WRONG - loses actor isolation when used via protocol
public protocol MCPCoordinatorProtocol: Sendable {
    func callTool(...) async throws -> String
}

// Anyone can conform without actor isolation:
class BadCoordinator: MCPCoordinatorProtocol {
    func callTool(...) async throws -> String {
        // No isolation! Race conditions possible!
    }
}
```

**Correct:**
```swift
// ✅ CORRECT - enforces actor at compile time
public protocol MCPCoordinatorProtocol: Sendable, Actor {
    func callTool(...) async throws -> String
}

// Only actors can conform:
actor GoodCoordinator: MCPCoordinatorProtocol {
    func callTool(...) async throws -> String {
        // Actor isolation guaranteed!
    }
}
```

**Why This Matters:**
- Actor provides race condition protection through isolation
- Protocol only defines method signatures
- If you use `any MCPCoordinatorProtocol`, Swift doesn't know it's an actor
- Without `: Actor`, callers can't rely on isolation guarantees
- This is a subtle but critical design flaw that can introduce race conditions

**Applied in Yrden:**
- `ServerConnectionProtocol: Sendable, Actor` ✅
- `MCPCoordinatorProtocol: Sendable, Actor` ✅

---

## Implementation Files

### Real Implementations (with Dependency Injection)

| File | Description |
|------|-------------|
| `Sources/Yrden/MCP/ProtocolServerConnection.swift` | Real ServerConnection actor with MCPClientFactory injection |
| `Sources/Yrden/MCP/ProtocolMCPCoordinator.swift` | Real Coordinator actor with ServerConnectionFactory injection |

### Protocols

| File | Description |
|------|-------------|
| `Sources/Yrden/MCP/MCPProtocols.swift` | All protocols (MCPClientProtocol, ServerConnectionProtocol, MCPCoordinatorProtocol) |
| `Sources/Yrden/MCP/MCPTypes.swift` | Shared types (ConnectionState, ConnectionEvent, CoordinatorEvent, etc.) |

### Test Infrastructure

| File | Description |
|------|-------------|
| `Tests/YrdenTests/MCP/TestDoubles/MockMCPClient.swift` | Mock for MCP SDK client |
| `Tests/YrdenTests/MCP/TestDoubles/MockServerConnection.swift` | Mock for ServerConnection |
| `Tests/YrdenTests/MCP/TestDoubles/MockServerConnectionFactory.swift` | Factory that returns mock connections |
| `Tests/YrdenTests/MCP/TestDoubles/MockCoordinator.swift` | Mock for MCPCoordinator |
| `Tests/YrdenTests/MCP/TestDoubles/MCPTestUtilities.swift` | Event collection, assertions |
| `Tests/YrdenTests/MCP/TestDoubles/MCPTestFixtures.swift` | Test data factories |
| `Tests/YrdenTests/MCP/TestDoubles/MCPManagerTestHelpers.swift` | TestMCPManager wrapper |

### Tests

| File | Tests | Description |
|------|-------|-------------|
| `Tests/YrdenTests/MCP/ServerConnectionTests.swift` | 14 | Tests real ProtocolServerConnection with MockMCPClient |
| `Tests/YrdenTests/MCP/MCPCoordinatorTests.swift` | 13 | Tests real ProtocolMCPCoordinator with MockServerConnection |
| `Tests/YrdenTests/MCP/MCPManagerTests.swift` | 14 | Tests MCPManager with MockCoordinator |

### Testing Approach

**Test with real implementations, mocks injected at the seams.**

```
┌─────────────────────────────────────────────────────────────────────┐
│  ServerConnectionTests                                               │
│  Real: ProtocolServerConnection                                      │
│  Mock: MockMCPClient (injected via MockMCPClientFactory)             │
└─────────────────────────────────────────────────────────────────────┘
                                  ↓
┌─────────────────────────────────────────────────────────────────────┐
│  MCPCoordinatorTests                                                 │
│  Real: ProtocolMCPCoordinator                                        │
│  Mock: MockServerConnection (injected via MockServerConnectionFactory│
└─────────────────────────────────────────────────────────────────────┘
                                  ↓
┌─────────────────────────────────────────────────────────────────────┐
│  MCPManagerTests                                                     │
│  Real: MCPManager (TODO)                                             │
│  Mock: MockCoordinator                                               │
└─────────────────────────────────────────────────────────────────────┘
```

This approach:
- Tests actual logic, not mock logic
- Isolates each layer from its dependencies
- Makes tests fast (no real I/O)
- Catches real bugs in real code
