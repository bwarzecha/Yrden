/// Authenticated HTTP transport for MCP servers with OAuth.
///
/// Wraps the standard HTTP transport with OAuth token management:
/// - Automatically injects Authorization header
/// - Refreshes tokens on 401 responses
/// - Supports re-authentication via delegate

import Foundation
import MCP
import Logging

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - AuthenticatedHTTPTransport

/// HTTP transport with OAuth authentication and automatic token refresh.
///
/// This transport wraps the standard `HTTPClientTransport` from the MCP SDK
/// and adds OAuth support:
///
/// - Automatically adds Bearer token to requests
/// - Refreshes tokens when they expire
/// - Handles 401 responses by refreshing and retrying
/// - Supports re-authentication flow when tokens can't be refreshed
///
/// ## Usage
/// ```swift
/// let flow = MCPOAuthFlow(config: oauthConfig, storage: storage, serverID: "server1")
/// let transport = AuthenticatedHTTPTransport(
///     endpoint: URL(string: "https://mcp.example.com")!,
///     oauthFlow: flow,
///     delegate: myDelegate
/// )
///
/// let client = Client(name: "MyApp", version: "1.0")
/// try await client.connect(transport: transport)
/// ```
public actor AuthenticatedHTTPTransport: Transport {
    public nonisolated let logger: Logger

    /// The server endpoint URL.
    private let endpoint: URL

    /// OAuth flow handler.
    private let oauthFlow: MCPOAuthFlow

    /// Delegate for authentication UI interactions.
    private weak var delegate: (any MCPOAuthDelegate)?

    /// URL session for HTTP requests.
    private let session: URLSession

    /// Whether streaming (SSE) is enabled.
    private let streaming: Bool

    /// Current session ID from the MCP server.
    private var sessionID: String?

    /// Whether the transport is connected.
    private var isConnected = false

    /// Message stream for received data.
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    /// Streaming task for SSE.
    private var streamingTask: Task<Void, Never>?

    /// Maximum retries for authentication failures.
    private let maxAuthRetries: Int

    /// Create an authenticated HTTP transport.
    ///
    /// - Parameters:
    ///   - endpoint: The MCP server URL
    ///   - oauthFlow: OAuth flow handler with token management
    ///   - delegate: Delegate for UI interactions (opening browser, prompts)
    ///   - streaming: Whether to enable SSE streaming (default: true)
    ///   - maxAuthRetries: Maximum retries for auth failures (default: 1)
    ///   - session: URL session to use (default: shared)
    ///   - logger: Optional logger for transport events
    public init(
        endpoint: URL,
        oauthFlow: MCPOAuthFlow,
        delegate: (any MCPOAuthDelegate)?,
        streaming: Bool = true,
        maxAuthRetries: Int = 1,
        session: URLSession = .shared,
        logger: Logger? = nil
    ) {
        self.endpoint = endpoint
        self.oauthFlow = oauthFlow
        self.delegate = delegate
        self.streaming = streaming
        self.maxAuthRetries = maxAuthRetries
        self.session = session

        self.logger = logger ?? Logger(
            label: "mcp.transport.http.authenticated",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )

        // Create message stream
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    // MARK: - Transport Protocol

    public func connect() async throws {
        guard !isConnected else { return }

        // Ensure we have valid tokens before connecting
        do {
            _ = try await oauthFlow.getValidAccessToken()
        } catch MCPOAuthError.notAuthenticated {
            // Need to authenticate first
            try await performInitialAuthentication()
        }

        isConnected = true

        #if !os(Linux)
        if streaming {
            streamingTask = Task { await startListeningForServerEvents() }
        }
        #endif

        logger.debug("Authenticated HTTP transport connected")
    }

    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false

        streamingTask?.cancel()
        streamingTask = nil

        messageContinuation.finish()

        logger.debug("Authenticated HTTP transport disconnected")
    }

    public func send(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.internalError("Transport not connected")
        }

        try await sendWithRetry(data: data, retriesRemaining: maxAuthRetries)
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return messageStream
    }

    // MARK: - Private Implementation

    /// Send data with automatic token refresh on 401.
    private func sendWithRetry(data: Data, retriesRemaining: Int) async throws {
        // Get current access token
        let accessToken: String
        do {
            accessToken = try await oauthFlow.getValidAccessToken()
        } catch MCPOAuthError.notAuthenticated {
            // Try to re-authenticate
            if retriesRemaining > 0 {
                try await performReauthentication(reason: "Session expired")
                try await sendWithRetry(data: data, retriesRemaining: retriesRemaining - 1)
                return
            }
            throw MCPOAuthError.notAuthenticated
        }

        // Build request
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = data

        // Add session ID if available
        if let sessionID = sessionID {
            request.addValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        // Send request
        let (responseData, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.internalError("Invalid HTTP response")
        }

        // Extract session ID if present
        if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
            self.sessionID = newSessionID
            logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
        }

        // Handle 401 - token might have expired between getValidAccessToken and request
        if httpResponse.statusCode == 401 {
            if retriesRemaining > 0 {
                logger.info("Got 401, attempting token refresh")

                // Try to refresh
                do {
                    _ = try await oauthFlow.refreshTokens()
                    try await sendWithRetry(data: data, retriesRemaining: retriesRemaining - 1)
                    return
                } catch {
                    // Refresh failed, try re-authentication
                    try await performReauthentication(reason: "Token refresh failed")
                    try await sendWithRetry(data: data, retriesRemaining: retriesRemaining - 1)
                    return
                }
            }
            throw MCPOAuthError.notAuthenticated
        }

        // Handle other HTTP errors
        try processHTTPResponse(httpResponse)

        // Yield response data
        if !responseData.isEmpty {
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.contains("application/json") || contentType.contains("text/event-stream") {
                messageContinuation.yield(responseData)
            }
        }
    }

    /// Process HTTP response status codes.
    private func processHTTPResponse(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return

        case 400:
            throw MCPError.internalError("Bad request")

        case 401:
            // Already handled in sendWithRetry
            throw MCPOAuthError.notAuthenticated

        case 403:
            throw MCPError.internalError("Access forbidden - insufficient permissions")

        case 404:
            if sessionID != nil {
                sessionID = nil
                throw MCPError.internalError("Session expired")
            }
            throw MCPError.internalError("Endpoint not found")

        case 429:
            throw MCPError.internalError("Too many requests - rate limited")

        case 500..<600:
            throw MCPError.internalError("Server error: \(response.statusCode)")

        default:
            throw MCPError.internalError("HTTP error: \(response.statusCode)")
        }
    }

    // MARK: - Authentication

    /// Perform initial OAuth authentication flow.
    private func performInitialAuthentication() async throws {
        await delegate?.authenticationProgress(.openingBrowser)

        let authURL = await oauthFlow.buildAuthorizationURL()

        // Open browser via delegate
        try await delegate?.openAuthorizationURL(authURL)

        await delegate?.authenticationProgress(.waitingForUser)

        // Note: The delegate must call handleOAuthCallback when the redirect is received
        // For now, we throw if delegate is nil since we can't complete the flow
        guard delegate != nil else {
            throw MCPOAuthError.cancelled
        }

        // The actual token exchange happens when handleOAuthCallback is called
        // This method just initiates the flow
    }

    /// Perform re-authentication when tokens can't be refreshed.
    private func performReauthentication(reason: String) async throws {
        guard let delegate = delegate else {
            throw MCPOAuthError.notAuthenticated
        }

        // Ask user if they want to re-authenticate
        let serverID = await getServerID()
        let shouldReauth = await delegate.promptReauthentication(for: serverID, reason: reason)

        if !shouldReauth {
            throw MCPOAuthError.cancelled
        }

        try await performInitialAuthentication()
    }

    /// Get the server ID from the OAuth flow.
    private func getServerID() async -> String {
        // Extract from endpoint host as fallback
        return endpoint.host ?? "unknown"
    }

    // MARK: - SSE Streaming

    #if !os(Linux)
    /// Start listening for server-sent events.
    private func startListeningForServerEvents() async {
        while isConnected && !Task.isCancelled {
            do {
                try await connectToEventStream()
            } catch {
                if !Task.isCancelled {
                    logger.error("SSE connection error: \(error)")
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// Connect to SSE endpoint with authentication.
    private func connectToEventStream() async throws {
        guard isConnected else { return }

        let accessToken = try await oauthFlow.getValidAccessToken()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.addValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.addValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        if let sessionID = sessionID {
            request.addValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let (stream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.internalError("Invalid HTTP response")
        }

        // Handle 401 by refreshing and retrying
        if httpResponse.statusCode == 401 {
            logger.info("SSE got 401, refreshing token")
            _ = try await oauthFlow.refreshTokens()
            return // Will retry in the while loop
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 405 {
                streamingTask?.cancel()
            }
            throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
        }

        // Extract session ID
        if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
            self.sessionID = newSessionID
        }

        // Process SSE events
        try await processSSEStream(stream)
    }

    /// Process SSE byte stream.
    private func processSSEStream(_ stream: URLSession.AsyncBytes) async throws {
        var buffer = ""

        for try await byte in stream {
            if Task.isCancelled { break }

            let char = Character(UnicodeScalar(byte))
            buffer.append(char)

            // Check for complete SSE event (double newline)
            if buffer.hasSuffix("\n\n") {
                if let eventData = parseSSEEvent(buffer) {
                    messageContinuation.yield(eventData)
                }
                buffer = ""
            }
        }
    }

    /// Parse SSE event data.
    private func parseSSEEvent(_ eventString: String) -> Data? {
        var data = ""

        for line in eventString.components(separatedBy: "\n") {
            if line.hasPrefix("data:") {
                let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if !data.isEmpty {
                    data += "\n"
                }
                data += value
            }
        }

        return data.isEmpty ? nil : data.data(using: .utf8)
    }
    #endif

    // MARK: - OAuth Callback Handling

    /// Handle the OAuth callback URL.
    ///
    /// Call this when your app receives the OAuth redirect callback.
    /// This completes the authentication flow and stores the tokens.
    ///
    /// - Parameter url: The callback URL received from the browser
    /// - Returns: The obtained OAuth tokens
    public func handleOAuthCallback(url: URL) async throws -> MCPOAuthTokens {
        await delegate?.authenticationProgress(.exchangingCode)

        let tokens = try await oauthFlow.handleCallback(url: url)

        await delegate?.authenticationProgress(.complete)

        return tokens
    }
}

