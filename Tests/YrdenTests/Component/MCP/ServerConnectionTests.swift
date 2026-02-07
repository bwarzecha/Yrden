/// Tests for ProtocolServerConnection behavior.
///
/// Tests:
/// - Connection lifecycle (idle → connecting → connected/failed → disconnected)
/// - State change events
/// - Tool calling through mock client
/// - Cancellation handling
/// - Error states

import Testing
import Foundation
import MCP
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Server Connection")
struct ServerConnectionTests {

    // MARK: - Connection Lifecycle Tests

    @Test("Initial state is idle")
    func initialStateIsIdle() async throws {
        let (connection, _, _) = makeConnection(id: "test-server")
        let state = await connection.state
        #expect(state == .idle)
    }

    @Test("Successful connect transitions to connected with tools")
    func successfulConnect() async throws {
        let (connection, mockClient, _) = makeConnection(id: "test-server")
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("tool1", "tool2"))

        await connection.connect()

        let state = await connection.state
        guard case .connected(let tools) = state else {
            Issue.record("Expected .connected, got \(state)")
            return
        }
        #expect(tools.count == 2, "Should have 2 tools")
        #expect(tools.map(\.name).sorted() == ["tool1", "tool2"])
    }

    @Test("Connect emits state change events")
    func connectEmitsEvents() async throws {
        let (connection, mockClient, _) = makeConnection(id: "test-server")
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("tool1"))

        let events = try await collectEvents(
            from: connection.events,
            count: 2,
            timeout: .seconds(2)
        ) {
            await connection.connect()
        }

        #expect(events.count >= 2, "Should emit at least 2 events")

        // First event: idle → connecting
        guard case .stateChanged(_, let from1, let to1) = events[0] else {
            Issue.record("Expected stateChanged event, got \(events[0])")
            return
        }
        #expect(from1 == .idle)
        guard case .connecting = to1 else {
            Issue.record("Expected .connecting, got \(to1)")
            return
        }

        // Second event: connecting → connected
        guard case .stateChanged(_, let from2, let to2) = events[1] else {
            Issue.record("Expected stateChanged event, got \(events[1])")
            return
        }
        guard case .connecting = from2 else {
            Issue.record("Expected from .connecting, got \(from2)")
            return
        }
        guard case .connected = to2 else {
            Issue.record("Expected to .connected, got \(to2)")
            return
        }
    }

    @Test("Failed connect transitions to failed")
    func failedConnect() async throws {
        let (connection, mockClient, _) = makeConnection(id: "test-server")
        await mockClient.setError(MCPTestError.connectionRefused)

        await connection.connect()

        let state = await connection.state
        guard case .failed(let message, _) = state else {
            Issue.record("Expected .failed, got \(state)")
            return
        }
        #expect(message.contains("Connection refused"),
               "Error message should mention connection refused: \(message)")
    }

    @Test("Disconnect transitions to disconnected")
    func disconnectTransition() async throws {
        let (connection, mockClient, _) = makeConnection(id: "test-server")
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("tool1"))

        await connection.connect()
        await connection.disconnect()

        let state = await connection.state
        #expect(state == .disconnected)
    }

    @Test("Disconnect calls client disconnect")
    func disconnectCallsClient() async throws {
        let (connection, mockClient, _) = makeConnection(id: "test-server")
        await mockClient.setToolsToReturn([])

        await connection.connect()
        await connection.disconnect()

        let disconnected = await mockClient.disconnectCalled
        #expect(disconnected, "Should call disconnect on client")
    }

    // MARK: - Tool Calling Tests

    @Test("Call tool returns result")
    func callToolReturnsResult() async throws {
        let (connection, mockClient, _) = makeConnection(id: "test-server")
        let expectedResult = MCPCallToolResult(content: [.text("result text")])
        await mockClient.setToolResult("search", result: expectedResult)
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("search"))

        await connection.connect()
        let result = try await connection.callTool(
            name: "search",
            arguments: ["query": .string("test")]
        )

        #expect(result == "result text")
    }

    @Test("Call tool records the call and arguments")
    func callToolRecordsCall() async throws {
        let (connection, mockClient, _) = makeConnection(id: "test-server")
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("search"))

        await connection.connect()
        _ = try await connection.callTool(
            name: "search",
            arguments: ["query": .string("test")]
        )

        let called = await mockClient.wasCalled("search")
        #expect(called, "search tool should have been called")

        let lastArgs = await mockClient.lastCall(for: "search")
        #expect(lastArgs?["query"] == .string("test"),
               "Should pass arguments through")
    }

    @Test("Call tool throws on error")
    func callToolThrowsOnError() async throws {
        let (connection, mockClient, _) = makeConnection(id: "test-server")
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("search"))

        await connection.connect()

        // Set error for tool call (after successful connect)
        await mockClient.setError(MCPTestError.toolFailed("Tool error"))

        do {
            _ = try await connection.callTool(name: "search", arguments: nil)
            Issue.record("Expected error to be thrown")
        } catch {
            #expect(error is MCPTestError,
                   "Should throw MCPTestError, got \(type(of: error))")
        }
    }

    @Test("Call tool emits events")
    func callToolEmitsEvents() async throws {
        let (connection, mockClient, _) = makeConnection(id: "test-server")
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("search"))

        // Collect events: 2 from connect + 2 from tool call
        let events = try await collectEvents(
            from: connection.events,
            count: 4,
            timeout: .seconds(1)
        ) {
            await connection.connect()
            _ = try await connection.callTool(name: "search", arguments: nil)
        }

        let hasStarted = events.contains {
            if case .toolCallStarted = $0 { return true }
            return false
        }
        let hasCompleted = events.contains {
            if case .toolCallCompleted = $0 { return true }
            return false
        }
        #expect(hasStarted, "Should emit toolCallStarted")
        #expect(hasCompleted, "Should emit toolCallCompleted")
    }

    // MARK: - Cancellation Tests

    @Test("Cancel tool call sends cancellation")
    func cancelToolCallSendsCancellation() async throws {
        let (connection, mockClient, _) = makeConnection(id: "test-server")
        await mockClient.setToolsToReturn(MCPTestFixtures.makeMCPTools("search"))

        await connection.connect()
        await connection.cancelToolCall(requestId: "req-123")

        let cancellations = await mockClient.cancellationsSent
        #expect(cancellations == ["req-123"])
    }

    @Test("Cancel tool call emits event")
    func cancelToolCallEmitsEvent() async throws {
        let (connection, mockClient, _) = makeConnection(id: "test-server")
        await mockClient.setToolsToReturn([])

        let events = try await collectEvents(
            from: connection.events,
            count: 3,
            timeout: .seconds(1)
        ) {
            await connection.connect()
            await connection.cancelToolCall(requestId: "req-456")
        }

        let cancelledEvent = events.first {
            if case .toolCallCancelled = $0 { return true }
            return false
        }
        guard case .toolCallCancelled(let requestId, _) = cancelledEvent else {
            Issue.record("Expected toolCallCancelled event in \(events)")
            return
        }
        #expect(requestId == "req-456")
    }

    // MARK: - Reconnection Tests

    @Test("Mark reconnecting updates state")
    func markReconnectingUpdatesState() async throws {
        let (connection, _, _) = makeConnection(id: "test-server")
        let nextRetry = Date().addingTimeInterval(5)

        await connection.markReconnecting(attempt: 2, maxAttempts: 5, nextRetryAt: nextRetry)

        let state = await connection.state
        guard case .reconnecting(let attempt, let max, let next) = state else {
            Issue.record("Expected .reconnecting, got \(state)")
            return
        }
        #expect(attempt == 2)
        #expect(max == 5)
        #expect(abs((next?.timeIntervalSince1970 ?? 0) - nextRetry.timeIntervalSince1970) < 0.1,
               "Next retry time should match")
    }

    // MARK: - Error Handling Tests

    @Test("Call tool when not connected throws")
    func callToolWhenNotConnectedThrows() async throws {
        let (connection, _, _) = makeConnection(id: "test-server")

        do {
            _ = try await connection.callTool(name: "search", arguments: nil)
            Issue.record("Expected error")
        } catch let error as MCPConnectionError {
            guard case .notConnected(let id) = error else {
                Issue.record("Expected .notConnected, got \(error)")
                return
            }
            #expect(id == "test-server")
        }
    }

    // MARK: - Helpers

    private func makeConnection(
        id: String
    ) -> (ProtocolServerConnection, MockMCPClient, MockMCPClientFactory) {
        let mockClient = MockMCPClient()
        let mockClientFactory = MockMCPClientFactory()
        mockClientFactory.defaultClient = mockClient
        let spec = MCPTestFixtures.makeStdioSpec(id: id)
        let connection = ProtocolServerConnection(
            id: id,
            spec: spec,
            clientFactory: mockClientFactory
        )
        return (connection, mockClient, mockClientFactory)
    }
}
