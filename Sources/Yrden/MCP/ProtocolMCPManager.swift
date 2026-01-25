/// Protocol-based MCP Manager for SwiftUI.
///
/// This manager is designed for SwiftUI integration:
/// - `@MainActor` for safe UI updates
/// - `ObservableObject` with `@Published` properties for binding
/// - Delegates all I/O to MCPCoordinatorProtocol
/// - Returns tool proxies that route through coordinator
///
/// ## Usage
/// ```swift
/// @StateObject private var mcp = ProtocolMCPManager(
///     coordinator: ProtocolMCPCoordinator(connectionFactory: factory)
/// )
///
/// var body: some View {
///     List(Array(mcp.servers.values)) { server in
///         ServerRow(server: server)
///     }
///     .task {
///         mcp.serverSpecs = [
///             .stdio("uvx", arguments: ["mcp-server-filesystem"], id: "fs", displayName: "Filesystem"),
///         ]
///         await mcp.startAll()
///     }
/// }
/// ```

import Foundation
import MCP

#if canImport(Combine)
import Combine
#endif

// MARK: - ProtocolMCPManager

/// MCP Manager for SwiftUI with protocol-based coordinator.
///
/// This class:
/// - Holds UI state as `@Published` properties
/// - Forwards actions to coordinator
/// - Subscribes to events and updates state
/// - Does NO I/O directly
///
/// - Note: Internal type for testing infrastructure. Use `mcpConnect()` for public API.
@MainActor
final class ProtocolMCPManager: ObservableObject {

    // MARK: - Published State

    /// All server states for UI binding.
    @Published private(set) var servers: [String: ServerStateView] = [:]

    /// All available tools from connected servers.
    @Published private(set) var availableTools: [String: ToolEntry] = [:]

    /// Active tool calls in progress.
    @Published private(set) var activeToolCalls: [ActiveToolCall] = []

    /// Pending alerts for user attention.
    @Published private(set) var pendingAlerts: [MCPAlert] = []

    // MARK: - Configuration

    /// Server specifications to connect to.
    var serverSpecs: [ServerSpec] = []

    // MARK: - Internal

    private let coordinator: any MCPCoordinatorProtocol
    private var eventSubscription: Task<Void, Never>?

    // MARK: - Initialization

    /// Create a manager with a coordinator.
    ///
    /// - Parameter coordinator: Coordinator to delegate I/O to
    init(coordinator: any MCPCoordinatorProtocol) {
        self.coordinator = coordinator
        subscribeToEvents()
    }

    deinit {
        eventSubscription?.cancel()
    }

    private func subscribeToEvents() {
        eventSubscription = Task { [weak self, coordinator] in
            for await event in coordinator.events {
                await self?.handleEvent(event)
            }
        }
    }

    // MARK: - Lifecycle Actions

