/// Callback router for MCP OAuth flows.
///
/// Routes OAuth callback URLs to the correct pending authorization flow.
/// This solves several problems:
/// - Race conditions: transport is registered BEFORE browser opens
/// - Multiple flows: each transport registered with unique ID
/// - Cleanup: timeouts prevent memory leaks from abandoned flows
///
/// Usage:
/// ```swift
/// // In AppDelegate (macOS)
/// func application(_ app: NSApplication, open urls: [URL]) {
///     MCP.handleCallback(urls.first!)
/// }
/// ```

import Foundation
import os.log

// MARK: - MCPCallbackRouter

/// Thread-safe router for OAuth callbacks.
///
/// Routes callbacks to the correct pending authorization flow by matching
/// the OAuth `state` parameter or server ID.
public actor MCPCallbackRouter: MCPCallbackRouting {
    /// Shared instance for simple usage.
    ///
    /// For testability, use dependency injection with the `MCPCallbackRouting`
    /// protocol instead of accessing this directly.
    public static let shared: any MCPCallbackRouting = MCPCallbackRouter()

    private let logger = Logger(subsystem: "Yrden", category: "MCPCallbackRouter")

    /// Registered transports that can receive callbacks.
    private var registeredTransports: [String: WeakTransport] = [:]

    /// Pending state-based flows (for the simplified API).
    private var pendingFlows: [String: PendingFlow] = [:]

    /// Default timeout for OAuth flows.
    public var defaultTimeout: Duration = .seconds(300)  // 5 minutes

    public init() {}

    // MARK: - Transport Registration

    /// Register a transport to receive OAuth callbacks.
    ///
    /// The transport will be registered by its server ID and any OAuth states.
    ///
    /// - Parameters:
    ///   - transport: The auto-auth transport to register
    ///   - serverID: Server identifier for routing
    public func register(transport: MCPAutoAuthTransport, serverID: String) {
        logger.info("Registering transport for server: \(serverID, privacy: .public)")
        registeredTransports[serverID] = WeakTransport(transport)
    }

    /// Unregister a transport.
    public func unregister(serverID: String) {
        logger.info("Unregistering transport for server: \(serverID, privacy: .public)")
        registeredTransports.removeValue(forKey: serverID)
    }

    // MARK: - State-Based Registration (Simplified API)

    /// Register a pending OAuth flow by state parameter.
    ///
    /// Call this BEFORE opening the browser to avoid race conditions.
    /// The continuation will be resumed when a matching callback arrives.
    ///
    /// - Parameters:
    ///   - state: OAuth state parameter (must be unique per flow)
    ///   - serverID: Server identifier for logging
    ///   - timeout: How long to wait before cancelling (default: 5 minutes)
    /// - Returns: The callback URL when received
    /// - Throws: `MCPOAuthError.cancelled` if timeout or manually cancelled
    public func waitForCallback(
        state: String,
        serverID: String,
        timeout: Duration? = nil
    ) async throws -> URL {
        let effectiveTimeout = timeout ?? defaultTimeout

        logger.info("Registering OAuth flow for state: \(state, privacy: .public), server: \(serverID, privacy: .public)")

        // Cancel any existing flow with same state (shouldn't happen, but be safe)
        if let existing = pendingFlows[state] {
            logger.warning("Cancelling existing flow for state: \(state, privacy: .public)")
            existing.continuation.resume(throwing: MCPOAuthError.cancelled)
            pendingFlows.removeValue(forKey: state)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let flow = PendingFlow(
                state: state,
                serverID: serverID,
                continuation: continuation,
                registeredAt: Date()
            )
            pendingFlows[state] = flow

            // Schedule timeout cleanup
            Task {
                try? await Task.sleep(for: effectiveTimeout)
                await self.timeoutFlow(state: state)
            }
        }
    }

    /// Cancel a pending flow.
    public func cancel(state: String) {
        guard let flow = pendingFlows.removeValue(forKey: state) else {
            logger.debug("No pending flow to cancel for state: \(state, privacy: .public)")
            return
        }

        logger.info("Cancelling OAuth flow for state: \(state, privacy: .public)")
        flow.continuation.resume(throwing: MCPOAuthError.cancelled)
    }

    /// Cancel all pending flows for a server.
    public func cancelAll(for serverID: String) {
        let toCancel = pendingFlows.filter { $0.value.serverID == serverID }

        for (state, flow) in toCancel {
            logger.info("Cancelling OAuth flow for server: \(serverID, privacy: .public)")
            flow.continuation.resume(throwing: MCPOAuthError.cancelled)
            pendingFlows.removeValue(forKey: state)
        }
    }

    // MARK: - Callback Handling

    /// Handle an OAuth callback URL.
    ///
    /// Routes the callback to either:
    /// 1. A registered transport (via server ID or state matching)
    /// 2. A pending state-based flow (simplified API)
    ///
    /// - Parameter url: The callback URL from OAuth redirect
    /// - Returns: `true` if callback was handled, `false` if no matching flow
    @discardableResult
    public func handleCallback(_ url: URL) async -> Bool {
        logger.info("Handling callback URL: \(url.absoluteString, privacy: .public)")

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let state = components?.queryItems?.first(where: { $0.name == "state" })?.value

        // Try state-based flow first (simplified API)
        if let state = state, let flow = pendingFlows.removeValue(forKey: state) {
            logger.info("Routing to state-based flow: \(state, privacy: .public)")
            flow.continuation.resume(returning: url)
            return true
        }

        // Try registered transports
        // Clean up dead weak references while iterating
        var deadKeys: [String] = []
        for (serverID, weakTransport) in registeredTransports {
            guard let transport = weakTransport.transport else {
                deadKeys.append(serverID)
                continue
            }

            // Try to route to this transport
            do {
                _ = try await transport.handleOAuthCallback(url: url)
                logger.info("Routed callback to transport: \(serverID, privacy: .public)")
                return true
            } catch {
                // This transport couldn't handle it, try next
                logger.debug("Transport \(serverID, privacy: .public) couldn't handle callback")
            }
        }

        // Clean up dead references
        for key in deadKeys {
            registeredTransports.removeValue(forKey: key)
        }

        logger.warning("No handler found for callback")
        return false
    }

    // MARK: - Private

    private func timeoutFlow(state: String) {
        guard let flow = pendingFlows.removeValue(forKey: state) else {
            return  // Already completed or cancelled
        }

        logger.warning("OAuth flow timed out for state: \(state, privacy: .public)")
        flow.continuation.resume(throwing: MCPOAuthError.cancelled)
    }
}

