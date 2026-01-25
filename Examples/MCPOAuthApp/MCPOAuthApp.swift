/// MCP OAuth Test App
///
/// A macOS SwiftUI app for testing OAuth flows with remote MCP servers.
/// Handles custom URL scheme redirects for OAuth callbacks.

import SwiftUI
import Yrden

@main
struct MCPOAuthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = OAuthViewModel()

    var body: some Scene {
        // Use Window instead of WindowGroup for single-window app
        Window("MCP OAuth Test", id: "main") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 600, minHeight: 500)
                // Note: OAuth callbacks are handled by AppDelegate.application(_:open:urls:)
                // Using only one callback path to avoid duplicate processing
                .onAppear {
                    // Share viewModel with AppDelegate for URL handling
                    appDelegate.viewModel = viewModel
                }
        }
        .commands {
            // Disable New Window command
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - App Delegate

/// AppDelegate handles URL scheme callbacks at the application level
class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel: OAuthViewModel?

    func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        // Close any extra windows that might have been created
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            self.closeExtraWindows()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }

        // Close any extra windows first
        Task { @MainActor in
            self.closeExtraWindows()
            // Bring main window to front
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        // Route the callback through the MCP router
        // This handles both auto-discovery connections and state-based flows
        Task {
            let handled = await mcpHandleCallbackAsync(url)
            if handled {
                print("Callback handled by MCP router")
                return
            }

            // Fall back to view model for manual OAuth flows
            await MainActor.run {
                guard let viewModel = self.viewModel else {
                    print("Warning: No viewModel available for URL callback")
                    return
                }
                Task {
                    await viewModel.handleCallback(url: url)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Bring existing window to front instead of creating new one
        if let window = sender.windows.first {
            window.makeKeyAndOrderFront(self)
        }
        return false  // Don't create new window
    }

    @MainActor
    private func closeExtraWindows() {
        let windows = NSApplication.shared.windows
        // Keep only the first window, close others
        if windows.count > 1 {
            for window in windows.dropFirst() {
                window.close()
            }
        }
    }
}

// MARK: - View Model

import MCP

// ToolInfo is now provided by the library (Yrden.ToolInfo)

/// Connection mode for MCP servers
enum ConnectionMode: String, CaseIterable {
    case httpAutoDiscovery = "HTTP (Auto-Discovery)"
    case httpManual = "HTTP (Manual OAuth)"
    case stdio = "Stdio (Local Process)"
}

@MainActor
class OAuthViewModel: ObservableObject {
    // Configuration - HTTP
    @Published var clientId: String = ""
    @Published var clientSecret: String = ""
    @Published var authURL: String = ""
    @Published var tokenURL: String = ""
    @Published var mcpServerURL: String = ""
    @Published var scopes: String = "read write"
    @Published var scopeSeparator: String = " "
    @Published var redirectScheme: String = "yrden-mcp-oauth"

    // Configuration - Stdio
    @Published var stdioCommand: String = ""
    @Published var stdioArguments: String = ""
    @Published var stdioEnvironment: String = ""

    // State
    @Published var status: String = "Ready"
    @Published var isLoading: Bool = false
    @Published var tokens: MCPOAuthTokens?
    @Published var tools: [ToolInfo] = []
    @Published var errorMessage: String?
    @Published var logs: [String] = []

    // Mode selection
    @Published var connectionMode: ConnectionMode = .httpAutoDiscovery

    // Tool invocation
    @Published var selectedTool: ToolInfo?
    @Published var toolParameters: [String: String] = [:]
    @Published var toolResult: String?
    @Published var isExecutingTool: Bool = false

    // Internal
    private var oauthFlow: MCPOAuthFlow?
    private var server: MCPServerConnection?

    // Computed for backwards compatibility
    var availableTools: [String] { tools.map { $0.name } }
    var useAutoDiscovery: Bool { connectionMode == .httpAutoDiscovery }

    // Presets
    struct ServerPreset: Identifiable {
        let id = UUID()
        let name: String
        let mode: ConnectionMode

        // HTTP config
        let clientId: String
        let authURL: String
        let tokenURL: String
        let mcpServerURL: String
        let scopes: String
        let scopeSeparator: String

        // Stdio config
        let command: String
        let arguments: String
        let environment: String

        init(
            name: String,
            mode: ConnectionMode = .httpAutoDiscovery,
            clientId: String = "",
            authURL: String = "",
            tokenURL: String = "",
            mcpServerURL: String = "",
            scopes: String = "",
            scopeSeparator: String = " ",
            command: String = "",
            arguments: String = "",
            environment: String = ""
        ) {
            self.name = name
            self.mode = mode
            self.clientId = clientId
            self.authURL = authURL
            self.tokenURL = tokenURL
            self.mcpServerURL = mcpServerURL
            self.scopes = scopes
            self.scopeSeparator = scopeSeparator
            self.command = command
            self.arguments = arguments
            self.environment = environment
        }
    }

    let presets: [ServerPreset] = [
        ServerPreset(
            name: "Todoist MCP",
            mode: .httpAutoDiscovery,
            authURL: "https://app.todoist.com/oauth/authorize",
            tokenURL: "https://api.todoist.com/oauth/access_token",
            mcpServerURL: "https://ai.todoist.net/mcp",
            scopes: "data:read_write data:delete",
            scopeSeparator: ","
        ),
        ServerPreset(
            name: "Fetch (uvx)",
            mode: .stdio,
            command: "uvx",
            arguments: "mcp-server-fetch"
        ),
        ServerPreset(
            name: "Filesystem (npx)",
            mode: .stdio,
            command: "npx",
            arguments: "-y @modelcontextprotocol/server-filesystem /tmp"
        ),
        ServerPreset(
            name: "Memory (npx)",
            mode: .stdio,
            command: "npx",
            arguments: "-y @modelcontextprotocol/server-memory"
        ),
        ServerPreset(
            name: "GitHub",
            mode: .httpManual,
            authURL: "https://github.com/login/oauth/authorize",
            tokenURL: "https://github.com/login/oauth/access_token",
            scopes: "read:user"
        ),
    ]

    func applyPreset(_ preset: ServerPreset) {
        connectionMode = preset.mode

        // HTTP config
        clientId = preset.clientId
        authURL = preset.authURL
        tokenURL = preset.tokenURL
        mcpServerURL = preset.mcpServerURL
        scopes = preset.scopes
        scopeSeparator = preset.scopeSeparator

        // Stdio config
        stdioCommand = preset.command
        stdioArguments = preset.arguments
        stdioEnvironment = preset.environment

        log("Applied preset: \(preset.name) (\(preset.mode.rawValue))")
    }

    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")
        // Keep last 100 logs
        if logs.count > 100 {
            logs.removeFirst()
        }
    }

    func startOAuthFlow() async {
        guard validateInputs() else { return }

        isLoading = true
        status = "Starting OAuth flow..."
        errorMessage = nil
        tokens = nil
        tools = []

        // Validate URLs (already done by validateInputs but double-check)
        guard let authorizationEndpoint = URL(string: authURL),
              let tokenEndpoint = URL(string: tokenURL) else {
            errorMessage = "Invalid authorization or token URL"
            status = "Error"
            isLoading = false
            return
        }

        let config = MCPOAuthConfig(
            clientId: clientId,
            clientSecret: clientSecret.isEmpty ? nil : clientSecret,
            authorizationURL: authorizationEndpoint,
            tokenURL: tokenEndpoint,
            scopes: scopes.components(separatedBy: " ").filter { !$0.isEmpty },
            redirectScheme: redirectScheme,
            scopeSeparator: scopeSeparator
        )

        log("Created OAuth config (scope separator: '\(scopeSeparator)')")
        log("Redirect URI: \(config.redirectURI)")

        let storage = InMemoryTokenStorage()
        oauthFlow = MCPOAuthFlow(config: config, storage: storage, serverID: "test-server")

        // Build authorization URL
        let authorizationURL = await oauthFlow!.buildAuthorizationURL()
        log("Authorization URL: \(authorizationURL.absoluteString)")

        status = "Opening browser..."
        log("Opening browser for authentication")

        // Open in browser
        NSWorkspace.shared.open(authorizationURL)

        status = "Waiting for callback..."
        log("Waiting for OAuth callback to \(redirectScheme)://...")

        // Note: isLoading stays true until callback is received
        // User can click Disconnect to cancel
    }

    /// Handle OAuth callback for manual OAuth flows only.
    /// Auto-discovery flows are handled by mcpHandleCallback() in AppDelegate.
    func handleCallback(url: URL) async {
        log("Received callback (manual OAuth): \(url.absoluteString)")

        // Manual OAuth mode only - auto-discovery is handled by the callback router
        guard let flow = oauthFlow else {
            log("Error: No manual OAuth flow in progress")
            errorMessage = "No OAuth flow in progress"
            return
        }

        status = "Exchanging code for tokens..."
        log("Exchanging authorization code for tokens")

        do {
            let obtainedTokens = try await flow.handleCallback(url: url)
            tokens = obtainedTokens
            log("Obtained access token: \(String(obtainedTokens.accessToken.prefix(20)))...")
            if let refreshToken = obtainedTokens.refreshToken {
                log("Obtained refresh token: \(String(refreshToken.prefix(20)))...")
            }
            if let expiresAt = obtainedTokens.expiresAt {
                log("Token expires at: \(expiresAt)")
            }

            status = "Authentication successful!"
            isLoading = false

            // If MCP server URL is configured, try to connect
            if !mcpServerURL.isEmpty {
                await connectToMCPServer()
            }

        } catch {
            errorMessage = error.localizedDescription
            status = "Authentication failed"
            log("Error handling callback: \(error)")
            isLoading = false
        }
    }

    func connectToMCPServer() async {
        guard let _ = tokens, !mcpServerURL.isEmpty else {
            log("Cannot connect: No tokens or MCP server URL")
            return
        }

        status = "Connecting to MCP server..."
        log("Connecting to MCP server at \(mcpServerURL)")

        do {
            let config = MCPOAuthConfig(
                clientId: clientId,
                clientSecret: clientSecret.isEmpty ? nil : clientSecret,
                authorizationURL: URL(string: authURL)!,
                tokenURL: URL(string: tokenURL)!,
                scopes: scopes.components(separatedBy: " ").filter { !$0.isEmpty },
                redirectScheme: redirectScheme,
                scopeSeparator: scopeSeparator
            )

            let storage = InMemoryTokenStorage()
            // Store the tokens we already have
            if let tokens = tokens {
                try await storage.store(tokens: tokens, for: "test-server")
            }

            server = try await MCPServerConnection.oauthHTTP(
                url: URL(string: mcpServerURL)!,
                oauthConfig: config,
                storage: storage,
                delegate: nil
            )

            log("Connected to MCP server")

            await loadTools()

            status = "Connected to MCP server"

        } catch {
            errorMessage = "MCP connection failed: \(error.localizedDescription)"
            log("MCP connection error: \(error)")
            status = "MCP connection failed"
        }
    }

    func clearLogs() {
        logs = []
    }

    private func validateInputs() -> Bool {
        errorMessage = nil

        // Client ID is optional (dynamic registration, testing, etc.)
        if authURL.isEmpty || URL(string: authURL) == nil {
            errorMessage = "Valid Authorization URL is required"
            return false
        }
        if tokenURL.isEmpty || URL(string: tokenURL) == nil {
            errorMessage = "Valid Token URL is required"
            return false
        }
        if redirectScheme.isEmpty {
            errorMessage = "Redirect scheme is required"
            return false
        }
        if !mcpServerURL.isEmpty && URL(string: mcpServerURL) == nil {
            errorMessage = "MCP Server URL must be valid if provided"
            return false
        }

        return true
    }

    // MARK: - Auto Discovery Mode

    /// Connect using automatic OAuth discovery (MCP spec compliant)
    func connectWithAutoDiscovery() async {
        guard !mcpServerURL.isEmpty, let url = URL(string: mcpServerURL) else {
            errorMessage = "MCP Server URL is required for auto-discovery"
            return
        }

        isLoading = true
        status = "Connecting with auto-discovery..."
        errorMessage = nil
        tokens = nil
        tools = []

        log("Starting auto-discovery connection to \(mcpServerURL)")
        log("Using simplified mcpConnect() API")

        defer {
            isLoading = false
        }

        do {
            // Use the NEW simplified API - just one function call!
            // The callback router handles OAuth callbacks automatically.
            server = try await mcpConnect(
                url: url,
                redirectScheme: redirectScheme,
                onProgress: { [weak self] state in
                    Task { @MainActor in
                        self?.handleOAuthProgress(state)
                    }
                }
            )

            log("Connected to MCP server via auto-discovery!")

            await loadTools()
            status = "Connected (auto-discovery)"

        } catch {
            errorMessage = "Auto-discovery failed: \(error.localizedDescription)"
            log("Error: \(error)")
            status = "Connection failed"
        }
    }

    // MARK: - Stdio Connection

    /// Connect to a local MCP server via stdio
    func connectWithStdio() async {
        guard !stdioCommand.isEmpty else {
            errorMessage = "Command is required for stdio connection"
            return
        }

        isLoading = true
        status = "Connecting via stdio..."
        errorMessage = nil
        tools = []
        toolResult = nil
        selectedTool = nil

        // Build full command line
        let commandLine = stdioArguments.isEmpty
            ? stdioCommand
            : "\(stdioCommand) \(stdioArguments)"

        log("Starting stdio connection: \(commandLine)")
        log("Using simplified mcpConnect() API")

        defer {
            isLoading = false
        }

        do {
            // Use the NEW simplified API - just one function call!
            server = try await mcpConnect(
                commandLine,
                environment: stdioEnvironment.isEmpty ? nil : stdioEnvironment
            )

            log("Connected to stdio MCP server!")

            await loadTools()
            status = "Connected (stdio)"

        } catch {
            errorMessage = "Stdio connection failed: \(error.localizedDescription)"
            log("Error: \(error)")
            status = "Connection failed"
        }
    }

    // MARK: - Tool Management

    /// Load tools from the connected server
    private func loadTools() async {
        guard let server = server else { return }

        do {
            let mcpTools = try await server.listTools()
            tools = mcpTools.map { ToolInfo($0) }
            log("Found \(tools.count) tools: \(tools.map { $0.name }.joined(separator: ", "))")
        } catch {
            log("Could not list tools: \(error.localizedDescription)")
        }
    }

    /// Select a tool for invocation
    func selectTool(_ tool: ToolInfo) {
        selectedTool = tool
        toolParameters = [:]
        toolResult = nil
        log("Selected tool: \(tool.name)")

        // Log the input schema for debugging
        if let schemaStr = try? tool.inputSchema.prettyPrinted() {
            log("Input schema: \(schemaStr)")
        }
    }

    /// Execute the selected tool with the current parameters
    func executeTool() async {
        guard let tool = selectedTool, let server = server else {
            errorMessage = "No tool selected or not connected"
            return
        }

        isExecutingTool = true
        toolResult = nil
        log("Executing tool: \(tool.name)")

        do {
            // Convert string parameters to Value using library utility
            var args: [String: Value] = [:]
            for (key, value) in toolParameters {
                if let parsedValue = Value.from(userInput: value) {
                    args[key] = parsedValue
                }
            }

            log("Arguments: \(args)")

            // Call the tool
            let (content, isError) = try await server.callTool(
                name: tool.name,
                arguments: args
            )

            // Format the result using library utility
            toolResult = formatMCPToolResult(content, isError: isError)
            log("Tool result: \(toolResult?.prefix(200) ?? "")...")

        } catch {
            toolResult = "Error: \(error.localizedDescription)"
            log("Tool execution error: \(error)")
        }

        isExecutingTool = false
    }

    func disconnect() async {
        if let server = server {
            await server.disconnect()
            log("Disconnected from MCP server")
        }
        server = nil
        tokens = nil
        tools = []
        selectedTool = nil
        toolResult = nil
        toolParameters = [:]
        oauthFlow = nil
        status = "Disconnected"
        isLoading = false
    }

    // MARK: - OAuth Progress Handler

    private func handleOAuthProgress(_ state: MCPOAuthProgress) {
        switch state {
        case .openingBrowser:
            status = "Opening browser..."
            log("OAuth: Opening browser")
        case .waitingForUser:
            status = "Waiting for user..."
            log("OAuth: Waiting for user authorization")
        case .exchangingCode:
            status = "Exchanging code..."
            log("OAuth: Exchanging authorization code")
        case .refreshingTokens:
            status = "Refreshing tokens..."
            log("OAuth: Refreshing tokens")
        case .complete:
            status = "Authentication complete"
            log("OAuth: Complete!")
        case .failed(let error):
            status = "Authentication failed"
            log("OAuth: Failed - \(error)")
        }
    }
}
