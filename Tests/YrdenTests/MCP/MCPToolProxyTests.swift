/// Tests for MCPToolProxy and related components.
///
/// Tests:
/// - MCPToolProxy routes calls through coordinator
/// - ToolFilter matches entries correctly
/// - ToolMode filtering works
/// - lifted() extension creates working tools

import Testing
import Foundation
import MCP
@testable import Yrden

// MARK: - MCPToolProxy Tests

@Suite("MCP Tool Proxy")
struct MCPToolProxyTests {

    // MARK: - Proxy Creation

    @Test("Creates proxy with correct properties")
    func proxyProperties() async throws {
        let coordinator = MockCoordinator()
        let toolInfo = ToolInfo(MCP.Tool(
            name: "test_tool",
            description: "Test description",
            inputSchema: .object(["type": .string("object")])
        ))

        let proxy = MCPToolProxy(
            serverID: "server1",
            toolInfo: toolInfo,
            coordinator: coordinator
        )

        #expect(proxy.serverID == "server1")
        #expect(proxy.name == "test_tool")
        #expect(proxy.description == "Test description")
        #expect(proxy.definition.name == "test_tool")
    }

    @Test("Creates AnyAgentTool with correct properties")
    func asAnyAgentTool() async throws {
        let coordinator = MockCoordinator()
        let proxy = MCPToolProxy(
            serverID: "server1",
            name: "my_tool",
            description: "My description",
            inputSchema: ["type": "object"],
            coordinator: coordinator
        )

        let tool = proxy.asAnyAgentTool()

        #expect(tool.name == "my_tool")
        #expect(tool.description == "My description")
        #expect(tool.definition.name == "my_tool")
    }

    // MARK: - Tool Call Routing

    @Test("Routes tool calls through coordinator")
    func routesCallsThroughCoordinator() async throws {
        let coordinator = MockCoordinator()
        await coordinator.setToolCallResult("success result")

        let proxy = MCPToolProxy(
            serverID: "server1",
            name: "my_tool",
            description: "Test tool",
            inputSchema: ["type": "object"],
            coordinator: coordinator
        )

        let result = try await proxy.call(argumentsJSON: #"{"key": "value"}"#)

        // Verify coordinator received the call
        let calls = await coordinator.toolCalls
        #expect(calls.count == 1)
        #expect(calls[0].serverID == "server1")
        #expect(calls[0].name == "my_tool")

        // Verify result
        if case .success(let value) = result {
            #expect(value == "success result")
        } else {
            Issue.record("Expected success result")
        }
    }

    @Test("Returns retry on timeout error")
    func returnsRetryOnTimeout() async throws {
        let coordinator = MockCoordinator()
        await coordinator.setToolCallError(MCPConnectionError.toolTimeout(
            serverID: "server1",
            tool: "slow_tool",
            timeout: .seconds(30)
        ))

        let proxy = MCPToolProxy(
            serverID: "server1",
            name: "slow_tool",
            description: "Slow tool",
            inputSchema: ["type": "object"],
            coordinator: coordinator
        )

        let result = try await proxy.call(argumentsJSON: "{}")

        if case .retry(let message) = result {
            #expect(message.contains("timed out"))
        } else {
            Issue.record("Expected retry result, got \(result)")
        }
    }

    @Test("Returns failure on server disconnected")
    func returnsFailureOnDisconnected() async throws {
        let coordinator = MockCoordinator()
        await coordinator.setToolCallError(MCPConnectionError.notConnected(serverID: "server1"))

        let proxy = MCPToolProxy(
            serverID: "server1",
            name: "my_tool",
            description: "Test tool",
            inputSchema: ["type": "object"],
            coordinator: coordinator
        )

        let result = try await proxy.call(argumentsJSON: "{}")

        if case .failure = result {
            // Expected
        } else {
            Issue.record("Expected failure result, got \(result)")
        }
    }

    @Test("Handles empty arguments")
    func handlesEmptyArguments() async throws {
        let coordinator = MockCoordinator()
        await coordinator.setToolCallResult("no args result")

        let proxy = MCPToolProxy(
            serverID: "server1",
            name: "no_args_tool",
            description: "Tool without arguments",
            inputSchema: ["type": "object"],
            coordinator: coordinator
        )

        // Test empty string
        _ = try await proxy.call(argumentsJSON: "")

        // Test empty object
        _ = try await proxy.call(argumentsJSON: "{}")

        let calls = await coordinator.toolCalls
        #expect(calls.count == 2)
        #expect(calls[0].arguments == nil)
        #expect(calls[1].arguments == nil)
    }
}

// MARK: - ToolFilter Tests

@Suite("Tool Filter")
struct ToolFilterTests {

    let entry1 = ToolEntry(
        serverID: "filesystem",
        name: "read_file",
        description: "Read a file",
        definition: ToolDefinition(name: "read_file", description: "", inputSchema: [:])
    )

    let entry2 = ToolEntry(
        serverID: "filesystem",
        name: "write_file",
        description: "Write a file",
        definition: ToolDefinition(name: "write_file", description: "", inputSchema: [:])
    )

    let entry3 = ToolEntry(
        serverID: "git",
        name: "git_status",
        description: "Git status",
        definition: ToolDefinition(name: "git_status", description: "", inputSchema: [:])
    )

    @Test(".all matches everything")
    func allMatchesEverything() {
        let filter = ToolFilter.all
        #expect(filter.matches(entry1))
        #expect(filter.matches(entry2))
        #expect(filter.matches(entry3))
    }

    @Test(".none matches nothing")
    func noneMatchesNothing() {
        let filter = ToolFilter.none
        #expect(!filter.matches(entry1))
        #expect(!filter.matches(entry2))
        #expect(!filter.matches(entry3))
    }

