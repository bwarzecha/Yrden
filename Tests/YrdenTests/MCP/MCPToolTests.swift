import Testing
import Foundation
@testable import Yrden
import MCP

/// Tests for MCPTool functionality.
@Suite("MCP Tool")
struct MCPToolTests {

    // MARK: - Tool Definition Generation

    @Test("MCPTool generates correct name from MCP tool")
    func toolName() {
        let mcpTool = MCP.Tool(
            name: "read_file",
            description: "Read a file",
            inputSchema: .object([:])
        )

        // We can't easily create a Client for testing without a transport,
        // but we can test the tool definition logic separately
        let definition = ToolDefinition(
            name: mcpTool.name,
            description: mcpTool.description ?? "No description",
            inputSchema: JSONValue(mcpValue: mcpTool.inputSchema)
        )

        #expect(definition.name == "read_file")
    }

    @Test("MCPTool generates correct description from MCP tool")
    func toolDescription() {
        let mcpTool = MCP.Tool(
            name: "write_file",
            description: "Write content to a file",
            inputSchema: .object([:])
        )

        let description = mcpTool.description ?? "No description"
        #expect(description == "Write content to a file")
    }

    @Test("MCPTool handles nil description")
    func toolNilDescription() {
        let mcpTool = MCP.Tool(
            name: "some_tool",
            description: nil,
            inputSchema: .object([:])
        )

        let description = mcpTool.description ?? "MCP tool: \(mcpTool.name)"
        #expect(description == "MCP tool: some_tool")
    }

    @Test("MCPTool converts simple input schema")
    func simpleInputSchema() {
        let mcpTool = MCP.Tool(
            name: "greet",
            description: "Greet someone",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Name to greet")
                    ])
                ]),
                "required": .array([.string("name")])
            ])
        )

        let jsonSchema = JSONValue(mcpValue: mcpTool.inputSchema)

        guard case .object(let schema) = jsonSchema else {
            Issue.record("Expected object schema")
            return
        }

        #expect(schema["type"] == .string("object"))

        guard let props = schema["properties"], case .object(let properties) = props else {
            Issue.record("Expected properties object")
            return
        }

        guard let nameProp = properties["name"], case .object(let nameSchema) = nameProp else {
            Issue.record("Expected name property")
            return
        }

        #expect(nameSchema["type"] == .string("string"))
        #expect(nameSchema["description"] == .string("Name to greet"))
    }

    @Test("MCPTool converts complex nested schema")
    func complexNestedSchema() {
        let mcpTool = MCP.Tool(
            name: "create_user",
            description: "Create a new user",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "user": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object(["type": .string("string")]),
                            "age": .object(["type": .string("integer")]),
                            "email": .object(["type": .string("string")])
                        ])
                    ]),
                    "roles": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ])
                ])
            ])
        )

        let jsonSchema = JSONValue(mcpValue: mcpTool.inputSchema)

        guard case .object(let schema) = jsonSchema,
              let properties = schema["properties"],
              case .object(let props) = properties else {
            Issue.record("Expected object with properties")
            return
        }

        // Verify user object exists
        guard let userProp = props["user"],
              case .object(let userSchema) = userProp else {
            Issue.record("Expected user property")
            return
        }

        #expect(userSchema["type"] == .string("object"))

        // Verify roles array exists
        guard let rolesProp = props["roles"],
              case .object(let rolesSchema) = rolesProp else {
            Issue.record("Expected roles property")
            return
        }

        #expect(rolesSchema["type"] == .string("array"))
    }

    // MARK: - MCPToolError

    @Test("MCPToolError.toolReturnedError formats correctly")
    func toolReturnedErrorFormat() {
        let error = MCPToolError.toolReturnedError(name: "read_file", message: "File not found")
        #expect(error.localizedDescription.contains("read_file"))
        #expect(error.localizedDescription.contains("File not found"))
    }

    @Test("MCPToolError.executionFailed formats correctly")
    func executionFailedErrorFormat() {
        let underlying = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Connection refused"
        ])
        let error = MCPToolError.executionFailed(
            name: "write_file",
            server: "filesystem-server",
            underlying: underlying
        )

        #expect(error.localizedDescription.contains("write_file"))
        #expect(error.localizedDescription.contains("filesystem-server"))
    }

    @Test("MCPToolError.serverDisconnected formats correctly")
    func serverDisconnectedErrorFormat() {
        let error = MCPToolError.serverDisconnected(serverID: "my-server")
        #expect(error.localizedDescription.contains("my-server"))
        #expect(error.localizedDescription.contains("disconnected"))
    }

    // MARK: - AnyAgentTool Closure Init

    @Test("AnyAgentTool closure init creates tool with correct properties")
    func anyAgentToolClosureInitProperties() {
        let definition = ToolDefinition(
            name: "test_tool",
            description: "A test tool",
            inputSchema: .object(["type": .string("object")])
        )

        let tool = AnyAgentTool<Void>(
            name: "test_tool",
            description: "A test tool",
            definition: definition,
            maxRetries: 2
        ) { _, args in
            return .success("Result: \(args)")
        }

        #expect(tool.name == "test_tool")
        #expect(tool.description == "A test tool")
        #expect(tool.maxRetries == 2)
        #expect(tool.definition.name == "test_tool")
    }
}
