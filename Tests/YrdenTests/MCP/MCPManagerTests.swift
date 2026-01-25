/// Tests for MCPManager behavior.
///
/// Tests the manager using MockCoordinator. Verifies:
/// - Server configuration and startup
/// - Tool aggregation across servers
/// - Event subscription and forwarding
/// - Graceful shutdown

import XCTest
import MCP
@testable import Yrden

final class MCPManagerTests: XCTestCase {

    // MARK: - Test Infrastructure

    private var mockCoordinator: MockCoordinator!

    override func setUp() async throws {
        mockCoordinator = MockCoordinator()
    }

    override func tearDown() async throws {
        mockCoordinator = nil
    }

    // MARK: - Server Configuration Tests

    func testAddServerSpecsCallsStartAll() async throws {
        await mockCoordinator.setStartResult(MCPTestFixtures.makeSuccessResult(servers: ["server1"]))

        let manager = makeManager()
        let specs = [MCPTestFixtures.makeStdioSpec(id: "server1")]

        try await manager.addServers(specs)

        let calls = await mockCoordinator.startAllCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.map(\.id), ["server1"])
    }

    func testAddServerSpecsReturnsResult() async throws {
        let expectedResult = MCPTestFixtures.makeSuccessResult(servers: ["s1", "s2"])
        await mockCoordinator.setStartResult(expectedResult)

        let manager = makeManager()
        let specs = MCPTestFixtures.makeSpecs("s1", "s2")

        let result = try await manager.addServers(specs)

        XCTAssertEqual(result.connectedServers.sorted(), ["s1", "s2"])
    }

    func testAddServerSpecsThrowsOnAllFailed() async throws {
        let failResult = MCPTestFixtures.makeFailedResult(
            connected: [],
            failed: [
                (id: "s1", message: "Connection refused"),
                (id: "s2", message: "Timeout")
            ]
        )
        await mockCoordinator.setStartResult(failResult)

        let manager = makeManager()

        do {
            _ = try await manager.addServers(MCPTestFixtures.makeSpecs("s1", "s2"))
            XCTFail("Expected error when all servers fail")
        } catch {
            // Expected
        }
    }

    // MARK: - Tool Aggregation Tests

    func testAllToolsReturnsToolsFromAllServers() async throws {
        await mockCoordinator.setSnapshot(MCPTestFixtures.makeSnapshot(servers: [
            "server1": .connected(toolCount: 2, toolNames: ["tool1", "tool2"]),
            "server2": .connected(toolCount: 1, toolNames: ["tool3"])
        ]))

        let manager = makeManager()
        let tools = await manager.allTools()

        XCTAssertEqual(tools.count, 3)
        let toolNames = Set(tools.map(\.name))
        XCTAssertEqual(toolNames, ["tool1", "tool2", "tool3"])
    }

    func testToolsFromServerReturnsOnlyThatServersTools() async throws {
        await mockCoordinator.setSnapshot(MCPTestFixtures.makeSnapshot(servers: [
            "server1": .connected(toolCount: 2, toolNames: ["tool1", "tool2"]),
            "server2": .connected(toolCount: 1, toolNames: ["tool3"])
        ]))

        let manager = makeManager()
        let tools = await manager.tools(from: "server1")

        XCTAssertEqual(tools.count, 2)
        let toolNames = Set(tools.map(\.name))
        XCTAssertEqual(toolNames, ["tool1", "tool2"])
    }

    func testToolsFromUnknownServerReturnsEmpty() async throws {
        await mockCoordinator.setSnapshot(MCPTestFixtures.makeSnapshot(servers: [:]))

        let manager = makeManager()
        let tools = await manager.tools(from: "nonexistent")

        XCTAssertTrue(tools.isEmpty)
    }

    // MARK: - Tool Call Tests

    func testCallToolDelegatesToCoordinator() async throws {
        await mockCoordinator.setToolCallResult("result text")

        let manager = makeManager()
        let result = try await manager.callTool(
            serverID: "server1",
            name: "search",
            arguments: ["query": .string("test")]
        )

        XCTAssertEqual(result, "result text")

        let calls = await mockCoordinator.callToolCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.serverID, "server1")
        XCTAssertEqual(calls.first?.name, "search")
    }

    func testCallToolPropagatesError() async throws {
        await mockCoordinator.setToolCallError(MCPTestError.toolFailed("Not found"))

        let manager = makeManager()

        do {
            _ = try await manager.callTool(
                serverID: "server1",
                name: "unknown",
                arguments: nil
            )
            XCTFail("Expected error")
        } catch let error as MCPTestError {
            if case .toolFailed(let msg) = error {
                XCTAssertEqual(msg, "Not found")
            } else {
                XCTFail("Wrong error type")
            }
        }
    }

    // MARK: - Server Status Tests

    func testServerStatusReturnsAllStates() async throws {
        await mockCoordinator.setSnapshot(MCPTestFixtures.makeSnapshot(servers: [
            "server1": .connected(toolCount: 1, toolNames: ["tool1"]),
            "server2": .failed(message: "Error", retryCount: 1),
            "server3": .connecting
        ]))

        let manager = makeManager()
        let statuses = await manager.serverStatuses()

        XCTAssertEqual(statuses.count, 3)
        XCTAssertTrue(statuses["server1"]?.isConnected ?? false)
        XCTAssertTrue(statuses["server2"]?.isFailed ?? false)
        // Check for connecting state using pattern matching
        if case .connecting = statuses["server3"] {
            // ok
        } else {
            XCTFail("Expected connecting state for server3")
        }
    }

    func testConnectedServersFiltersToConnectedOnly() async throws {
        await mockCoordinator.setSnapshot(MCPTestFixtures.makeSnapshot(servers: [
            "server1": .connected(toolCount: 1, toolNames: []),
            "server2": .failed(message: "Error", retryCount: 0),
            "server3": .connected(toolCount: 2, toolNames: [])
        ]))

        let manager = makeManager()
        let connected = await manager.connectedServers()

        XCTAssertEqual(Set(connected), Set(["server1", "server3"]))
    }

    // MARK: - Reconnection Tests

    func testReconnectServerDelegatesToCoordinator() async throws {
        let manager = makeManager()
        await manager.reconnect(serverID: "server1")

        let calls = await mockCoordinator.reconnectCalls
        XCTAssertEqual(calls, ["server1"])
    }

    // MARK: - Disconnect Tests

    func testDisconnectServerDelegatesToCoordinator() async throws {
        let manager = makeManager()
        await manager.disconnect(serverID: "server1")

        let calls = await mockCoordinator.disconnectCalls
        XCTAssertEqual(calls, ["server1"])
    }

    func testDisconnectAllCallsStopAll() async throws {
        let manager = makeManager()
        await manager.disconnectAll()

        let called = await mockCoordinator.stopAllCalled
        XCTAssertTrue(called)
    }

    // MARK: - Event Subscription Tests

    func testEventsStreamForwardsCoordinatorEvents() async throws {
        let manager = makeManager()

        // Emit state change event from coordinator
        let event = MCPEvent.stateChanged(
            serverID: "server1",
            from: .connecting,
            to: .connected(toolCount: 1, toolNames: ["tool1"])
        )

        let coordinator = mockCoordinator!
        let events = try await collectCoordinatorEvents(
            from: manager.events,
            count: 1,
            timeout: .seconds(1)
        ) {
            await coordinator.emit(event)
        }

        guard case .stateChanged(let serverID, _, let to) = events.first else {
            XCTFail("Expected stateChanged event")
            return
        }
        XCTAssertEqual(serverID, "server1")
        if case .connected = to { /* ok */ }
        else { XCTFail("Expected connected state") }
    }

    // MARK: - Helper Methods

    private func makeManager() -> TestMCPManager {
        TestMCPManager(coordinator: mockCoordinator)
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
