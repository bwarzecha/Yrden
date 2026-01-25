# MCP Simplified API Design

## Goal

Reduce a typical MCP client app from ~700 lines to ~50 lines while:
- Preventing common mistakes (race conditions, memory leaks, state bugs)
- Making the simple case trivial
- Keeping advanced customization possible
- **Supporting production requirements** (reconnection, multiple servers, error recovery)

## Naming Decision

**`mcpConnect()`** - Global function. Originally `mcpConnect()` was planned, but this conflicts with the `MCP` module from the SDK (which provides `MCP.Tool`, etc.). Using `mcpConnect()` and `mcpHandleCallback()` as top-level functions avoids the namespace collision.

---

## Production App Requirements

Before diving into API, let's list what real production apps need:

### Error Recovery
- Connection drops mid-session → auto-reconnect?
- Network failures during OAuth → retry logic
- Token refresh failures → re-authenticate
- Server goes down → graceful degradation

### Multiple Connections
- Different MCP servers for different capabilities
- Some OAuth, some local stdio
- Independent lifecycle per connection

### App Lifecycle
- iOS: app backgrounded, suspended, terminated
- macOS: app closed during OAuth flow
- Resume connections on app restart?
- Persist tokens across launches

### Observability
- Structured logging for debugging
- State changes for UI updates
- Error tracking integration

### Testing
- Mock MCP servers
- Simulate OAuth flows
- Test error scenarios

---

## Key Insight: The Wrapper Problem

Looking at typical SwiftUI usage, every app would write this boilerplate:

```swift
// This wrapper is ~25 lines that EVERY app would copy-paste
@MainActor
class MCPConnection: ObservableObject {
    @Published var server: MCPServer?
    @Published var state: MCPConnectionState = .disconnected

    func connect(_ command: String) {
        Task {
            do {
                let srv = try await mcpConnect(command)
                self.server = srv
                for await newState in srv.stateStream {
                    self.state = newState
                }
            } catch {
                self.state = .failed(error)
            }
        }
    }
}
```

**This is the very boilerplate we're trying to eliminate!**

### Solution: Library provides the observable wrapper

```swift
// Library provides this - apps don't write it
@MainActor
public class MCPClient: ObservableObject {
    /// All connections with their individual states
    @Published public private(set) var connections: [String: MCPConnection] = [:]

    public func connect(id: String = "default", _ command: String) { ... }
    public func connect(id: String = "default", url: URL, ...) { ... }
    public func disconnect(id: String = "default") { ... }
    public func disconnectAll() { ... }

    // Convenience for single-server apps
    public var server: MCPServer? { connections["default"]?.server }
    public var state: MCPConnectionState { connections["default"]?.state ?? .idle }
}

/// State of a single MCP connection
public struct MCPConnection: Identifiable {
    public let id: String
    public let state: MCPConnectionState
    public let server: MCPServer?  // nil until connected
}

/// State for ONE connection (not the whole client)
public enum MCPConnectionState: Equatable, Sendable {
    case idle           // Not started
    case connecting     // TCP/stdio connecting
    case authenticating(MCPAuthProgress)  // OAuth in progress
    case connected      // Ready to use
    case failed(Error)  // Connection failed
    case disconnected   // Was connected, now closed
}
```

**Now UI can show state per connection:**
```swift
ForEach(Array(mcp.connections.values)) { conn in
    HStack {
        Text(conn.id)
        switch conn.state {
        case .connecting: ProgressView().scaleEffect(0.5)
        case .authenticating: Text("Auth...")
        case .connected: Image(systemName: "checkmark.circle.fill")
        case .failed(let e): Text(e.localizedDescription).foregroundColor(.red)
        default: EmptyView()
        }
    }
}
```

---

## Revised Layered API

### Layer 0: SwiftUI (Zero Boilerplate)

