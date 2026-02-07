# Design: Unified Tool Protocol

## Problem

The current tool API requires users to manually type-erase every tool:

```swift
let agent = try Agent<Void, Report>(
    model: claude,
    tools: [AnyAgentTool(SearchTool()), AnyAgentTool(FlakyAPI())]
         + mcpTools.map { $0.asAnyAgentTool() }
)
```

This happens because:

1. **`AgentTool` has associated types** (`Args`, `Output`, `Deps`) — Swift can't store `[any AgentTool]` when there are multiple unconstrained associated types
2. **`AnyAgentTool<Deps>` exists as a type-erased wrapper** — manually wraps each tool, erasing `Args` and `Output` while preserving `Deps`
3. **MCP tools go through a separate conversion** — `MCPToolProxy.asAnyAgentTool()` creates the wrapper from external tool metadata

The result: two abstractions for the same concept (`AgentTool` protocol + `AnyAgentTool` struct), boilerplate wrapping at every call site, and MCP tools requiring explicit conversion.

## Current Architecture

```
AgentTool protocol (typed: Deps, Args, Output)
    │
    │  AnyAgentTool(myTool)  ← manual wrapping
    ▼
AnyAgentTool struct (typed: Deps only, closure-captured Args/Output)
    │
    │  stored in Agent
    ▼
Agent.tools: [AnyAgentTool<Deps>]
```

### Current tool definition

```swift
struct SearchTool: AgentTool {
    typealias Deps = Void
    typealias Args = SearchArgs
    var name: String { "search" }
    var description: String { "Search the web" }

    func call(context: AgentContext<Void>, arguments: SearchArgs) async throws -> ToolResult<String> {
        .success("results for: \(arguments.query)")
    }
}

// Usage — wrapper required
let agent = try Agent(model: m, tools: [AnyAgentTool(SearchTool())])
```

### What we analyzed

- **50 files** reference `AnyAgentTool` across Sources, Tests, and Examples
- **100%** of concrete tool implementations use `Output = String` (the default), but `Output` is designed for future structured outputs and must be preserved
- **100%** of concrete tool implementations use `Deps = Void` — no non-Void deps exist in the codebase
- `ToolResult<T>` carries `.success(T)`, `.failure(Error)`, `.deferred(DeferredToolCall)` — the generic `T` enables typed outputs
- `AnyToolResult` is the erased result type (always String-based) used by the agent loop
- `ToolResult.erased()` handles the `Output → String` conversion (JSON-encodes non-String outputs)

---

## Research: Swift Ecosystem Approaches

> Full research: [Research-SwiftToolProtocols.md](Research-SwiftToolProtocols.md)

We analyzed all major Swift AI agent libraries (February 2026):

| Library | Tool type | Storage | Type erasure | DI on Tool |
|---------|-----------|---------|--------------|------------|
| **Apple FoundationModels** | Protocol (2 ATs) | `[any Tool]` | Existentials | None |
| **SwiftAI** (mi12labs) | Protocol (2 ATs) | `[any Tool]` | Existentials | None |
| **SwiftAgent** (1amageek) | Apple's protocol | `[any Tool]` | Existentials | None |
| **SwiftAgents** (karani) | 2 protocols + struct | `[any AnyJSONTool]` | Box pattern | None |
| **AgentSDK-Swift** (fumito-ito) | Concrete struct | `[Tool<Ctx>]` | Not needed | `RunContext<Ctx>` |

### Key findings

1. **Every library uses `[any Tool]` existentials** (except AgentSDK-Swift which uses a concrete struct). No manual `AnyTool` wrappers.
2. **No library puts dependency injection on the tool protocol.** Tools capture dependencies as stored properties at init. AgentSDK-Swift is the only one with DI, via a concrete struct (not protocol).
3. **Apple's FoundationModels validates our design direction** — protocol-based tools, existential arrays, `@Generable`/`@Guide` macros for schema generation. Their `Tool` protocol is close to what we're building.
4. **Yrden's two-tier approach (base `Tool` + refined `TypedTool`) is unique** — closest parallel is SwiftAgents' `AnyJSONTool`/`Tool` split, but ours is more ergonomic because the JSON bridge is a default implementation on `TypedTool`.
5. **Retry/approval/deferred is a Yrden differentiator** — no other library has `ToolResult<T>` with explicit failure signaling, deferred execution, or composable wrappers like `RetryingTool` and `ApprovalRequired`.

---

## Approaches Explored

### 1. Existential array: `[any AgentTool<Deps>]`