    @Test(".servers filters by server ID")
    func serversFilters() {
        let filter = ToolFilter.servers(["filesystem"])
        #expect(filter.matches(entry1))
        #expect(filter.matches(entry2))
        #expect(!filter.matches(entry3))
    }

    @Test(".tools filters by tool name")
    func toolsFilters() {
        let filter = ToolFilter.tools(["read_file", "git_status"])
        #expect(filter.matches(entry1))
        #expect(!filter.matches(entry2))
        #expect(filter.matches(entry3))
    }

    @Test(".pattern filters by regex")
    func patternFilters() {
        let filter = ToolFilter.pattern("^read_")
        #expect(filter.matches(entry1))
        #expect(!filter.matches(entry2))
        #expect(!filter.matches(entry3))
    }

    @Test(".and requires all filters to match")
    func andFilters() {
        let filter = ToolFilter.and([
            .servers(["filesystem"]),
            .pattern("^read_")
        ])
        #expect(filter.matches(entry1))
        #expect(!filter.matches(entry2))
        #expect(!filter.matches(entry3))
    }

    @Test(".or requires any filter to match")
    func orFilters() {
        let filter = ToolFilter.or([
            .tools(["read_file"]),
            .servers(["git"])
        ])
        #expect(filter.matches(entry1))
        #expect(!filter.matches(entry2))
        #expect(filter.matches(entry3))
    }

    @Test(".not inverts filter")
    func notFilters() {
        let filter = ToolFilter.not(.servers(["filesystem"]))
        #expect(!filter.matches(entry1))
        #expect(!filter.matches(entry2))
        #expect(filter.matches(entry3))
    }

    @Test(".toolIDs filters by qualified ID")
    func toolIDsFilters() {
        let filter = ToolFilter.toolIDs(["filesystem.read_file", "git.git_status"])
        #expect(filter.matches(entry1))
        #expect(!filter.matches(entry2))
        #expect(filter.matches(entry3))
    }
}

// MARK: - ToolMode Tests

@Suite("Tool Mode")
struct ToolModeTests {

    @Test("fullAccess mode matches all tools")
    func fullAccessMode() {
        let entry = ToolEntry(
            serverID: "test",
            name: "any_tool",
            description: "Any tool",
            definition: ToolDefinition(name: "any_tool", description: "", inputSchema: [:])
        )

        #expect(ToolMode.fullAccess.filter.matches(entry))
    }

    @Test("readOnly mode matches read patterns")
    func readOnlyMode() {
        let readEntry = ToolEntry(
            serverID: "test",
            name: "read_file",
            description: "Read",
            definition: ToolDefinition(name: "read_file", description: "", inputSchema: [:])
        )

        let writeEntry = ToolEntry(
            serverID: "test",
            name: "write_file",
            description: "Write",
            definition: ToolDefinition(name: "write_file", description: "", inputSchema: [:])
        )

        #expect(ToolMode.readOnly.filter.matches(readEntry))
        #expect(!ToolMode.readOnly.filter.matches(writeEntry))
    }

    @Test("none mode matches no tools")
    func noneMode() {
        let entry = ToolEntry(
            serverID: "test",
            name: "any_tool",
            description: "Any tool",
            definition: ToolDefinition(name: "any_tool", description: "", inputSchema: [:])
        )

        #expect(!ToolMode.none.filter.matches(entry))
    }

    @Test("Custom mode with filter")
    func customMode() {
        let mode = ToolMode(
            id: "custom",
            name: "Custom Mode",
            icon: "star",
            filter: .servers(["allowed-server"])
        )

        let allowedEntry = ToolEntry(
            serverID: "allowed-server",
            name: "tool",
            description: "Tool",
            definition: ToolDefinition(name: "tool", description: "", inputSchema: [:])
        )

        let deniedEntry = ToolEntry(
            serverID: "other-server",
            name: "tool",
            description: "Tool",
            definition: ToolDefinition(name: "tool", description: "", inputSchema: [:])
        )

        #expect(mode.filter.matches(allowedEntry))
        #expect(!mode.filter.matches(deniedEntry))
    }
}

// MARK: - ToolFilter Codable Tests

@Suite("Tool Filter Codable")
struct ToolFilterCodableTests {

    @Test("Encodes and decodes .all")
    func codableAll() throws {
        let filter = ToolFilter.all
        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(ToolFilter.self, from: data)
        #expect(decoded == filter)
    }

    @Test("Encodes and decodes .servers")
    func codableServers() throws {
        let filter = ToolFilter.servers(["a", "b", "c"])
        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(ToolFilter.self, from: data)
        #expect(decoded == filter)
    }

    @Test("Encodes and decodes nested filters")
    func codableNested() throws {
        let filter = ToolFilter.and([
            .servers(["server1"]),
            .not(.tools(["blocked_tool"]))
        ])
        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(ToolFilter.self, from: data)
        #expect(decoded == filter)
    }
}

// MARK: - Array Extension Tests

@Suite("Array Extensions")
struct ArrayExtensionTests {

    @Test("Array of proxies converts to AnyAgentTools")
    func arrayToAnyAgentTools() async throws {
        let coordinator = MockCoordinator()

        let proxies = [
            MCPToolProxy(
                serverID: "s1",
                name: "tool1",
                description: "Tool 1",
                inputSchema: [:],
                coordinator: coordinator
            ),
            MCPToolProxy(
                serverID: "s2",
                name: "tool2",
                description: "Tool 2",
                inputSchema: [:],
                coordinator: coordinator
            )
        ]

        let tools = proxies.asAnyAgentTools()

        #expect(tools.count == 2)
        #expect(tools[0].name == "tool1")
        #expect(tools[1].name == "tool2")
    }
}
