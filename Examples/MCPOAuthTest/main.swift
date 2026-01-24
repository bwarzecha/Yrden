/// MCP OAuth Test Application
///
/// This is a simple macOS CLI app to test the OAuth flow for remote MCP servers.
///
/// Usage:
///   1. Configure the OAuth settings below for your MCP server
///   2. Run: swift run MCPOAuthTest
///   3. A browser will open for authentication
///   4. After authenticating, the app will connect to the MCP server
///
/// For testing purposes, you can use any OAuth provider that supports
/// authorization code flow with PKCE.

import Foundation
import Yrden

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Configuration

/// Edit these values for your MCP server's OAuth configuration
struct OAuthTestConfig {
    // OAuth Provider Settings (example: GitHub, Google, custom OAuth server)
    static let clientId = ProcessInfo.processInfo.environment["OAUTH_CLIENT_ID"] ?? "your-client-id"
    static let clientSecret = ProcessInfo.processInfo.environment["OAUTH_CLIENT_SECRET"]

    // OAuth Endpoints
    static let authorizationURL = URL(string: ProcessInfo.processInfo.environment["OAUTH_AUTH_URL"] ?? "https://example.com/oauth/authorize")!
    static let tokenURL = URL(string: ProcessInfo.processInfo.environment["OAUTH_TOKEN_URL"] ?? "https://example.com/oauth/token")!

    // MCP Server
    static let mcpServerURL = URL(string: ProcessInfo.processInfo.environment["MCP_SERVER_URL"] ?? "https://mcp.example.com")!

    // Scopes requested
    static let scopes = (ProcessInfo.processInfo.environment["OAUTH_SCOPES"] ?? "read write").components(separatedBy: " ")

    // Local callback handling
    static let redirectScheme = "yrden-oauth-test"
}

// MARK: - OAuth Delegate

/// OAuth delegate implementation for the test app.
final class TestOAuthDelegate: MCPOAuthDelegate, @unchecked Sendable {
    func openAuthorizationURL(_ url: URL) async throws {
        print("\n" + String(repeating: "=", count: 60))
        print("AUTHORIZATION REQUIRED")
        print(String(repeating: "=", count: 60))
        print("\nOpening browser for authentication...")
        print("\nIf the browser doesn't open, visit this URL manually:")
        print(url.absoluteString)
        print(String(repeating: "=", count: 60) + "\n")

        #if canImport(AppKit)
        // Open URL in default browser
        NSWorkspace.shared.open(url)
        #else
        print("Please open the URL above in your browser.")
        #endif
    }

    func promptReauthentication(for serverID: String, reason: String) async -> Bool {
        print("\n" + String(repeating: "-", count: 60))
        print("RE-AUTHENTICATION NEEDED")
        print("Server: \(serverID)")
        print("Reason: \(reason)")
        print(String(repeating: "-", count: 60))
        print("\nPress 'y' to re-authenticate, any other key to cancel: ", terminator: "")

        if let input = readLine()?.lowercased(), input == "y" {
            return true
        }
        return false
    }

    func authenticationProgress(_ state: MCPOAuthProgress) {
        switch state {
        case .openingBrowser:
            print("[OAuth] Opening browser for authentication...")
        case .waitingForUser:
            print("[OAuth] Waiting for user to authenticate...")
        case .exchangingCode:
            print("[OAuth] Exchanging authorization code for tokens...")
        case .refreshingTokens:
            print("[OAuth] Refreshing access token...")
        case .complete:
            print("[OAuth] Authentication complete!")
        case .failed(let error):
            print("[OAuth] Authentication failed: \(error)")
        }
    }
}

// MARK: - Main

@main
struct MCPOAuthTestApp {
    static func main() async {
        print("""

        ╔═══════════════════════════════════════════════════════════════╗
        ║           MCP OAuth Test Application                          ║
        ║           Testing OAuth flow for remote MCP servers           ║
        ╚═══════════════════════════════════════════════════════════════╝

        """)

        // Print configuration
        print("Configuration:")
        print("  Client ID:        \(OAuthTestConfig.clientId)")
        print("  Auth URL:         \(OAuthTestConfig.authorizationURL)")
        print("  Token URL:        \(OAuthTestConfig.tokenURL)")
        print("  MCP Server:       \(OAuthTestConfig.mcpServerURL)")
        print("  Scopes:           \(OAuthTestConfig.scopes.joined(separator: ", "))")
        print("  Redirect Scheme:  \(OAuthTestConfig.redirectScheme)")
        print("")

        // Check for required configuration
        if OAuthTestConfig.clientId == "your-client-id" {
            print("""

            ⚠️  WARNING: Using default configuration values!

            To test with a real OAuth provider, set these environment variables:

              export OAUTH_CLIENT_ID="your-client-id"
              export OAUTH_CLIENT_SECRET="your-client-secret"  # optional
              export OAUTH_AUTH_URL="https://provider.com/oauth/authorize"
              export OAUTH_TOKEN_URL="https://provider.com/oauth/token"
              export MCP_SERVER_URL="https://your-mcp-server.com"
              export OAUTH_SCOPES="read write"

            Then run:
              swift run MCPOAuthTest

            """)

            // For demo purposes, we'll show what would happen
            await runDemoMode()
            return
        }

        await runOAuthFlow()
    }

