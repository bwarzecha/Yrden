/// Concurrency safety tests for MCP coordinator.
///
/// Tests:
/// - Multiple concurrent tool calls complete correctly
/// - Concurrent calls don't corrupt each other
/// - Disconnection during tool calls is handled gracefully
/// - Reconnection during tool calls doesn't corrupt results
/// - Rapid connect/disconnect cycles don't crash

import Testing
import Foundation
import MCP
@testable import Yrden
@testable import YrdenTestSupport

@Suite("MCP Concurrency", .serialized)
struct MCPConcurrencyTests {

    // MARK: - Concurrent Tool Calls

    @Test("Concurrent tool calls all complete with correct results")
    func concurrentToolCallsAllComplete() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1", "tool2", "tool3"]))
        await mockConn.setToolBehavior("tool1", behavior: .delay(.milliseconds(50), then: .succeed(result: "result1")))
        await mockConn.setToolBehavior("tool2", behavior: .delay(.milliseconds(50), then: .succeed(result: "result2")))
        await mockConn.setToolBehavior("tool3", behavior: .delay(.milliseconds(50), then: .succeed(result: "result3")))
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        async let r1 = coordinator.callTool(serverID: "server1", name: "tool1", arguments: nil, timeout: nil)
        async let r2 = coordinator.callTool(serverID: "server1", name: "tool2", arguments: nil, timeout: nil)
        async let r3 = coordinator.callTool(serverID: "server1", name: "tool3", arguments: nil, timeout: nil)

        let results = try await [r1, r2, r3]

