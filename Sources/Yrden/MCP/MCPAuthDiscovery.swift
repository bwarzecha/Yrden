/// MCP OAuth Discovery
///
/// Implements the MCP authorization discovery flow as specified in:
/// - RFC 9728 (OAuth 2.0 Protected Resource Metadata)
/// - RFC 8414 (OAuth 2.0 Authorization Server Metadata)
/// - RFC 7591 (OAuth 2.0 Dynamic Client Registration)
///
/// Flow:
/// 1. Client sends request to MCP server
/// 2. Server returns 401 with WWW-Authenticate header
/// 3. Client fetches Protected Resource Metadata
/// 4. Client fetches Authorization Server Metadata
/// 5. (Optional) Client performs Dynamic Client Registration
/// 6. Client proceeds with OAuth flow

import Foundation

// MARK: - Protected Resource Metadata

/// OAuth 2.0 Protected Resource Metadata (RFC 9728)
public struct ProtectedResourceMetadata: Codable, Sendable {
    /// The resource identifier (MCP server URL)
    public let resource: URL?

    /// Authorization servers that can issue tokens for this resource
    public let authorizationServers: [URL]

    /// Scopes available at this resource
    public let scopesSupported: [String]?

    /// Bearer token methods supported
    public let bearerMethodsSupported: [String]?

    /// Resource documentation URL
    public let resourceDocumentation: URL?

    /// Resource policy URL
    public let resourcePolicyUri: URL?

    /// Resource terms of service URL
    public let resourceTosUri: URL?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
        case bearerMethodsSupported = "bearer_methods_supported"
        case resourceDocumentation = "resource_documentation"
        case resourcePolicyUri = "resource_policy_uri"
        case resourceTosUri = "resource_tos_uri"
    }
}

// MARK: - Authorization Server Metadata

/// OAuth 2.0 Authorization Server Metadata (RFC 8414)
public struct AuthorizationServerMetadata: Codable, Sendable {
    /// Authorization server issuer URL
    public let issuer: URL

    /// Authorization endpoint
    public let authorizationEndpoint: URL

    /// Token endpoint
    public let tokenEndpoint: URL

    /// Dynamic client registration endpoint
    public let registrationEndpoint: URL?

    /// Scopes supported
    public let scopesSupported: [String]?

    /// Response types supported
    public let responseTypesSupported: [String]?

    /// Grant types supported
    public let grantTypesSupported: [String]?

    /// Code challenge methods supported
    public let codeChallengeMethodsSupported: [String]?

    /// Token endpoint auth methods supported
    public let tokenEndpointAuthMethodsSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case scopesSupported = "scopes_supported"
        case responseTypesSupported = "response_types_supported"
        case grantTypesSupported = "grant_types_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
    }

    /// Check if PKCE is supported (S256 method)
    public var supportsPKCE: Bool {
        codeChallengeMethodsSupported?.contains("S256") ?? false
    }

    /// Check if dynamic registration is supported
    public var supportsDynamicRegistration: Bool {
        registrationEndpoint != nil
    }
}

// MARK: - Dynamic Client Registration

/// Client registration request (RFC 7591)
public struct ClientRegistrationRequest: Codable, Sendable {
    /// Redirect URIs for the client
    public let redirectUris: [String]

    /// Token endpoint auth method
    public let tokenEndpointAuthMethod: String

    /// Grant types requested
    public let grantTypes: [String]

    /// Response types requested
    public let responseTypes: [String]

    /// Client name
    public let clientName: String?

    /// Client URI
    public let clientUri: String?

    /// Scopes requested
    public let scope: String?

    enum CodingKeys: String, CodingKey {
        case redirectUris = "redirect_uris"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
        case grantTypes = "grant_types"
        case responseTypes = "response_types"
        case clientName = "client_name"
        case clientUri = "client_uri"
        case scope
    }

    public init(
        redirectUris: [String],
        tokenEndpointAuthMethod: String = "none",
        grantTypes: [String] = ["authorization_code", "refresh_token"],
        responseTypes: [String] = ["code"],
        clientName: String? = nil,
        clientUri: String? = nil,
        scope: String? = nil
    ) {
        self.redirectUris = redirectUris
        self.tokenEndpointAuthMethod = tokenEndpointAuthMethod
        self.grantTypes = grantTypes
        self.responseTypes = responseTypes
        self.clientName = clientName
        self.clientUri = clientUri
        self.scope = scope
    }
}

