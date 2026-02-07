/// Resilience tests for MCP coordinator.
///
/// Tests:
/// - Auto-reconnect with configurable backoff
/// - Health checks detect dead connections
/// - Graceful degradation with partial server availability
/// - Per-tool timeout on proxy
/// - Alerts emitted on connection events (failed, lost, reconnecting, reconnected, timeout, unhealthy)

import Testing
import Foundation
import MCP
@testable import Yrden
@testable import YrdenTestSupport

@Suite("MCP Resilience", .serialized)
struct MCPResilienceTests {

    // MARK: - Connection Resilience

    @Test("Auto-reconnect after disconnect")
    func autoReconnectAfterDisconnect() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        factory.register(mockConn, for: "server1")

        let config = CoordinatorConfiguration(
            reconnectPolicy: .exponentialBackoff(maxAttempts: 3, baseDelay: 0.01)
        )
        let coordinator = ProtocolMCPCoordinator(
            connectionFactory: factory, configuration: config
        )

        let result = await coordinator.startAllAndWait(
            specs: MCPTestFixtures.makeSpecs("server1")
        )
        #expect(result.allSucceeded, "Initial connection should succeed")

        // Simulate connection loss
        await mockConn.forceState(.failed(message: "Connection lost", retryCount: 0))
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))

        // Trigger auto-reconnect
        await coordinator.triggerAutoReconnect(serverID: "server1")

        let reconnected = await waitFor(timeout: .seconds(1)) {
            let snapshot = await coordinator.snapshot
            return snapshot.servers["server1"]?.state.isConnected == true
        }
        #expect(reconnected, "Server should reconnect after failure")

        let connectCount = await mockConn.connectCallCount
        #expect(connectCount >= 2,
               "Should have at least 2 connect attempts (initial + reconnect), got \(connectCount)")
    }

    @Test("Auto-reconnect respects max attempts")
    func autoReconnectRespectsMaxAttempts() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        factory.register(mockConn, for: "server1")

        let config = CoordinatorConfiguration(
            reconnectPolicy: .exponentialBackoff(maxAttempts: 2, baseDelay: 0.01)
        )
        let coordinator = ProtocolMCPCoordinator(
            connectionFactory: factory, configuration: config
        )

        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        // Now set behavior to always fail for reconnection
        await mockConn.forceState(.failed(message: "Connection lost", retryCount: 0))
        await mockConn.setConnectBehavior(.fail(message: "Always fails"))

        let initialConnectCount = await mockConn.connectCallCount

        await coordinator.triggerAutoReconnect(serverID: "server1")

        try await Task.sleep(for: .milliseconds(200))

        let finalConnectCount = await mockConn.connectCallCount
        let reconnectAttempts = finalConnectCount - initialConnectCount
        #expect(reconnectAttempts <= 2,
               "Should not exceed max attempts (2), got \(reconnectAttempts)")
    }

    @Test("Auto-reconnect with exponential backoff retries multiple times")
    func autoReconnectExponentialBackoff() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        factory.register(mockConn, for: "server1")

        let config = CoordinatorConfiguration(
            reconnectPolicy: .exponentialBackoff(maxAttempts: 3, baseDelay: 0.05)
        )
        let coordinator = ProtocolMCPCoordinator(
            connectionFactory: factory, configuration: config
        )

        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        await mockConn.forceState(.failed(message: "Connection lost", retryCount: 0))
        await mockConn.setConnectBehavior(.fail(message: "Keep failing"))

        let initialConnectCount = await mockConn.connectCallCount

        await coordinator.triggerAutoReconnect(serverID: "server1")

        try await Task.sleep(for: .milliseconds(500))

        let finalConnectCount = await mockConn.connectCallCount
        let reconnectAttempts = finalConnectCount - initialConnectCount
        #expect(reconnectAttempts >= 2,
               "Should attempt multiple reconnects, got \(reconnectAttempts)")
    }

    @Test("Health check detects dead connection")
    func healthCheckDetectsDeadConnection() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        factory.register(mockConn, for: "server1")

        let config = CoordinatorConfiguration(
            reconnectPolicy: .exponentialBackoff(maxAttempts: 1, baseDelay: 0.01),
            healthCheckInterval: .milliseconds(20)
        )
        let coordinator = ProtocolMCPCoordinator(
            connectionFactory: factory, configuration: config
        )

        let result = await coordinator.startAllAndWait(
            specs: MCPTestFixtures.makeSpecs("server1")
        )
        #expect(result.allSucceeded)

        // Set up unhealthy behavior BEFORE starting health checks
        await mockConn.setHealthy(false)

        let alerts = try await collectEvents(
            from: coordinator.alerts,
            count: 1,
            timeout: .milliseconds(200)
        ) {
            await coordinator.startHealthChecks()
            try? await Task.sleep(for: .milliseconds(150))
        }

        let unhealthyAlert = alerts.first { alert in
            if case .serverUnhealthy = alert { return true }
            return false
        }
        #expect(unhealthyAlert != nil,
               "Health check should detect dead connection and emit unhealthy alert")
    }

    // MARK: - Graceful Degradation

    @Test("Graceful degradation with partial server availability")
    func gracefulDegradationPartialServers() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn1 = MockServerConnection(id: "server1")
        let mockConn2 = MockServerConnection(id: "server2")
        await mockConn1.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        await mockConn2.setConnectBehavior(.fail(message: "Server 2 unavailable"))
        factory.register(mockConn1, for: "server1")
        factory.register(mockConn2, for: "server2")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)

        let result = await coordinator.startAllAndWait(
            specs: MCPTestFixtures.makeSpecs("server1", "server2")
        )

        #expect(!result.allSucceeded, "Not all servers should succeed")
        #expect(result.connectedServers == ["server1"])
        #expect(result.failedServers.count == 1)

        // Only connected server's tools should be available
        let availableTools = await coordinator.availableTools()
        #expect(availableTools.count == 1)
        #expect(availableTools.first?.name == "tool1")

        // Tool calls to connected server should work
        await mockConn1.setDefaultToolBehavior(.succeed(result: "success"))
        let toolResult = try await coordinator.callTool(
            serverID: "server1",
            name: "tool1",
            arguments: nil,
            timeout: nil
        )
        #expect(toolResult == "success")
    }

    @Test("Available tools filters disconnected servers")
    func availableToolsFiltersDisconnected() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn1 = MockServerConnection(id: "server1")
        let mockConn2 = MockServerConnection(id: "server2")
        await mockConn1.setConnectBehavior(.succeed(toolNames: ["tool1a", "tool1b"]))
        await mockConn2.setConnectBehavior(.succeed(toolNames: ["tool2a"]))
        factory.register(mockConn1, for: "server1")
        factory.register(mockConn2, for: "server2")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)

        let result = await coordinator.startAllAndWait(
            specs: MCPTestFixtures.makeSpecs("server1", "server2")
        )
        #expect(result.allSucceeded)

        var availableTools = await coordinator.availableTools()
        #expect(availableTools.count == 3, "All 3 tools should be available initially")

        await coordinator.disconnect(serverID: "server2")

        availableTools = await coordinator.availableTools()
        #expect(availableTools.count == 2,
               "Only server1 tools (2) should remain after disconnect")
        #expect(availableTools.allSatisfy { $0.serverID == "server1" },
               "All remaining tools should be from server1")
    }

    // MARK: - Tool Timeout via Proxy

    @Test("Tool proxy timeout is respected")
    func toolProxyTimeout() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["slow_tool"]))
        await mockConn.setToolBehavior(
            "slow_tool",
            behavior: .delay(.milliseconds(200), then: .succeed(result: "done"))
        )
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        let proxy = MCPToolProxy(
            serverID: "server1",
            name: "slow_tool",
            description: "A slow tool",
            inputSchema: ["type": "object"],
            coordinator: coordinator,
            timeout: .milliseconds(50) // Shorter than tool execution time
        )

        let context = ToolContext(model: FakeModel())
        let result = try await proxy.call(context: context, argumentsJSON: "{}")

        // Should be a failure (timeout)
        guard case .failure(let error) = result else {
            Issue.record("Expected .failure for timeout, got \(result)")
            return
        }
        #expect(error.localizedDescription.lowercased().contains("timed out")
                || error.localizedDescription.lowercased().contains("timeout"),
               "Error should mention timeout: \(error.localizedDescription)")
    }

    // MARK: - Alert Tests

    @Test("Alert emitted on connection failed")
    func alertOnConnectionFailed() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.fail(message: "Connection refused"))
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)

        let alerts = try await collectEvents(
            from: coordinator.alerts,
            count: 1,
            timeout: .milliseconds(500)
        ) {
            _ = await coordinator.startAllAndWait(
                specs: MCPTestFixtures.makeSpecs("server1")
            )
        }

        #expect(alerts.count >= 1, "Should emit at least one alert")
        guard case .connectionFailed(let serverID, _) = alerts.first else {
            Issue.record("Expected connectionFailed alert, got: \(alerts)")
            return
        }
        #expect(serverID == "server1")
    }

    @Test("Alert emitted on connection lost")
    func alertOnConnectionLost() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        _ = await coordinator.startAllAndWait(
            specs: MCPTestFixtures.makeSpecs("server1")
        )

        let alerts = try await collectEvents(
            from: coordinator.alerts,
            count: 1,
            timeout: .milliseconds(500)
        ) {
            await mockConn.forceState(.failed(message: "Connection lost", retryCount: 0))
            await coordinator.emitConnectionLost(serverID: "server1")
        }

        let lostAlert = alerts.first { alert in
            if case .connectionLost = alert { return true }
            return false
        }
        #expect(lostAlert != nil, "Should emit connectionLost alert")
    }

    @Test("Alert emitted on reconnecting")
    func alertOnReconnecting() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        factory.register(mockConn, for: "server1")

        let config = CoordinatorConfiguration(
            reconnectPolicy: .exponentialBackoff(maxAttempts: 3, baseDelay: 0.05)
        )
        let coordinator = ProtocolMCPCoordinator(
            connectionFactory: factory, configuration: config
        )
        _ = await coordinator.startAllAndWait(
            specs: MCPTestFixtures.makeSpecs("server1")
        )

        await mockConn.forceState(.failed(message: "Lost", retryCount: 0))
        await mockConn.setConnectBehavior(.fail(message: "Keep failing"))

        let alerts = try await collectEvents(
            from: coordinator.alerts,
            count: 3,
            timeout: .milliseconds(400)
        ) {
            await coordinator.triggerAutoReconnect(serverID: "server1")
            try? await Task.sleep(for: .milliseconds(300))
        }

        let reconnectingAlert = alerts.first { alert in
            if case .reconnecting = alert { return true }
            return false
        }
        #expect(reconnectingAlert != nil,
               "Expected reconnecting alert, got: \(alerts)")
    }

    @Test("Alert emitted on successful reconnect")
    func alertOnReconnected() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        factory.register(mockConn, for: "server1")

        let config = CoordinatorConfiguration(
            reconnectPolicy: .exponentialBackoff(maxAttempts: 3, baseDelay: 0.05)
        )
        let coordinator = ProtocolMCPCoordinator(
            connectionFactory: factory, configuration: config
        )
        _ = await coordinator.startAllAndWait(
            specs: MCPTestFixtures.makeSpecs("server1")
        )

        await mockConn.forceState(.failed(message: "Lost", retryCount: 0))
        // Keep succeed behavior for reconnection
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))

        let alerts = try await collectEvents(
            from: coordinator.alerts,
            count: 3,
            timeout: .milliseconds(400)
        ) {
            await coordinator.triggerAutoReconnect(serverID: "server1")
            try? await Task.sleep(for: .milliseconds(300))
        }

        let reconnectedAlert = alerts.first { alert in
            if case .reconnected = alert { return true }
            return false
        }
        #expect(reconnectedAlert != nil,
               "Expected reconnected alert, got: \(alerts)")
    }

    @Test("Alert emitted on tool timeout")
    func alertOnToolTimeout() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["slow_tool"]))
        await mockConn.setToolBehavior("slow_tool", behavior: .hang)
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        _ = await coordinator.startAllAndWait(
            specs: MCPTestFixtures.makeSpecs("server1")
        )

        let alerts = try await collectEvents(
            from: coordinator.alerts,
            count: 1,
            timeout: .milliseconds(500)
        ) {
            do {
                _ = try await coordinator.callTool(
                    serverID: "server1",
                    name: "slow_tool",
                    arguments: nil,
                    timeout: .milliseconds(50)
                )
            } catch {
                // Expected timeout
            }
        }

        let timeoutAlert = alerts.first { alert in
            if case .toolTimedOut = alert { return true }
            return false
        }
        #expect(timeoutAlert != nil, "Should emit toolTimedOut alert")
    }

    @Test("Alert emitted on server unhealthy")
    func alertOnServerUnhealthy() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        factory.register(mockConn, for: "server1")

        let config = CoordinatorConfiguration(
            healthCheckInterval: .milliseconds(50)
        )
        let coordinator = ProtocolMCPCoordinator(
            connectionFactory: factory, configuration: config
        )
        _ = await coordinator.startAllAndWait(
            specs: MCPTestFixtures.makeSpecs("server1")
        )

        let alerts = try await collectEvents(
            from: coordinator.alerts,
            count: 1,
            timeout: .milliseconds(500)
        ) {
            await coordinator.startHealthChecks()
            await mockConn.setHealthy(false)
            try? await Task.sleep(for: .milliseconds(100))
        }

        let unhealthyAlert = alerts.first { alert in
            if case .serverUnhealthy = alert { return true }
            return false
        }
        #expect(unhealthyAlert != nil, "Should emit serverUnhealthy alert")
    }
}