        #expect(results.sorted() == ["result1", "result2", "result3"],
               "All 3 concurrent calls should complete with correct results")

        let callHistory = await mockConn.toolCallHistory
        #expect(callHistory.count == 3, "Should have recorded 3 tool calls")
    }

    @Test("Concurrent tool calls don't corrupt each other")
    func concurrentCallsNoCorruption() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["echo"]))
        await mockConn.setDefaultToolBehavior(.delay(.milliseconds(10), then: .succeed(result: "ok")))
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        let concurrentCount = 10
        var successCount = 0

        await withTaskGroup(of: String?.self) { group in
            for _ in 0..<concurrentCount {
                group.addTask {
                    do {
                        return try await coordinator.callTool(
                            serverID: "server1",
                            name: "echo",
                            arguments: nil,
                            timeout: .seconds(5)
                        )
                    } catch {
                        return nil
                    }
                }
            }

            for await result in group {
                if result != nil {
                    successCount += 1
                }
            }
        }

        #expect(successCount == concurrentCount,
               "All \(concurrentCount) concurrent calls should succeed, got \(successCount)")

        let history = await mockConn.toolCallHistory
        #expect(history.count == concurrentCount,
               "Should record all \(concurrentCount) tool calls")
    }

    // MARK: - Disconnection During Tool Call

    @Test("Disconnect during tool call fails gracefully")
    func disconnectDuringToolCall() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["slow_tool"]))
        await mockConn.setToolBehavior("slow_tool", behavior: .hang)
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        let toolTask = Task {
            try await coordinator.callTool(
                serverID: "server1",
                name: "slow_tool",
                arguments: nil,
                timeout: .seconds(1)
            )
        }

        try await Task.sleep(for: .milliseconds(50))
        await coordinator.disconnect(serverID: "server1")

        // Should either complete or fail - not crash
        do {
            _ = try await toolTask.value
        } catch {
            // Expected - tool call failed due to disconnect or timeout
        }

        let disconnectCount = await mockConn.disconnectCallCount
        #expect(disconnectCount == 1, "Disconnect should have been called")
    }

    @Test("Tool call on disconnected server doesn't crash or deadlock")
    func toolCallOnDisconnectedServer() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        await mockConn.setDefaultToolBehavior(.succeed(result: "success"))
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        await coordinator.disconnect(serverID: "server1")

        // Crash/deadlock safety: completes without hanging regardless of outcome
        do {
            _ = try await coordinator.callTool(
                serverID: "server1",
                name: "tool1",
                arguments: nil,
                timeout: .seconds(1)
            )
        } catch {
            // Expected — disconnected server should error
        }
    }

    // MARK: - Reconnection During Tool Call

    @Test("Tool call during reconnect doesn't deadlock")
    func toolCallDuringReconnect() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        await mockConn.setDefaultToolBehavior(.succeed(result: "success"))
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        await mockConn.forceState(.failed(message: "Connection lost", retryCount: 0))
        await mockConn.setConnectBehavior(
            .delay(.milliseconds(100), then: .succeed(toolNames: ["tool1"]))
        )

        Task {
            await coordinator.reconnect(serverID: "server1")
        }

        try await Task.sleep(for: .milliseconds(20))

        // Crash/deadlock safety: completes within timeout regardless of outcome
        do {
            _ = try await coordinator.callTool(
                serverID: "server1",
                name: "tool1",
                arguments: nil,
                timeout: .milliseconds(500)
            )
        } catch {
            // Expected — server may still be reconnecting
        }
    }

    @Test("State change during in-flight tool call doesn't corrupt result")
    func reconnectDuringToolCall() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["slow_tool"]))
        await mockConn.setToolBehavior(
            "slow_tool",
            behavior: .delay(.milliseconds(100), then: .succeed(result: "completed"))
        )
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        _ = await coordinator.startAllAndWait(specs: MCPTestFixtures.makeSpecs("server1"))

        let toolTask = Task<String, Error> {
            try await coordinator.callTool(
                serverID: "server1",
                name: "slow_tool",
                arguments: nil,
                timeout: .seconds(2)
            )
        }

        try await Task.sleep(for: .milliseconds(20))

        // markReconnecting only changes state metadata, doesn't interrupt in-flight calls
        await mockConn.markReconnecting(attempt: 1, maxAttempts: 3, nextRetryAt: nil)

        let result = try await toolTask.value
        #expect(result == "completed",
               "In-flight tool call should complete despite state change")
    }

    // MARK: - Rapid Connect/Disconnect Cycles

    @Test("Rapid connect/disconnect cycles don't crash")
    func rapidConnectDisconnectCycles() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn = MockServerConnection(id: "server1")
        await mockConn.setConnectBehavior(.succeed(toolNames: ["tool1"]))
        factory.register(mockConn, for: "server1")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        let specs = MCPTestFixtures.makeSpecs("server1")

        for _ in 0..<5 {
            _ = await coordinator.startAllAndWait(specs: specs)

            let snapshot = await coordinator.snapshot
            #expect(snapshot.servers["server1"]?.state.isConnected == true,
                   "Should be connected after startAllAndWait")

            await coordinator.disconnect(serverID: "server1")
        }

        // Final state should not be connected
        let finalSnapshot = await coordinator.snapshot
        let state = finalSnapshot.servers["server1"]?.state
        if case .connected = state {
            Issue.record("Expected disconnected state after final disconnect")
        }
    }

    @Test("Concurrent start and stopAll don't crash or deadlock")
    func concurrentStartAndStop() async throws {
        let factory = MockServerConnectionFactory()
        let mockConn1 = MockServerConnection(id: "server1")
        let mockConn2 = MockServerConnection(id: "server2")
        await mockConn1.setConnectBehavior(.delay(.milliseconds(50), then: .succeed(toolNames: [])))
        await mockConn2.setConnectBehavior(.delay(.milliseconds(50), then: .succeed(toolNames: [])))
        factory.register(mockConn1, for: "server1")
        factory.register(mockConn2, for: "server2")

        let coordinator = ProtocolMCPCoordinator(connectionFactory: factory)
        let specs = MCPTestFixtures.makeSpecs("server1", "server2")

        Task {
            await coordinator.startAll(specs: specs)
        }

        try await Task.sleep(for: .milliseconds(20))
        await coordinator.stopAll()

        // After stopAll, no server should be in connected state
        let snapshot = await coordinator.snapshot
        for (serverID, serverSnapshot) in snapshot.servers {
            if case .connected = serverSnapshot.state {
                Issue.record("Server \(serverID) should not be connected after stopAll")
            }
        }
    }
}