    static func runDemoMode() async {
        print("Running in DEMO mode (no actual OAuth will be performed)...\n")

        // Create OAuth config
        let config = MCPOAuthConfig(
            clientId: OAuthTestConfig.clientId,
            clientSecret: OAuthTestConfig.clientSecret,
            authorizationURL: OAuthTestConfig.authorizationURL,
            tokenURL: OAuthTestConfig.tokenURL,
            scopes: OAuthTestConfig.scopes,
            redirectScheme: OAuthTestConfig.redirectScheme
        )

        print("OAuth Configuration Created:")
        print("  Redirect URI: \(config.redirectURI)")
        print("  Uses PKCE:    \(config.usePKCE)")
        print("")

        // Generate sample authorization URL
        let storage = InMemoryTokenStorage()
        let flow = MCPOAuthFlow(config: config, storage: storage, serverID: "demo-server")
        let authURL = await flow.buildAuthorizationURL()

        print("Sample Authorization URL:")
        print(authURL.absoluteString)
        print("")

        // Parse and show URL components
        if let components = URLComponents(url: authURL, resolvingAgainstBaseURL: true) {
            print("URL Parameters:")
            for item in components.queryItems ?? [] {
                let value = item.value ?? ""
                let displayValue = value.count > 50 ? String(value.prefix(50)) + "..." : value
                print("  \(item.name): \(displayValue)")
            }
        }

        let redirectScheme = OAuthTestConfig.redirectScheme
        print("""

        ✅ Demo complete!

        In a real scenario:
        1. The browser would open to the authorization URL
        2. User would log in and authorize
        3. Provider would redirect to: \(redirectScheme)://oauth/callback?code=xxx&state=yyy
        4. The app would exchange the code for tokens
        5. Tokens would be stored securely
        6. The MCP connection would be established with the access token

        """)
    }

    static func runOAuthFlow() async {
        print("Starting OAuth flow...\n")

        // Create OAuth configuration
        let config = MCPOAuthConfig(
            clientId: OAuthTestConfig.clientId,
            clientSecret: OAuthTestConfig.clientSecret,
            authorizationURL: OAuthTestConfig.authorizationURL,
            tokenURL: OAuthTestConfig.tokenURL,
            scopes: OAuthTestConfig.scopes,
            redirectScheme: OAuthTestConfig.redirectScheme
        )

        // Use in-memory storage for testing (use KeychainTokenStorage for production)
        let storage = InMemoryTokenStorage()

        // Create delegate
        let delegate = TestOAuthDelegate()

        do {
            // Create the OAuth flow
            let flow = MCPOAuthFlow(config: config, storage: storage, serverID: "test-server")

            // Build authorization URL
            let authURL = await flow.buildAuthorizationURL()

            // Open browser
            try await delegate.openAuthorizationURL(authURL)

            print("")
            print("After authenticating, you'll be redirected to a callback URL.")
            print("")
            print("Please paste the FULL callback URL here (including the ?code=... part):")
            print("> ", terminator: "")

            // Read callback URL from stdin
            guard let callbackURLString = readLine(), !callbackURLString.isEmpty else {
                print("No callback URL provided. Exiting.")
                return
            }

            guard let callbackURL = URL(string: callbackURLString) else {
                print("Invalid URL. Exiting.")
                return
            }

            // Handle the callback
            print("\nProcessing callback...")
            let tokens = try await flow.handleCallback(url: callbackURL)

            let tokenPrefix = String(tokens.accessToken.prefix(20))
            let expiresDescription = tokens.expiresAt?.description ?? "Never"
            let hasRefresh = tokens.refreshToken != nil
            print("""

            ✅ Authentication successful!

            Access Token:  \(tokenPrefix)...
            Token Type:    \(tokens.tokenType)
            Expires At:    \(expiresDescription)
            Has Refresh:   \(hasRefresh)

            """)

            // Now try to connect to the MCP server
            print("Connecting to MCP server at \(OAuthTestConfig.mcpServerURL)...")

            let server = try await MCPServerConnection.oauthHTTP(
                url: OAuthTestConfig.mcpServerURL,
                oauthConfig: config,
                storage: storage,
                delegate: delegate
            )

            let serverName = await server.name
            print("Connected to MCP server: \(serverName)")

            // List available tools
            let supportsTools = await server.supportsTools
            if supportsTools {
                let tools = try await server.listTools()
                print("\nAvailable tools (\(tools.count)):")
                for tool in tools.prefix(10) {
                    print("  - \(tool.name): \(tool.description ?? "")")
                }
                if tools.count > 10 {
                    print("  ... and \(tools.count - 10) more")
                }
            }

            // List available resources
            let supportsResources = await server.supportsResources
            if supportsResources {
                let resources = try await server.listResources()
                print("\nAvailable resources (\(resources.count)):")
                for resource in resources.prefix(10) {
                    print("  - \(resource.name): \(resource.uri)")
                }
                if resources.count > 10 {
                    print("  ... and \(resources.count - 10) more")
                }
            }

            // Disconnect
            await server.disconnect()
            print("\nDisconnected from MCP server.")

        } catch {
            print("\n❌ Error: \(error)")
            if let oauthError = error as? MCPOAuthError {
                print("OAuth Error Details: \(oauthError.localizedDescription)")
            }
        }

        print("\nTest complete.")
    }
}
