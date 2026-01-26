/// Protocol for OAuth callback routing.
///
/// Enables dependency injection for testing and custom implementations.
/// The default implementation is `MCPCallbackRouter`.
///
/// Example usage with dependency injection:
/// ```swift
/// // In production
/// let connection = try await mcpConnect(url: serverURL, callbackRouter: nil)  // Uses default
///
/// // In tests
/// let mockRouter = MockCallbackRouter()
/// let connection = try await mcpConnect(url: serverURL, callbackRouter: mockRouter)
/// ```

import Foundation

// MARK: - MCPCallbackRouting Protocol

/// Protocol for routing OAuth callbacks to pending authorization flows.
///
/// Implementations must be actors to ensure thread-safe access to
/// registered transports and pending flows.
public protocol MCPCallbackRouting: Actor, Sendable {
    /// Register a transport to receive OAuth callbacks.
    ///
    /// - Parameters:
    ///   - transport: The auto-auth transport to register
    ///   - serverID: Server identifier for routing
    func register(transport: MCPAutoAuthTransport, serverID: String)

    /// Unregister a transport.
    ///
    /// - Parameter serverID: Server identifier to unregister
    func unregister(serverID: String)

    /// Wait for an OAuth callback matching the given state.
    ///
    /// Call this BEFORE opening the browser to avoid race conditions.
    ///
    /// - Parameters:
    ///   - state: OAuth state parameter (must be unique per flow)
    ///   - serverID: Server identifier for logging
    ///   - timeout: How long to wait before cancelling
    /// - Returns: The callback URL when received
    /// - Throws: `MCPOAuthError.cancelled` if timeout or manually cancelled
    func waitForCallback(
        state: String,
        serverID: String,
        timeout: Duration?
    ) async throws -> URL

    /// Cancel a pending OAuth flow.
    ///
    /// - Parameter state: OAuth state parameter to cancel
    func cancel(state: String)

    /// Cancel all pending flows for a server.
    ///
    /// - Parameter serverID: Server identifier whose flows to cancel
    func cancelAll(for serverID: String)

    /// Handle an OAuth callback URL.
    ///
    /// Routes the callback to the appropriate pending flow.
    ///
    /// - Parameter url: The callback URL from OAuth redirect
    /// - Returns: `true` if callback was handled, `false` if no matching flow
    @discardableResult
    func handleCallback(_ url: URL) async -> Bool
}