// MARK: - Supporting Types

private struct PendingFlow {
    let state: String
    let serverID: String
    let continuation: CheckedContinuation<URL, Error>
    let registeredAt: Date
}

/// Weak reference to a transport (avoids retain cycles).
///
/// @unchecked Sendable is safe here because:
/// - `weak var` reads/writes are atomic on Apple platforms
/// - The only mutation is setting to nil when transport deallocates
/// - We only read the value, never store back a non-nil value after init
private final class WeakTransport: @unchecked Sendable {
    weak var transport: MCPAutoAuthTransport?

    init(_ transport: MCPAutoAuthTransport) {
        self.transport = transport
    }
}

// MARK: - Global Convenience Functions

/// Handle an MCP OAuth callback URL asynchronously.
///
/// This is the preferred way to handle callbacks when in an async context:
/// ```swift
/// Task {
///     await mcpHandleCallbackAsync(url)
/// }
/// ```
///
/// - Parameter url: The callback URL from OAuth redirect
/// - Returns: `true` if callback was handled, `false` if no matching flow
@discardableResult
public func mcpHandleCallbackAsync(_ url: URL) async -> Bool {
    await MCPCallbackRouter.shared.handleCallback(url)
}

/// Handle an MCP OAuth callback URL (fire-and-forget).
///
/// Call this from your AppDelegate when receiving a URL:
/// ```swift
/// func application(_ app: NSApplication, open urls: [URL]) {
///     mcpHandleCallback(urls.first!)
/// }
/// ```
///
/// This routes the callback to the correct pending OAuth flow.
/// The callback is handled asynchronously - this function returns
/// immediately without waiting for the result.
///
/// - Parameter url: The callback URL from OAuth redirect
public func mcpHandleCallback(_ url: URL) {
    Task {
        await MCPCallbackRouter.shared.handleCallback(url)
    }
}
