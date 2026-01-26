/// Command line and environment parsing utilities for MCP.
///
/// These functions help parse command strings and environment variables
/// for MCP server connections.

import Foundation

// MARK: - Command Line Parsing

/// Parse a command line string into command and arguments.
///
/// Handles simple space-separated arguments. For complex quoting,
/// pass arguments as an array to `MCPServerConnection.stdio(command:arguments:)`.
///
/// - Parameter commandLine: Full command line (e.g., "npx -y @modelcontextprotocol/server-filesystem /tmp")
/// - Returns: Tuple of (command, arguments)
public func parseCommandLine(_ commandLine: String) -> (command: String, arguments: [String]) {
    let parts = commandLine
        .trimmingCharacters(in: .whitespaces)
        .components(separatedBy: .whitespaces)
        .filter { !$0.isEmpty }

    guard let command = parts.first else {
        return ("", [])
    }

    return (command, Array(parts.dropFirst()))
}

// MARK: - Environment Parsing

/// Parse environment variables from a string.
///
/// Expects "KEY=VALUE" format, one per line.
///
/// - Parameter environment: Environment string (e.g., "API_KEY=xxx\nDEBUG=1")
/// - Returns: Dictionary of environment variables, or nil if input is nil/empty
public func parseEnvironment(_ environment: String?) -> [String: String]? {
    guard let env = environment?.trimmingCharacters(in: .whitespacesAndNewlines),
          !env.isEmpty else {
        return nil
    }

    var result: [String: String] = [:]
    for line in env.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }

        let parts = trimmed.components(separatedBy: "=")
        guard parts.count >= 2 else { continue }

        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts.dropFirst().joined(separator: "=")
        result[key] = value
    }

    return result.isEmpty ? nil : result
}