/// Client registration response (RFC 7591)
public struct ClientRegistrationResponse: Codable, Sendable {
    /// Assigned client ID
    public let clientId: String

    /// Client secret (if confidential client)
    public let clientSecret: String?

    /// When the client secret expires
    public let clientSecretExpiresAt: Int?

    /// Registration access token for managing registration
    public let registrationAccessToken: String?

    /// URI for managing client registration
    public let registrationClientUri: String?

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
        case clientSecretExpiresAt = "client_secret_expires_at"
        case registrationAccessToken = "registration_access_token"
        case registrationClientUri = "registration_client_uri"
    }
}

// MARK: - Discovery Errors

/// Errors during MCP auth discovery
public enum MCPAuthDiscoveryError: Error, Sendable {
    /// WWW-Authenticate header missing or malformed
    case missingAuthenticateHeader

    /// Could not parse WWW-Authenticate header
    case invalidAuthenticateHeader(String)

    /// Protected resource metadata fetch failed
    case resourceMetadataFetchFailed(String)

    /// Authorization server metadata fetch failed
    case authServerMetadataFetchFailed(String)

    /// Dynamic client registration failed
    case registrationFailed(String)

    /// No authorization servers found in metadata
    case noAuthorizationServers

    /// Server doesn't support required features
    case unsupportedFeatures(String)
}

extension MCPAuthDiscoveryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAuthenticateHeader:
            return "Server returned 401 but no WWW-Authenticate header"
        case .invalidAuthenticateHeader(let header):
            return "Could not parse WWW-Authenticate header: \(header)"
        case .resourceMetadataFetchFailed(let reason):
            return "Failed to fetch protected resource metadata: \(reason)"
        case .authServerMetadataFetchFailed(let reason):
            return "Failed to fetch authorization server metadata: \(reason)"
        case .registrationFailed(let reason):
            return "Dynamic client registration failed: \(reason)"
        case .noAuthorizationServers:
            return "No authorization servers found in resource metadata"
        case .unsupportedFeatures(let features):
            return "Server doesn't support required features: \(features)"
        }
    }
}

// MARK: - Auth Discovery

