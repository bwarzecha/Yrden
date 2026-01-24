/// OAuth types and configuration for MCP server authentication.
///
/// Provides OAuth 2.0 authorization code flow with PKCE support for
/// connecting to remote MCP servers that require authentication.

import Foundation

// MARK: - OAuth Configuration

/// Configuration for OAuth 2.0 authentication.
public struct MCPOAuthConfig: Sendable, Codable {
    /// OAuth client ID (from the MCP server provider).
    public let clientId: String

    /// OAuth client secret (optional, not recommended for public clients).
    public let clientSecret: String?

    /// Authorization endpoint URL.
    public let authorizationURL: URL

    /// Token endpoint URL.
    public let tokenURL: URL

    /// Requested OAuth scopes.
    public let scopes: [String]

    /// Custom URL scheme for redirect (e.g., "myapp" for myapp://oauth/callback).
    public let redirectScheme: String

    /// Redirect path (default: "/oauth/callback").
    public let redirectPath: String

    /// Additional authorization parameters.
    public let additionalParams: [String: String]?

    /// Whether to use PKCE (Proof Key for Code Exchange). Recommended for all clients.
    public let usePKCE: Bool

    /// Separator for scopes in authorization URL (default: space, Todoist uses comma).
    public let scopeSeparator: String

    /// Full redirect URI.
    public var redirectURI: String {
        "\(redirectScheme)://\(redirectPath.hasPrefix("/") ? String(redirectPath.dropFirst()) : redirectPath)"
    }

    public init(
        clientId: String,
        clientSecret: String? = nil,
        authorizationURL: URL,
        tokenURL: URL,
        scopes: [String],
        redirectScheme: String,
        redirectPath: String = "/oauth/callback",
        additionalParams: [String: String]? = nil,
        usePKCE: Bool = true,
        scopeSeparator: String = " "
    ) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
        self.scopes = scopes
        self.redirectScheme = redirectScheme
        self.redirectPath = redirectPath
        self.additionalParams = additionalParams
        self.usePKCE = usePKCE
        self.scopeSeparator = scopeSeparator
    }
}

// MARK: - OAuth Tokens

/// OAuth tokens returned from token exchange.
public struct MCPOAuthTokens: Sendable, Codable {
    /// Access token for API requests.
    public let accessToken: String

    /// Token type (usually "Bearer").
    public let tokenType: String

    /// Refresh token for obtaining new access tokens.
    public let refreshToken: String?

    /// Access token expiration time.
    public let expiresAt: Date?

    /// Scopes granted by the authorization server.
    public let scopes: [String]?

    /// When the tokens were obtained.
    public let obtainedAt: Date

    /// Check if the access token is expired (with 60 second buffer).
    public var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date().addingTimeInterval(60) >= expiresAt
    }

    /// Check if we can refresh the token.
    public var canRefresh: Bool {
        refreshToken != nil
    }

    public init(
        accessToken: String,
        tokenType: String = "Bearer",
        refreshToken: String? = nil,
        expiresIn: Int? = nil,
        scopes: [String]? = nil,
        obtainedAt: Date = Date()
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.refreshToken = refreshToken
        self.expiresAt = expiresIn.map { obtainedAt.addingTimeInterval(TimeInterval($0)) }
        self.scopes = scopes
        self.obtainedAt = obtainedAt
    }

    /// Create from token response JSON.
    public init(from response: [String: Any], obtainedAt: Date = Date()) throws {
        guard let accessToken = response["access_token"] as? String else {
            throw MCPOAuthError.invalidTokenResponse("Missing access_token")
        }

        self.accessToken = accessToken
        self.tokenType = response["token_type"] as? String ?? "Bearer"
        self.refreshToken = response["refresh_token"] as? String
        self.obtainedAt = obtainedAt

        if let expiresIn = response["expires_in"] as? Int {
            self.expiresAt = obtainedAt.addingTimeInterval(TimeInterval(expiresIn))
        } else {
            self.expiresAt = nil
        }

        if let scope = response["scope"] as? String {
            self.scopes = scope.components(separatedBy: " ")
        } else {
            self.scopes = nil
        }
    }
}

