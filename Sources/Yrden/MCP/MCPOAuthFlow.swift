/// OAuth 2.0 authorization flow handler for MCP servers.
///
/// Manages the complete OAuth flow including:
/// - Building authorization URLs with PKCE
/// - Handling OAuth callbacks
/// - Exchanging authorization codes for tokens
/// - Refreshing expired tokens

import Foundation

// MARK: - MCPOAuthFlow

/// Handles OAuth 2.0 authorization code flow with PKCE.
public actor MCPOAuthFlow {
    /// OAuth configuration.
    private let config: MCPOAuthConfig

    /// Token storage.
    private let storage: any MCPTokenStorage

    /// Server ID for this flow.
    private let serverID: String

    /// In-progress OAuth state (during authorization).
    private var pendingState: MCPOAuthState?

    /// URL session for token requests.
    private let session: URLSession

    /// Create an OAuth flow handler.
    ///
    /// - Parameters:
    ///   - config: OAuth configuration
    ///   - storage: Token storage
    ///   - serverID: Server identifier
    ///   - session: URL session (defaults to shared)
    public init(
        config: MCPOAuthConfig,
        storage: any MCPTokenStorage,
        serverID: String,
        session: URLSession = .shared
    ) {
        self.config = config
        self.storage = storage
        self.serverID = serverID
        self.session = session
    }

    // MARK: - Authorization

    /// Build the authorization URL to open in a browser.
    ///
    /// Call this to start the OAuth flow, then open the returned URL
    /// in a browser. The user will authenticate and be redirected back
    /// to your app's callback URL.
    ///
    /// - Returns: URL to open in browser
    public func buildAuthorizationURL() -> URL {
        let state = MCPOAuthState.generate(serverID: serverID, usePKCE: config.usePKCE)
        self.pendingState = state

        var components = URLComponents(url: config.authorizationURL, resolvingAgainstBaseURL: true)!

        var queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "state", value: state.state)
        ]

        if !config.scopes.isEmpty {
            queryItems.append(URLQueryItem(name: "scope", value: config.scopes.joined(separator: config.scopeSeparator)))
        }

        if let pkce = state.pkce {
            queryItems.append(URLQueryItem(name: "code_challenge", value: pkce.codeChallenge))
            queryItems.append(URLQueryItem(name: "code_challenge_method", value: pkce.codeChallengeMethod))
        }

        if let additionalParams = config.additionalParams {
            for (key, value) in additionalParams {
                queryItems.append(URLQueryItem(name: key, value: value))
            }
        }

        components.queryItems = queryItems
        return components.url!
    }

    /// Handle the OAuth callback URL.
    ///
    /// Call this when your app receives the OAuth redirect callback.
    /// Extracts the authorization code and exchanges it for tokens.
    ///
    /// - Parameter url: The callback URL (e.g., myapp://oauth/callback?code=...&state=...)
    /// - Returns: OAuth tokens
    /// - Throws: MCPOAuthError if the callback is invalid or token exchange fails
    public func handleCallback(url: URL) async throws -> MCPOAuthTokens {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw MCPOAuthError.invalidCallbackURL(url.absoluteString)
        }

        let queryItems = components.queryItems ?? []
        let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })

        // Check for error response
        if let error = params["error"] {
            let description = params["error_description"]
            throw MCPOAuthError.authorizationDenied(description ?? error)
        }

        // Validate state
        guard let state = params["state"],
              let pendingState = pendingState,
              state == pendingState.state else {
            throw MCPOAuthError.stateMismatch
        }

        // Get authorization code
        guard let code = params["code"] else {
            throw MCPOAuthError.invalidCallbackURL("Missing authorization code")
        }

        // Exchange code for tokens
        let tokens = try await exchangeCodeForTokens(code: code, pkce: pendingState.pkce)

        // Store tokens
        try await storage.store(tokens: tokens, for: serverID)

        // Clear pending state
        self.pendingState = nil

        return tokens
    }

    /// Cancel the in-progress OAuth flow.
    public func cancel() {
        pendingState = nil
    }

    // MARK: - Token Exchange

    /// Exchange authorization code for tokens.
    private func exchangeCodeForTokens(code: String, pkce: PKCEParameters?) async throws -> MCPOAuthTokens {
        var body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "client_id": config.clientId
        ]

        if let clientSecret = config.clientSecret {
            body["client_secret"] = clientSecret
        }

        if let pkce = pkce {
            body["code_verifier"] = pkce.codeVerifier
        }

        // Include resource parameter per RFC 8707 (required by MCP spec)
        if let resource = config.additionalParams?["resource"] {
            body["resource"] = resource
        }

        return try await performTokenRequest(body: body)
    }

    // MARK: - Token Refresh

    /// Refresh the access token using the refresh token.
    ///
    /// - Returns: New tokens
    /// - Throws: MCPOAuthError if refresh fails
    public func refreshTokens() async throws -> MCPOAuthTokens {
        guard let existingTokens = try await storage.retrieve(for: serverID) else {
            throw MCPOAuthError.notAuthenticated
        }

        guard let refreshToken = existingTokens.refreshToken else {
            throw MCPOAuthError.tokenRefreshFailed("No refresh token available")
        }

        var body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientId
        ]

        if let clientSecret = config.clientSecret {
            body["client_secret"] = clientSecret
        }

        let newTokens = try await performTokenRequest(body: body)

        // Store updated tokens (keep old refresh token if new one not provided)
        let tokensToStore: MCPOAuthTokens
        if newTokens.refreshToken == nil, let oldRefreshToken = existingTokens.refreshToken {
            tokensToStore = MCPOAuthTokens(
                accessToken: newTokens.accessToken,
                tokenType: newTokens.tokenType,
                refreshToken: oldRefreshToken,
                expiresIn: newTokens.expiresAt.map { Int($0.timeIntervalSince(newTokens.obtainedAt)) },
                scopes: newTokens.scopes,
                obtainedAt: newTokens.obtainedAt
            )
        } else {
            tokensToStore = newTokens
        }

        try await storage.store(tokens: tokensToStore, for: serverID)

        return tokensToStore
    }

    // MARK: - Token Access

    /// Get the current access token, refreshing if expired.
    ///
    /// - Returns: Valid access token
    /// - Throws: MCPOAuthError if not authenticated or refresh fails
    public func getValidAccessToken() async throws -> String {
        guard var tokens = try await storage.retrieve(for: serverID) else {
            throw MCPOAuthError.notAuthenticated
        }

        if tokens.isExpired && tokens.canRefresh {
            tokens = try await refreshTokens()
        }

        return tokens.accessToken
    }

    /// Check if we have stored tokens (may be expired).
    public func hasTokens() async throws -> Bool {
        try await storage.retrieve(for: serverID) != nil
    }

    /// Clear stored tokens (logout).
    public func clearTokens() async throws {
        try await storage.delete(for: serverID)
    }

    // MARK: - Private

    /// Perform a token endpoint request.
    private func performTokenRequest(body: [String: String]) async throws -> MCPOAuthTokens {
        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let bodyString = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPOAuthError.networkError(URLError(.badServerResponse))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // Try to parse error response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String {
                let description = json["error_description"] as? String
                throw MCPOAuthError.tokenExchangeFailed("\(error): \(description ?? "No description")")
            }
            throw MCPOAuthError.tokenExchangeFailed("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPOAuthError.invalidTokenResponse("Could not parse JSON")
        }

        return try MCPOAuthTokens(from: json)
    }
}