```swift
import SwiftUI
import Yrden

@main
struct MyApp: App {
    @StateObject private var mcp = MCPClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mcp)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var mcp: MCPClient

    var body: some View {
        switch mcp.state {
        case .idle:
            Button("Connect") {
                mcp.connect("uvx mcp-server-fetch")
            }
        case .connecting:
            ProgressView("Connecting...")
        case .ready:
            ToolsView(server: mcp.servers["default"]!)
        case .failed(_, let error):
            Text("Error: \(error.localizedDescription)")
        }
    }
}
```

**Lines: ~25** - And that includes actual UI logic!

### Layer 1: Async/Await (Non-SwiftUI apps, CLI tools)

```swift
// Direct async API for non-UI code
let server = try await mcpConnect("uvx mcp-server-fetch")
let tools = try await server.listTools()
```

### Layer 2: Full Control (Custom transports, debugging)

```swift
// Current API remains available
let transport = MCPAutoAuthTransport(...)
let connection = try await MCPServerConnection.withTransport(transport, ...)
```

---

## MCPClient Design (SwiftUI Layer)

```swift
@MainActor
public class MCPClient: ObservableObject {
    // MARK: - Published State (per-connection)

    /// All connections with their individual states
    @Published public private(set) var connections: [String: MCPConnection] = [:]

    /// Detailed logs (for debugging UI)
    @Published public private(set) var logs: [MCPLogEntry] = []

    // MARK: - Configuration

    /// Token storage (defaults to Keychain)
    public var tokenStorage: MCPTokenStorage = KeychainTokenStorage()

    /// Reconnection policy
    public var reconnectPolicy: MCPReconnectPolicy = .onNetworkChange

    /// Maximum log entries to keep
    public var maxLogEntries: Int = 100

    // MARK: - Connect Methods

    /// Connect to stdio server
    public func connect(
        id: String = "default",
        _ command: String
    ) { ... }

    /// Connect to HTTP server (no auth)
    public func connect(
        id: String = "default",
        url: URL
    ) { ... }

    #if os(macOS)
    /// Connect with OAuth (macOS)
    public func connect(
        id: String = "default",
        url: URL,
        redirectScheme: String
    ) { ... }
    #endif

    #if os(iOS)
    /// Connect with OAuth (iOS)
    public func connect(
        id: String = "default",
        url: URL,
        redirectScheme: String,
        anchor: ASPresentationAnchor
    ) { ... }
    #endif

    // MARK: - Disconnect

    public func disconnect(id: String = "default") { ... }
    public func disconnectAll() { ... }

    // MARK: - Convenience (single-server apps)

    /// First/default server (for single-server apps)
    public var server: MCPServer? { connections["default"]?.server }

    /// Default connection state (for single-server apps)
    public var state: MCPConnectionState { connections["default"]?.state ?? .idle }

    /// Whether any server is connected
    public var isConnected: Bool {
        connections.values.contains { $0.state == .connected }
    }
}

/// State of a single MCP connection
public struct MCPConnection: Identifiable, Sendable {
    public let id: String
    public let state: MCPConnectionState
    public let server: MCPServer?  // nil until connected
}

/// State for ONE connection (not the whole client)
public enum MCPConnectionState: Equatable, Sendable {
    case idle           // Not started
    case connecting     // TCP/stdio connecting
    case authenticating(MCPAuthProgress)  // OAuth in progress
    case connected      // Ready to use
    case failed(Error)  // Connection failed
    case disconnected   // Was connected, now closed

    // Equatable conformance for Error
    public static func == (lhs: MCPConnectionState, rhs: MCPConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.connecting, .connecting),
             (.connected, .connected), (.disconnected, .disconnected):
            return true
        case (.authenticating(let l), .authenticating(let r)):
            return l == r
        case (.failed, .failed):
            return true  // Errors compared by case only
        default:
            return false
        }
    }
}
```

### Per-Connection State Machine

Each connection has its own independent state:

