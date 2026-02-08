# MCP (Model Context Protocol) Integration

Yrden provides full MCP integration, enabling agents to discover and use tools from external MCP servers. This includes local subprocess-based servers (stdio), remote HTTP/SSE servers, and servers requiring OAuth 2.0 authentication.

## Quick Start

### Local Server (stdio)

The simplest way to connect to a local MCP server:

```swift
// One-line connection using the convenience function
let server = try await mcpConnect("uvx mcp-server-fetch")

// Get tools and use with an agent
let tools = try await server.tools()
let agent = try Agent<String>(model: model, tools: tools)
```

### Remote Server (HTTP)

```swift
let server = try await mcpConnect(url: URL(string: "https://api.example.com/mcp")!)
let tools = try await server.tools()
```

### Remote Server with OAuth (macOS)

```swift
let server = try await mcpConnect(
    url: URL(string: "https://ai.todoist.net/mcp")!,
    redirectScheme: "myapp"
)
```

OAuth requires handling the callback in your AppDelegate:

```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ app: NSApplication, open urls: [URL]) {
        mcpHandleCallback(urls.first!)
    }
}
```

---

## Architecture

### Layers

The MCP integration is organized into three layers:

1. **MCPServerConnection** -- manages a single server connection (actor)
2. **ProtocolMCPCoordinator** -- manages multiple connections with resilience (actor)
3. **ProtocolMCPManager** -- SwiftUI-friendly manager with `@Published` state (`@MainActor`)

For most use cases, the `mcpConnect()` convenience functions or `MCPServerConnection` are sufficient.

### Connection State Machine

Each server connection follows this state machine:

```
idle -> connecting -> connected(tools: [ToolInfo])
          |               |
       failed  <----------+
          |
    reconnecting -> connecting
          |
     disconnected
```

Additionally, an `authenticating` state is used during OAuth flows:

```
idle -> connecting -> authenticating -> connected
                          |
                        failed
```

States are represented by the `ConnectionState` enum:

```swift
public enum ConnectionState: Sendable {
    case idle
    case connecting
    case authenticating(progress: AuthProgress)
    case connected(tools: [ToolInfo])
    case failed(message: String, retryCount: Int)
    case reconnecting(attempt: Int, maxAttempts: Int, nextRetryAt: Date?)
    case disconnected
}
```

---

## MCPServerConnection

The core connection type. It is an `actor` that wraps the MCP SDK's `Client` with a simpler interface.

### Factory Methods

**Stdio (local process):**

```swift
// Parsed command string
let server = try await MCPServerConnection.stdio("uvx mcp-server-fetch")

// Explicit command and arguments
let server = try await MCPServerConnection.stdio(
    command: "npx",
    arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
    environment: ["NODE_ENV": "production"],
    id: "filesystem",
    name: "Filesystem Server"
)

// With environment variables as KEY=VALUE lines
let server = try await MCPServerConnection.stdio(
    "npx mcp-server-github",
    environment: "GITHUB_TOKEN=ghp_xxx"
)
```

**HTTP (remote, no auth):**

```swift
let server = try await MCPServerConnection.http(
    url: URL(string: "https://api.example.com/mcp")!,
    headers: ["X-API-Key": "secret"]
)
```

**HTTP with explicit OAuth:**

```swift
let config = MCPOAuthConfig(
    clientId: "your-client-id",
    authorizationURL: URL(string: "https://auth.example.com/authorize")!,
    tokenURL: URL(string: "https://auth.example.com/token")!,
    scopes: ["mcp:read", "mcp:write"],
    redirectScheme: "myapp"
)

let server = try await MCPServerConnection.oauthHTTP(
    url: URL(string: "https://mcp.example.com")!,
    oauthConfig: config,
    storage: KeychainTokenStorage(service: "com.myapp.mcp"),
    delegate: SimpleOAuthDelegate.macOS()
)
```

**HTTP with auto-discovery OAuth (recommended):**

```swift
let server = try await MCPServerConnection.autoAuth(
    url: URL(string: "https://ai.todoist.net/mcp")!,
    storage: KeychainTokenStorage(),
    delegate: SimpleOAuthDelegate.macOS(),
    redirectScheme: "myapp"
)
```

Auto-discovery automatically:
- Discovers authorization endpoints via RFC 9728 (Protected Resource Metadata)
- Fetches authorization server metadata via RFC 8414
- Performs dynamic client registration via RFC 7591 (if supported)
- Initiates OAuth with PKCE

**Custom transport:**

```swift
let server = try await MCPServerConnection.withTransport(
    transport: myCustomTransport,
    id: "custom",
    name: "Custom Server"
)
```

### Tool Discovery