/// Handles MCP OAuth discovery flow
public actor MCPAuthDiscovery {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Parse WWW-Authenticate header to extract resource metadata URL
    ///
    /// Format: `Bearer resource_metadata="https://example.com/.well-known/oauth-protected-resource"`
    public func parseWWWAuthenticate(header: String) throws -> URL {
        // Look for resource_metadata parameter
        // Format: Bearer resource_metadata="URL"
        let pattern = #"resource_metadata\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let urlRange = Range(match.range(at: 1), in: header) else {
            throw MCPAuthDiscoveryError.invalidAuthenticateHeader(header)
        }

        let urlString = String(header[urlRange])
        guard let url = URL(string: urlString) else {
            throw MCPAuthDiscoveryError.invalidAuthenticateHeader("Invalid URL: \(urlString)")
        }

        return url
    }

    /// Construct protected resource metadata URL from MCP server URL
    ///
    /// Per RFC 9728, metadata is at `/.well-known/oauth-protected-resource`
    public func resourceMetadataURL(for serverURL: URL) -> URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: true)!
        components.path = "/.well-known/oauth-protected-resource"
        components.query = nil
        components.fragment = nil
        return components.url!
    }

    /// Fetch protected resource metadata
    public func fetchResourceMetadata(from url: URL) async throws -> ProtectedResourceMetadata {
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPAuthDiscoveryError.resourceMetadataFetchFailed("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            throw MCPAuthDiscoveryError.resourceMetadataFetchFailed("HTTP \(httpResponse.statusCode)")
        }

        do {
            return try JSONDecoder().decode(ProtectedResourceMetadata.self, from: data)
        } catch {
            throw MCPAuthDiscoveryError.resourceMetadataFetchFailed("JSON decode: \(error)")
        }
    }

    /// Construct authorization server metadata URL
    ///
    /// Per RFC 8414, metadata is at `/.well-known/oauth-authorization-server`
    public func authServerMetadataURL(for authServerURL: URL) -> URL {
        var components = URLComponents(url: authServerURL, resolvingAgainstBaseURL: true)!

        // Per RFC 8414, the well-known path should be at the root
        // but preserve the path if the auth server has one
        let basePath = components.path
        if basePath.isEmpty || basePath == "/" {
            components.path = "/.well-known/oauth-authorization-server"
        } else {
            // For servers with path like https://auth.example.com/tenant1
            // metadata is at /.well-known/oauth-authorization-server/tenant1
            components.path = "/.well-known/oauth-authorization-server\(basePath)"
        }

        components.query = nil
        components.fragment = nil
        return components.url!
    }

    /// Fetch authorization server metadata
    public func fetchAuthServerMetadata(from url: URL) async throws -> AuthorizationServerMetadata {
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPAuthDiscoveryError.authServerMetadataFetchFailed("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            throw MCPAuthDiscoveryError.authServerMetadataFetchFailed("HTTP \(httpResponse.statusCode)")
        }

        do {
            return try JSONDecoder().decode(AuthorizationServerMetadata.self, from: data)
        } catch {
            throw MCPAuthDiscoveryError.authServerMetadataFetchFailed("JSON decode: \(error)")
        }
    }

    /// Perform dynamic client registration
    public func registerClient(
        at registrationEndpoint: URL,
        request: ClientRegistrationRequest
    ) async throws -> ClientRegistrationResponse {
        var urlRequest = URLRequest(url: registrationEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPAuthDiscoveryError.registrationFailed("Invalid response")
        }

        guard httpResponse.statusCode == 201 || httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "No body"
            throw MCPAuthDiscoveryError.registrationFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        do {
            return try JSONDecoder().decode(ClientRegistrationResponse.self, from: data)
        } catch {
            throw MCPAuthDiscoveryError.registrationFailed("JSON decode: \(error)")
        }
    }

    /// Full discovery flow: parse 401 response and discover auth endpoints
    ///
    /// - Parameters:
    ///   - response: The 401 HTTPURLResponse
    ///   - serverURL: The MCP server URL (used as fallback for metadata discovery)
    /// - Returns: Authorization server metadata
    public func discover(
        from response: HTTPURLResponse,
        serverURL: URL
    ) async throws -> (resource: ProtectedResourceMetadata, authServer: AuthorizationServerMetadata) {
        // 1. Parse WWW-Authenticate header
        let resourceMetadataURL: URL
        if let authenticateHeader = response.value(forHTTPHeaderField: "WWW-Authenticate") {
            resourceMetadataURL = try parseWWWAuthenticate(header: authenticateHeader)
        } else {
            // Fallback: try well-known path
            resourceMetadataURL = self.resourceMetadataURL(for: serverURL)
        }

        // 2. Fetch protected resource metadata
        let resourceMetadata = try await fetchResourceMetadata(from: resourceMetadataURL)

        // 3. Get authorization server URL
        guard let authServerURL = resourceMetadata.authorizationServers.first else {
            throw MCPAuthDiscoveryError.noAuthorizationServers
        }

        // 4. Construct and fetch authorization server metadata
        let authMetadataURL = authServerMetadataURL(for: authServerURL)
        let authServerMetadata = try await fetchAuthServerMetadata(from: authMetadataURL)

        return (resourceMetadata, authServerMetadata)
    }

    /// Register client dynamically if supported
    public func registerClientIfNeeded(
        authServer: AuthorizationServerMetadata,
        redirectURI: String,
        clientName: String?,
        scopes: [String]?
    ) async throws -> ClientRegistrationResponse? {
        guard let registrationEndpoint = authServer.registrationEndpoint else {
            return nil
        }

        let request = ClientRegistrationRequest(
            redirectUris: [redirectURI],
            clientName: clientName,
            scope: scopes?.joined(separator: " ")
        )

        return try await registerClient(at: registrationEndpoint, request: request)
    }
}

// MARK: - Discovered OAuth Config

/// OAuth configuration discovered from MCP server metadata
public struct DiscoveredOAuthConfig: Sendable {
    /// The MCP server URL (resource)
    public let resourceURL: URL

    /// Authorization endpoint
    public let authorizationURL: URL

    /// Token endpoint
    public let tokenURL: URL

    /// Client ID (from registration or provided)
    public let clientId: String

    /// Client secret (if any)
    public let clientSecret: String?

    /// Scopes to request
    public let scopes: [String]

    /// Whether PKCE is supported (always use if available)
    public let supportsPKCE: Bool

    /// Convert to MCPOAuthConfig
    public func toOAuthConfig(redirectScheme: String) -> MCPOAuthConfig {
        MCPOAuthConfig(
            clientId: clientId,
            clientSecret: clientSecret,
            authorizationURL: authorizationURL,
            tokenURL: tokenURL,
            scopes: scopes,
            redirectScheme: redirectScheme,
            additionalParams: ["resource": resourceURL.absoluteString],
            usePKCE: supportsPKCE
        )
    }
}