```
[idle] --connect()--> [connecting]
                           |
                           +--(success)--> [connected]
                           |
                           +--(needs auth)--> [authenticating(progress)]
                           |                        |
                           |                        +--(callback)--> [connecting]
                           |                        |
                           |                        +--(cancel/timeout)--> [failed(error)]
                           |
                           +--(error)--> [failed(error)]

[connected] --disconnect()--> [disconnected]
[connected] --(connection lost)--> [connecting] (if reconnect policy)
[failed] --connect()--> [connecting]
```

**UI Example - Multiple Connections:**
```swift
ForEach(Array(mcp.connections.values)) { conn in
    HStack {
        Text(conn.id)
        Spacer()
        switch conn.state {
        case .idle: Text("Idle").foregroundColor(.secondary)
        case .connecting: ProgressView().scaleEffect(0.5)
        case .authenticating(let p): Text(p.description)
        case .connected: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed(let e): Text(e.localizedDescription).foregroundColor(.red)
        case .disconnected: Text("Disconnected")
        }
    }
}
```

---

## Platform-Specific OAuth

### macOS: External Safari + Callback Router

```swift
// App provides: redirect scheme, callback routing
class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ app: NSApplication, open urls: [URL]) {
        mcpHandleCallback(urls.first!)  // Routes to correct pending flow
    }
}

// MCPClient uses NSWorkspace.shared.open() internally
mcp.connect(url: serverURL, redirectScheme: "myapp")
```

### iOS: ASWebAuthenticationSession (No Callback Routing!)

```swift
// iOS uses ASWebAuthenticationSession - handles callback automatically
// No AppDelegate code needed!
mcp.connect(url: serverURL, redirectScheme: "myapp", anchor: window)

// Internally:
// 1. Create ASWebAuthenticationSession with callback URL
// 2. Present it (shows Safari sheet)
// 3. User authenticates
// 4. ASWebAuthenticationSession returns callback URL directly
// 5. No URL scheme handling in AppDelegate!
```

**Key insight:** On iOS, the entire callback routing problem doesn't exist because ASWebAuthenticationSession handles it internally.

---

## Reconnection Policy

```swift
public enum MCPReconnectPolicy: Sendable {
    /// Never auto-reconnect
    case never

    /// Reconnect when network becomes available
    case onNetworkChange

    /// Exponential backoff with max delay
    case exponentialBackoff(initialDelay: Duration, maxDelay: Duration, maxAttempts: Int?)

    /// Custom logic
    case custom(@Sendable (Error, Int) -> Duration?)  // error, attempt -> delay or nil to stop
}
```

Usage:
```swift
let mcp = MCPClient()
mcp.reconnectPolicy = .exponentialBackoff(
    initialDelay: .seconds(1),
    maxDelay: .minutes(5),
    maxAttempts: 10
)
```

---

## Complete Production Examples

### iOS App (~30 lines)

```swift
import SwiftUI
import Yrden

@main
struct TodoistApp: App {
    @StateObject private var mcp = MCPClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mcp)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var mcp: MCPClient
    @Environment(\.window) var window  // iOS 15+

    var body: some View {
        Group {
            if mcp.isConnected {
                TaskListView()
            } else {
                ConnectButton()
            }
        }
        .overlay {
            if case .authenticating = mcp.state {
                Color.black.opacity(0.3)
                ProgressView("Authenticating...")
            }
        }
    }
}

struct ConnectButton: View {
    @EnvironmentObject var mcp: MCPClient
    @Environment(\.window) var window

    var body: some View {
        Button("Connect to Todoist") {
            mcp.connect(
                url: URL(string: "https://ai.todoist.net/mcp")!,
                redirectScheme: "myapp",
                anchor: window
            )
        }
        .disabled(mcp.state != .idle)
    }
}
```

**No AppDelegate, no callback handling, ~30 lines total.**

### macOS App (~40 lines)

