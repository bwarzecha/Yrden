/// Tests for MCPCoordinator using MockServerConnection.

import XCTest
import MCP
@testable import Yrden

final class MCPCoordinatorTests: XCTestCase {

    // MARK: - Test Infrastructure

    private var connectionFactory: MockServerConnectionFactory!

    override func setUp() async throws {
        connectionFactory = MockServerConnectionFactory()
    }

    override func tearDown() async throws {
        connectionFactory = nil
    }

    // MARK: - Startup Tests

    func testStartAllConnectsAllServers() async throws {
        let mockConn1 = MockServerConnection(id: "server1")
        let mockConn2 = MockServerConnection(id: "server2")
        await mockConn1.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        await mockConn2.setConnectBehavior(.succeed(toolNames: ["tool2"]))

        connectionFactory.register(mockConn1, for: "server1")
        connectionFactory.register(mockConn2, for: "server2")

        let coordinator = makeCoordinator()
        let specs = MCPTestFixtures.makeSpecs("server1", "server2")

        await coordinator.startAll(specs: specs)

        let conn1Count = await mockConn1.connectCallCount
        let conn2Count = await mockConn2.connectCallCount
        XCTAssertEqual(conn1Count, 1)
        XCTAssertEqual(conn2Count, 1)
    }

    func testStartAllAndWaitReturnsSuccessResult() async throws {
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1", "tool2"]))
        connectionFactory.register(mockConn, for: "server1")

        let coordinator = makeCoordinator()
        let specs = MCPTestFixtures.makeSpecs("server1")

        let result = await coordinator.startAllAndWait(specs: specs)

        XCTAssertEqual(result.connectedServers, ["server1"])
        XCTAssertTrue(result.failedServers.isEmpty)
    }

    func testStartAllAndWaitReportsFailures() async throws {
        let successConn = MockServerConnection(id: "server1")
        let failConn = MockServerConnection(id: "server2")

        await successConn.setConnectBehavior(.succeed(toolNames: []))
        await failConn.setConnectBehavior(.fail(message: "Connection refused"))

        connectionFactory.register(successConn, for: "server1")
        connectionFactory.register(failConn, for: "server2")

        let coordinator = makeCoordinator()
        let specs = MCPTestFixtures.makeSpecs("server1", "server2")

        let result = await coordinator.startAllAndWait(specs: specs)

        XCTAssertEqual(result.connectedServers, ["server1"])
        XCTAssertEqual(result.failedServers.count, 1)
        XCTAssertEqual(result.failedServers.first?.serverID, "server2")
    }

    // MARK: - Reconnection Tests

    func testReconnectAttemptAfterFailure() async throws {
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.fail(message: "Temporary failure"))
        connectionFactory.register(mockConn, for: "server1")

        let coordinator = makeCoordinator()
        await coordinator.startAll(specs: MCPTestFixtures.makeSpecs("server1"))

        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        await coordinator.reconnect(serverID: "server1")