**Idea:** Since `AgentTool` declares `Deps` as a primary associated type, use `any AgentTool<Deps>` as an existential.

**POC result:** Compiles and runs. Swift 5.9+ handles implicit existential opening — even when `AnyAgentTool.init` captures the concrete type in a closure.

**Limitation:** Only works for concrete `AgentTool` conformers. `AnyAgentTool` (used by MCP tools) doesn't conform to `AgentTool`, so you can't mix inline tools and MCP tools in the same `[any AgentTool<Deps>]` array. Two overloaded inits or array concatenation needed.

**Verdict:** Partial solution. Doesn't unify all tool sources.

### 2. Result builder (`@ToolsBuilder`)

**Idea:** SwiftUI-style DSL with `buildExpression` overloads for each tool source.

**Limitation:** Adds complexity (~40 lines). Still keeps `AnyAgentTool` internally — hides the problem rather than solving it. Debugging result builder type errors can be cryptic.

**Verdict:** Ergonomic but papering over the real issue.

### 3. Unified protocol hierarchy with `Deps` (previously chosen)

**Idea:** Base protocol with `Deps` as only primary associated type, `[any Tool<Deps>]` for storage.

**POC result:** All 8 test scenarios pass.

**Limitation:** `Deps` as a type parameter infects the entire API surface — `Agent<Deps, Output>`, `AgentIterator<Deps, Output>`, `ToolExecutionEngine`, etc. Requires `LiftedTool` to convert `Tool<Void>` → `Tool<D>` for MCP tools. Zero non-Void Deps usage exists in the codebase.

**Verdict:** Works, but adds complexity for a feature nobody uses yet.

### 4. Unified protocol hierarchy without `Deps` (chosen)

**Idea:** Same as approach 3, but drop `Deps` entirely. Base `Tool` protocol has zero associated types → `[any Tool]` with no type parameter. Dependencies handled via constructor injection and `@TaskLocal` for request-scoped data.

**Rationale:**
- Aligns with every Swift AI library in the ecosystem (Apple, SwiftAI, SwiftAgent)
- Removes `LiftedTool` entirely — MCP tools and local tools coexist naturally in `[any Tool]`
- Simplifies `Agent<Output>` (one generic parameter instead of two)
- No non-Void Deps usage exists — designing for a use case that hasn't materialized
- Constructor injection + `@TaskLocal` cover all real dependency use cases (see Dependency Patterns below)
- Can add typed DI later if a compelling need emerges

**Verdict:** Simplest correct solution. One protocol, one array type, no wrappers, no type parameter.

---

## Chosen Design

### Protocol hierarchy

```
Tool                    ← base: JSON string → AnyToolResult, zero associated types
  ├── TypedTool         ← adds Args + Output, auto-implements Tool.call()
  ├── MCPToolProxy      ← raw Tool (no typed args, schema from server)
  ├── RetryingTool<T>   ← wraps any Tool, retries on .failed
  ├── ApprovalRequired<T> ← overrides requiresApproval to true
  └── ClosureTool<A,O>  ← inline closure definition
```

### Protocol definitions

```swift
/// Base tool protocol. The agent stores [any Tool].
/// Zero associated types — enables heterogeneous arrays with no type parameter.
public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var definition: ToolDefinition { get }
    var requiresApproval: Bool { get }  // default: false
    func call(context: ToolContext, argumentsJSON: String) async throws -> AnyToolResult
}

/// Typed tool with compile-time argument and output types.
/// Default call() implementation: decodes JSON → Args, calls execute(), erases Output → String.
public protocol TypedTool: Tool {
    associatedtype Args: SchemaType
    associatedtype Output: Sendable = String
    func execute(context: ToolContext, arguments: Args) async throws -> ToolResult<Output>
}
```

### ToolContext (framework-owned, non-generic)

```swift
/// Framework context passed to every tool call.
/// Contains execution metadata — NOT user dependencies.
/// User dependencies are handled via constructor injection or @TaskLocal.
public struct ToolContext: Sendable {
    /// ID of the current tool call.
    public let toolCallID: String

    /// Unique identifier for this agent run.
    public let runID: String

    /// Current step in the agent run (increments each model call).
    public let runStep: Int

    /// Current retry attempt (0 on first call, incremented by RetryingTool).
    public let retryAttempt: Int

    /// Accumulated token usage for this run.
    public let usage: Usage

    /// All messages in the conversation so far.
    public let messages: [Message]
}
```

### How Output flows through the system