```swift
import SwiftUI
import Yrden

@main
struct TodoistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var mcp = MCPClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mcp)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ app: NSApplication, open urls: [URL]) {
        mcpHandleCallback(urls.first!)
    }
}

struct ContentView: View {
    @EnvironmentObject var mcp: MCPClient

    var body: some View {
        Group {
            switch mcp.state {
            case .idle:
                Button("Connect") {
                    mcp.connect(
                        url: URL(string: "https://ai.todoist.net/mcp")!,
                        redirectScheme: "myapp"
                    )
                }
            case .connecting, .authenticating:
                ProgressView()
            case .ready:
                TaskListView()
            case .failed(_, let error):
                VStack {
                    Text("Error: \(error.localizedDescription)")
                    Button("Retry") { mcp.connect(...) }
                }
            }
        }
    }
}
```

### CLI Tool (~15 lines)

```swift
import Yrden

@main
struct MCPCli {
    static func main() async throws {
        let server = try await mcpConnect("uvx mcp-server-fetch")

        let tools = try await server.listTools()
        for tool in tools {
            print("- \(tool.name): \(tool.description ?? "")")
        }

        let result = try await server.callTool(
            name: "fetch",
            arguments: ["url": .string("https://example.com")]
        )
        print(result)
    }
}
```

### Multi-Server App

```swift
@StateObject private var mcp = MCPClient()

// Connect to multiple servers
mcp.connect(id: "todoist", url: todoistURL, redirectScheme: "myapp")
mcp.connect(id: "filesystem", "uvx mcp-server-filesystem /tmp")
mcp.connect(id: "memory", "npx @modelcontextprotocol/server-memory")

// Use specific server
if let todoist = mcp.servers["todoist"] {
    let tasks = try await todoist.callTool(name: "get_tasks", arguments: nil)
}

// Disconnect one
mcp.disconnect(id: "filesystem")

// Disconnect all
mcp.disconnectAll()
```

---

## Current Pain Points

### 1. OAuth Callback Routing Hell
```swift
// Current: Client must manually route callbacks
func application(_ app: NSApplication, open urls: [URL]) {
    // Which connection does this belong to?
    // What if multiple OAuth flows are pending?
    // What if the transport isn't stored yet?
    await viewModel.handleCallback(url)  // Manual routing
}

// In ViewModel - more manual routing
func handleCallback(url: URL) async {
    if let transport = autoAuthTransport {
        try await transport.handleOAuthCallback(url: url)
    } else if let flow = oauthFlow {
        try await flow.handleCallback(url: url)
    }
    // Easy to get wrong, race conditions possible
}
```

**Risks:**
- Race condition: callback arrives before transport is stored
- Memory leak: transport stored but never cleaned up
- Wrong routing: multiple pending flows, wrong one gets callback

### 2. Token Management Exposed
```swift
// Current: Client manages tokens
@Published var tokens: MCPOAuthTokens?  // Why does UI care?

// Client creates storage
let storage = InMemoryTokenStorage()

// Client stores tokens manually
try await storage.store(tokens: tokens, for: "test-server")
```

**Risks:**
- Tokens in memory after logout (security)
- Inconsistent storage (some in Keychain, some in memory)
- Token refresh timing bugs

### 3. Transport/Connection Lifecycle Confusion
```swift
// Current: Create transport, then connection, keep both
let transport = MCPAutoAuthTransport(...)
self.autoAuthTransport = transport  // Must store for callbacks
server = try await MCPServerConnection.withTransport(transport, ...)
// Now we have transport AND server - which do we use?
```

**Risks:**
- Holding transport reference after disconnect
- Calling methods on wrong object
- Unclear ownership

### 4. Verbose Configuration
```swift
// Current: Many parameters repeated
let config = MCPOAuthConfig(
    clientId: clientId,
    clientSecret: clientSecret.isEmpty ? nil : clientSecret,
    authorizationURL: URL(string: authURL)!,
    tokenURL: URL(string: tokenURL)!,
    scopes: scopes.components(separatedBy: " ").filter { !$0.isEmpty },
    redirectScheme: redirectScheme,
    scopeSeparator: scopeSeparator
)
// Config created twice in same file!
```

