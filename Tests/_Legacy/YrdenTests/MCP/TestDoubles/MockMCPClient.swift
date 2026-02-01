/// Mock MCP client for testing ServerConnection.
///
/// Provides controllable behavior for:
/// - Tool listing (success, failure, hang)
/// - Tool calls (success, failure, delay, hang)
/// - Cancellation handling
///
/// Records all method calls for verification.

import Foundation
import MCP
@testable import Yrden

/// Mock MCP client for testing ServerConnection.
public actor MockMCPClient: MCPClientProtocol {

    // MARK: - Behavior Configuration

    /// Tools to return from listTools().
    public var toolsToReturn: [MCP.Tool] = []

    /// Results for specific tools (tool name → result).
    public var toolResults: [String: MCPCallToolResult] = [:]

    /// Default result for tools not in toolResults.
    public var defaultToolResult: MCPCallToolResult = MCPCallToolResult(content: [.text("mock result")])

    /// Error to throw from all methods.
    public var errorToThrow: Error?

    /// Delay before returning from tool calls.
    public var toolCallDelay: Duration?

    /// Whether to hang indefinitely (for testing cancellation/timeout).
    public var shouldHang: Bool = false

    // MARK: - Recording

    /// Whether listTools() was called.
    public private(set) var listToolsCalled = false

    /// History of tool calls: (name, arguments).
    public private(set) var toolCallHistory: [(name: String, arguments: [String: Value]?)] = []

    /// Whether disconnect() was called.
    public private(set) var disconnectCalled = false

    /// Request IDs for which cancellation was sent.
    public private(set) var cancellationsSent: [String] = []

    // MARK: - Initialization

    public init() {}

    // MARK: - MCPClientProtocol

    public func listTools() async throws -> MCPListToolsResult {
        listToolsCalled = true

        if let error = errorToThrow {
            throw error
        }

        return MCPListToolsResult(tools: toolsToReturn)
    }

    public func callTool(name: String, arguments: [String: Value]?) async throws -> MCPCallToolResult {
        toolCallHistory.append((name, arguments))

        // Hang forever if configured (tests cancellation)
        if shouldHang {
            try await Task.sleep(for: .seconds(3600))
        }

        // Apply delay if configured
        if let delay = toolCallDelay {
            try await Task.sleep(for: delay)
        }

        // Check for cancellation
        try Task.checkCancellation()

        // Throw error if configured
        if let error = errorToThrow {
            throw error
        }

        return toolResults[name] ?? defaultToolResult
    }

    public func disconnect() async {
        disconnectCalled = true
    }

    public func sendCancellation(requestId: String) async throws {
        cancellationsSent.append(requestId)
    }

    // MARK: - Test Helpers

    /// Reset all recorded state.
    public func reset() {
        listToolsCalled = false
        toolCallHistory = []
        disconnectCalled = false
        cancellationsSent = []
        errorToThrow = nil
        shouldHang = false
        toolCallDelay = nil
    }

    /// Get the last tool call arguments for a specific tool.
    public func lastCall(for tool: String) -> [String: Value]? {
        toolCallHistory.last(where: { $0.name == tool })?.arguments
    }

    /// Check if a specific tool was called.
    public func wasCalled(_ tool: String) -> Bool {
        toolCallHistory.contains { $0.name == tool }
    }

    /// Count how many times a tool was called.
    public func callCount(for tool: String) -> Int {
        toolCallHistory.filter { $0.name == tool }.count
    }
}

// MARK: - Mock Client Factory

/// Factory that returns pre-configured mock clients.
public final class MockMCPClientFactory: MCPClientFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var _clients: [String: MockMCPClient] = [:]
    private var _defaultClient: MockMCPClient?
    private var _errorToThrow: Error?

    /// Clients by server ID.
    public var clients: [String: MockMCPClient] {
        get { lock.withLock { _clients } }
        set { lock.withLock { _clients = newValue } }
    }

    /// Default client for servers without specific client.
    public var defaultClient: MockMCPClient? {
        get { lock.withLock { _defaultClient } }
        set { lock.withLock { _defaultClient = newValue } }
    }

    /// Error to throw from makeClient.
    public var errorToThrow: Error? {
        get { lock.withLock { _errorToThrow } }
        set { lock.withLock { _errorToThrow = newValue } }
    }

    public init() {}

    public func makeClient(spec: ServerSpec) async throws -> MCPClientProtocol {
        if let error = errorToThrow {
            throw error
        }

        if let client = clients[spec.id] {
            return client
        }

        if let client = defaultClient {
            return client
        }

        return MockMCPClient()
    }

    /// Pre-register a client for a server ID.
    public func register(_ client: MockMCPClient, for id: String) {
        clients[id] = client
    }
}