```
User's tool:     execute() -> ToolResult<WeatherData>
                      │
                      │  .success(WeatherData(city: "NYC", tempF: 72))
                      ▼
Default call():  result.erased() -> AnyToolResult
                      │
                      │  .success('{"city":"NYC","tempF":72}')  ← JSON-encoded
                      ▼
Agent loop:      AnyToolResult.success(String) → sent to LLM
```

The `Output` associated type lives only in the `TypedTool` layer. By the time it reaches `Tool.call()`, it's been erased to `String` inside `AnyToolResult`. This is why `[any Tool]` works — the base protocol never sees `Output` or `Args`.

### Default `call()` implementation on TypedTool

```swift
extension TypedTool {
    var definition: ToolDefinition {
        ToolDefinition(name: name, description: description, inputSchema: Args.jsonSchema)
    }

    func call(context: ToolContext, argumentsJSON: String) async throws -> AnyToolResult {
        // Step 1: Decode JSON → Args (throws on parse failure — propagates up)
        guard let data = argumentsJSON.data(using: .utf8) else {
            throw ToolExecutionError.argumentParsing("Invalid UTF-8")
        }
        let args = try JSONDecoder().decode(Args.self, from: data)

        // Step 2: Execute tool (returns ToolResult<Output>)
        let result = try await execute(context: context, arguments: args)

        // Step 3: Erase Output → String
        return result.erased()
    }
}
```

### `execute()` return type: `ToolResult<Output>`

We keep `ToolResult<Output>` as the return type (not bare `Output`) because:

1. **Explicit failure signaling** — `.failure(error)` sends the error to the LLM for retry; `throw` propagates as unrecoverable. Tools control which path errors take.
2. **Deferred support** — tools can return `.deferred(...)` for human-in-the-loop approval
3. **Output type preservation** — `ToolResult<WeatherData>.success(...)` carries the typed output through to `erased()`
4. **Consistent with current API** — minimizes behavioral changes during refactor

### TypedTool inference

Swift infers `Args` (and `Output` if defaulted) from the `execute()` signature:

```swift
// Zero typealiases for the common case
struct SearchTool: TypedTool {
    var name: String { "search" }
    var description: String { "Search the web" }

    func execute(context: ToolContext, arguments: SearchArgs) async throws -> ToolResult<String> {
        .success("results for: \(arguments.query)")
    }
}

// With structured (non-String) output — one typealias
struct WeatherTool: TypedTool {
    typealias Output = WeatherData

    var name: String { "weather" }
    var description: String { "Get weather" }

    func execute(context: ToolContext, arguments: WeatherArgs) async throws -> ToolResult<WeatherData> {
        .success(WeatherData(city: arguments.city, tempF: 72, condition: "sunny"))
    }
}
```

### Helper types

**RetryingTool** — wraps any `Tool`, retries on `.failed`:
```swift
struct RetryingTool<Wrapped: Tool>: Tool {
    // Delegates name, description, definition, requiresApproval to wrapped
    // call() retries on .failed/.failure, returns immediately on .success/.deferred/.denied/.replaced
    // Increments ToolContext.retryAttempt on each retry
}

extension Tool {
    func withRetries(_ maxRetries: Int) -> RetryingTool<Self>
}
```

**ApprovalRequired** — marks tool as needing approval:
```swift
struct ApprovalRequired<Wrapped: Tool>: Tool {
    // Delegates everything, overrides requiresApproval to true
}

extension Tool {
    func requireApproval() -> ApprovalRequired<Self>
}
```

**ClosureTool** — inline closure definition:
```swift
struct ClosureTool<Args: SchemaType, Output: Sendable>: TypedTool {
    let name: String
    let description: String
    private let _execute: @Sendable (ToolContext, Args) async throws -> ToolResult<Output>
}
```

---

## Dependency Patterns

With `Deps` removed from the `Tool` protocol, dependencies are handled through two complementary patterns. This aligns with Apple's FoundationModels framework and every major Swift AI library.

### Pattern 1: Constructor injection (static dependencies)

For services that don't change between runs — API clients, database pools, configuration:

```swift
struct SearchTool: TypedTool {
    // Dependencies captured at construction time
    let apiClient: APIClient
    let maxResults: Int

    var name: String { "search" }
    var description: String { "Search the knowledge base" }

    func execute(context: ToolContext, arguments: SearchArgs) async throws -> ToolResult<String> {
        let results = try await apiClient.search(arguments.query, limit: maxResults)
        return .success(results.formatted())
    }
}

// Constructed once, reused across runs
let searchTool = SearchTool(apiClient: productionClient, maxResults: 10)
let agent = try Agent<Report>(model: claude, tools: [searchTool])
```