```swift
// List raw MCP tools (cached after first call)
let mcpTools = try await server.listTools()

// Refresh the cache
let updated = try await server.refreshTools()

// Get agent-compatible tools (wraps as [any Tool])
let tools = try await server.tools()
```

### Tool Execution

```swift
let (content, isError) = try await server.callTool(
    name: "read_file",
    arguments: ["path": .string("/tmp/hello.txt")]
)
```

### Resources and Prompts

```swift
// Resources
let resources = try await server.listResources()
let content = try await server.readResource(uri: "file:///tmp/hello.txt")
try await server.subscribeToResource(uri: "file:///tmp/watch-me.txt")

// Prompts
let prompts = try await server.listPrompts()
let (description, messages) = try await server.getPrompt(
    name: "summarize",
    arguments: ["style": .string("brief")]
)
```

### Notifications

```swift
await server.onToolsChanged {
    let updated = try await server.refreshTools()
    print("Tools changed: \(updated.map(\.name))")
}

await server.onResourceUpdated { uri in
    print("Resource updated: \(uri)")
}
```

### Capability Checks

```swift
server.supportsTools      // true if server has tool capabilities
server.supportsResources  // true if server has resource capabilities
server.supportsPrompts    // true if server has prompt capabilities
```

### Lifecycle

```swift
// Disconnect when done
await server.disconnect()
```

---

## MCPToolProxy

`MCPToolProxy` implements the `Tool` protocol, routing tool calls through the MCP coordinator. This is the recommended way to expose MCP tools to agents when using the coordinator architecture.

Key properties:
- Does not hold connection state -- routes through the coordinator
- Handles reconnection transparently
- Supports per-tool timeout overrides
- Maps MCP errors to tool-friendly results

```swift
let proxy = MCPToolProxy(
    serverID: "filesystem",
    toolInfo: toolInfo,
    coordinator: coordinator,
    timeout: .seconds(60),
    requiresApproval: false
)

// Use directly in tool arrays
let agent = try Agent<String>(model: model, tools: [proxy])
```

For direct `MCPServerConnection` usage, `MCPServerTool` is used instead (created automatically by `server.tools()`).

---

## ProtocolMCPCoordinator

Manages multiple MCP server connections with resilience features.

### Configuration

```swift
let config = CoordinatorConfiguration(
    toolTimeout: .seconds(30),          // Per-tool call timeout
    connectionTimeout: .seconds(10),     // Initial connection timeout
    oauthTimeout: .seconds(120),        // OAuth flow timeout
    reconnectPolicy: .exponentialBackoff(maxAttempts: 5, baseDelay: 1.0),
    healthCheckInterval: .seconds(30),   // nil to disable
    pollingInterval: .milliseconds(100)
)
```

### Reconnection Policies

```swift
// No automatic reconnection
.none

// Retry immediately up to N times
.immediate(maxAttempts: 3)

// Exponential backoff (1s, 2s, 4s, 8s, ...)
.exponentialBackoff(maxAttempts: 5, baseDelay: 1.0)
```

### Health Checks

The coordinator can periodically check connection health and trigger automatic reconnection for failed connections:

```swift
await coordinator.startHealthChecks()
```

---

## ProtocolMCPManager (SwiftUI)

A `@MainActor ObservableObject` for SwiftUI integration. Holds `@Published` state and delegates all I/O to the coordinator.

```swift
@StateObject private var mcp = ProtocolMCPManager(
    coordinator: ProtocolMCPCoordinator(connectionFactory: factory)
)

var body: some View {
    List(Array(mcp.servers.values)) { server in
        HStack {
            Text(server.displayName)
            Spacer()
            Text(server.status.description)
        }
    }
    .task {
        mcp.serverSpecs = [
            .stdio(
                command: "uvx",
                arguments: ["mcp-server-filesystem"],
                environment: nil,
                id: "fs",
                displayName: "Filesystem"
            ),
        ]
        await mcp.startAll()
    }
}
```

### Getting Tools

```swift
// All tools from all connected servers
let tools = mcp.allTools()

// Tools from a specific server
let fsTools = mcp.tools(matching: { $0.serverID == "fs" })

// Tools matching a mode
let readOnlyTools = mcp.tools(for: .readOnly)
```

---

## Tool Modes and Filters

Tool modes define profiles of available tools for UI selection.

### Built-in Modes

```swift
ToolMode.fullAccess  // All tools from all servers
ToolMode.readOnly    // Tools matching read/list/get patterns
ToolMode.none        // No tools
```

### Custom Modes

```swift
let safeMode = ToolMode(
    id: "safe",
    name: "Safe Mode",
    icon: "shield",
    filter: .and([
        .servers(["filesystem"]),
        .not(.tools(["delete_file", "remove_directory"]))
    ])
)
```