---

## Proposed Layered API

### Layer 1: Simple (90% of use cases)

```swift
// Stdio - one line
let server = try await mcpConnect("uvx mcp-server-fetch")

// OAuth - automatic discovery, automatic everything
let server = try await mcpConnect(
    url: "https://ai.todoist.net/mcp",
    redirectScheme: "myapp",
    openURL: { NSWorkspace.shared.open($0) }
)

// AppDelegate - one line
func application(_ app: NSApplication, open urls: [URL]) {
    mcpHandleCallback(urls.first!)
}
```

### Layer 2: Customizable (when needed)

```swift
// Custom token storage
let server = try await mcpConnect(
    url: "https://api.example.com/mcp",
    redirectScheme: "myapp",
    openURL: { NSWorkspace.shared.open($0) },
    tokenStorage: MyCustomStorage()
)

// Custom OAuth config (skip auto-discovery)
let server = try await mcpConnect(
    url: "https://api.example.com/mcp",
    oauth: MCPOAuthConfig(
        authorizationURL: ...,
        tokenURL: ...,
        scopes: [...]
    ),
    openURL: { ... }
)

// Progress callbacks
let server = try await mcpConnect(
    url: "https://api.example.com/mcp",
    redirectScheme: "myapp",
    openURL: { ... },
    onProgress: { state in
        print("Auth progress: \(state)")
    }
)
```

### Layer 3: Full Control (existing API)

```swift
// Current API remains available for edge cases
let transport = MCPAutoAuthTransport(...)
let server = try await MCPServerConnection.withTransport(transport, ...)
```

---

## Design Decisions

### 1. Callback Router: Singleton vs Instance

**Option A: Global Singleton**
```swift
// Simple, works everywhere
mcpHandleCallback(url)
```
- Pros: Simple, no passing around
- Cons: Global state, harder to test, can't have isolated instances

**Option B: Instance-based with Global Default**
```swift
// Default (covers 99% of cases)
mcpHandleCallback(url)

// Advanced: Custom router for testing
let router = MCPCallbackRouter()
let server = try await mcpConnect(url: ..., router: router)
router.handleCallback(url)
```
- Pros: Testable, isolated
- Cons: Slightly more complex

**Decision: Option B** - Global default, injectable for testing

### 2. Token Storage: Default

**Options:**
- A) In-memory (current default) - Tokens lost on app restart
- B) Keychain (macOS/iOS) - Persists, secure
- C) UserDefaults - Persists, not secure
- D) No default, require explicit choice

**Decision: B (Keychain)** with fallback to in-memory
- Most apps want persistent tokens
- Keychain is the secure choice on Apple platforms
- Fallback for platforms without Keychain

### 3. OAuth State Management

**Current Problem:**
```swift
// Client creates transport
let transport = MCPAutoAuthTransport(...)
// Client stores it
self.autoAuthTransport = transport
// Race: callback might arrive before this line!
```

**Solution: Library owns the pending state**
```swift
// Library registers BEFORE opening browser
internal func startOAuth() async throws {
    let state = generateState()
    MCPCallbackRouter.shared.register(state: state, continuation: ...)
    // NOW open browser - callback can't arrive before registration
    openURL(authURL)
}
```

### 4. Connection Lifecycle

**State Machine:**
```
[Disconnected] --connect()--> [Connecting] --success--> [Connected]
                                   |
                                   +--(needs auth)--> [Authenticating] --callback--> [Connecting]
                                   |
                                   +--(error)--> [Failed]

[Connected] --disconnect()--> [Disconnected]
[Connected] --(token expired)--> [Refreshing] --success--> [Connected]
                                      |
                                      +--(refresh failed)--> [Authenticating]
```