**Testing:** pass a fake at construction.
```swift
let tool = SearchTool(apiClient: FakeAPIClient(), maxResults: 5)
```

### Pattern 2: @TaskLocal (request-scoped data)

For values that change per-request — user ID, auth token, trace ID:

```swift
/// Define task-local keys for request-scoped data.
enum RequestContext {
    @TaskLocal static var userID: String?
    @TaskLocal static var authToken: String?
    @TaskLocal static var traceID: String?
}

struct SearchTool: TypedTool {
    let apiClient: APIClient  // static dep via constructor

    var name: String { "search" }
    var description: String { "Search on behalf of user" }

    func execute(context: ToolContext, arguments: SearchArgs) async throws -> ToolResult<String> {
        // Request-scoped data via @TaskLocal
        guard let userID = RequestContext.userID else {
            return .failure("No user context available")
        }
        let results = try await apiClient.search(arguments.query, for: userID)
        return .success(results.formatted())
    }
}

// Agent created once
let agent = try Agent<Report>(model: claude, tools: [SearchTool(apiClient: client)])

// Request-scoped data set per invocation — propagates to all tool calls
RequestContext.$userID.withValue(currentUser.id) {
    RequestContext.$traceID.withValue(UUID().uuidString) {
        try await agent.run("find quarterly reports")
    }
}
```

### How @TaskLocal works

- Values propagate automatically through all async call chains within the `withValue` scope
- Child tasks, `async let`, and task groups all inherit the value
- Read-only from children — only the setting scope controls the value
- Used internally by Swift's own distributed tracing and logging infrastructure

### Mitigating @TaskLocal's implicitness

`@TaskLocal` values are invisible in the type signature. To prevent "forgot to set it" bugs:

**Option A: Helper that validates required context**
```swift
extension RequestContext {
    /// Call at the start of agent.run() to validate required context is set.
    static func requireUserContext() throws {
        guard userID != nil else {
            throw AgentError.missingContext("RequestContext.userID must be set via withValue")
        }
    }
}
```

**Option B: Convenience run method that sets context**
```swift
extension Agent {
    /// Run with request context — ensures @TaskLocal values are set.
    func run(_ prompt: String, userID: String, traceID: String = UUID().uuidString) async throws -> Output {
        try await RequestContext.$userID.withValue(userID) {
            RequestContext.$traceID.withValue(traceID) {
                try await self.run(prompt)
            }
        }
    }
}
```

### When to use which pattern

| Need | Pattern | Example |
|------|---------|---------|
| API clients, DB pools | Constructor injection | `SearchTool(apiClient: client)` |
| Configuration, settings | Constructor injection | `SearchTool(maxResults: 10)` |
| User ID, auth token | `@TaskLocal` | `RequestContext.$userID.withValue(id) { ... }` |
| Trace ID, request ID | `@TaskLocal` | `RequestContext.$traceID.withValue(id) { ... }` |
| Token budget, retry count | `ToolContext` (framework) | `context.usage`, `context.retryAttempt` |

### Why not generic `Deps`?

