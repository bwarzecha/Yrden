/// Tests for ProtocolServerConnection behavior.
///
/// Tests the real ServerConnection implementation using MockMCPClient.
/// Verifies connection lifecycle, state transitions, tool calling, and events.

import XCTest
import MCP
@testable import Yrden

final class ServerConnectionTests: XCTestCase {

    // MARK: - Test Infrastructure

    private var mockClient: MockMCPClient!
    private var mockClientFactory: MockMCPClientFactory!

    override func setUp() async throws {
        mockClient = MockMCPClient()
        mockClientFactory = MockMCPClientFactory()
        mockClientFactory.defaultClient = mockClient
    }

    override func tearDown() async throws {
        mockClient = nil
        mockClientFactory = nil
    }

    // MARK: - Connection Lifecycle Tests

    func testInitialStateIsIdle() async throws {
        let connection = makeConnection(id: "test-server")
        let state = await connection.state
        XCTAssertEqual(state, .idle)
    }

    func testSuccessfulConnectTransitionsToConnected() async throws {
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("tool1", "tool2"))
        let connection = makeConnection(id: "test-server")

        await connection.connect()

        let state = await connection.state
        state.assertConnected(withToolCount: 2)
    }

    func testConnectEmitsStateChangeEvents() async throws {
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("tool1"))
        let connection = makeConnection(id: "test-server")

        let events = try await collectEvents(
            from: connection.events,
            count: 2,
            timeout: .seconds(2)
        ) {
            await connection.connect()
        }

        // Should have: idle → connecting, connecting → connected
        XCTAssertEqual(events.count, 2)

        if case .stateChanged(_, let from1, let to1) = events[0] {
            XCTAssertEqual(from1, .idle)
            if case .connecting = to1 { /* ok */ }
            else { XCTFail("Expected connecting state") }
        } else {
            XCTFail("Expected stateChanged event")
        }

        if case .stateChanged(_, let from2, let to2) = events[1] {
            if case .connecting = from2 { /* ok */ }
            else { XCTFail("Expected from connecting") }
            if case .connected = to2 { /* ok */ }
            else { XCTFail("Expected to connected") }
        }
    }

    func testFailedConnectTransitionsToFailed() async throws {
        await mockClient.setError(MCPTestError.connectionRefused)
        let connection = makeConnection(id: "test-server")

        await connection.connect()

        let state = await connection.state
        state.assertFailed(withMessage: "Connection refused")
    }

    func testDisconnectTransitionsToDisconnected() async throws {
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("tool1"))
        let connection = makeConnection(id: "test-server")

        await connection.connect()
        await connection.disconnect()

        let state = await connection.state
        XCTAssertEqual(state, .disconnected)
    }

    func testDisconnectCallsClientDisconnect() async throws {
        await mockClient.setToolsToReturn([])
        let connection = makeConnection(id: "test-server")

        await connection.connect()
        await connection.disconnect()

        let disconnected = await mockClient.disconnectCalled
        XCTAssertTrue(disconnected)
    }

    // MARK: - Tool Calling Tests

    func testCallToolReturnsResult() async throws {
        let expectedResult = MCPCallToolResult(content: [.text("result text")])
        await mockClient.setToolResult("search", result: expectedResult)
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("search"))
        let connection = makeConnection(id: "test-server")

        await connection.connect()
        let result = try await connection.callTool(name: "search", arguments: ["query": .string("test")])

        XCTAssertEqual(result, "result text")
    }

    func testCallToolRecordsCall() async throws {
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("search"))
        let connection = makeConnection(id: "test-server")

        await connection.connect()
        _ = try await connection.callTool(name: "search", arguments: ["query": .string("test")])

        let called = await mockClient.wasCalled("search")
        XCTAssertTrue(called)

        let lastArgs = await mockClient.lastCall(for: "search")
        XCTAssertEqual(lastArgs?["query"], .string("test"))
    }

    func testCallToolThrowsOnError() async throws {
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("search"))
        let connection = makeConnection(id: "test-server")
        await connection.connect()

        // Now set error for tool call (after successful connect)
        await mockClient.setError(MCPTestError.toolFailed("Tool error"))

        do {
            _ = try await connection.callTool(name: "search", arguments: nil)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is MCPTestError)
        }
    }

    func testCallToolEmitsEvents() async throws {
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("search"))
        let connection = makeConnection(id: "test-server")

        // Collect all events: 2 from connect (idle→connecting, connecting→connected)
        // plus 2 from tool call (toolCallStarted, toolCallCompleted)
        let events = try await collectEvents(
            from: connection.events,
            count: 4,
            timeout: .seconds(1)
        ) {
            await connection.connect()
            _ = try await connection.callTool(name: "search", arguments: nil)
        }

        // Should have toolCallStarted and toolCallCompleted among the events
        let hasStarted = events.contains { if case .toolCallStarted = $0 { return true }; return false }
        let hasCompleted = events.contains { if case .toolCallCompleted = $0 { return true }; return false }
        XCTAssertTrue(hasStarted, "Should emit toolCallStarted")
        XCTAssertTrue(hasCompleted, "Should emit toolCallCompleted")
    }

    // MARK: - Cancellation Tests

    func testCancelToolCallSendsCancellation() async throws {
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("search"))
        let connection = makeConnection(id: "test-server")

        await connection.connect()
        await connection.cancelToolCall(requestId: "req-123")

        let cancellations = await mockClient.cancellationsSent
        XCTAssertEqual(cancellations, ["req-123"])
    }

    func testCancelToolCallEmitsEvent() async throws {
        await mockClient.setToolsToReturn([])
        let connection = makeConnection(id: "test-server")

        // Collect all events: 2 from connect + 1 from cancel
        let events = try await collectEvents(
            from: connection.events,
            count: 3,
            timeout: .seconds(1)
        ) {
            await connection.connect()
            await connection.cancelToolCall(requestId: "req-456")
        }

        // Find the toolCallCancelled event among all collected events
        let cancelledEvent = events.first { if case .toolCallCancelled = $0 { return true }; return false }
        guard case .toolCallCancelled(let requestId, _) = cancelledEvent else {
            XCTFail("Expected toolCallCancelled event")
            return
        }
        XCTAssertEqual(requestId, "req-456")
    }

    // MARK: - Reconnection Tests

    func testMarkReconnectingUpdatesState() async throws {
        let connection = makeConnection(id: "test-server")
        let nextRetry = Date().addingTimeInterval(5)

        await connection.markReconnecting(attempt: 2, maxAttempts: 5, nextRetryAt: nextRetry)

        let state = await connection.state
        if case .reconnecting(let attempt, let max, let next) = state {
            XCTAssertEqual(attempt, 2)
            XCTAssertEqual(max, 5)
            XCTAssertEqual(next?.timeIntervalSince1970 ?? 0, nextRetry.timeIntervalSince1970, accuracy: 0.1)
        } else {
            XCTFail("Expected reconnecting state, got \(state)")
        }
    }

    // MARK: - Error Handling Tests

    func testCallToolWhenNotConnectedThrows() async throws {
        let connection = makeConnection(id: "test-server")
        // Don't connect

        do {
            _ = try await connection.callTool(name: "search", arguments: nil)
            XCTFail("Expected error")
        } catch let error as MCPConnectionError {
            if case .notConnected(let id) = error {
                XCTAssertEqual(id, "test-server")
            } else {
                XCTFail("Wrong error type")
            }
        }
    }

    // MARK: - Helper Methods

    private func makeConnection(id: String) -> ProtocolServerConnection {
        let spec = MCPTestFixtures.makeStdioSpec(id: id)
        return ProtocolServerConnection(id: id, spec: spec, clientFactory: mockClientFactory)
    }
}

// MARK: - MockMCPClient Extensions for Test Setup

extension MockMCPClient {
    func setToolsToReturn(_ tools: [MCP.Tool]) async {
        toolsToReturn = tools
    }

    func setToolResult(_ name: String, result: MCPCallToolResult) async {
        toolResults[name] = result
    }

    func setError(_ error: Error) async {
        errorToThrow = error
    }

    func setToolCallDelay(_ delay: Duration) async {
        toolCallDelay = delay
    }
}