// MARK: - PKCE

/// PKCE (Proof Key for Code Exchange) parameters.
public struct PKCEParameters: Sendable {
    /// Code verifier (random string).
    public let codeVerifier: String

    /// Code challenge (SHA256 hash of verifier, base64url encoded).
    public let codeChallenge: String

    /// Challenge method (always S256).
    public let codeChallengeMethod: String = "S256"

    /// Generate new PKCE parameters.
    public static func generate() -> PKCEParameters {
        // Generate 32 random bytes for verifier
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        let verifier = Data(bytes).base64URLEncodedString()

        // SHA256 hash of verifier
        let verifierData = verifier.data(using: .utf8)!
        var hash = [UInt8](repeating: 0, count: 32)
        verifierData.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }

        let challenge = Data(hash).base64URLEncodedString()

        return PKCEParameters(codeVerifier: verifier, codeChallenge: challenge)
    }

    private init(codeVerifier: String, codeChallenge: String) {
        self.codeVerifier = codeVerifier
        self.codeChallenge = codeChallenge
    }
}

// MARK: - OAuth Errors

/// Errors during OAuth flow.
public enum MCPOAuthError: Error, Sendable {
    /// Authorization was denied by the user.
    case authorizationDenied(String?)

    /// Invalid or missing state parameter (CSRF protection).
    case stateMismatch

    /// Failed to exchange authorization code for tokens.
    case tokenExchangeFailed(String)

    /// Token refresh failed.
    case tokenRefreshFailed(String)

    /// Invalid token response from server.
    case invalidTokenResponse(String)

    /// No tokens available (not authenticated).
    case notAuthenticated

    /// Token storage error.
    case storageError(String)

    /// Network error during OAuth.
    case networkError(Error)

    /// OAuth callback URL could not be parsed.
    case invalidCallbackURL(String)

    /// The OAuth flow was cancelled.
    case cancelled
}

extension MCPOAuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authorizationDenied(let reason):
            return "Authorization denied\(reason.map { ": \($0)" } ?? "")"
        case .stateMismatch:
            return "OAuth state mismatch - possible CSRF attack"
        case .tokenExchangeFailed(let reason):
            return "Failed to exchange code for tokens: \(reason)"
        case .tokenRefreshFailed(let reason):
            return "Failed to refresh token: \(reason)"
        case .invalidTokenResponse(let reason):
            return "Invalid token response: \(reason)"
        case .notAuthenticated:
            return "Not authenticated - no tokens available"
        case .storageError(let reason):
            return "Token storage error: \(reason)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidCallbackURL(let url):
            return "Invalid OAuth callback URL: \(url)"
        case .cancelled:
            return "OAuth flow was cancelled"
        }
    }
}

// MARK: - OAuth State

/// State for an in-progress OAuth flow.
public struct MCPOAuthState: Sendable {
    /// Random state parameter for CSRF protection.
    public let state: String

    /// PKCE parameters (if using PKCE).
    public let pkce: PKCEParameters?

    /// Server ID this auth is for.
    public let serverID: String

    /// When the flow was started.
    public let startedAt: Date

    /// Generate new OAuth state.
    public static func generate(serverID: String, usePKCE: Bool) -> MCPOAuthState {
        var stateBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, stateBytes.count, &stateBytes)

        return MCPOAuthState(
            state: Data(stateBytes).base64URLEncodedString(),
            pkce: usePKCE ? PKCEParameters.generate() : nil,
            serverID: serverID,
            startedAt: Date()
        )
    }
}

// MARK: - Helpers

import CommonCrypto

extension Data {
    /// Base64 URL encoding (no padding, URL-safe characters).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