We considered and rejected a generic `Deps` type parameter on the `Tool` protocol (PydanticAI's approach). Rationale:

| Concern | Assessment |
|---------|------------|
| **Ecosystem alignment** | Every Swift AI library (Apple, SwiftAI, SwiftAgent) skips DI on tools |
| **API surface cost** | `Deps` infects every type: `Tool<Deps>`, `Agent<Deps, Output>`, `AgentIterator<Deps, Output>`, `ToolExecutionEngine<Deps>` |
| **LiftedTool complexity** | MCP tools are `Tool<Void>` — need `LiftedTool` wrapper to mix with `Tool<MyDeps>` |
| **Actual usage** | Zero non-Void Deps implementations exist in the codebase |
| **Testability** | Constructor injection provides identical testability |
| **Reversibility** | Can add typed context later if a compelling use case emerges |

---

## API Before/After

### Tool definition

```swift
// ─── BEFORE ───
struct SearchTool: AgentTool {
    typealias Deps = Void
    typealias Args = SearchArgs
    var name: String { "search" }
    var description: String { "Search the web" }
    func call(context: AgentContext<Void>, arguments: SearchArgs) async throws -> ToolResult<String> {
        .success("results")
    }
}

// ─── AFTER ───
struct SearchTool: TypedTool {
    var name: String { "search" }
    var description: String { "Search the web" }
    func execute(context: ToolContext, arguments: SearchArgs) async throws -> ToolResult<String> {
        .success("results")
    }
}
```

### Agent creation

```swift
// ─── BEFORE ───
let agent = try Agent<Void, Report>(
    model: claude,
    tools: [AnyAgentTool(SearchTool()), AnyAgentTool(flakyAPI)]
         + mcpManager.allTools()  // already [AnyAgentTool<Void>]
)

// ─── AFTER ───
let agent = try Agent<Report>(
    model: claude,
    tools: [SearchTool(), flakyAPI] + mcpManager.allTools()
)
```

### Mixed tool arrays (local + MCP)

```swift
// ─── BEFORE ───
let localTools: [AnyAgentTool<MyDeps>] = [AnyAgentTool(SearchTool()), AnyAgentTool(CalcTool())]
let mcpTools: [AnyAgentTool<Void>] = mcpManager.allTools()
let combined = localTools + mcpTools.map { $0.lifted() }  // LiftedTool needed

// ─── AFTER ───
let tools: [any Tool] = [SearchTool(api: client), CalcTool()] + mcpManager.allTools()
// No lifting, no wrapping — everything is `any Tool`
```

### Approval

```swift
// ─── BEFORE ───
tools: [AnyAgentTool(tool, requiresApproval: true)]

// ─── AFTER ───
tools: [tool.requireApproval()]
```

### MCP tools

```swift
// ─── BEFORE ───
let tools: [AnyAgentTool<Void>] = proxies.asAnyAgentTools()

// ─── AFTER ───
let tools: [any Tool] = proxies  // MCPToolProxy conforms to Tool directly
```

---

## What Gets Removed

| Removed | Replaced by |
|---------|-------------|
| `AnyAgentTool<Deps>` struct | `[any Tool]` existential array |
| `AgentTool` protocol | `TypedTool` |
| `SimpleTool` protocol | `TypedTool` (no `Deps` to constrain away) |
| `AgentContext<Deps>` | `ToolContext` (non-generic) |
| `LiftedTool<D>` | Not needed — no `Deps` type parameter to bridge |
| `MCPToolProxy.asAnyAgentTool()` | `MCPToolProxy` conforms to `Tool` directly |
| `[MCPToolProxy].asAnyAgentTools()` | Array is already `[any Tool]` |

## What Stays

| Kept | Reason |
|------|--------|
| `ToolResult<T>` | Carries typed `Output`, explicit success/failure/deferred |
| `ToolResult.erased()` | Converts `Output → String` for `AnyToolResult` |
| `AnyToolResult` | Return type of `Tool.call()`, used by agent loop |
| `Output` associated type | Enables structured (non-String) tool outputs |
| `DeferredToolCall`, `DeferralKind` | Approval workflow |
| `ToolExecutionError` | Error types |
| `AnyEncodable` helper | Used by `ToolResult.erased()` |

---

## Blast Radius

### Source files (8)
- `AgentTool.swift` — rewrite: new protocols, remove AnyAgentTool, remove LiftedTool
- `AgentContext.swift` — replace with `ToolContext` (non-generic)
- `RetryingTool.swift` — wrap `Tool` instead of `AgentTool`, manage `retryAttempt`
- `Agent.swift` — `[any Tool]` storage, `Agent<Output>` (one type param)
- `ToolExecutionEngine.swift` — `[any Tool]` params
- `AgentIterator.swift` — `any Tool` throughout
- `IterationContext.swift` — `any Tool` throughout
- `MCPToolProxy.swift` — conform to `Tool`, remove `asAnyAgentTool()`
- `MCPTool.swift` — conform to `Tool`, remove `asAnyAgentTool()`
- `ProtocolMCPManager.swift` — return `[any Tool]`

### Test support (4)
- `ConfigurableTool.swift` — `TypedTool`, `execute()`
- `FakeTool.swift` — `TypedTool`, `execute()`
- `TestToolTypes.swift` — `TypedTool`, `execute()`
- `AgentTestHelpers.swift` (legacy) — same

### Test files (~30)
- Mechanical: remove `AnyAgentTool(...)` wrapping, `AgentContext<Void>` → `ToolContext`

### Examples (3)
- `ChatViewModel.swift`, `SettingsStore.swift`, `MCPSettingsSection.swift` — type changes

### Docs (~6)
- Update references to `AnyAgentTool`, `AgentContext`, `SimpleTool`
