/// Auto-authenticating MCP Transport
///
/// Wraps an HTTP transport and automatically handles the MCP OAuth flow:
/// 1. Detects 401 responses
/// 2. Discovers authorization server via protected resource metadata
/// 3. Performs dynamic client registration (if available)
/// 4. Initiates OAuth flow with PKCE
/// 5. Handles callback and stores tokens
/// 6. Retries failed request with access token
///
/// This implements the full MCP authorization spec (2025-06-18).

import Foundation
import Logging
import MCP

// MARK: - Token Holder

/// Thread-safe token holder for requestModifier access.
/// Used to inject auth tokens into httpTransport requests.
///
/// @unchecked Sendable is safe here because:
/// - All access to mutable state (`_token`) is protected by NSLock
/// - NSLock provides proper memory barriers for thread safety
/// - The class is final (no subclass can break invariants)
private final class TokenHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _token: String?

    var token: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _token
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _token = newValue
        }
    }
}

// MARK: - Auto Auth Transport

/// HTTP transport with automatic OAuth discovery and authentication.
///
/// When the MCP server returns 401, this transport automatically:
/// 1. Fetches protected resource metadata
/// 2. Discovers authorization server endpoints
/// 3. Registers as a client (dynamic registration)
/// 4. Opens browser for user authorization
/// 5. Handles OAuth callback
/// 6. Retries the request with the access token
public actor MCPAutoAuthTransport: Transport {
    /// Logger for transport events
    public nonisolated let logger: Logger

    /// The underlying HTTP transport
    private let httpTransport: HTTPClientTransport

    /// The MCP server URL (resource)
    public let serverURL: URL

    /// Message stream for receiving data
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    /// Token storage
    private let storage: any MCPTokenStorage

    /// Server ID for token storage
    private let serverID: String

    /// OAuth delegate for UI interactions
    private weak var delegate: (any MCPOAuthDelegate)?

    /// Custom redirect scheme
    private let redirectScheme: String

    /// Client name for dynamic registration
    private let clientName: String

    /// Discovery handler
    private let discovery: MCPAuthDiscovery

    /// Current OAuth flow (if in progress)
    private var currentFlow: MCPOAuthFlow?

    /// Pending OAuth coordinator
    private var oauthCoordinator: MCPOAuthCoordinator?

    /// Whether we're currently authenticating
    private var isAuthenticating: Bool = false

    /// Discovered OAuth config (cached)
    private var discoveredConfig: DiscoveredOAuthConfig?

    /// URL session
    private let session: URLSession

    /// Optional logging callback for debugging
    private let logCallback: (@Sendable (String) -> Void)?

    /// Token holder for injecting auth into httpTransport requests
    private let tokenHolder: TokenHolder

    /// Create an auto-authenticating MCP transport.
    ///
    /// - Parameters:
    ///   - serverURL: The MCP server URL
    ///   - storage: Token storage implementation
    ///   - serverID: Unique ID for token storage (defaults to server host)
    ///   - delegate: OAuth UI delegate
    ///   - redirectScheme: Custom URL scheme for OAuth callback
    ///   - clientName: Client name for dynamic registration
    ///   - session: URL session for HTTP requests
    ///   - logCallback: Optional callback for debug logging (appears in app UI)
    public init(
        serverURL: URL,
        storage: any MCPTokenStorage = InMemoryTokenStorage(),
        serverID: String? = nil,
        delegate: (any MCPOAuthDelegate)?,
        redirectScheme: String = "yrden-mcp",
        clientName: String = "Yrden MCP Client",
        session: URLSession = .shared,
        logger: Logger? = nil,
        logCallback: (@Sendable (String) -> Void)? = nil
    ) {
        self.serverURL = serverURL
        self.storage = storage
        self.serverID = serverID ?? serverURL.host ?? "mcp-server"
        self.delegate = delegate
        self.redirectScheme = redirectScheme
        self.clientName = clientName
        self.session = session
        self.discovery = MCPAuthDiscovery(session: session)
        self.logCallback = logCallback

        self.logger = logger ?? Logger(label: "yrden.mcp.autoauth")

        // Create message stream
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation

        // Create token holder for injecting auth into requests
        let holder = TokenHolder()
        self.tokenHolder = holder

        // Create HTTP transport with request modifier that injects auth token
        // The requestModifier is called synchronously, so we use TokenHolder
        // which can be safely read from the closure
        self.httpTransport = HTTPClientTransport(
            endpoint: serverURL,
            streaming: true,
            requestModifier: { request in
                var modifiedRequest = request
                if let token = holder.token {
                    modifiedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                return modifiedRequest
            }
        )
    }

    // MARK: - Transport Protocol

    public func connect() async throws {
        debugLog("[connect] Starting connection to \(serverURL)")
        try await httpTransport.connect()
        debugLog("[connect] HTTP transport connected")

        // Forward messages from underlying transport to our stream
        // NOTE: We do NOT call finish() here because we may need to yield
        // responses from sendWithToken() which bypasses httpTransport.
        // The stream is only finished in disconnect().
        Task {
            debugLog("[connect] Starting message forwarding task")
            do {
                for try await data in await httpTransport.receive() {
                    debugLog("[connect] Forwarding message: \(data.count) bytes")
                    messageContinuation.yield(data)
                }
                debugLog("[connect] httpTransport stream ended normally")
            } catch {
                debugLog("[connect] httpTransport stream error: \(error)")
            }
            // Do NOT call messageContinuation.finish() here!
            // sendWithToken() may still need to yield responses.
        }
    }

    /// Helper for debug logging that also calls the callback
    private func debugLog(_ message: String) {
        logger.info("\(message)")
        logCallback?(message)
    }

    public func disconnect() async {
        debugLog("[disconnect] Disconnecting")
        await httpTransport.disconnect()
        currentFlow = nil
        oauthCoordinator = nil
        // Finish the message stream so readers know we're done
        messageContinuation.finish()
        debugLog("[disconnect] Done")
    }

    public func send(_ data: Data) async throws {
        debugLog("[send] Called with \(data.count) bytes")

        // Update token holder with current token (if any)
        // The requestModifier in httpTransport will inject it
        if let token = try? await getAccessToken() {
            debugLog("[send] Setting token in holder for auth injection")
            tokenHolder.token = token
        } else {
            debugLog("[send] No token available, will try without auth")
            tokenHolder.token = nil
        }

        // Send via httpTransport - it handles SSE, sessions, etc.
        do {
            try await httpTransport.send(data)
            debugLog("[send] Sent successfully via httpTransport")
        } catch {
            debugLog("[send] Error: \(error)")
            // Check if this is a 401 that needs auth
            if isAuthenticationRequired(error: error) {
                debugLog("[send] 401 detected, starting OAuth flow...")
                try await handleAuthenticationRequired()
                debugLog("[send] OAuth complete, retrying with token")
                // Update token holder with new token
                if let token = try await getAccessToken() {
                    debugLog("[send] Got token, updating holder and retrying")
                    tokenHolder.token = token
                    try await httpTransport.send(data)
                    debugLog("[send] Retry successful!")
                } else {
                    debugLog("[send] ERROR: No token after OAuth!")
                    throw MCPOAuthError.notAuthenticated
                }
            } else {
                debugLog("[send] Non-auth error, rethrowing")
                throw error
            }
        }
    }

    public nonisolated func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }

    // MARK: - OAuth Flow

    /// Handle OAuth callback URL.
    ///
    /// Call this when your app receives the OAuth redirect.
    ///
    /// - Parameter url: The callback URL
    /// - Returns: The obtained tokens
    public func handleOAuthCallback(url: URL) async throws -> MCPOAuthTokens {
        debugLog("[handleOAuthCallback] Called with URL")

        guard let coordinator = oauthCoordinator else {
            debugLog("[handleOAuthCallback] ERROR: No coordinator!")
            throw MCPOAuthError.invalidCallbackURL("No OAuth flow in progress")
        }

        debugLog("[handleOAuthCallback] Signaling coordinator")

        // Signal the coordinator to continue - it will handle the callback and exchange tokens
        // handleAuthenticationRequired() is already waiting on coordinator.authorize()
        await coordinator.receiveCallback(url: url)

        debugLog("[handleOAuthCallback] Coordinator signaled, waiting for token exchange...")

        // Wait a moment for tokens to be stored by the coordinator
        // The coordinator.authorize() handles the token exchange
        try await Task.sleep(for: .milliseconds(500))

        debugLog("[handleOAuthCallback] Retrieving tokens from storage")

        // Return the tokens from storage (coordinator stored them via flow.handleCallback)
        guard let tokens = try await storage.retrieve(for: serverID) else {
            debugLog("[handleOAuthCallback] ERROR: No tokens in storage after callback!")
            throw MCPOAuthError.notAuthenticated
        }

        debugLog("[handleOAuthCallback] Got tokens, returning")
        return tokens
    }

    /// Manually trigger authentication.
    ///
    /// Use this to proactively authenticate before making requests.
    public func authenticate() async throws {
        try await handleAuthenticationRequired()
    }

    /// Clear stored tokens.
    public func logout() async throws {
        try await storage.delete(for: serverID)
        discoveredConfig = nil
    }

    // MARK: - Private

    /// Get current access token, refreshing if needed.
    private func getAccessToken() async throws -> String? {
        guard let tokens = try await storage.retrieve(for: serverID) else {
            return nil
        }

        if tokens.isExpired && tokens.canRefresh {
            if let flow = currentFlow {
                let newTokens = try await flow.refreshTokens()
                return newTokens.accessToken
            }
        }

        return tokens.accessToken
    }

    /// Check if error indicates authentication is required.
    private func isAuthenticationRequired(error: Error) -> Bool {
        // Check for 401 errors
        if let mcpError = error as? MCPError {
            // MCPError.internalError contains the message
            return String(describing: mcpError).contains("401") ||
                   String(describing: mcpError).contains("Authentication required")
        }
        return false
    }

    /// Handle 401 response - discover and authenticate.
    private func handleAuthenticationRequired() async throws {
        debugLog("[handleAuthRequired] Starting authentication flow")

        guard !isAuthenticating else {
            debugLog("[handleAuthRequired] Already authenticating, waiting...")
            // Wait for ongoing authentication
            while isAuthenticating {
                try await Task.sleep(for: .milliseconds(100))
            }
            debugLog("[handleAuthRequired] Other auth completed, returning")
            return
        }

        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            // 1. Discover authorization endpoints
            debugLog("[handleAuthRequired] Discovering auth endpoints...")
            let (resourceMetadata, authServerMetadata) = try await discoverAuthEndpoints()
            debugLog("[handleAuthRequired] Found auth server: \(authServerMetadata.authorizationEndpoint)")

            // 2. Get or register client ID
            let clientId: String
            let clientSecret: String?

            if let registration = try await discovery.registerClientIfNeeded(
                authServer: authServerMetadata,
                redirectURI: "\(redirectScheme)://oauth/callback",
                clientName: clientName,
                scopes: resourceMetadata.scopesSupported
            ) {
                clientId = registration.clientId
                clientSecret = registration.clientSecret
            } else {
                // No dynamic registration - we need a pre-configured client ID
                throw MCPAuthDiscoveryError.registrationFailed(
                    "Server doesn't support dynamic registration. " +
                    "Please provide a client ID through MCPOAuthConfig."
                )
            }

            // 3. Create OAuth config
            let config = MCPOAuthConfig(
                clientId: clientId,
                clientSecret: clientSecret,
                authorizationURL: authServerMetadata.authorizationEndpoint,
                tokenURL: authServerMetadata.tokenEndpoint,
                scopes: resourceMetadata.scopesSupported ?? [],
                redirectScheme: redirectScheme,
                additionalParams: ["resource": serverURL.absoluteString],
                usePKCE: authServerMetadata.supportsPKCE
            )

            // 4. Create OAuth flow
            let flow = MCPOAuthFlow(
                config: config,
                storage: storage,
                serverID: serverID,
                session: session
            )
            self.currentFlow = flow

            // 5. Create coordinator and start flow
            debugLog("[handleAuthRequired] Creating coordinator and starting OAuth")
            let coordinator = MCPOAuthCoordinator(flow: flow, delegate: delegate)
            self.oauthCoordinator = coordinator

            debugLog("[handleAuthRequired] Calling coordinator.authorize() - will block until callback")

            // 6. Start authorization (blocks until callback is received and tokens exchanged)
            // The coordinator handles delegate callbacks (.openingBrowser, .waitingForUser, .complete)
            _ = try await coordinator.authorize()

            debugLog("[handleAuthRequired] authorize() RETURNED - OAuth complete!")

            // Clean up coordinator reference
            self.oauthCoordinator = nil
            debugLog("[handleAuthRequired] Cleanup done, returning to send()")

        } catch {
            debugLog("[handleAuthRequired] ERROR: \(error)")
            self.oauthCoordinator = nil
            throw error
        }
    }

    /// Discover authorization endpoints from MCP server.
    private func discoverAuthEndpoints() async throws -> (ProtectedResourceMetadata, AuthorizationServerMetadata) {
        // Try to fetch resource metadata directly
        let resourceMetadataURL = await discovery.resourceMetadataURL(for: serverURL)
        let resourceMetadata = try await discovery.fetchResourceMetadata(from: resourceMetadataURL)

        guard let authServerURL = resourceMetadata.authorizationServers.first else {
            throw MCPAuthDiscoveryError.noAuthorizationServers
        }

        let authMetadataURL = await discovery.authServerMetadataURL(for: authServerURL)
        let authServerMetadata = try await discovery.fetchAuthServerMetadata(from: authMetadataURL)

        return (resourceMetadata, authServerMetadata)
    }
}

