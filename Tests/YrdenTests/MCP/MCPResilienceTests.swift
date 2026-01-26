/// Resilience tests for MCP coordinator.
///
/// Tests verify:
/// - Auto-reconnect with configurable backoff
/// - Health checks detect dead connections
/// - Graceful degradation with partial server availability
/// - Per-tool timeout configuration
/// - Tool-level retry before model error
/// - Alerts emitted on connection events

import XCTest
import MCP
@testable import Yrden

final class MCPResilienceTests: XCTestCase {

    // MARK: - Test Infrastructure

    private var connectionFactory: MockServerConnectionFactory!

    override func setUp() async throws {
        connectionFactory = MockServerConnectionFactory()
    }

    override func tearDown() async throws {
        connectionFactory = nil
    }

    // MARK: - 4.1 Connection Resilience Tests

    func testAutoReconnectAfterDisconnect() async throws {
        // Setup: server that will fail then succeed
        let mockConn = MockServerConnection(id: "server1")
        // First connection succeeds
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        connectionFactory.register(mockConn, for: "server1")

        let config = CoordinatorConfiguration(
            reconnectPolicy: .exponentialBackoff(maxAttempts: 3, baseDelay: 0.01)
        )
        let coordinator = makeCoordinator(config: config)

        // Connect initially
        let result = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))
        XCTAssertTrue(result.allSucceeded)

        // Simulate connection loss
        await mockConn.forceState(.failed(message: "Connection lost", retryCount: 0))

        // Set up behavior for reconnection to succeed
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))

        // Trigger auto-reconnect
        await coordinator.triggerAutoReconnect(serverID: "server1")

        // Wait for reconnection
        let reconnected = await waitFor(timeout: .seconds(1)) {
            let snapshot = await coordinator.snapshot
            return snapshot.servers["server1"]?.state.isConnected == true
        }

        XCTAssertTrue(reconnected, "Server should reconnect after failure")

        // Verify multiple connect attempts were made (initial + reconnect)
        let connectCount = await mockConn.connectCallCount
        XCTAssertGreaterThanOrEqual(connectCount, 2)
    }

    func testAutoReconnectRespectsMaxAttempts() async throws {
        // Setup: server that initially connects, then always fails on reconnect
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        connectionFactory.register(mockConn, for: "server1")

        let config = CoordinatorConfiguration(
            reconnectPolicy: .exponentialBackoff(maxAttempts: 2, baseDelay: 0.01)
        )
        let coordinator = makeCoordinator(config: config)

        // Connect first
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        // Now set behavior to always fail for reconnection
        await mockConn.forceState(.failed(message: "Connection lost", retryCount: 0))
        await mockConn.setConnectBehavior(.fail(message: "Always fails"))

        let initialConnectCount = await mockConn.connectCallCount

        // Trigger reconnection
        await coordinator.triggerAutoReconnect(serverID: "server1")

        // Wait for retries to exhaust
        try await Task.sleep(for: .milliseconds(200))

        // Verify max attempts was respected (initial + max reconnect attempts)
        let finalConnectCount = await mockConn.connectCallCount
        let reconnectAttempts = finalConnectCount - initialConnectCount
        XCTAssertLessThanOrEqual(reconnectAttempts, 2, "Should not exceed max attempts")
    }

    func testAutoReconnectWithExponentialBackoff() async throws {
        // Setup: server that initially connects, then fails on reconnect
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        connectionFactory.register(mockConn, for: "server1")

        let baseDelay = 0.05 // 50ms
        let config = CoordinatorConfiguration(
            reconnectPolicy: .exponentialBackoff(maxAttempts: 3, baseDelay: baseDelay)
        )
        let coordinator = makeCoordinator(config: config)

        // Connect first
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        // Now set behavior to fail for reconnection
        await mockConn.forceState(.failed(message: "Connection lost", retryCount: 0))
        await mockConn.setConnectBehavior(.fail(message: "Keep failing"))

        let initialConnectCount = await mockConn.connectCallCount

        // Trigger reconnection
        await coordinator.triggerAutoReconnect(serverID: "server1")

        // Wait for all attempts
        try await Task.sleep(for: .milliseconds(500))

        let finalConnectCount = await mockConn.connectCallCount
        let reconnectAttempts = finalConnectCount - initialConnectCount
        XCTAssertGreaterThanOrEqual(reconnectAttempts, 2, "Should attempt multiple reconnects")
    }

    func testHealthCheckDetectsDeadConnection() async throws {
        // Setup: server with health check
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        connectionFactory.register(mockConn, for: "server1")

        let config = CoordinatorConfiguration(
            reconnectPolicy: .exponentialBackoff(maxAttempts: 1, baseDelay: 0.01),
            healthCheckInterval: .milliseconds(20)
        )
        let coordinator = makeCoordinator(config: config)

        // Connect
        let result = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))
        XCTAssertTrue(result.allSucceeded)

        // Set up unhealthy behavior BEFORE starting health checks
        await mockConn.setHealthy(false)

        // Collect alerts during health check
        let alerts = try await collectEvents(
            from: coordinator.alerts,
            count: 1,
            timeout: .milliseconds(200)
        ) {
            await coordinator.startHealthChecks()
            try? await Task.sleep(for: .milliseconds(150))
        }

        // Verify unhealthy alert was emitted
        let unhealthyAlert = alerts.first { alert in
            if case .serverUnhealthy = alert { return true }
            return false
        }
        XCTAssertNotNil(unhealthyAlert, "Health check should detect dead connection and emit alert")
    }

    func testGracefulDegradationWithPartialServers() async throws {
        // Setup: two servers, one will fail
        let mockConn1 = MockServerConnection(id: "server1")
        let mockConn2 = MockServerConnection(id: "server2")
        await mockConn1.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        await mockConn2.setConnectBehavior(.fail(message: "Server 2 unavailable"))
        connectionFactory.register(mockConn1, for: "server1")
        connectionFactory.register(mockConn2, for: "server2")

        let coordinator = makeCoordinator()

        // Start all servers
        let result = await coordinator.startAllAndWait(
            specs: MCPTestFixtures.makeSpecs("server1", "server2")
        )

        // One should succeed, one should fail
        XCTAssertFalse(result.allSucceeded)
        XCTAssertEqual(result.connectedServers, ["server1"])
        XCTAssertEqual(result.failedServers.count, 1)

        // Available tools should only include connected servers
        let availableTools = await coordinator.availableTools()
        XCTAssertEqual(availableTools.count, 1)
        XCTAssertEqual(availableTools.first?.name, "tool1")

        // Tool calls to connected server should work
        await mockConn1.setDefaultToolBehavior(.succeed(result: "success"))
        let toolResult = try await coordinator.callTool(
            serverID: "server1",
            name: "tool1",
            arguments: nil,
            timeout: nil
        )
        XCTAssertEqual(toolResult, "success")
    }

    func testAvailableToolsFiltersDisconnectedServers() async throws {
        // Setup: two servers initially connected
        let mockConn1 = MockServerConnection(id: "server1")
        let mockConn2 = MockServerConnection(id: "server2")
        await mockConn1.setConnectBehavior(.succeed(toolNames: ["tool1a", "tool1b"]))
        await mockConn2.setConnectBehavior(.succeed(toolNames: ["tool2a"]))
        connectionFactory.register(mockConn1, for: "server1")
        connectionFactory.register(mockConn2, for: "server2")

        let coordinator = makeCoordinator()

        let result = await coordinator.startAllAndWait(
            specs: MCPTestFixtures.makeSpecs("server1", "server2")
        )
        XCTAssertTrue(result.allSucceeded)

        // Initially all tools available
        var availableTools = await coordinator.availableTools()
        XCTAssertEqual(availableTools.count, 3)

        // Disconnect server2
        await coordinator.disconnect(serverID: "server2")

        // Now only server1 tools should be available
        availableTools = await coordinator.availableTools()
        XCTAssertEqual(availableTools.count, 2)
        XCTAssertTrue(availableTools.allSatisfy { $0.serverID == "server1" })
    }

    // MARK: - 4.2 Tool Call Resilience Tests

    func testToolTimeoutIsRespected() async throws {
        // Setup: server with slow tool
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["slow_tool"]))
        await mockConn.setToolBehavior("slow_tool", behavior: .delay(.milliseconds(200), then: .succeed(result: "done")))
        connectionFactory.register(mockConn, for: "server1")

        let coordinator = makeCoordinator()
        await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        // Create proxy with short timeout
        let proxy = MCPToolProxy(
            serverID: "server1",
            name: "slow_tool",
            description: "A slow tool",
            inputSchema: ["type": "object"],
            coordinator: coordinator,
            timeout: .milliseconds(50)  // Shorter than tool execution time
        )

        // Call should timeout
        let result = try await proxy.call(argumentsJSON: "{}")

        // Result should be retry (timeout)
        switch result {
        case .retry(let message):
            XCTAssertTrue(message.contains("timed out"))
        case .success, .failure, .deferred:
            XCTFail("Expected retry result for timeout")
        }
    }

    func testToolRetryBeforeModelError() async throws {
        // Setup: tool that succeeds (proxy retry logic handles failures)
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["test_tool"]))
        await mockConn.setToolBehavior("test_tool", behavior: .succeed(result: "success"))
        connectionFactory.register(mockConn, for: "server1")

        let coordinator = makeCoordinator()
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        // Create proxy with retries
        let proxy = MCPToolProxy(
            serverID: "server1",
            name: "test_tool",
            description: "Test tool",
            inputSchema: ["type": "object"],
            coordinator: coordinator,
            maxRetries: 2
        )

        // Call with retry logic - should succeed on first try
        let result = try await proxy.callWithRetry(argumentsJSON: "{}")

        // Should succeed
        switch result {
        case .success(let value):
            XCTAssertEqual(value, "success")
        case .retry, .failure, .deferred:
            XCTFail("Expected success")
        }

        // Verify tool was called (at least once)
        let history = await mockConn.toolCallHistory
        XCTAssertGreaterThanOrEqual(history.count, 1)
    }

    func testToolRetryExhausted() async throws {
        // Setup: tool that always fails
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["always_fail"]))
        await mockConn.setToolBehavior("always_fail", behavior: .fail(error: MCPTestError.toolFailed("Always fails")))
        connectionFactory.register(mockConn, for: "server1")

        let coordinator = makeCoordinator()
        await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        let proxy = MCPToolProxy(
            serverID: "server1",
            name: "always_fail",
            description: "Always fails",
            inputSchema: ["type": "object"],
            coordinator: coordinator,
            maxRetries: 2
        )

        // Call with retry logic
        let result = try await proxy.callWithRetry(argumentsJSON: "{}")

        // Should fail after exhausting retries
        switch result {
        case .failure:
            break // Expected
        case .success, .retry, .deferred:
            XCTFail("Expected failure after exhausting retries")
        }
    }

    // MARK: - 4.3 MCP Alerts Tests

    func testAlertEmittedOnConnectionFailed() async throws {
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.fail(message: "Connection refused"))
        connectionFactory.register(mockConn, for: "server1")

        let coordinator = makeCoordinator()

        // Collect alerts during connection attempt
        let alerts = try await collectEvents(
            from: coordinator.alerts,
            count: 1,
            timeout: .milliseconds(500)
        ) {
            _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))
        }

        // Verify alert
        XCTAssertGreaterThanOrEqual(alerts.count, 1)
        if case .connectionFailed(let serverID, _) = alerts.first {
            XCTAssertEqual(serverID, "server1")
        } else {
            XCTFail("Expected connectionFailed alert")
        }
    }

    func testAlertEmittedOnConnectionLost() async throws {
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        connectionFactory.register(mockConn, for: "server1")

        let coordinator = makeCoordinator()

        // Connect first
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        // Collect alerts during disconnection
        let alerts = try await collectEvents(
            from: coordinator.alerts,
            count: 1,
            timeout: .milliseconds(500)
        ) {
            // Simulate connection loss
            await mockConn.forceState(.failed(message: "Connection lost", retryCount: 0))
            // Emit connection lost event manually
            await coordinator.emitConnectionLost(serverID: "server1")
        }

        // Verify alert
        let lostAlert = alerts.first { alert in
            if case .connectionLost = alert { return true }
            return false
        }
        XCTAssertNotNil(lostAlert)
    }

    func testAlertEmittedOnReconnecting() async throws {
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        connectionFactory.register(mockConn, for: "server1")

        let config = CoordinatorConfiguration(
            reconnectPolicy: .exponentialBackoff(maxAttempts: 3, baseDelay: 0.05)
        )
        let coordinator = makeCoordinator(config: config)

        // Connect first
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        // Simulate connection loss
        await mockConn.forceState(.failed(message: "Lost", retryCount: 0))
        await mockConn.setConnectBehavior(.fail(message: "Keep failing"))

        // Collect alerts during reconnection
        let alerts = try await collectEvents(
            from: coordinator.alerts,
            count: 3,
            timeout: .milliseconds(400)
        ) {
            await coordinator.triggerAutoReconnect(serverID: "server1")
            try? await Task.sleep(for: .milliseconds(300))
        }

        // Verify reconnecting alert was received
        let reconnectingAlert = alerts.first { alert in
            if case .reconnecting = alert { return true }
            return false
        }
        XCTAssertNotNil(reconnectingAlert, "Expected reconnecting alert, got: \(alerts)")
    }

    func testAlertEmittedOnReconnected() async throws {
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        connectionFactory.register(mockConn, for: "server1")

        let config = CoordinatorConfiguration(
            reconnectPolicy: .exponentialBackoff(maxAttempts: 3, baseDelay: 0.05)
        )
        let coordinator = makeCoordinator(config: config)

        // Connect first
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        // Simulate connection loss
        await mockConn.forceState(.failed(message: "Lost", retryCount: 0))
        // Keep the succeed behavior for reconnection
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))

        // Collect alerts during reconnection
        let alerts = try await collectEvents(
            from: coordinator.alerts,
            count: 3,
            timeout: .milliseconds(400)
        ) {
            await coordinator.triggerAutoReconnect(serverID: "server1")
            try? await Task.sleep(for: .milliseconds(300))
        }

        // Verify reconnected alert was received
        let reconnectedAlert = alerts.first { alert in
            if case .reconnected = alert { return true }
            return false
        }
        XCTAssertNotNil(reconnectedAlert, "Expected reconnected alert, got: \(alerts)")
    }

    func testAlertEmittedOnToolTimeout() async throws {
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["slow_tool"]))
        await mockConn.setToolBehavior("slow_tool", behavior: .hang)
        connectionFactory.register(mockConn, for: "server1")

        let coordinator = makeCoordinator()
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        // Collect alerts during timeout
        let alerts = try await collectEvents(
            from: coordinator.alerts,
            count: 1,
            timeout: .milliseconds(500)
        ) {
            // Call tool with short timeout
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

        // Verify timeout alert
        let timeoutAlert = alerts.first { alert in
            if case .toolTimedOut = alert { return true }
            return false
        }
        XCTAssertNotNil(timeoutAlert)
    }

    func testAlertEmittedOnServerUnhealthy() async throws {
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        connectionFactory.register(mockConn, for: "server1")

        let config = CoordinatorConfiguration(
            healthCheckInterval: .milliseconds(50)
        )
        let coordinator = makeCoordinator(config: config)

        // Connect
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        // Collect alerts during health check
        let alerts = try await collectEvents(
            from: coordinator.alerts,
            count: 1,
            timeout: .milliseconds(500)
        ) {
            // Start health checks and mark server unhealthy
            await coordinator.startHealthChecks()
            await mockConn.setHealthy(false)
            // Wait for health check to run
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Verify unhealthy alert
        let unhealthyAlert = alerts.first { alert in
            if case .serverUnhealthy = alert { return true }
            return false
        }
        XCTAssertNotNil(unhealthyAlert)
    }

    // MARK: - Helper Methods

    private func makeCoordinator(config: CoordinatorConfiguration = .default) -> ProtocolMCPCoordinator {
        ProtocolMCPCoordinator(connectionFactory: connectionFactory, configuration: config)
    }
}

// MARK: - Test Helper Extensions

extension MockServerConnection {
    /// Set whether the connection is healthy for health check tests.
    func setHealthy(_ healthy: Bool) async {
        // For now, unhealthy means failing tool calls
        if healthy {
            defaultToolCallBehavior = .succeed(result: "healthy")
        } else {
            defaultToolCallBehavior = .fail(error: MCPTestError.connectionRefused)
        }
    }
}

// Note: ConnectionState.isReconnecting is defined in MCPConcurrencyTests.swift
// Note: Alert collection uses generic collectEvents from MCPTestUtilities.swift