**Public State:**
```swift
public enum MCPConnectionState: Sendable {
    case disconnected
    case connecting
    case authenticating  // Waiting for user in browser
    case connected
    case failed(Error)
}

// Observable
server.state  // Current state
server.stateStream  // AsyncSequence<MCPConnectionState>
```

---

## Risk Mitigation

### Risk 1: Race Condition in Callback Routing

**Problem:** Callback URL arrives before the pending flow is registered.

**Mitigation:**
```swift
// WRONG order:
openBrowser(authURL)
router.register(state, continuation)  // Too late!

// RIGHT order (library enforces):
router.register(state, continuation)  // Register FIRST
openBrowser(authURL)  // Then open browser
```

**Implementation:**
- `waitForCallback()` MUST be called before `openURL()`
- Single method handles both: `performOAuthFlow()` does registration, then opens URL

### Risk 2: Memory Leak from Uncleaned State

**Problem:** Pending continuation never resumed (user closes browser).

**Mitigation:**
```swift
// Timeout with cleanup
func waitForCallback(timeout: Duration = .minutes(5)) async throws -> URL {
    defer { cleanup() }  // Always cleanup

    return try await withTimeout(timeout) {
        try await withCheckedThrowingContinuation { ... }
    }
}
```

**Also:**
- `disconnect()` cancels pending OAuth flows
- App termination cancels pending flows (actor deinit)

### Risk 3: Multiple Pending Flows

**Problem:** User starts OAuth, cancels, starts again. Two flows pending.

**Mitigation:**
```swift
// Only one flow per server URL
func startOAuth(for url: URL) {
    // Cancel any existing flow for this URL
    cancelPending(for: url)
    // Start new flow
    register(...)
}
```

### Risk 4: Token Security

**Problem:** Tokens in memory after logout, or stored insecurely.

**Mitigation:**
- Default to Keychain storage
- `disconnect()` clears tokens from memory
- Optional: `disconnect(clearTokens: true)` removes from Keychain

### Risk 5: Thread Safety

**Problem:** Callbacks on wrong thread, data races.

**Mitigation:**
- All public API is `async` (caller controls thread)
- Internal state managed by `actor` (thread-safe)
- Callbacks to client are `@Sendable`

### Risk 6: Stale Connection Reference

**Problem:** Client holds `server` after disconnect, calls methods.

**Mitigation:**
```swift
public func callTool(...) async throws -> ... {
    guard isConnected else {
        throw MCPError.notConnected
    }
    ...
}
```

---

## API Surface

### Main Entry Points

```swift
public enum MCP {
    /// Connect to stdio server
    static func connect(_ command: String) async throws -> MCPServer

    /// Connect to HTTP server (no auth)
    static func connect(url: URL) async throws -> MCPServer

    /// Connect to HTTP server with OAuth
    static func connect(
        url: URL,
        redirectScheme: String,
        openURL: @escaping (URL) -> Void,
        tokenStorage: MCPTokenStorage? = nil,
        onProgress: ((MCPAuthProgress) -> Void)? = nil
    ) async throws -> MCPServer

    /// Handle OAuth callback (call from AppDelegate)
    static func handleCallback(_ url: URL) -> Bool
}
```

### MCPServer (renamed from MCPServerConnection for clarity)

```swift
public actor MCPServer {
    // State
    var state: MCPConnectionState { get }
    var stateStream: AsyncStream<MCPConnectionState> { get }
    var isConnected: Bool { get }

    // Tools
    func listTools() async throws -> [MCP.Tool]
    func callTool(name: String, arguments: [String: Value]?) async throws -> ToolResult

    // Resources
    func listResources() async throws -> [Resource]
    func readResource(uri: String) async throws -> [Resource.Content]

    // Prompts
    func listPrompts() async throws -> [Prompt]
    func getPrompt(name: String, arguments: [String: Value]?) async throws -> PromptResult

    // Lifecycle
    func disconnect() async
    func disconnect(clearTokens: Bool) async  // Also clear stored tokens
}
```

### MCPAuthProgress

