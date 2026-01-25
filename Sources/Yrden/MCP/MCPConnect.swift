/// Simplified MCP connection API.
///
/// Provides convenience functions for connecting to MCP servers with minimal boilerplate.
///
/// Usage:
/// ```swift
/// // Stdio server (local process)
/// let server = try await mcpConnect("uvx mcp-server-fetch")
///
/// // HTTP server with OAuth (macOS)
/// let server = try await mcpConnect(
///     url: URL(string: "https://ai.todoist.net/mcp")!,
///     redirectScheme: "myapp"
/// )
/// ```

import Foundation
import os.log

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Simplified MCP Connection Functions

private let mcpLogger = Logger(subsystem: "Yrden", category: "MCPConnect")

/// Connect to an MCP server via stdio (local process).
///
/// Parses the command string and spawns the process with PATH augmentation
/// for common package managers (npm, uvx, etc.).
///
/// - Parameters:
///   - command: Command line string (e.g., "uvx mcp-server-fetch")
///   - environment: Optional environment variables as "KEY=value" lines
///   - name: Optional display name for the connection
/// - Returns: Connected MCP server
public func mcpConnect(
    _ command: String,
    environment: String? = nil,
    name: String? = nil
) async throws -> MCPServerConnection {
    mcpLogger.info("Connecting to stdio server: \(command, privacy: .public)")

    return try await MCPServerConnection.stdio(
        command,
        environment: environment,
        name: name
    )
}

/// Connect to an MCP server via HTTP (no authentication).
///
/// - Parameters:
///   - url: Server URL (e.g., "https://api.example.com/mcp")
///   - name: Optional display name for the connection
/// - Returns: Connected MCP server
public func mcpConnect(
    url: URL,
    name: String? = nil
) async throws -> MCPServerConnection {
    mcpLogger.info("Connecting to HTTP server: \(url.absoluteString, privacy: .public)")

    return try await MCPServerConnection.http(
        url: url,
        name: name
    )
}

#if os(macOS)

/// Connect to an MCP server via HTTP with OAuth authentication (macOS).
///
/// Uses auto-discovery to find OAuth endpoints. Opens the system browser
/// for user authentication and handles the callback automatically.
///
/// **Important:** You must call `mcpHandleCallback(url)` from your
/// AppDelegate when receiving the OAuth redirect:
/// ```swift
/// class AppDelegate: NSObject, NSApplicationDelegate {
///     func application(_ app: NSApplication, open urls: [URL]) {
///         mcpHandleCallback(urls.first!)
///     }
/// }
/// ```
///
/// - Parameters:
///   - url: Server URL (e.g., "https://ai.todoist.net/mcp")
///   - redirectScheme: Custom URL scheme for OAuth callback (e.g., "myapp")
///   - tokenStorage: Token storage (defaults to KeychainTokenStorage)
///   - clientName: Client name for dynamic registration
///   - onProgress: Progress callback for OAuth flow
///   - name: Optional display name for the connection
/// - Returns: Connected MCP server
/// - Throws: `MCPOAuthError` if authentication fails
public func mcpConnect(
    url: URL,
    redirectScheme: String,
    tokenStorage: MCPTokenStorage? = nil,
    clientName: String = "Yrden MCP Client",
    onProgress: (@Sendable (MCPOAuthProgress) -> Void)? = nil,
    name: String? = nil
) async throws -> MCPServerConnection {
    mcpLogger.info("Connecting to OAuth server: \(url.absoluteString, privacy: .public)")

    let effectiveStorage = tokenStorage ?? KeychainTokenStorage()
    let serverID = url.host ?? url.absoluteString

    // Create delegate that opens URL and reports progress
    let delegate: SimpleOAuthDelegate
    if let onProgress = onProgress {
        delegate = SimpleOAuthDelegate.macOS(onProgress: onProgress)
    } else {
        delegate = SimpleOAuthDelegate.macOS()
    }

    // Use autoAuth which handles discovery, registration, and OAuth flow
    let connection = try await MCPServerConnection.autoAuth(
        url: url,
        storage: effectiveStorage,
        delegate: delegate,
        redirectScheme: redirectScheme,
        clientName: clientName,
        id: serverID,
        name: name
    )

    // Register the transport with the callback router for future callbacks
    let transport = await connection.autoAuthTransport
    if let transport = transport {
        await MCPCallbackRouter.shared.register(transport: transport, serverID: serverID)
    }

    return connection
}

#endif
