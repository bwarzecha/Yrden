/// Tests for ProtocolMCPCoordinator using MockServerConnection.
///
/// Tests:
/// - Startup (startAll, startAllAndWait)
/// - Reconnection after failure
/// - Tool call routing
/// - Disconnection and stopAll
/// - Snapshot state reporting
/// - Event aggregation
/// - Connection cancellation

import Testing
import Foundation
import MCP
@testable import Yrden
@testable import YrdenTestSupport

@Suite("MCP Coordinator")
struct MCPCoordinatorTests {

    // MARK: - Startup Tests

    @Test("startAll connects all servers")
    func startAllConnectsAllServers() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn1 = MockServerConnection(id: "server1")
        let mockConn2 = MockServerConnection(id: "server2")
        await mockConn1.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        await mockConn2.setConnectBehavior(.succeed(toolNames: ["tool2"]))
        factory.register(mockConn1, for: "server1")
        factory.register(mockConn2, for: "server2")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        let specs = MCPTestFixtures.makeSpecs("server1", "server2")

        await coordinator.startAll(specs: specs)

        let conn1Count = await mockConn1.connectCallCount
        let conn2Count = await mockConn2.connectCallCount
        #expect(conn1Count == 1, "server1 should be connected once")
        #expect(conn2Count == 1, "server2 should be connected once")
    }

    @Test("startAllAndWait returns success result")
    func startAllAndWaitSuccess() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1", "tool2"]))
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        let specs = MCPTestFixtures.makeSpecs("server1")

        let result = await coordinator.startAllAndWait(specs: specs)

        #expect(result.connectedServers == ["server1"])
        #expect(result.failedServers.isEmpty, "No servers should fail")
    }

    @Test("startAllAndWait reports failures")
    func startAllAndWaitReportsFailures() async throws {
        let factory = MockServerConnectionFactory()
        let successConn = MockServerConnection(id: "server1")
        let failConn = MockServerConnection(id: "server2")
        await successConn.setConnectBehavior(.succeed(toolNames: []))
        await failConn.setConnectBehavior(.fail(message: "Connection refused"))
        factory.register(successConn, for: "server1")
        factory.register(failConn, for: "server2")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        let specs = MCPTestFixtures.makeSpecs("server1", "server2")

        let result = await coordinator.startAllAndWait(specs: specs)

        #expect(result.connectedServers == ["server1"])
        #expect(result.failedServers.count == 1)
        #expect(result.failedServers.first?.serverID == "server2")
    }

    // MARK: - Reconnection Tests

    @Test("Reconnect after failure retries connection")
    func reconnectAfterFailure() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.fail(message: "Temporary failure"))
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        await coordinator.startAll(specs: MCPTestFixtures.makeSpecs("server1"))

        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        await coordinator.reconnect(serverID: "server1")

        let callCount = await mockConn.connectCallCount
        #expect(callCount == 2, "Should have 2 connect attempts (initial + reconnect)")
    }

    @Test("Reconnect marks reconnecting state")
    func reconnectMarksReconnectingState() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(
            .delay(.milliseconds(100), then: .succeed(toolNames: []))
        )
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))
        await mockConn.forceState(.failed(message: "Lost connection", retryCount: 0))
        async let _ = coordinator.reconnect(serverID: "server1")

        let reached = await waitFor(timeout: .milliseconds(500)) {
            let state = await mockConn.state
            if case .reconnecting = state { return true }
            if case .connecting = state { return true }
            return false
        }
        #expect(reached, "Should reach reconnecting or connecting state")
    }

    // MARK: - Tool Call Tests

    @Test("Call tool routes to correct server")
    func callToolRoutes() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["search"]))
        await mockConn.setDefaultToolBehavior(.succeed(result: "search result"))
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        let result = try await coordinator.callTool(
            serverID: "server1",
            name: "search",
            arguments: ["q": .string("test")],
            timeout: nil
        )

        #expect(result == "search result")

        let called = await mockConn.wasCalled("search")
        #expect(called, "search tool should have been called")
    }

    @Test("Call tool throws for unknown server")
    func callToolUnknownServer() async throws {
        let factory = MockServerConnectionFactory()
        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)

        do {
            _ = try await coordinator.callTool(
                serverID: "nonexistent",
                name: "tool",
                arguments: nil,
                timeout: nil
            )
            Issue.record("Expected error for unknown server")
        } catch {
            // Expected - unknown server
        }
    }

    @Test("Call tool with timeout cancels on expiry")
    func callToolTimeout() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["slow_tool"]))
        await mockConn.setToolBehavior("slow_tool", behavior: .hang)
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        do {
            _ = try await coordinator.callTool(
                serverID: "server1",
                name: "slow_tool",
                arguments: nil,
                timeout: .milliseconds(100)
            )
            Issue.record("Expected timeout error")
        } catch {
            // Expected - timeout or cancellation
        }
    }

    // MARK: - Disconnection Tests

    @Test("Disconnect server calls disconnect")
    func disconnectServer() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: []))
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        await coordinator.disconnect(serverID: "server1")

        let disconnectCount = await mockConn.disconnectCallCount
        #expect(disconnectCount == 1, "Should call disconnect once")
    }

    @Test("stopAll disconnects all servers")
    func stopAllDisconnects() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn1 = MockServerConnection(id: "server1")
        let mockConn2 = MockServerConnection(id: "server2")
        await mockConn1.setConnectBehavior(.succeed(toolNames: []))
        await mockConn2.setConnectBehavior(.succeed(toolNames: []))
        factory.register(mockConn1, for: "server1")
        factory.register(mockConn2, for: "server2")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1", "server2"))

        await coordinator.stopAll()

        let disc1 = await mockConn1.disconnectCallCount
        let disc2 = await mockConn2.disconnectCallCount
        #expect(disc1 == 1, "server1 should be disconnected")
        #expect(disc2 == 1, "server2 should be disconnected")
    }

    // MARK: - Snapshot Tests

    @Test("Snapshot reflects current state")
    func snapshotReflectsState() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1", "tool2"]))
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        let snapshot = await coordinator.snapshot

        #expect(snapshot.servers.count == 1)
        let serverSnapshot = snapshot.servers["server1"]
        #expect(serverSnapshot != nil, "server1 should be in snapshot")
        #expect(serverSnapshot?.toolNames.sorted() == ["tool1", "tool2"])
    }

    // MARK: - Event Aggregation Tests

    @Test("Coordinator emits server events")
    func coordinatorEmitsEvents() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: []))
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)

        let events = try await collectEvents(
            from: coordinator.events,
            count: 2,
            timeout: .seconds(2)
        ) {
            _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))
        }

        let hasConnectedEvent = events.contains { event in
            if case .stateChanged(_, _, let to) = event,
               case .connected = to {
                return true
            }
            return false
        }
        #expect(hasConnectedEvent, "Should emit connected state change event")
    }

    // MARK: - Cancellation Tests

    @Test("Cancel connection stops pending connect")
    func cancelConnection() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.hang)
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)

        Task {
            await coordinator.startAll(specs: MCPTestFixtures.makeSpecs("server1"))
        }

        try await Task.sleep(for: .milliseconds(50))
        await coordinator.cancelConnection(serverID: "server1")

        let snapshot = await coordinator.snapshot
        let serverState = snapshot.servers["server1"]?.state
        if case .connected = serverState {
            Issue.record("Should not be connected after cancellation")
        }
    }
}