```swift
public enum MCPAuthProgress: Sendable {
    case discovering           // Finding OAuth endpoints
    case registering           // Dynamic client registration
    case openingBrowser        // About to open auth URL
    case waitingForUser        // User is in browser
    case exchangingCode        // Got callback, exchanging
    case complete              // Done!
    case failed(Error)
}
```

---

## Observable State

Two levels of observability:

### 1. MCPClient (SwiftUI layer) - Per-connection state
```swift
@MainActor
public class MCPClient: ObservableObject {
    /// All connections with their individual states
    @Published public private(set) var connections: [String: MCPConnection] = [:]
}
```

### 2. MCPServer (async layer) - Single server state stream
```swift
public actor MCPServer {
    /// AsyncSequence for state changes (non-SwiftUI apps)
    public var stateStream: AsyncStream<MCPConnectionState> { ... }
}
```

**Key principle:** UI observes state, doesn't manage it. Library manages all state internally.
- SwiftUI apps use `MCPClient.connections` - automatic `@Published` updates
- Non-SwiftUI apps use `MCPServer.stateStream` - `AsyncSequence` for reactive updates

---

## Usage Patterns

### Pattern 1: Minimal Stdio App (SwiftUI)

```swift
import SwiftUI
import Yrden

@main
struct MyApp: App {
    @StateObject private var mcp = MCPClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mcp)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var mcp: MCPClient

    var body: some View {
        VStack {
            switch mcp.state {  // Convenience for single-server apps
            case .idle:
                Button("Connect") { mcp.connect("uvx mcp-server-fetch") }
            case .connecting:
                ProgressView("Connecting...")
            case .connected:
                Text("Connected!")
                // Use mcp.server for tools, etc.
            case .failed(let error):
                Text("Error: \(error.localizedDescription)")
                Button("Retry") { mcp.connect("uvx mcp-server-fetch") }
            default:
                ProgressView()
            }
        }
    }
}
```

**Lines: ~25** - No wrapper class needed, library provides `MCPClient`.

### Pattern 2: OAuth App (macOS)

```swift
import SwiftUI
import Yrden

@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var mcp = MCPClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mcp)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ app: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            mcpHandleCallback(url)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var mcp: MCPClient

    var body: some View {
        VStack {
            switch mcp.state {
            case .idle:
                Button("Connect to Todoist") {
                    mcp.connect(
                        url: URL(string: "https://ai.todoist.net/mcp")!,
                        redirectScheme: "myapp"
                    )
                }
            case .connecting:
                ProgressView("Connecting...")
            case .authenticating(let progress):
                VStack {
                    ProgressView()
                    Text(progress.description)  // "Waiting for browser..."
                }
            case .connected:
                Text("Connected!")
            case .failed(let error):
                Text("Error: \(error.localizedDescription)")
            default:
                EmptyView()
            }
        }
    }
}
```

**Lines: ~45** - Clean, no boilerplate wrapper class.

### Pattern 3: With Progress UI

```swift
let server = try await mcpConnect(
    url: serverURL,
    redirectScheme: "myapp",
    openURL: { NSWorkspace.shared.open($0) },
    onProgress: { progress in
        await MainActor.run {
            switch progress {
            case .waitingForUser:
                statusText = "Complete login in browser..."
            case .complete:
                statusText = "Connected!"
            case .failed(let error):
                statusText = "Error: \(error.localizedDescription)"
            default:
                break
            }
        }
    }
)
```

### Pattern 4: Custom Token Storage

```swift
let server = try await mcpConnect(
    url: serverURL,
    redirectScheme: "myapp",
    openURL: { NSWorkspace.shared.open($0) },
    tokenStorage: FileTokenStorage(path: "~/.myapp/tokens.json")
)
```

### Pattern 5: Testing

