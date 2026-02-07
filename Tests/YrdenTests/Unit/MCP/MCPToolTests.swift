import Testing
import Foundation
@testable import Yrden
import MCP

/// Tests for MCPToolError formatting.
@Suite("MCP Tool Error")
struct MCPToolTests {

    // MARK: - MCPToolError

    @Test("MCPToolError.toolReturnedError formats correctly")
    func toolReturnedErrorFormat() {
        let error = MCPToolError.toolReturnedError(name: "read_file", message: "File not found")
        #expect(error.localizedDescription.contains("read_file"))
        #expect(error.localizedDescription.contains("File not found"))
    }

    @Test("MCPToolError.executionFailed formats correctly")
    func executionFailedErrorFormat() {
        let error = MCPToolError.executionFailed(
            name: "write_file",
            server: "filesystem-server",
            message: "Connection refused"
        )

        #expect(error.localizedDescription.contains("write_file"))
        #expect(error.localizedDescription.contains("filesystem-server"))
        #expect(error.localizedDescription.contains("Connection refused"))
    }

    @Test("MCPToolError.serverDisconnected formats correctly")
    func serverDisconnectedErrorFormat() {
        let error = MCPToolError.serverDisconnected(serverID: "my-server")
        #expect(error.localizedDescription.contains("my-server"))
        #expect(error.localizedDescription.contains("disconnected"))
    }

}