### Filter Types

```swift
.all                           // Include all tools
.none                          // Include no tools
.servers(["fs", "github"])     // Tools from specific servers
.tools(["read_file", "search"]) // Specific tools by name
.toolIDs(["fs.read_file"])     // Specific tools by qualified ID
.pattern("^(read|list)_")     // Regex pattern matching tool name

// Combinators
.and([filter1, filter2])       // All must match
.or([filter1, filter2])        // Any must match
.not(filter)                   // Invert
```

---

## Events

The MCP system emits events throughout the lifecycle:

```swift
public enum MCPEvent: Sendable, Equatable {
    // Connection lifecycle
    case stateChanged(serverID: String, from: ConnectionState, to: ConnectionState)
    case log(serverID: String, entry: LogEntry)

    // Tool execution
    case toolCallStarted(serverID: String, tool: String, requestId: String)
    case toolCallCompleted(requestId: String, duration: TimeInterval, success: Bool)
    case toolCallCancelled(requestId: String, reason: CancellationReason)
}
```

Subscribe via the coordinator or manager:

```swift
for await event in coordinator.events {
    switch event {
    case .stateChanged(let id, _, let to):
        print("Server \(id) -> \(to)")
    case .toolCallStarted(_, let tool, _):
        print("Calling: \(tool)")
    default:
        break
    }
}
```

### Alerts

User-facing alerts for UI notification:

```swift
for await alert in coordinator.alerts {
    switch alert {
    case .connectionFailed(let id, let error):
        showError("Server \(id) failed: \(error)")
    case .reconnecting(let id, let attempt):
        showInfo("Reconnecting to \(id) (attempt \(attempt))")
    case .reconnected(let id):
        showSuccess("Reconnected to \(id)")
    case .toolTimedOut(let id, let tool):
        showWarning("Tool \(tool) timed out on \(id)")
    default:
        break
    }
}
```

---

## Transport Types

### Stdio (SubprocessStdioTransport)

Spawns a local subprocess and communicates via stdin/stdout using the MCP JSON-RPC protocol.

Features:
- PATH augmentation for common binary locations (Homebrew, nvm, pip, Volta, etc.)
- Non-blocking I/O with async/await
- Stderr capture and logging via callback
- Graceful shutdown (SIGTERM then SIGKILL)

```swift
let server = try await MCPServerConnection.stdio(
    command: "uvx",
    arguments: ["mcp-server-filesystem"],
    logCallback: { message in
        print("[MCP] \(message)")
    }
)
```

### HTTP (HTTPClientTransport)

Uses the MCP SDK's HTTP transport for remote servers with Server-Sent Events.

```swift
let server = try await MCPServerConnection.http(
    url: URL(string: "https://api.example.com/mcp")!,
    headers: ["Authorization": "Bearer token123"]
)
```

### Authenticated HTTP (AuthenticatedHTTPTransport)

Wraps HTTP transport with OAuth token injection. Automatically adds Bearer tokens to requests.

### Auto-Auth HTTP (MCPAutoAuthTransport)

The highest-level transport that handles the full OAuth discovery and authentication flow automatically.

---

## OAuth Support

### Overview

Yrden implements the MCP OAuth specification, including:
- OAuth 2.0 Authorization Code flow with PKCE
- Protected Resource Metadata discovery (RFC 9728)
- Authorization Server Metadata discovery (RFC 8414)
- Dynamic Client Registration (RFC 7591)
- Token refresh and storage

### Components

**MCPOAuthConfig** -- Configuration for OAuth endpoints, scopes, and client credentials.

**MCPOAuthFlow** -- Handles the OAuth flow mechanics (building auth URLs, exchanging codes, refreshing tokens).

**MCPAuthDiscovery** -- Discovers OAuth endpoints from server metadata. Implements the MCP auth discovery flow:
1. Client sends request to MCP server
2. Server returns 401 with `WWW-Authenticate` header
3. Client fetches Protected Resource Metadata
4. Client fetches Authorization Server Metadata
5. Client performs Dynamic Client Registration (if supported)
6. Client proceeds with OAuth flow

**MCPOAuthDelegate** -- Protocol for UI interactions during OAuth:
```swift
public protocol MCPOAuthDelegate: AnyObject, Sendable {
    func openAuthorizationURL(_ url: URL) async throws
    func promptReauthentication(for serverID: String, reason: String) async -> Bool
    func authenticationProgress(_ state: MCPOAuthProgress)
}
```