    /// Start all configured servers in parallel.
    func startAll() async {
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
    func startAllAndWait() async -> StartResult {
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

        return await coordinator.startAllAndWait(specs: serverSpecs)
    }

    /// Reconnect a server.
    func reconnect(serverID: String) async {
        await coordinator.reconnect(serverID: serverID)
    }

    /// Reconnect all failed servers.
    func reconnectFailed() async {
        let failed = servers.values.filter { $0.status.isFailed }
        for server in failed {
            await coordinator.reconnect(serverID: server.id)
        }
    }

    /// Cancel a connection attempt.
    func cancelConnection(serverID: String) async {
        await coordinator.cancelConnection(serverID: serverID)
    }

    /// Disconnect a server.
    func disconnect(serverID: String) async {
        await coordinator.disconnect(serverID: serverID)
    }

    /// Stop all servers.
    func stopAll() async {
        await coordinator.stopAll()
    }

    // MARK: - Tool Access

    /// Get all tools from connected servers as proxies.
    ///
    /// The returned tools route through the coordinator,
    /// ensuring they never hold stale connection references.
    ///
    /// - Returns: Array of type-erased agent tools
    func allTools() -> [AnyAgentTool<Void>] {
        availableTools.values.map { entry in
            MCPToolProxy(
                serverID: entry.serverID,
                name: entry.name,
                description: entry.description,
                inputSchema: entry.definition.inputSchema,
                coordinator: coordinator
            ).asAnyAgentTool()
        }
    }

    /// Get tools filtered by predicate.
    ///
    /// - Parameter predicate: Filter function
    /// - Returns: Filtered tools as proxies
    func tools(matching predicate: (ToolEntry) -> Bool) -> [AnyAgentTool<Void>] {
        availableTools.values
            .filter(predicate)
            .map { entry in
                MCPToolProxy(
                    serverID: entry.serverID,
                    name: entry.name,
                    description: entry.description,
                    inputSchema: entry.definition.inputSchema,
                    coordinator: coordinator
                ).asAnyAgentTool()
            }
    }

    /// Get tools for a specific mode.
    ///
    /// - Parameter mode: Tool mode defining filter
    /// - Returns: Tools matching the mode's filter
    func tools(for mode: ToolMode) -> [AnyAgentTool<Void>] {
        tools(matching: { mode.filter.matches($0) })
    }

    /// Get all tool entries (for filtering/display without proxies).
    var toolEntries: [ToolEntry] {
        Array(availableTools.values)
    }

    // MARK: - Tool Call Management

    /// Cancel a specific tool call.
    func cancelToolCall(requestId: String) async {
        await coordinator.cancelToolCall(requestId: requestId)
    }

    // MARK: - Alert Management

    /// Dismiss an alert.
    func dismissAlert(_ alert: MCPAlert) {
        pendingAlerts.removeAll { $0.id == alert.id }
    }

    /// Dismiss all alerts.
    func dismissAllAlerts() {
        pendingAlerts.removeAll()
    }

    // MARK: - Computed Properties

    /// Whether any server has failed.
    var hasFailures: Bool {
        servers.values.contains { $0.status.isFailed }
    }

    /// All failed servers.
    var failedServers: [ServerStateView] {
        Array(servers.values.filter { $0.status.isFailed })
    }

    /// Count of connected servers.
    var connectedCount: Int {
        servers.values.filter { $0.status.isConnected }.count
    }

    /// Total server count.
    var totalCount: Int {
        servers.count
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: MCPEvent) {
        switch event {
        case .stateChanged(let id, _, let to):
            updateServerState(id: id, state: to)

        case .log(let id, let entry):
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

        case .reconnecting(let attempt, let max, _):
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

        // Add new tools with full metadata from ToolInfo
        for toolInfo in tools {
            let entry = ToolEntry(
                serverID: serverID,
                name: toolInfo.name,
                description: toolInfo.description ?? "",
                definition: ToolDefinition(
                    name: toolInfo.name,
                    description: toolInfo.description ?? "",
                    inputSchema: JSONValue(mcpValue: toolInfo.inputSchema)
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

/// Server state for UI display.
struct ServerStateView: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public var status: ConnectionStatusView
    public var toolCount: Int
    public var logs: [LogEntry]
    public var lastErrorMessage: String?

    public init(
        id: String,
        displayName: String,
        status: ConnectionStatusView,
        toolCount: Int,
        logs: [LogEntry],
        lastErrorMessage: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.status = status
        self.toolCount = toolCount
        self.logs = logs
        self.lastErrorMessage = lastErrorMessage
    }
}

/// Connection status for UI display.
enum ConnectionStatusView: Equatable, Sendable {
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

/// Active tool call for UI display.
struct ActiveToolCall: Identifiable, Sendable {
    public let id: String
    public let serverID: String
    public let toolName: String
    public let startedAt: Date

    public init(id: String, serverID: String, toolName: String, startedAt: Date) {
        self.id = id
        self.serverID = serverID
        self.toolName = toolName
        self.startedAt = startedAt
    }
}

/// Alert for user attention.
struct MCPAlert: Identifiable, Sendable {
    public let id: UUID
    public let serverID: String
    public let kind: AlertKind
    public let message: String
    public let timestamp: Date

    public init(id: UUID, serverID: String, kind: AlertKind, message: String, timestamp: Date) {
        self.id = id
        self.serverID = serverID
        self.kind = kind
        self.message = message
        self.timestamp = timestamp
    }

    enum AlertKind: Sendable {
        case connectionFailed
        case authExpired
        case disconnected
        case authRequired
    }
}