```swift
func testOAuthFlow() async throws {
    let mockRouter = MCPCallbackRouter()
    let mockStorage = InMemoryTokenStorage()

    // Start connection in background
    let connectTask = Task {
        try await mcpConnect(
            url: testServerURL,
            redirectScheme: "test",
            openURL: { capturedURL = $0 },
            tokenStorage: mockStorage,
            router: mockRouter
        )
    }

    // Simulate callback
    try await Task.sleep(for: .milliseconds(100))
    let callbackURL = URL(string: "test://callback?code=abc&state=xyz")!
    mockRouter.handleCallback(callbackURL)

    // Verify
    let server = try await connectTask.value
    XCTAssertTrue(server.isConnected)
}
```

---

## Migration Path

### From Current API

```swift
// Before (verbose)
let delegate = SimpleOAuthDelegate(...)
let transport = MCPAutoAuthTransport(
    serverURL: url,
    storage: InMemoryTokenStorage(),
    serverID: url.host ?? "mcp-server",
    delegate: delegate,
    redirectScheme: redirectScheme,
    clientName: "My App",
    logCallback: logCallback
)
self.autoAuthTransport = transport
server = try await MCPServerConnection.withTransport(transport, ...)

// After (simple)
server = try await mcpConnect(
    url: url,
    redirectScheme: redirectScheme,
    openURL: { NSWorkspace.shared.open($0) }
)
```

### Keeping Advanced Access

The current API (`MCPServerConnection`, `MCPAutoAuthTransport`, etc.) remains available for:
- Custom transports
- Non-standard OAuth flows
- Fine-grained control
- Debugging

---

## Implementation Checklist

### Phase 1: Core Infrastructure
1. [ ] `MCPCallbackRouter` - Thread-safe callback routing (macOS only)
2. [ ] `KeychainTokenStorage` - Default secure storage
3. [ ] `MCPConnectionState` enum with full state machine
4. [ ] Timeout and cleanup for pending OAuth flows

### Phase 2: Simplified API
5. [ ] `mcpConnect()` - Async entry points (Layer 1)
6. [ ] `mcpHandleCallback()` - macOS callback routing
7. [ ] iOS `ASWebAuthenticationSession` integration

### Phase 3: SwiftUI Layer
8. [ ] `MCPClient` - ObservableObject wrapper (Layer 0)
9. [ ] Multi-server support (`servers` dictionary)
10. [ ] `MCPReconnectPolicy` and auto-reconnect logic
11. [ ] Structured logging (`MCPLogEntry`)

### Phase 4: Testing & Docs
12. [ ] Unit tests for callback routing
13. [ ] Unit tests for state machine
14. [ ] Integration tests for OAuth flow
15. [ ] Update example app to use new API
16. [ ] Migration guide

---

## Resolved Decisions

### 1. Naming: `mcpConnect()`
Simple namespace. Library is client-only, no ambiguity.

### 2. Callback Miss: Return Bool, Don't Throw
```swift
@discardableResult
public static func handleCallback(_ url: URL) -> Bool
```
- Old/invalid callbacks are harmless, no need to throw
- Return value lets caller log if needed

### 3. Multiple Simultaneous OAuth: Yes, via State Parameter
OAuth `state` parameter routes callbacks to correct pending flow:
- Generate unique state per connection
- Same redirect scheme works for all connections
- Router matches by state, not URL

### 4. iOS: ASWebAuthenticationSession (Different API)

| Platform | Method | Callback Handling |
|----------|--------|-------------------|
| macOS | External Safari | AppDelegate receives URL |
| iOS | ASWebAuthenticationSession | API returns URL directly |

```swift
#if os(macOS)
static func connect(
    url: URL,
    redirectScheme: String,
    openURL: @escaping (URL) -> Void,
    ...
) async throws -> MCPServer
#endif

#if os(iOS)
static func connect(
    url: URL,
    redirectScheme: String,
    presentingWindow: UIWindowScene,  // For auth session
    ...
) async throws -> MCPServer
// No AppDelegate handling needed - ASWebAuthenticationSession handles callback
#endif
```