**SimpleOAuthDelegate** -- Closure-based delegate for common use cases:
```swift
// macOS: opens URL in default browser
let delegate = SimpleOAuthDelegate.macOS()

// With progress tracking
let delegate = SimpleOAuthDelegate.macOS { progress in
    print("OAuth progress: \(progress)")
}

// Custom
let delegate = SimpleOAuthDelegate { url in
    UIApplication.shared.open(url)
}
```

### Token Storage

Three built-in storage implementations:

| Storage | Platform | Persistence | Security |
|---------|----------|-------------|----------|
| `KeychainTokenStorage` | macOS/iOS | Persistent | Encrypted (Keychain) |
| `FileTokenStorage` | All | Persistent | Not encrypted |
| `InMemoryTokenStorage` | All | None | N/A |

```swift
// Keychain (recommended for production)
let storage = KeychainTokenStorage(service: "com.myapp.mcp")

// File-based (Linux or testing)
let storage = try FileTokenStorage(directory: tokensDir)

// In-memory (testing)
let storage = InMemoryTokenStorage()
```

### Callback Routing

`MCPCallbackRouter` routes OAuth callbacks to the correct pending authorization flow:

```swift
// In your AppDelegate (macOS)
func application(_ app: NSApplication, open urls: [URL]) {
    mcpHandleCallback(urls.first!)
}

// Or use the async version
Task {
    await mcpHandleCallbackAsync(url)
}
```

The router handles:
- Race conditions (transport registered BEFORE browser opens)
- Multiple concurrent flows (each matched by unique state parameter)
- Timeouts (default: 5 minutes) to prevent memory leaks from abandoned flows
- State-based routing for CSRF protection

---

## Server Specifications

When using the coordinator, servers are defined as `ServerSpec` values:

```swift
// Local stdio server
.stdio(
    command: "uvx",
    arguments: ["mcp-server-filesystem", "--root", "/tmp"],
    environment: nil,
    id: "filesystem",
    displayName: "Filesystem"
)

// Remote HTTP server
.http(
    url: URL(string: "https://api.example.com/mcp")!,
    headers: nil,
    id: "remote",
    displayName: "Remote API"
)

// Remote with explicit OAuth
.oauth(
    url: URL(string: "https://mcp.example.com")!,
    config: OAuthConfigSpec(
        clientId: "abc",
        authorizationURL: authURL,
        tokenURL: tokenURL,
        scopes: ["read", "write"],
        redirectScheme: "myapp"
    ),
    id: "oauth-server",
    displayName: "OAuth Server"
)

// Remote with auto-discovery OAuth
.autoAuth(
    url: URL(string: "https://ai.todoist.net/mcp")!,
    redirectScheme: "myapp",
    clientName: "My App",
    id: "todoist",
    displayName: "Todoist"
)
```

---

## Error Handling

### MCPConnectionError

```swift
public enum MCPConnectionError: Error, Sendable {
    case notConnected(serverID: String)
    case unknownServer(serverID: String)
    case toolTimeout(serverID: String, tool: String, timeout: Duration)
    case toolCancelled(serverID: String, tool: String)
    case connectionFailed(serverID: String, message: String)
    case internalError(String)
}
```

### MCPToolError

```swift
public enum MCPToolError: Error, Sendable {
    case toolReturnedError(name: String, message: String)
    case executionFailed(name: String, server: String, message: String)
    case serverDisconnected(serverID: String)
    case toolCancelled(serverID: String, tool: String)
}
```

### MCPOAuthError

```swift
public enum MCPOAuthError: Error, Sendable {
    case authorizationDenied(String?)
    case stateMismatch
    case tokenExchangeFailed(String)
    case tokenRefreshFailed(String)
    case invalidTokenResponse(String)
    case notAuthenticated
    case storageError(String)
    case networkError(Error)
    case invalidCallbackURL(String)
    case cancelled
}
```

---

## Integration with Agents

MCP tools integrate seamlessly with the Yrden agent system through the `Tool` protocol:

```swift
// Direct connection approach
let server = try await mcpConnect("uvx mcp-server-filesystem")
let mcpTools = try await server.tools()

let agent = try Agent<String>(
    model: model,
    tools: localTools + mcpTools  // Mix local and MCP tools
)

let result = try await agent.run("List files in /tmp")
```

```swift
// Coordinator approach (multiple servers)
let manager = ProtocolMCPManager(coordinator: coordinator)
manager.serverSpecs = [
    .stdio(command: "uvx", arguments: ["mcp-server-filesystem"], environment: nil, id: "fs", displayName: "FS"),
    .stdio(command: "uvx", arguments: ["mcp-server-fetch"], environment: nil, id: "fetch", displayName: "Fetch"),
]
await manager.startAll()

let agent = try Agent<String>(
    model: model,
    tools: manager.allTools()
)
```