// MARK: - OAuth Delegate

/// Delegate protocol for OAuth UI interactions.
public protocol MCPOAuthDelegate: AnyObject, Sendable {
    /// Called when the authorization URL should be opened in a browser.
    ///
    /// Implement this to open the URL in Safari, ASWebAuthenticationSession, etc.
    ///
    /// - Parameter url: Authorization URL to open
    func openAuthorizationURL(_ url: URL) async throws

    /// Called when re-authentication is needed (token expired with no refresh token).
    ///
    /// - Parameters:
    ///   - serverID: Server that needs re-authentication
    ///   - reason: Human-readable reason
    /// - Returns: True if user wants to re-authenticate, false to cancel
    func promptReauthentication(for serverID: String, reason: String) async -> Bool

    /// Called with authentication progress updates.
    ///
    /// - Parameter state: Current state of the OAuth flow
    func authenticationProgress(_ state: MCPOAuthProgress)
}

/// Progress states during OAuth flow.
public enum MCPOAuthProgress: Sendable {
    /// Opening browser for authorization.
    case openingBrowser

    /// Waiting for user to authenticate in browser.
    case waitingForUser

    /// Exchanging authorization code for tokens.
    case exchangingCode

    /// Refreshing expired tokens.
    case refreshingTokens

    /// Authentication complete.
    case complete

    /// Authentication failed.
    case failed(Error)
}

// MARK: - OAuth Coordinator

/// Coordinates the full OAuth flow with UI integration.
public actor MCPOAuthCoordinator {
    private let flow: MCPOAuthFlow
    private weak var delegate: (any MCPOAuthDelegate)?

    /// Continuation for pending authorization callback.
    private var pendingCallback: CheckedContinuation<URL, Error>?

    public init(flow: MCPOAuthFlow, delegate: (any MCPOAuthDelegate)?) {
        self.flow = flow
        self.delegate = delegate
    }

    /// Start the OAuth flow.
    ///
    /// Opens the browser for authorization and waits for the callback.
    ///
    /// - Returns: OAuth tokens
    public func authorize() async throws -> MCPOAuthTokens {
        print("[Coordinator] authorize() starting")
        await delegate?.authenticationProgress(.openingBrowser)

        let authURL = await flow.buildAuthorizationURL()

        // Open browser
        try await delegate?.openAuthorizationURL(authURL)

        await delegate?.authenticationProgress(.waitingForUser)

        print("[Coordinator] Waiting for callback continuation")
        // Wait for callback
        let callbackURL = try await withCheckedThrowingContinuation { continuation in
            self.pendingCallback = continuation
            print("[Coordinator] Continuation stored, waiting...")
        }
        print("[Coordinator] Got callback URL, exchanging code")

        await delegate?.authenticationProgress(.exchangingCode)

        // Handle callback
        let tokens = try await flow.handleCallback(url: callbackURL)
        print("[Coordinator] Got tokens, completing")

        await delegate?.authenticationProgress(.complete)

        print("[Coordinator] authorize() returning tokens")
        return tokens
    }

    /// Receive the OAuth callback URL.
    ///
    /// Call this when your app receives the callback URL scheme.
    ///
    /// - Parameter url: Callback URL
    public func receiveCallback(url: URL) {
        print("[Coordinator] receiveCallback() called, pendingCallback=\(pendingCallback != nil)")
        pendingCallback?.resume(returning: url)
        pendingCallback = nil
        print("[Coordinator] receiveCallback() done")
    }

    /// Cancel the in-progress flow.
    public func cancel() {
        pendingCallback?.resume(throwing: MCPOAuthError.cancelled)
        pendingCallback = nil
        Task {
            await flow.cancel()
        }
    }
}