        let callCount = await mockConn.connectCallCount
        XCTAssertEqual(callCount, 2)
    }

    func testReconnectMarksReconnectingState() async throws {
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.delay(.milliseconds(100), then: .succeed(toolNames: [])))
        connectionFactory.register(mockConn, for: "server1")

        let coordinator = makeCoordinator()
        await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))
        await mockConn.forceState(.failed(message: "Lost connection", retryCount: 0))
        async let _ = coordinator.reconnect(serverID: "server1")
        await assertEventually(timeout: .milliseconds(500)) {
            let state = await mockConn.state
            if case .reconnecting = state { return true }
            if case .connecting = state { return true }
            return false
        }
    }

    // MARK: - Tool Call Tests

    func testCallToolRoutesToCorrectServer() async throws {
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["search"]))
        await mockConn.setDefaultToolBehavior(.succeed(result: "search result"))
        connectionFactory.register(mockConn, for: "server1")

        let coordinator = makeCoordinator()
        await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        let result = try await coordinator.callTool(
            serverID: "server1",
            name: "search",
            arguments: ["q": .string("test")],
            timeout: nil
        )

        XCTAssertEqual(result, "search result")

        let called = await mockConn.wasCalled("search")
        XCTAssertTrue(called)
    }

    func testCallToolThrowsForUnknownServer() async throws {
        let coordinator = makeCoordinator()

        do {
            _ = try await coordinator.callTool(
                serverID: "nonexistent",
                name: "tool",
                arguments: nil,
                timeout: nil
            )
            XCTFail("Expected error")
        } catch {
            // Expected
        }
    }

    func testCallToolWithTimeoutCancelsOnExpiry() async throws {
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["slow_tool"]))
        await mockConn.setToolBehavior("slow_tool", behavior: .hang)
        connectionFactory.register(mockConn, for: "server1")

        let coordinator = makeCoordinator()
        await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        do {
            _ = try await coordinator.callTool(
                serverID: "server1",
                name: "slow_tool",
                arguments: nil,
                timeout: .milliseconds(100)
            )
            XCTFail("Expected timeout error")
        } catch {
            // Expected - either CancellationError or timeout error
        }
    }

    // MARK: - Disconnection Tests

    func testDisconnectServerCallsDisconnect() async throws {
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: []))
        connectionFactory.register(mockConn, for: "server1")

        let coordinator = makeCoordinator()
        await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        await coordinator.disconnect(serverID: "server1")

        let disconnectCount = await mockConn.disconnectCallCount
        XCTAssertEqual(disconnectCount, 1)
    }

    func testStopAllDisconnectsAllServers() async throws {
        let mockConn1 = MockServerConnection(id: "server1")
        let mockConn2 = MockServerConnection(id: "server2")
        await mockConn1.setConnectBehavior(.succeed(toolNames: []))
        await mockConn2.setConnectBehavior(.succeed(toolNames: []))

        connectionFactory.register(mockConn1, for: "server1")
        connectionFactory.register(mockConn2, for: "server2")

        let coordinator = makeCoordinator()
        await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1", "server2"))

        await coordinator.stopAll()

        let disc1 = await mockConn1.disconnectCallCount
        let disc2 = await mockConn2.disconnectCallCount
        XCTAssertEqual(disc1, 1)
        XCTAssertEqual(disc2, 1)
    }

    // MARK: - Snapshot Tests

    func testSnapshotReflectsCurrentState() async throws {
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1", "tool2"]))
        connectionFactory.register(mockConn, for: "server1")

        let coordinator = makeCoordinator()
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        let snapshot = await coordinator.snapshot

        XCTAssertEqual(snapshot.servers.count, 1)
        let serverSnapshot = snapshot.servers["server1"]
        XCTAssertNotNil(serverSnapshot)
        XCTAssertEqual(serverSnapshot?.toolNames, ["tool1", "tool2"])
    }

    // MARK: - Event Aggregation Tests

    func testCoordinatorEmitsServerEvents() async throws {
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: []))
        connectionFactory.register(mockConn, for: "server1")

        let coordinator = makeCoordinator()

        // Collect 2 events: idle→connecting, connecting→connected
        let events = try await collectCoordinatorEvents(
            from: coordinator.events,
            count: 2,
            timeout: .seconds(2)
        ) {
            _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))
        }

        // Should have at least one state change event showing connected
        let hasConnectedEvent = events.contains(where: { (event: CoordinatorEvent) in
            if case .stateChanged(_, _, let to) = event,
               case .connected = to {
                return true
            }
            return false
        })
        XCTAssertTrue(hasConnectedEvent)
    }

    // MARK: - Cancellation Tests

    func testCancelConnectionStopsPendingConnect() async throws {
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.hang) // Hang forever
        connectionFactory.register(mockConn, for: "server1")

        let coordinator = makeCoordinator()

        // Start connection (don't await)
        Task {
            await coordinator.startAll(specs: MCPTestFixtures.makeSpecs("server1"))
        }

        // Wait a bit then cancel
        try await Task.sleep(for: .milliseconds(50))
        await coordinator.cancelConnection(serverID: "server1")

        // Should not be connected
        let snapshot = await coordinator.snapshot
        let serverState = snapshot.servers["server1"]?.state
        if case .connected = serverState {
            XCTFail("Should not be connected after cancellation")
        }
    }

    // MARK: - Helper Methods

    private func makeCoordinator() -> ProtocolMCPCoordinator {
        ProtocolMCPCoordinator(connectionFactory: connectionFactory)
    }

    private func collectCoordinatorEvents(
        from stream: AsyncStream<CoordinatorEvent>,
        count: Int,
        timeout: Duration,
        during action: @Sendable () async throws -> Void
    ) async throws -> [CoordinatorEvent] {
        try await collectEvents(from: stream, count: count, timeout: timeout, during: action)
    }
}
