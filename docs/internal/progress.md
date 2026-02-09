# Development Progress

## Running Tests

### Quick Reference

```bash
# Run all tests (unit tests only - no API keys needed)
swift test

# Run tests with API keys from .env file
export $(cat .env | grep -v '^#' | xargs) && swift test

# Run specific test filter
export $(cat .env | grep -v '^#' | xargs) && swift test --filter "OpenAI"

# Run expensive tests (o1, etc.)
export $(cat .env | grep -v '^#' | xargs) RUN_EXPENSIVE_TESTS=1 && swift test --filter "o1_"

# List available OpenAI models
export $(cat .env | grep -v '^#' | xargs) && swift test --filter "listAllModels"
```

### Environment Variables

Create a `.env` file in the project root (see `.env.template`):

```bash
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
# Optional
RUN_EXPENSIVE_TESTS=1
```

The `export $(cat .env | grep -v '^#' | xargs)` pattern:
1. Reads .env file
2. Filters out comment lines (starting with #)
3. Exports all key=value pairs to the environment
4. Runs the following command with those variables

---

## Current Status Summary (2026-01-25)

### What's Complete

| Component | Status | Tests |
|-----------|--------|-------|
| **Core Types** | ✅ Complete | 165 (JSONValue, Message, Tool, etc.) |
| **Anthropic Provider** | ✅ Complete | 31 integration tests |
| **OpenAI Provider** | ✅ Complete | 21 integration tests |
| **AWS Bedrock Provider** | ✅ Complete | 37 integration tests |
| **@Schema/@Guide Macros** | ✅ Complete | 35+ expansion tests |
| **Typed Structured Output** | ✅ Complete | generate(), generateWithTool() |
| **Agent System** | ✅ Complete | 73 tests (run, runStream, iter, resume) |
| **MCP Integration** | ✅ Complete | 64 tests |
| **Tool Execution** | ✅ Complete | Retry, timeout, deferred resolution |
| **Output Validators** | ✅ Complete | Automatic retry on validation failure |

**Total: 580+ tests passing**

### What's In Progress

| Item | Status | Notes |
|------|--------|-------|
| Phase 0.2: MCP Consolidation | Pending | Old vs Protocol* hierarchy cleanup |
| Phase 0.4: Test Quality | Pending | Simplify test doubles |
| Phase 0.5: Minor Cleanup | Pending | Small refactorings |
| API Polish | Pending | Builder pattern, error messages |

### What's Planned (Not Blocking)

- Skills system (Anthropic-style reusable capabilities)
- Multi-agent handoffs
- Additional providers (OpenRouter, local models)
- Example application

---

## Session: 2026-01-25 (Part 7)

### Completed

#### Phase 0.1 Continued: Agent Refactoring with ToolExecutionEngine and Observer Pattern

Attempted further refactoring to reduce Agent.swift by extracting tool execution and unifying the agent loop.

**New Files Created:**

| File | Lines | Description |
|------|-------|-------------|
| [ToolExecutionEngine.swift](../Sources/Yrden/Agent/ToolExecutionEngine.swift) | 211 | Tool execution with retry and timeout logic |
| [AgentLoopObserver.swift](../Sources/Yrden/Agent/AgentLoopObserver.swift) | 184 | Observer protocol for agent loop events |
| [ToolExecutionEngineTests.swift](../Tests/YrdenTests/Agent/ToolExecutionEngineTests.swift) | 480 | 14 tests covering execution, timeout, retry, batch |

**Changes to Agent.swift:**

- Added `runLoop()` unified loop method
- Simplified `run()` to use `runLoop()` with `NoOpLoopObserver`
- Simplified `iterInternal()` to use `runLoop()` with `IteratingLoopObserver`
- Streaming (`runStream()`) remains separate due to fundamentally different model calls

**Results:**

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| Agent.swift | ~1180 lines | ~1108 lines | -72 lines |
| ToolExecutionEngine.swift | N/A | 211 lines | +211 lines |
| AgentLoopObserver.swift | N/A | 184 lines | +184 lines |
| **Total** | ~1180 lines | ~1503 lines | **+323 lines** |

**Assessment:**

This refactoring was over-engineering. The extracted components are clean and well-tested, but the net result is more code, not less. The complexity moved rather than decreased.

**What worked:**
- ToolExecutionEngine is a clean, isolated unit with good test coverage
- Observer pattern successfully unified `run()` and `iter()` code paths

**What didn't work:**
- Streaming couldn't be unified (model.stream() vs model.complete() are fundamentally different)
- The abstraction overhead exceeded the consolidation gains
- Goal of reducing Agent.swift to ~700-750 lines was not achieved

**Decision:** Keep the current state. The extracted components have value:
- ToolExecutionEngine isolates retry/timeout logic (testable separately)
- Observer pattern reduces some duplication between run() and iter()
- Tests provide regression safety

**Test Results:** 73/73 Agent tests passing (including 14 new ToolExecutionEngine tests)

---

## Session: 2026-01-25 (Part 6)

### Completed

#### Phase 0.3: Unsafe Code Fixes (COMPLETE)

Completed all crash-prevention fixes from the production readiness plan. All 28 Agent/MCP tests pass.

**Fixes Applied:**

| Issue | Location | Fix |
|-------|----------|-----|
| Forced cast | [Agent.swift:1244](../Sources/Yrden/Agent/Agent.swift#L1244) | `content as! Output` → safe cast with `AgentError.internalError` |
| Force unwrap | [ProtocolMCPCoordinator.swift:167](../Sources/Yrden/MCP/ProtocolMCPCoordinator.swift#L167) | `group.next()!` → guard with `MCPConnectionError.internalError` |
| Debug prints | [MCPOAuthFlow.swift](../Sources/Yrden/MCP/MCPOAuthFlow.swift) | Removed 8 `print()` statements from `MCPOAuthCoordinator` |
| Semaphore blocking | [MCPCallbackRouter.swift](../Sources/Yrden/MCP/MCPCallbackRouter.swift) | Replaced blocking semaphore with async API |
| `@unchecked Sendable` | Multiple files | Documented safety justification for all 5 usages |

**New Error Cases:**

| Type | Case | Description |
|------|------|-------------|
| `AgentError` | `.internalError(String)` | Library bug indicator |
| `MCPConnectionError` | `.internalError(String)` | MCP library bug indicator |

**API Changes:**

| Old | New | Notes |
|-----|-----|-------|
| `mcpHandleCallback(_ url: URL) -> Bool` | `mcpHandleCallback(_ url: URL)` (fire-and-forget) | No longer blocks main thread |
| - | `mcpHandleCallbackAsync(_ url: URL) async -> Bool` | New async version for async contexts |

**`@unchecked Sendable` Audit:**

All 5 usages documented with safety justification:

| Type | File | Justification |
|------|------|---------------|
| `WeakTransport` | MCPCallbackRouter.swift | `weak var` is atomic on Apple platforms |
| `SimpleOAuthDelegate` | MCPOAuthFlow.swift | Immutable with `@Sendable` closures |
| `TokenHolder` | MCPAutoAuthTransport.swift | NSLock synchronized access |
| `ProtocolServerConnectionFactory` | ProtocolServerConnection.swift | Swift existential type limitation |
| `BedrockProvider/Model` | Bedrock/*.swift | AWS SDK thread-safe but not Sendable |

**Test Results:** 28/28 Agent and MCP tests passing

---

### Next: Phase 0.1 - Agent Code Duplication

**Goal:** Consolidate 4 duplicated execution loops into one parameterized implementation.

**Current State (Agent.swift - 1482 lines):**

| Method | Lines | Location |
|--------|-------|----------|
| `run()` | 96 | Agent.swift:127-204 |
| `runStreamInternal()` | 105 | Agent.swift:245-349 |
| `iterInternal()` | 110 | Agent.swift:570-679 |
| `resume()` | 149 | Agent.swift:962-1015 |

**Duplicated Patterns (~90% overlap):**
- Main loop: `while state.requestCount < maxIterations`
- Stop reason switch (identical error messages in 4 places)
- Tool call extraction and processing
- Output tool detection
- Message accumulation

**Three `processToolCalls*` variants (~80% overlap):**
- `processToolCalls()` - Agent.swift:1076-1182 (107 lines)
- `processToolCallsStreaming()` - Agent.swift:390-507 (118 lines)
- `processToolCallsWithNodes()` - Agent.swift:682-824 (143 lines)

**Refactoring Tasks:**

- [ ] **0.1.1** Extract `handleStopReason(response:) throws` - consolidate stop reason switch
- [ ] **0.1.2** Extract `ToolCallProcessor` with single `process()` method taking output mode enum
- [ ] **0.1.3** Create unified `ExecutionLoop` that takes mode parameter (sync/stream/iter)
- [ ] **0.1.4** Consolidate `resume()` to use same loop infrastructure
- [ ] **0.1.5** Target: Agent.swift under 800 lines (currently ~1482)

**Success Criteria:**
- No logic duplicated more than once
- Changes to loop behavior require editing ONE location
- All existing tests pass

---

## Session: 2026-01-25 (Part 5)

### Completed

#### Code Quality Review & Phase 0 Planning

Conducted comprehensive code review of Agent and MCP systems to assess production readiness.

**Review Findings:**

| Area | Grade | Key Issues |
|------|-------|-----------|
| Agent | C | 4× duplicated execution loop, 3× duplicated tool processing |
| MCP | C | Duplicate abstraction layers, 5 "tool" types, 935-line file |
| Tests | D | Tests verify mocks not behavior, 300-line test doubles |

**Critical Issues Identified:**

1. **Agent code duplication** - `run()`, `runStreamInternal()`, `iterInternal()`, `resume()` share ~90% identical logic
2. **Three `processToolCalls*` variants** - 80% code overlap
3. **MCP dual hierarchy** - Old API vs Protocol* versions
4. **Unsafe patterns** - Forced cast, force unwrap, debug prints, semaphore blocking
5. **Test quality** - Tests verify mock behavior, not production code

**Phase 0 Added to Production Readiness Plan:**

New blocking phase with prioritized refactoring:
- 0.3 Unsafe Code Fixes (~1 day)
- 0.1 Agent Duplication (~2 days)
- 0.2 MCP Consolidation (~2 days)
- 0.4 Test Quality (~1 day)
- 0.5 Minor Cleanup (~0.5 day)

**Updated Timeline:** 14 days → 20.5 days total.

---

## Session: 2026-01-25 (Part 4)

### Completed

#### Phase 2: Concurrency Safety Tests

Implemented comprehensive concurrency safety tests to verify the Agent actor correctly handles concurrent access and maintains state isolation.

**New File:** `Tests/YrdenTests/Agent/AgentConcurrencyTests.swift`

**Test Suites (11 tests in 4 suites):**

| Suite | Tests | Coverage |
|-------|-------|----------|
| Agent - Concurrent Runs | 4 | Multiple runs, tools isolation, streams, iterations |
| Agent - Concurrent Tool Execution | 3 | Multiple tool calls, state isolation, deps passing |
| Agent - Cancellation Propagation | 2 | Cancel concurrent runs, propagate to tools |
| Agent - Data Race Safety | 2 | State corruption, unique runIDs |

**Tests:**

1. **Multiple concurrent runs complete independently** - 3+ concurrent `run()` calls complete with unique runIDs
2. **Concurrent runs with tools maintain isolation** - Tools called from concurrent runs don't interfere
3. **Concurrent streams don't interfere** - Multiple `runStream()` calls maintain separate event flows
4. **Concurrent iterations maintain separate state** - Multiple `iter()` calls yield separate nodes
5. **Tools execute concurrently when model returns multiple tool calls** - Tests parallel tool execution
6. **Tool state is isolated between calls** - Stateful tools maintain correct call order
7. **Sendable deps are safely passed to tools** - Deps cross actor boundaries correctly
8. **Cancellation stops concurrent runs** - `Task.cancel()` propagates to running tasks
9. **Cancellation propagates to tool execution** - Long-running tools detect cancellation
10. **Agent state is not corrupted by concurrent access** - 10 concurrent runs maintain valid state
11. **RunID is unique across concurrent runs** - 20 concurrent runs have 20 unique IDs

**Test Infrastructure:**

| Helper | Description |
|--------|-------------|
| `ConcurrentTrackingModel` | Actor-based model with configurable response patterns |
| `SlowModel` | Model with configurable delay for timing tests |
| `AtomicCounterTool` | Thread-safe counter tool |
| `ConcurrentSlowTool` | Tool with configurable delay |
| `StatefulTool` | Tool that tracks call order |
| `DepsCapturingTool` | Tool that captures deps for verification |
| `LongRunningTool` | Tool for cancellation testing |

**Key Verifications:**

- Actor isolation correctly protects internal state
- Concurrent runs don't share mutable state
- Tools correctly receive Sendable deps across actor boundaries
- Cancellation propagates through the task hierarchy
- Unique identifiers (runID) are generated per-run even under concurrent load

**Test Results:** 59 Agent tests passing (48 previous + 11 concurrency tests)

---

## Session: 2026-01-25 (Part 3)

### Completed

#### Phase 1: Agent Failure Handling - Production Readiness

Implemented comprehensive failure handling for the Agent system with retry policies, tool timeouts, and extensive test coverage.

**New Types (AgentTypes.swift):**

| Type | Description |
|------|-------------|
| `RetryPolicy` | Configurable retry policy with exponential backoff and jitter |
| `RetryableErrorKind` | Enum: `.rateLimited`, `.serverError`, `.networkError` |

**RetryPolicy Configuration:**

```swift
// Default: 3 attempts with exponential backoff
let policy = RetryPolicy.default

// No retries - fail immediately
let none = RetryPolicy.none

// Aggressive: 5 attempts with longer waits
let aggressive = RetryPolicy.aggressive

// Custom policy
let custom = RetryPolicy(
    maxAttempts: 3,
    initialDelay: .milliseconds(100),
    maxDelay: .seconds(30),
    backoffMultiplier: 2.0,
    jitter: 0.1,
    retryableErrors: [.rateLimited, .serverError]
)
```

**New Agent Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `retryPolicy` | `RetryPolicy` | Controls LLM request retry behavior |
| `toolTimeout` | `Duration?` | Maximum time for tool execution |

**New Error Cases (AgentError.swift):**

| Error | Description |
|-------|-------------|
| `.toolTimeout(toolName:timeout:)` | Tool execution exceeded timeout |
| `.retriesExhausted(attempts:lastError:)` | LLM request failed after all retry attempts |

**Implementation Details:**

1. **`completeWithRetry()`** - Retries LLM requests with exponential backoff:
   - Only retries `LLMError.rateLimited`, `.serverError`, `.networkError`
   - Respects `maxAttempts` limit
   - Calculates delay with jitter to prevent thundering herd
   - Throws `.retriesExhausted` when attempts exhausted

2. **`executeToolWithTimeout()`** - Enforces tool execution time limits:
   - Uses `withThrowingTaskGroup` for racing tool vs timeout
   - Cancels tool task when timeout fires
   - Throws `.toolTimeout` with tool name and duration

**Test Infrastructure (AgentFailureTests.swift):**

| Helper | Description |
|--------|-------------|
| `TestMockModel` | Actor-based mock with async configuration (setResponses, setError) |
| `RetryTestModel` | Fails N times then succeeds, tracks call count |
| `SlowTool` | Delays for specified duration, for timeout testing |

**Test Suites (25 tests in 8 suites):**

| Suite | Tests | Coverage |
|-------|-------|----------|
| AgentToolFailureTests | 4 | Tool throws error, retry messages, failure after retries |
| AgentModelResponseFailureTests | 3 | Stop reasons, empty response, invalid JSON |
| AgentUsageLimitTests | 3 | Max requests, max tool calls, token limits |
| AgentNetworkErrorTests | 2 | Network errors, timeout handling |
| AgentOutputValidationTests | 3 | Validator retry, rejected output, max validation retries |
| AgentStreamingFailureTests | 3 | Mid-stream errors, error events, stream cancellation |
| AgentCancellationTests | 2 | Task cancellation during model call and tool execution |
| AgentRetryPolicyTests | 4 | Retry on rate limit, exhausted retries, non-retryable errors, delay calculation |
| AgentToolTimeoutTests | 2 | Timeout triggers error, tool completes within timeout |

**Usage Example:**

```swift
let agent = Agent<Void, Result>(
    model: model,
    tools: [slowTool],
    retryPolicy: RetryPolicy(
        maxAttempts: 3,
        retryableErrors: [.rateLimited, .serverError]
    ),
    toolTimeout: .seconds(30)  // Tools must complete within 30s
)

do {
    let result = try await agent.run("Process data", deps: ())
} catch AgentError.toolTimeout(let name, let timeout) {
    print("Tool \(name) timed out after \(timeout)")
} catch AgentError.retriesExhausted(let attempts, let lastError) {
    print("Failed after \(attempts) attempts: \(lastError)")
}
```

**Test Results:** 48 Agent tests passing (19 existing + 25 new failure tests + 4 retry/timeout tests)

---

## Session: 2026-01-25 (Part 2)

### Completed

#### MCP Tool Proxy and Filtering System

Implemented the remaining MCP + Agent Integration components from the design document.

**New Files:**

| File | Description |
|------|-------------|
| `Sources/Yrden/MCP/MCPToolProxy.swift` | Routes tool calls through coordinator, handles errors |
| `Sources/Yrden/MCP/MCPToolMode.swift` | ToolMode and ToolFilter for filtering tools |
| `Sources/Yrden/MCP/ProtocolMCPManager.swift` | @MainActor ObservableObject-based manager for SwiftUI |
| `Tests/YrdenTests/MCP/MCPToolProxyTests.swift` | Tests for proxy, filter, mode, and array extensions |

**MCPToolProxy:**
- Routes tool calls through `MCPCoordinatorProtocol`
- Maps MCP errors to appropriate `AnyToolResult` cases:
  - Timeout → `.retry(message:)` - LLM can try simpler request
  - Disconnected → `.failure(error)`
  - Cancelled → `.failure(error)`
- Converts to `AnyAgentTool<Void>` for use with Agent
- Supports custom timeout and retry configuration

**ToolFilter System:**
- Composable filter enum with logical operators:
  - `.all` / `.none` - include/exclude everything
  - `.servers([String])` - filter by server ID
  - `.tools([String])` - filter by tool name
  - `.toolIDs([String])` - filter by qualified ID (serverID.toolName)
  - `.pattern(String)` - regex matching on tool name
  - `.and([ToolFilter])` / `.or([ToolFilter])` / `.not(ToolFilter)` - logical combinations
- Codable for persistence
- Used by `ToolMode` to define tool access profiles

**ToolMode Profiles:**
- `.fullAccess` - all tools from all servers
- `.readOnly` - tools matching read/list/get/search patterns
- `.none` - no tools
- Custom modes with arbitrary filters

**lifted() Extension:**
- Added `lifted<D>()` to `AnyAgentTool<Void>` to lift deps-free tools to arbitrary deps types
- Enables MCP tools (which have no deps) to work with agents that have deps

**Test Results:** 64 MCP tests passing (27 XCTest + 37 Swift Testing)

---

## Session: 2026-01-25

### Completed

#### MCP Test Harness with Real Implementations

Built a bulletproof test harness for MCP by implementing **real** implementations with **protocol-based dependency injection**, allowing tests to verify actual behavior with mocks injected at the seams.

**Design Change from Original:**

The original design used concrete actors (`ServerConnection`, `MCPCoordinator`). We introduced **protocol abstractions** for testability:

| Original Design | New Implementation | Purpose |
|-----------------|-------------------|---------|
| `ServerConnection` actor | `ServerConnectionProtocol` + `ProtocolServerConnection` | Inject MockMCPClient |
| `MCPCoordinator` actor | `MCPCoordinatorProtocol` + `ProtocolMCPCoordinator` | Inject MockServerConnectionFactory |
| Direct MCP Client | `MCPClientProtocol` | Mock the MCP SDK |

This is a **good deviation** from the design - the original architecture is preserved, but protocols make it testable.

**New Files:**

| File | Description |
|------|-------------|
| `Sources/Yrden/MCP/ProtocolServerConnection.swift` | Real ServerConnection using MCPClientFactory injection |
| `Sources/Yrden/MCP/ProtocolMCPCoordinator.swift` | Real Coordinator using ServerConnectionFactory injection |

**Updated Test Files:**

| File | Tests | Description |
|------|-------|-------------|
| `Tests/YrdenTests/MCP/ServerConnectionTests.swift` | 14 | Uses real ProtocolServerConnection with MockMCPClient |
| `Tests/YrdenTests/MCP/MCPCoordinatorTests.swift` | 13 | Uses real ProtocolMCPCoordinator with MockServerConnectionFactory |
| `Tests/YrdenTests/MCP/MCPManagerTests.swift` | 14 | Uses TestMCPManager with MockCoordinator |

**Test Infrastructure Fixes:**

- Fixed `collectEvents` race condition by adding delay before action
- Fixed event collection tests to account for buffered events from previous operations
- Tests now properly collect multiple events when state transitions occur

**Critical Fix: Protocols Must Require Actor**

Protocols only define shape - they don't provide race condition protection. Actors do. When abstracting actors for testing, protocols must inherit from `Actor` to maintain safety:

```swift
// ❌ WRONG - allows non-actor conformance, loses isolation
public protocol MCPCoordinatorProtocol: Sendable { ... }

// ✅ CORRECT - enforces actor at compile time
public protocol MCPCoordinatorProtocol: Sendable, Actor { ... }
```

Fixed protocols:
- `ServerConnectionProtocol: Sendable, Actor` (was already correct)
- `MCPCoordinatorProtocol: Sendable, Actor` (fixed - was missing Actor)

**Architecture Pattern:**

```
┌─────────────────────────────────────────────────────────────┐
│  MCPManager (uses MCPCoordinatorProtocol)                   │
│     └── TestMCPManager uses MockCoordinator                 │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  ProtocolMCPCoordinator (uses ServerConnectionFactory)      │
│     └── Tests inject MockServerConnectionFactory            │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  ProtocolServerConnection (uses MCPClientFactory)           │
│     └── Tests inject MockMCPClientFactory → MockMCPClient   │
└─────────────────────────────────────────────────────────────┘
```

**Test Results:** 41 MCP tests passing (14 ServerConnection + 13 Coordinator + 14 Manager)

**Design Document Updated:**

Updated `docs/mcp-agent-integration-design.md` to capture:
- Implementation status (checklist with completed items)
- Critical lesson: Protocols abstracting actors MUST inherit from `: Actor`
- File structure for real implementations and test infrastructure
- Testing approach diagram (test real implementations, mocks at seams)

---

## Session: 2026-01-24

### Completed

#### MCP (Model Context Protocol) Integration

Integrated the official MCP Swift SDK to enable dynamic tool discovery from external MCP servers.

**New Files:**

| File | Description |
|------|-------------|
| `Sources/Yrden/MCP/MCPValueConversion.swift` | Bidirectional conversion between MCP.Value and JSONValue |
| `Sources/Yrden/MCP/MCPTool.swift` | ⚠️ **Deprecated** - use MCPToolProxy instead |
| `Sources/Yrden/MCP/MCPServerConnection.swift` | Actor managing single MCP server connection |
| `Sources/Yrden/MCP/MCPManager.swift` | Multi-server orchestration actor |
| `Sources/Yrden/MCP/MCPResourceProvider.swift` | Resource injection for context enrichment |
| `Tests/YrdenTests/MCP/MCPValueConversionTests.swift` | 27 unit tests for value conversion |
| `Tests/YrdenTests/MCP/MCPToolTests.swift` | 7 unit tests for tool wrapping |
| `Tests/YrdenTests/Integration/MCPIntegrationTests.swift` | Integration tests (requires uvx + mcp-server-git) |

**Package.swift Changes:**

Added MCP SDK dependency:
```swift
.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
```

**Key Types:**

| Type | Description |
|------|-------------|
| `MCPServerConnection` | Actor wrapping MCP Client for single server |
| `MCPTool<Deps>` | ⚠️ **Deprecated** - use MCPToolProxy |
| `MCPManager` | Actor coordinating multiple MCP servers |
| `MCPResourceProvider` | Fetches MCP resources for context injection |
| `MCPServerConfig` | Configuration enum for stdio/http transports |
| `MCPToolError` | MCP-specific error types |

**Usage:**

```swift
// Connect to an MCP server via stdio
let server = try await MCPServerConnection.stdio(
    command: "uvx",
    arguments: ["mcp-server-git", "--repository", "/path/to/repo"]
)

// Discover tools as AnyAgentTool
let tools: [AnyAgentTool<Void>] = try await server.discoverTools()

// Use with Agent
let agent = Agent<Void, String>(
    model: model,
    tools: tools,  // MCP tools work like any other tool
    systemPrompt: "You can use git commands."
)

// Multi-server management
let manager = MCPManager()
_ = try await manager.addServer(.stdio(
    command: "uvx",
    arguments: ["mcp-server-git", "--repository", "/repo1"],
    id: "git-server"
))
let allTools: [AnyAgentTool<Void>] = try await manager.allTools()
```

**Value Conversion:**

```swift
// MCP.Value → JSONValue
let jsonValue = JSONValue(mcpValue: mcpValue)

// JSONValue → MCP.Value
let mcpValue = MCP.Value(jsonValue: jsonValue)

// Dictionary helpers
let jsonDict = mcpDict.asJSONValue
let mcpDict = jsonDict.asMCPValue
```

**AnyAgentTool Changes:**

Added closure-based initializer to support external tool sources:
```swift
public init(
    name: String,
    description: String,
    definition: ToolDefinition,
    maxRetries: Int = 1,
    call: @escaping @Sendable (AgentContext<Deps>, String) async throws -> AnyToolResult
)
```

**Tests:** 34 MCP unit tests (all passing)

**Integration Test Notes:**
- Tests require `uvx` (Python uv tool) and `mcp-server-git` package
- Tests use `mcp-server-git` since it's available via uvx (Python)
- Filesystem server (`@modelcontextprotocol/server-filesystem`) requires npx (Node.js)
- Tests skip gracefully if prerequisites are not available

---

## Session: 2026-01-23 (Part 4)

### Completed

#### Human-in-the-Loop (Deferred Tool Resolution)

Implemented full human-in-the-loop support for agent tool execution, allowing tools to defer execution pending human approval or external resolution.

**New Types:**

| Type | Description |
|------|-------------|
| `PausedAgentRun` | Captures all state needed to resume after deferral |
| `PendingToolCall` | Pairs `ToolCall` with `DeferredToolCall` info |
| `ResolvedTool` | Resolution provided for a deferred tool |
| `Resolution` | `.approved`, `.denied(reason:)`, `.completed(result:)`, `.failed(error:)` |

**API:**

```swift
// Tool returns deferred for approval
func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
    return .deferred(.needsApproval(
        id: "delete-\(arguments.target)",
        reason: "Deletion requires human approval"
    ))
}

// Catch deferral, get user approval, resume
do {
    let result = try await agent.run("Delete important files", deps: myDeps)
} catch let error as AgentError {
    if case .hasDeferredTools(let paused) = error {
        // Get user approval for each pending tool
        var resolutions: [ResolvedTool] = []
        for pending in paused.pendingCalls {
            let approved = await askUser("Allow \(pending.toolCall.name)?")
            resolutions.append(ResolvedTool(
                id: pending.deferral.id,
                resolution: approved ? .approved : .denied(reason: "User rejected")
            ))
        }

        // Resume execution
        let result = try await agent.resume(
            paused: paused,
            resolutions: resolutions,
            deps: myDeps
        )
    }
}
```

**Resolution Types:**

| Resolution | Description |
|------------|-------------|
| `.approved` | Execute the tool now |
| `.denied(reason:)` | Reject with reason (sent to model as error) |
| `.completed(result:)` | Provide result directly (for external operations) |
| `.failed(error:)` | Report external failure |

**Tests:** 8 human-in-the-loop tests covering all resolution types and all execution modes (`run()`, `runStream()`, `iter()`)

**Test Count:** 19 Agent tests (3 core + 6 integration + 2 validators + 8 human-in-the-loop)

---

## Session: 2026-01-23 (Part 3)

### Completed

#### Agent Core Implementation

Implemented the core Agent system inspired by PydanticAI with typed output, tool execution loop, and dependency injection.

**New Files:**

| File | Description |
|------|-------------|
| `Sources/Yrden/Agent/Agent.swift` | Main `Agent<Deps, Output>` actor with `run()` method |
| `Sources/Yrden/Agent/AgentContext.swift` | Rich context passed to tools during execution |
| `Sources/Yrden/Agent/AgentTool.swift` | `AgentTool` protocol, `ToolResult` enum, `AnyAgentTool` wrapper |
| `Sources/Yrden/Agent/AgentError.swift` | Agent-specific errors (maxIterationsReached, usageLimitExceeded, etc.) |
| `Sources/Yrden/Agent/AgentTypes.swift` | Supporting types: UsageLimits, EndStrategy, AgentResult, OutputValidator |
| `Tests/YrdenTests/Agent/AgentTests.swift` | Unit and integration tests |

**Core Types:**

| Type | Description |
|------|-------------|
| `Agent<Deps, Output>` | Actor that orchestrates tool use and produces typed output |
| `AgentContext<Deps>` | Context passed to tools with deps, model, usage, messages |
| `AgentTool` | Protocol for tools with typed `Args: SchemaType` and `Output: Sendable` |
| `ToolResult<T>` | `.success(T)`, `.retry(message:)`, `.failure(Error)`, `.deferred(DeferredToolCall)` |
| `AnyAgentTool<Deps>` | Type-erased wrapper for heterogeneous tool collections |
| `UsageLimits` | Token, request, and tool call limits |
| `EndStrategy` | `.early` (stop at first output) vs `.exhaustive` (run all tools) |
| `OutputValidator` | Post-validation with retry capability |

**Key Design Decisions:**

| Decision | Rationale |
|----------|-----------|
| Output tool for structured types | Anthropic/OpenAI require object schemas for tool input; using a tool ensures schema compliance |
| Text response for String output | When `Output == String`, no output tool is created; model responds with text directly |
| `AnyAgentTool` type erasure | Enables heterogeneous `[AnyAgentTool<Deps>]` collections while preserving type safety |
| `ToolResult` with retry | Tools can signal "try again" to the LLM with feedback message |
| `DeferredToolCall` foundation | Prepares for human-in-the-loop approval patterns |

**Message.swift Changes:**

- Added `ToolResultEntry` struct for multi-tool responses
- Added `.toolResults([ToolResultEntry])` case to Message enum
- Updated all providers (Anthropic, OpenAI, Bedrock) to handle new case

**Usage:**

```swift
// Define a tool
struct CalculatorTool: AgentTool {
    @Schema struct Args { let expression: String }

    var name: String { "calculator" }
    var description: String { "Evaluate a mathematical expression" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        // ... evaluate expression ...
        return .success(result)
    }
}

// Create agent with typed output
@Schema struct MathResult { let expression: String; let result: Int }

let agent = Agent<Void, MathResult>(
    model: model,
    systemPrompt: "You are a math assistant.",
    tools: [AnyAgentTool(CalculatorTool())],
    maxIterations: 5
)

// Run and get typed result
let result = try await agent.run("What is 5 + 3?", deps: ())
print(result.output.result)  // 8
```

**Tests:** 6 new tests (unit + integration)

#### Agent.runStream() Implementation

Added streaming execution to the Agent with real-time event delivery.

**New Types:**

| Type | Description |
|------|-------------|
| `AgentStreamEvent<Output>` | Events emitted during streaming: contentDelta, toolCallStart/Delta/End, toolResult, usage, result |

**API:**

```swift
for try await event in agent.runStream("Analyze data", deps: myDeps) {
    switch event {
    case .contentDelta(let text):
        print(text, terminator: "")
    case .toolCallStart(let name, _):
        print("\n[Calling \(name)...]")
    case .toolResult(let id, let result):
        print("[Tool returned: \(result.prefix(50))...]")
    case .result(let result):
        print("\n\nFinal: \(result.output)")
    default:
        break
    }
}
```

**Implementation Details:**

- Uses `model.stream()` internally instead of `model.complete()`
- Forwards content deltas, tool call events to the stream
- Yields tool results as they complete
- Final `.result(AgentResult)` event signals completion
- `nonisolated` method - stream creation doesn't require actor isolation

**Tests:** 2 new streaming integration tests

#### Agent.iter() Implementation

Added iterable execution for fine-grained control over the agent loop.

**API:**

```swift
for try await node in agent.iter("Analyze data", deps: myDeps) {
    switch node {
    case .userPrompt(let prompt):
        print("Starting: \(prompt)")
    case .modelRequest(let request):
        print("Sending \(request.messages.count) messages")
    case .modelResponse(let response):
        print("Model: \(response.content ?? "")")
    case .toolExecution(let calls):
        for call in calls {
            print("Executing: \(call.name)")
            // Inspect/approve tool calls here
        }
    case .toolResults(let results):
        print("Got \(results.count) results")
    case .end(let result):
        print("Done: \(result.output)")
    }
}
```

**Node Types (AgentNode enum):**

| Node | Description |
|------|-------------|
| `.userPrompt(String)` | Initial user prompt |
| `.modelRequest(CompletionRequest)` | About to send request to model |
| `.modelResponse(CompletionResponse)` | Model responded |
| `.toolExecution([ToolCall])` | About to execute tool calls |
| `.toolResults([ToolCallResult])` | Tool execution completed with results and durations |
| `.end(AgentResult)` | Run completed with final typed result |

**Use Cases:**

- **Observability**: Log/monitor each step of agent execution
- **Human-in-the-loop**: Inspect tool calls before execution
- **Debugging**: See exact request/response pairs
- **Custom control flow**: Break out of loop early, inject messages

**Tests:** 2 new iteration integration tests

#### Output Validators with Retry

Implemented output validation with automatic retry when validators fail.

**How It Works:**

1. Validators are run after the model produces structured output
2. Validators can transform output (e.g., normalize, enrich)
3. Validators can throw `ValidationRetry` to request the model retry
4. The retry message is sent as tool error feedback
5. Model sees the feedback and tries again with corrected output

**API:**

```swift
// Validator that transforms output
let uppercaseValidator = OutputValidator<Void, String> { _, output in
    return output.uppercased()
}

// Validator that requires specific conditions
let sectionValidator = OutputValidator<Void, Report> { _, report in
    if report.sections.count < 3 {
        throw ValidationRetry("Report must have at least 3 sections")
    }
    return report
}

let agent = Agent<Void, Report>(
    model: model,
    outputValidators: [sectionValidator],
    maxIterations: 5
)
```

**Implementation Details:**

- `ValidationRetry` error caught in all three processing methods (run, runStream, iter)
- Error message sent back as tool result error
- Model receives feedback and can retry with corrected output
- Works with the existing agent loop iteration limit

**Tests:** 2 new output validator tests

**Test Count:** 461 tests (459 passing, 2 Bedrock flaky)

---

## Session: 2026-01-23 (Part 2)

### Completed

#### AWS Bedrock Provider Planning

Created comprehensive implementation plan for AWS Bedrock support: [bedrock-implementation-plan.md](bedrock-implementation-plan.md)

**Key Decisions:**

| Decision | Rationale |
|----------|-----------|
| Use AWS SDK for Swift | SigV4 signing is complex; SDK handles credentials, refresh, retries |
| Tool forcing for structured output | Bedrock has NO native JSON mode |
| Test with Claude + Amazon Nova | Validates cross-model family compatibility |
| `BedrockProvider` + `BedrockModel` | Follows existing architecture pattern |

**Bedrock Converse API Differences:**

| Aspect | Anthropic Direct | Bedrock Converse |
|--------|------------------|------------------|
| Auth | API key | AWS Signature V4 |
| System message | String | Array of content blocks |
| Tool schema | `input_schema` | `toolSpec.inputSchema.json` |
| Streaming | Same endpoint | Different endpoint (`/converseStream`) |
| Structured output | Native (beta) | Not supported |

**Implementation Phases:**
1. Provider setup + credentials
2. Basic completion (Claude + Nova)
3. Streaming
4. Tools & structured output
5. Advanced features (inference profiles, vision)
6. Testing & documentation

---

## Session: 2026-01-23 (Part 1)

### Completed

#### @Schema and @Guide Macros

Implemented compile-time JSON Schema generation from Swift types using Swift macros.

**New Files:**

| File | Description |
|------|-------------|
| `Sources/YrdenMacros/SchemaMacro.swift` | Main macro implementation for structs and enums |
| `Sources/YrdenMacros/GuideMacro.swift` | Property-level description/constraint marker |
| `Sources/YrdenMacros/SchemaGeneration/TypeParser.swift` | Parses Swift types to schema representation |
| `Sources/YrdenMacros/SchemaGeneration/SchemaBuilder.swift` | Generates Swift code for JSON Schema literals |

**Supported Types:**

| Swift Type | JSON Schema |
|------------|-------------|
| `String` | `{"type": "string"}` |
| `Int` | `{"type": "integer"}` |
| `Double` | `{"type": "number"}` |
| `Bool` | `{"type": "boolean"}` |
| `[T]` | `{"type": "array", "items": ...}` |
| `T?` | Same type, omitted from `required` |
| `@Schema struct` | Nested object reference |
| `enum: String` | `{"type": "string", "enum": [...]}` |
| `enum: Int` | `{"type": "integer", "enum": [...]}` |

**@Guide Constraints:**

```swift
@Guide(description: "Max results", .range(1...100))      // "Must be between 1 and 100"
@Guide(description: "Score", .rangeDouble(0.0...1.0))    // "Must be between 0.0 and 1.0"
@Guide(description: "Page", .minimum(1))                  // "Must be at least 1"
@Guide(description: "Count", .maximum(50))                // "Must be at most 50"
@Guide(description: "Tags", .count(1...10))               // "Must have between 1 and 10 items"
@Guide(description: "Items", .exactCount(5))              // "Must have exactly 5 items"
@Guide(description: "Sort", .options(["a", "b"]))         // Generates "enum": ["a", "b"]
@Guide(description: "Pattern", .pattern("^[a-z]+$"))      // "Must match pattern: ^[a-z]+$"
```

Note: `.options()` generates JSON Schema `enum`, all other constraints generate description text since most providers don't support JSON Schema validation keywords.

**Tests:** 63 tests covering all schema generation scenarios

---

#### Typed Structured Output API

Implemented PydanticAI-style typed API that returns decoded Swift types directly.

**New Types:**

| Type | Description |
|------|-------------|
| `TypedResponse<T>` | Wraps decoded data with usage, stopReason, rawJSON |
| `StructuredOutputError` | Comprehensive error enum for all failure modes |
| `RetryingHTTPClient` | Configurable retry logic with exponential backoff |

**Model Extension Methods:**

```swift
// OpenAI - native structured output
let result = try await model.generate(prompt, as: PersonInfo.self)
print(result.data.name)  // Already typed!

// Anthropic - tool-based extraction
let result = try await model.generateWithTool(
    prompt,
    as: PersonInfo.self,
    toolName: "extract_person"
)

// Streaming variants
for try await event in model.generateStream(prompt, as: PersonInfo.self) { ... }
for try await event in model.generateStreamWithTool(prompt, as: PersonInfo.self, toolName: "extract") { ... }

// Lower-level extraction
let typed = try model.extractAndDecode(from: response, as: PersonInfo.self, expectToolCall: false)
```

**StructuredOutputError Cases:**

| Error | Description |
|-------|-------------|
| `.modelRefused(reason)` | Model declined (safety, policy) |
| `.emptyResponse` | No content or tool calls |
| `.unexpectedTextResponse(content)` | Expected tool call, got text |
| `.unexpectedToolCall(toolName)` | Expected text, got tool call |
| `.decodingFailed(json, error)` | JSON didn't match schema |
| `.incompleteResponse(partialJSON)` | Response truncated (max tokens) |

**Tests:** 33 unit tests + 32 integration tests

---

#### Examples

Added runnable example targets:

```bash
swift run BasicSchema        # Schema generation demo (no API keys)
swift run StructuredOutput   # Typed API demo (requires API keys)
```

**Test Count:** 402 tests (all passing)

---

## Session: 2026-01-22 (Part 10)

### Completed

#### GPT-5.2 and Newer Models Support

Tested and added support for the newest OpenAI models discovered through model listing:
- **GPT-5 family**: gpt-5, gpt-5-mini, gpt-5-nano, gpt-5-pro, gpt-5.1, gpt-5.2
- **o3 family**: o3, o3-mini, o3-pro, o3-deep-research
- **GPT-4.1 family**: gpt-4.1, gpt-4.1-mini, gpt-4.1-nano

**Key API Changes for Newer Models:**

| Parameter | Old Models (GPT-4, GPT-3.5) | New Models (GPT-5.x, o3, o1, GPT-4.1) |
|-----------|----------------------------|----------------------------------------|
| Max tokens | `max_tokens` | `max_completion_tokens` |
| Temperature | Supported | o3/o1: NOT supported, GPT-5: supported |
| System messages | Supported | o3/o1: NOT supported, GPT-5: supported |

**Updated Files:**
- [OpenAITypes.swift](../Sources/Yrden/Providers/OpenAI/OpenAITypes.swift) - Added `max_completion_tokens` parameter
- [OpenAIModel.swift](../Sources/Yrden/Providers/OpenAI/OpenAIModel.swift) - Auto-detect which parameter to use based on model name
- [Model.swift](../Sources/Yrden/Model.swift) - Added `.gpt5` capability preset (400K context)

**Test Results:**
- GPT-5.2 completion: ✅ Working
- GPT-5.2 streaming: ✅ Working
- o3-mini reasoning: ✅ Working (uses more tokens for reasoning)

#### Structured Output Implementation (OpenAI)

Wired up `outputSchema` to OpenAI's `response_format` with `json_schema`. This enables type-safe JSON responses that conform to a specified schema.

**How it works:**
```swift
let schema: JSONValue = [
    "type": "object",
    "properties": [
        "sentiment": ["type": "string", "enum": ["positive", "negative", "neutral"]],
        "confidence": ["type": "number"]
    ],
    "required": ["sentiment", "confidence"],
    "additionalProperties": false
]

let request = CompletionRequest(
    messages: [.user("Analyze: 'I love this!'")],
    outputSchema: schema
)

let response = try await model.complete(request)
// response.content is guaranteed to be valid JSON matching the schema
```

**Updated Files:**
- [OpenAIModel.swift](../Sources/Yrden/Providers/OpenAI/OpenAIModel.swift) - Converts `outputSchema` to `response_format: json_schema`

**Tests Added:**
- `structuredOutput_sentimentAnalysis()` - Complex schema with enum, number, array
- `structuredOutput_dataExtraction()` - Extract structured data from text
- `structuredOutput_streaming()` - Structured output works with streaming
- `encode_structuredOutputRequest()` - Unit test for wire format

**Note:** Anthropic's structured output is in beta and not yet implemented.

**Learnings for Future Schema Development:**

1. **`additionalProperties: false` is required** for OpenAI's strict mode. Without it, the model may add extra fields.

2. **JSONValue has separate `.int` and `.double` cases**, not a unified `.number`. When parsing responses, handle both:
   ```swift
   switch value {
   case .int(let i): // handle integer
   case .double(let d): // handle decimal
   }
   ```

3. **Dictionary subscript returns optional** - `obj["key"]` returns `JSONValue?`, must unwrap before pattern matching:
   ```swift
   // Wrong: case .string(let s) = obj["key"]
   // Right:
   guard let value = obj["key"], case .string(let s) = value else { ... }
   ```

4. **"integer" in schema may return as double** - JSON doesn't distinguish int/double, so `"type": "integer"` might come back as `.double(32.0)` not `.int(32)`. Handle both.

5. **Streaming works with structured output** - Accumulate deltas, parse complete JSON at end. The model streams valid JSON fragments.

6. **Schema name is arbitrary** - We use `"response"` but any valid identifier works. OpenAI uses it for logging/debugging.

7. **`strict: true` enforces exact compliance** - Model will only output valid JSON matching the schema. No need for fallback parsing.

**Test Count:** 294 tests (all passing)

---

## Session: 2026-01-22 (Part 9)

### Completed

#### OpenAI Provider Implementation

Implemented `OpenAIProvider` and `OpenAIModel` as the second provider, validating the Model/Provider architecture works across different API formats.

**New Files:**

| File | Lines | Description |
|------|-------|-------------|
| [OpenAIProvider.swift](../Sources/Yrden/Providers/OpenAI/OpenAIProvider.swift) | ~110 | Bearer token auth, model listing |
| [OpenAITypes.swift](../Sources/Yrden/Providers/OpenAI/OpenAITypes.swift) | ~350 | Wire format types (internal) |
| [OpenAIModel.swift](../Sources/Yrden/Providers/OpenAI/OpenAIModel.swift) | ~430 | Model protocol implementation |

**Key Differences from Anthropic:**

| Aspect | Anthropic | OpenAI |
|--------|-----------|--------|
| Auth header | `x-api-key` | `Authorization: Bearer` |
| System message | Extracted to `system` field | In messages array (`role: system`) |
| Tool results | Content block in user message | Separate message (`role: tool`) |
| Images | `source.data` with base64 | Data URL format |
| Stream end | `message_stop` event | `data: [DONE]` |
| Stop reasons | `end_turn`, `tool_use` | `stop`, `tool_calls` |

**Capability Detection:**

Models are auto-detected by name prefix:
- `gpt-4o*`, `gpt-4-turbo*` → Full capabilities
- `o1*` → No temperature, no tools, no vision, no system messages
- `o3*` → No temperature, has tools/vision, no system messages

**Tests:**

| File | Tests | Coverage |
|------|-------|----------|
| [OpenAITypesTests.swift](../Tests/YrdenTests/OpenAITypesTests.swift) | 39 | Content parts, messages, requests, responses, streaming |
| [OpenAIIntegrationTests.swift](../Tests/YrdenTests/Integration/OpenAIIntegrationTests.swift) | 21 | Real API: completion, streaming, tools, vision, unicode, errors |

**Integration Test Coverage:**
- Simple completion with system messages
- Temperature and max_tokens config
- Streaming (basic, long response)
- Tool calling (single, multi-turn, multiple tools, streaming)
- Multi-turn conversation context
- Vision/images
- Unicode/emoji handling
- Error handling (invalid API key, invalid model)
- Model listing
- o1 capability validation (temperature, tools, system message restrictions)

**Test Counts:** 286 tests total (284 passing, 2 skipped)

**Expensive Test Pattern:**

Tests requiring special API access (o1 models) are gated:
```swift
@Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_EXPENSIVE_TESTS"] != nil))
func o1_simpleCompletion() async throws { ... }
```

Run with: `RUN_EXPENSIVE_TESTS=1 swift test --filter o1_`

---

## Session: 2026-01-22 (Part 8)

### Completed

#### listModels() → AsyncThrowingStream + Caching

Refactored `listModels()` to return `AsyncThrowingStream<ModelInfo, Error>` instead of `[ModelInfo]`. This enables:
- **Lazy pagination** - Pages fetched on demand as stream is consumed
- **Early exit** - Stop iterating when you find what you need
- **Memory efficiency** - Don't hold 200+ models in memory for large catalogs (OpenRouter)

Also added `CachedModelList` actor for opt-in caching of model lists.

**Protocol Change:**

```swift
// Before
func listModels() async throws -> [ModelInfo]

// After
func listModels() -> AsyncThrowingStream<ModelInfo, Error>
```

**Usage:**

```swift
// Collect all models
var models: [ModelInfo] = []
for try await model in provider.listModels() {
    models.append(model)
}

// Find first matching model (stops early, no extra pages fetched)
for try await model in provider.listModels() {
    if model.id.contains("claude-3-5") {
        return model
    }
}

// With caching (recommended for repeated access)
let cache = CachedModelList(ttl: 3600)  // 1 hour TTL
let models = try await cache.models(from: provider)
let models2 = try await cache.models(from: provider)  // Cached
let fresh = try await cache.models(from: provider, forceRefresh: true)
```

**New Files/Types:**

| Type | Location | Description |
|------|----------|-------------|
| `CachedModelList` | Provider.swift | Actor for caching model lists with TTL |

**New Tests:**

| Test | Description |
|------|-------------|
| `listModels_earlyExit()` | Verifies lazy evaluation and early exit |
| `listModels_cached()` | Verifies CachedModelList caching behavior |

**Test Counts:** 226 tests (all passing)

---

## Session: 2026-01-22 (Part 7)

### Completed

#### Comprehensive Anthropic Test Coverage

In-depth review of test coverage revealed gaps in streaming, tool calling, and edge cases. Added 11 new integration tests and 2 unit tests to achieve robust coverage.

**Bug Fix: Streaming Mixed Content**

Fixed a bug in `AnthropicModel.processStreamEvent()` where `contentBlockStop` events for tool calls were not being handled correctly when text content preceded the tool call. The SSE `index` is the absolute content block index, not the tool call index.

- Changed `ToolCallAccumulator` to track `blockIndex`
- Updated `contentBlockStop` handler to find tool call by block index

**New Integration Tests:**

| Test | Category | Description |
|------|----------|-------------|
| `streamingWithStopSequence()` | Streaming | Stop sequence terminates stream correctly |
| `streamingWithMaxTokens()` | Streaming | Truncation mid-stream with `.maxTokens` |
| `streamingMixedContent()` | Streaming | Text + tool call in same stream |
| `streamingUsageTracking()` | Streaming | Token counts in streaming response |
| `multipleToolCalls()` | Tools | Multiple tools available, model selects |
| `toolCallWithNestedArguments()` | Tools | Complex nested object/array arguments |
| `toolResultWithError()` | Tools | Error response handled gracefully |
| `multiTurnWithTools()` | Multi-turn | Full loop: user → tool → result → follow-up |
| `unicodeHandling()` | Edge Cases | Unicode/emoji in messages |
| `unicodeInToolArguments()` | Edge Cases | Unicode in tool call arguments |
| `expensive_contextLengthExceeded()` | Error Handling | Context overflow (skipped by default) |

**New Unit Tests:**

| Test | Description |
|------|-------------|
| `decode_stopSequenceResponse()` | Response with `stop_sequence` field set |
| `decode_maxTokensResponse()` | Response with `max_tokens` stop reason |

**Test Counts:**
- Anthropic Integration: 31 tests (was 20)
- Anthropic Types Unit: 29 tests (was 27)
- **Total: 224 tests (all passing)**

**Expensive Test Pattern:**

Tests that are costly (high token usage) or slow are gated with:
```swift
@Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_EXPENSIVE_TESTS"] != nil))
```

Run with: `RUN_EXPENSIVE_TESTS=1 swift test --filter expensive`

---

## Session: 2026-01-22 (Part 6)

### Completed

#### Anthropic Integration Test Gaps

Closed testing gaps for stop sequences and vision/images. Identified that structured outputs (`outputSchema`) is not yet implemented for Anthropic.

**New Tests Added:**

| Test | Description |
|------|-------------|
| `stopSequences()` | Verifies generation stops at stop sequence with `.stopSequence` reason |
| `stopSequences_multipleSequences()` | Tests multiple stop sequences (first match wins) |
| `imageInput()` | Single image (red PNG) with color recognition |
| `imageInputWithText()` | Image with system message |
| `multipleImages()` | Two images (red + green) in single request |

**Test Infrastructure:**
- Added helper functions for creating minimal valid PNG images programmatically
- `createTestPNG(color:)` generates 2x2 pixel solid color PNGs
- Includes CRC32 and Adler32 implementations for PNG chunk checksums

**Finding: Structured Outputs Not Yet Implemented**

The `outputSchema` field exists in `CompletionRequest` but is not used in `AnthropicModel.encodeRequest()`. Anthropic supports structured outputs via:
1. Tool use (forcing tool call with schema)
2. Beta structured outputs API

Implementation deferred to OpenAI provider work (where structured outputs are more mature).

---

## Session: 2026-01-22 (Part 5)

### Completed

#### Anthropic Provider Implementation

Implemented `AnthropicProvider` and `AnthropicModel` as the first real provider, validating the Model/Provider architecture with actual API support.

**New Files:**

| File | Lines | Description |
|------|-------|-------------|
| [AnthropicProvider.swift](../Sources/Yrden/Providers/Anthropic/AnthropicProvider.swift) | ~50 | API key auth, headers, base URL |
| [AnthropicTypes.swift](../Sources/Yrden/Providers/Anthropic/AnthropicTypes.swift) | ~280 | Internal wire format types for encoding/decoding |
| [AnthropicModel.swift](../Sources/Yrden/Providers/Anthropic/AnthropicModel.swift) | ~350 | `Model` protocol implementation with streaming |

**Key Implementation Details:**

1. **Request Encoding:**
   - System messages extracted to request `system` field (not in messages array)
   - Tool arguments converted from string to parsed JSON object
   - Images base64 encoded with `media_type`

2. **Response Decoding:**
   - Text content extracted from `content` blocks
   - Tool calls converted back to `ToolCall` with stringified arguments
   - Stop reason mapped to our `StopReason` enum

3. **Streaming:**
   - SSE event parsing for Anthropic's event types
   - Event types: `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`
   - Tool call arguments accumulated during streaming

4. **Error Handling:**
   - HTTP status codes mapped to `LLMError` cases
   - Anthropic error responses parsed for detailed messages
   - Rate limit retry-after header support

**Tests:**

| File | Tests | Coverage |
|------|-------|----------|
| [AnthropicTypesTests.swift](../Tests/YrdenTests/AnthropicTypesTests.swift) | 29 | Content blocks, messages, requests, responses, SSE events |
| [AnthropicIntegrationTests.swift](../Tests/YrdenTests/Integration/AnthropicIntegrationTests.swift) | 31 | Real API calls: completion, streaming, tools, vision, stop sequences, multi-turn, unicode, errors |

**Integration Test Coverage:**
- Simple completion with system messages
- Temperature and max_tokens config
- Streaming (basic, stop sequences, max tokens, mixed content, usage tracking)
- Tool calling (single, multi-turn, multiple tools, nested args, error results)
- Multi-turn conversation context
- Vision/images (single, multiple, with text)
- Stop sequences (single, multiple)
- Unicode/emoji handling
- Error handling (invalid API key, invalid model, context overflow)
- Model listing (`listModels()`)

**Model Discovery:**
- Added `ModelInfo` type with id, displayName, createdAt, metadata
- Added `listModels()` to `Provider` protocol
- Implemented for `AnthropicProvider` via `GET /v1/models`

---

## Session: 2026-01-22 (Part 4)

### Completed

#### Core LLM Types Implementation

Implemented all core types from [llm-provider-design.md](llm-provider-design.md) with comprehensive test coverage (164 tests total, 0 failures).

**Phase 1: Foundation Types**

| File | Types | Description |
|------|-------|-------------|
| [Tool.swift](../Sources/Yrden/Tool.swift) | `ToolDefinition`, `ToolCall`, `ToolOutput` | Tool calling primitives |
| [Message.swift](../Sources/Yrden/Message.swift) | `Message`, `ContentPart` | Conversation messages with multimodal support |
| [LLMError.swift](../Sources/Yrden/LLMError.swift) | `LLMError` | Typed error enum with all common failure modes |

**Phase 2: Composite Types**

| File | Types | Description |
|------|-------|-------------|
| [Completion.swift](../Sources/Yrden/Completion.swift) | `CompletionConfig`, `CompletionRequest`, `CompletionResponse`, `StopReason`, `Usage` | Request/response types |
| [Streaming.swift](../Sources/Yrden/Streaming.swift) | `StreamEvent` | Fine-grained streaming events |

**Phase 3: Protocols**

| File | Types | Description |
|------|-------|-------------|
| [Model.swift](../Sources/Yrden/Model.swift) | `Model` protocol, `ModelCapabilities` | Model abstraction with capability validation |
| [Provider.swift](../Sources/Yrden/Provider.swift) | `Provider` protocol, `OpenAICompatibleProvider` | Connection and authentication |

**Key Features:**
- All types are `Sendable`, `Codable`, `Equatable`, `Hashable`
- `ModelCapabilities` with predefined constants for common models (Claude 3.5, GPT-4o, o1/o3)
- Request validation against model capabilities (throws `LLMError.capabilityNotSupported`)
- Convenience extensions on `Model` for common patterns

**Tests:**

| File | Tests | Coverage |
|------|-------|----------|
| [ToolTests.swift](../Tests/YrdenTests/ToolTests.swift) | 21 | ToolDefinition, ToolCall, ToolOutput roundtrip + edge cases |
| [MessageTests.swift](../Tests/YrdenTests/MessageTests.swift) | 29 | Message, ContentPart roundtrip + convenience constructors |
| [LLMErrorTests.swift](../Tests/YrdenTests/LLMErrorTests.swift) | 26 | Error enum + LocalizedError descriptions |
| [CompletionTests.swift](../Tests/YrdenTests/CompletionTests.swift) | 28 | Request/Response/Config/StopReason/Usage |
| [StreamingTests.swift](../Tests/YrdenTests/StreamingTests.swift) | 26 | StreamEvent roundtrip + event sequences |
| [ModelTests.swift](../Tests/YrdenTests/ModelTests.swift) | 26 | ModelCapabilities + request validation |

---

## Session: 2026-01-22 (Part 3)

### Completed

#### JSONValue Implementation - All 5 Phases Complete

Fully implemented `JSONValue` type with comprehensive test coverage (165 tests, 0 failures).

**Implementation** ([Sources/Yrden/JSONValue.swift](../Sources/Yrden/JSONValue.swift)):
- Recursive enum: `null`, `bool`, `int`, `double`, `string`, `array`, `object`
- Custom Codable (not synthesized - proper JSON format, not wrapped enum)
- Type-safe accessors: `boolValue`, `intValue`, `doubleValue`, `stringValue`, `arrayValue`, `objectValue`
- Subscript access: `value["key"]` for objects, `value[0]` for arrays
- Literal expressibility: `nil`, `true`, `42`, `3.14`, `"hello"`, `[1, 2]`, `["a": 1]`
- Sendable, Equatable, Hashable

**Tests** ([Tests/YrdenTests/JSONValue/](../Tests/YrdenTests/JSONValue/)):

| File | Tests | Coverage |
|------|-------|----------|
| [JSONValuePrimitiveTests.swift](../Tests/YrdenTests/JSONValue/JSONValuePrimitiveTests.swift) | 55 | null, bool, int, double, string - roundtrip, encoding, decoding, accessors, literals |
| [JSONValueObjectTests.swift](../Tests/YrdenTests/JSONValue/JSONValueObjectTests.swift) | 29 | objects - roundtrip, accessor, subscript, nested, literals, edge cases |
| [JSONValueArrayTests.swift](../Tests/YrdenTests/JSONValue/JSONValueArrayTests.swift) | 29 | arrays - roundtrip, accessor, subscript, heterogeneous, nested, literals |
| [JSONValueEqualityTests.swift](../Tests/YrdenTests/JSONValue/JSONValueEqualityTests.swift) | 32 | Equatable/Hashable - same/different values, nested, Set/Dictionary usage |
| [JSONValueE2ETests.swift](../Tests/YrdenTests/JSONValue/JSONValueE2ETests.swift) | 20 | real-world: JSON Schema, tool args, structured outputs, provider formats |

**Phases completed:**
1. ✅ Primitives - null, bool, int, double, string + accessors + literals
2. ✅ Object - object case + objectValue + subscript + nested
3. ✅ Array - array case + arrayValue + subscript + mixed
4. ✅ Equatable/Hashable - synthesized works, edge cases verified
5. ✅ E2E - JSON Schema, tool arguments, structured output scenarios

---

## Session: 2026-01-22 (Part 2)

### Completed

#### 1. Research: JSONValue Patterns
Investigated how to represent arbitrary JSON in Swift. Key findings:

- **`[String: Any]` won't work** - not Sendable, not Codable (Swift 6 requirement)
- **JSEN pattern** is industry standard - recursive enum for JSON representation
- **Swift's gap** - no built-in arbitrary JSON type, everyone rolls their own
- **Our scope** - we wrap Apple's JSONDecoder, we don't parse JSON ourselves

Created research document: [docs/research-jsonvalue.md](research-jsonvalue.md)

#### 2. Test Strategy: JSONValue
Defined focused test strategy. Key decisions:

- **Don't test Apple's code** - JSONDecoder handles parsing
- **Test our code** - Codable impl, accessors, subscripts, literals
- **8 test categories** - roundtrip, encoding format, decoding, accessors, subscripts, literals, equatable, **end-to-end**
- **E2E tests critical** - verify full flow (schema → encode → decode → access) works for real scenarios
- **~45 tests total** - small, focused, maintainable

Created test strategy: [docs/test-strategy-jsonvalue.md](test-strategy-jsonvalue.md)

---

## Session: 2026-01-22 (Part 1)

### Completed

#### 1. LLM Provider Design Document
Created comprehensive design document at [docs/llm-provider-design.md](llm-provider-design.md) covering:

- **Design Tenets** (7 core principles):
  - Sendable everywhere
  - Codable by default (opt-in usage)
  - Deps never Codable
  - Lazy initialization
  - State/behavior separation
  - Pausable execution
  - Model-agnostic core

- **Architecture Decision: Model/Provider Split** (PydanticAI-style)
  - `Model` = API format + capabilities + complete()/stream()
  - `Provider` = connection + authentication
  - Avoids N×M type explosion
  - Enables: Azure OpenAI, Ollama, Bedrock with multiple model families

- **10 Design Decisions** with rationale and alternatives considered:
  1. Model/Provider split
  2. Swift API surface (TBD - options documented)
  3. Request type with convenience overloads
  4. Models implement both streaming and non-streaming
  5. Fine-grained streaming events
  6. Closed Message enum
  7. JSONValue for schema representation
  8. Typed error enum
  9. Unified tool system
  10. Codable opt-in for serialization

- **Apple Ecosystem Opportunities** identified (future, not blocking):
  - Handoff, CloudKit sync, SwiftUI binding, Siri/Shortcuts, Background tasks, On-device models

- **Risks and Open Questions** documented

#### 2. Test Configuration Setup
Created environment variable support for integration tests:

- [.env.template](.env.template) - Template for API keys
- [Tests/YrdenTests/TestConfig.swift](../Tests/YrdenTests/TestConfig.swift) - Loads keys from env vars or .env file
- Updated [.gitignore](../.gitignore) to exclude `.env` files

**Key design decision:** Tests fail loudly if required API keys are missing (no silent skipping).

---

## Next Steps

### Immediate (Phase 0 Remaining)

1. **MCP Consolidation (0.2)**
   - Choose Protocol* hierarchy as canonical
   - Deprecate old MCPServerConnection/MCPManager
   - ~~Merge MCPTool and MCPToolProxy~~ ✅ Done: MCPTool deprecated, shared parsing extracted

2. **Test Quality (0.4)**
   - Simplify test doubles (<50 lines each)
   - Replace loose assertions with exact expectations

3. **Minor Cleanup (0.5)**
   - Extract helper methods
   - Cache compiled regex in ToolFilter

### Future

1. **Provider Variants**
   - `AzureOpenAIProvider` - Different auth, URL structure
   - `LocalProvider` (Ollama) - OpenAI-compatible, no auth
   - `OpenRouterProvider` - Multi-model aggregator

2. **Skills System**
   - Anthropic-style reusable capabilities
   - Composable skill sets for agents

3. **Example Application**
   - Demonstrate all capabilities
   - SwiftUI chat interface

### Completed ✅

- ~~@Schema Macro~~ - JSON Schema generation from Swift types
- ~~@Guide constraints~~ - Descriptions and validation hints
- ~~Structured Outputs~~ - OpenAI native + Anthropic tool-based
- ~~Typed API~~ - generate(), generateWithTool(), TypedResponse<T>
- ~~Agent Core~~ - Agent<Deps, Output> with run(), tools, typed output
- ~~Agent.runStream()~~ - Streaming events during execution
- ~~Agent.iter()~~ - Iterable execution with AgentNode yielding
- ~~Output Validators~~ - Post-validation with retry capability
- ~~Human-in-the-Loop~~ - Deferred tool resolution with resume()
- ~~AWS Bedrock Provider~~ - Converse API with Claude + Nova models (37 tests)
- ~~MCP Integration~~ - Official MCP Swift SDK with tool discovery (64 tests)
- ~~Agent Failure Handling~~ - RetryPolicy, tool timeouts, comprehensive failure tests (73 tests)
- ~~Concurrency Safety~~ - Actor isolation, concurrent runs, cancellation propagation
- ~~Phase 0.1~~ - Agent code duplication reduced (1485 → 1108 lines)
- ~~Phase 0.3~~ - Unsafe code fixes (forced casts, debug prints, semaphore blocking)

---

## File Structure (Current)

```
Yrden/
├── CLAUDE.md                           # Project instructions
├── README.md                           # ✅ Updated documentation
├── Package.swift
├── docs/
│   ├── llm-provider-design.md          # Design document
│   ├── bedrock-implementation-plan.md  # ✅ AWS Bedrock (implemented)
│   ├── research-jsonvalue.md           # JSONValue research
│   ├── test-strategy-jsonvalue.md      # JSONValue test plan
│   └── progress.md                     # This file
├── Examples/
│   ├── BasicSchema/main.swift          # ✅ Schema generation demo
│   └── StructuredOutput/main.swift     # ✅ Typed API demo
├── Sources/
│   ├── Yrden/
│   │   ├── Yrden.swift                 # SchemaType protocol, macro declarations
│   │   ├── JSONValue.swift             # JSONValue enum (Sendable, Codable)
│   │   ├── Message.swift               # Message, ContentPart
│   │   ├── Tool.swift                  # ToolDefinition, ToolCall, ToolOutput
│   │   ├── Completion.swift            # Request/Response/Config types
│   │   ├── Streaming.swift             # StreamEvent
│   │   ├── Model.swift                 # Model protocol, ModelCapabilities
│   │   ├── Provider.swift              # Provider protocol
│   │   ├── LLMError.swift              # Typed error enum
│   │   ├── Model+StructuredOutput.swift # ✅ generate(), generateWithTool()
│   │   ├── StructuredOutput.swift      # ✅ TypedResponse<T>
│   │   ├── StructuredOutputError.swift # ✅ Error enum
│   │   ├── Retry.swift                 # ✅ RetryingHTTPClient
│   │   ├── Agent/                      # ✅ Agent system
│   │   │   ├── Agent.swift             # Main Agent<Deps, Output> actor
│   │   │   ├── AgentContext.swift      # Context passed to tools
│   │   │   ├── AgentTool.swift         # Tool protocol + AnyAgentTool
│   │   │   ├── AgentError.swift        # Agent-specific errors
│   │   │   ├── AgentTypes.swift        # UsageLimits, EndStrategy, etc.
│   │   │   ├── ToolExecutionEngine.swift    # ✅ Tool execution with retry/timeout
│   │   │   └── AgentLoopObserver.swift      # ✅ Observer protocol for loop unification
│   │   ├── MCP/                        # ✅ Model Context Protocol
│   │   │   ├── MCPValueConversion.swift # MCP.Value ↔ JSONValue
│   │   │   ├── MCPTool.swift           # MCP tools as AgentTools
│   │   │   ├── MCPServerConnection.swift # Single server management (old)
│   │   │   ├── MCPManager.swift        # Multi-server orchestration
│   │   │   ├── MCPResourceProvider.swift # Resource context injection
│   │   │   ├── MCPTypes.swift          # ✅ ConnectionState, events, errors
│   │   │   ├── MCPProtocols.swift      # ✅ Protocols for DI
│   │   │   ├── MCPToolMode.swift       # ✅ ToolMode, ToolFilter, ToolEntry
│   │   │   ├── MCPToolProxy.swift      # ✅ Routes calls through coordinator
│   │   │   ├── ProtocolServerConnection.swift  # ✅ Real impl with MCPClientFactory
│   │   │   ├── ProtocolMCPCoordinator.swift    # ✅ Real impl with ConnectionFactory
│   │   │   └── ProtocolMCPManager.swift        # ✅ @MainActor ObservableObject manager
│   │   └── Providers/
│   │       ├── Anthropic/
│   │       │   ├── AnthropicProvider.swift
│   │       │   ├── AnthropicTypes.swift
│   │       │   └── AnthropicModel.swift
│   │       ├── OpenAI/
│   │       │   ├── OpenAIProvider.swift
│   │       │   ├── OpenAITypes.swift
│   │       │   ├── OpenAIModel.swift
│   │       │   └── OpenAIResponsesTypes.swift  # ✅ Responses API types
│   │       └── Bedrock/                        # ✅ AWS Bedrock
│   │           ├── BedrockProvider.swift       # AWS SDK auth + model listing
│   │           └── BedrockModel.swift          # Converse API implementation
│   └── YrdenMacros/
│       ├── YrdenMacros.swift           # Plugin entry point
│       ├── SchemaMacro.swift           # ✅ @Schema macro implementation
│       ├── GuideMacro.swift            # ✅ @Guide macro implementation
│       └── SchemaGeneration/
│           ├── TypeParser.swift        # ✅ Type parsing
│           └── SchemaBuilder.swift     # ✅ Schema code generation
├── Tests/
│   ├── YrdenTests/
│   │   ├── TestConfig.swift            # API key loading
│   │   ├── ToolTests.swift
│   │   ├── MessageTests.swift
│   │   ├── LLMErrorTests.swift
│   │   ├── CompletionTests.swift
│   │   ├── StreamingTests.swift
│   │   ├── ModelTests.swift
│   │   ├── AnthropicTypesTests.swift
│   │   ├── OpenAITypesTests.swift
│   │   ├── StructuredOutputTests.swift # ✅ Typed API unit tests
│   │   ├── Integration/
│   │   │   ├── AnthropicIntegrationTests.swift
│   │   │   ├── OpenAIIntegrationTests.swift
│   │   │   ├── BedrockIntegrationTests.swift     # ✅ AWS Bedrock (37 tests)
│   │   │   ├── SchemaIntegrationTests.swift      # ✅ @Schema with real APIs
│   │   │   └── TypedOutputIntegrationTests.swift # ✅ Typed API with real APIs
│   │   ├── Agent/
│   │   │   ├── AgentTests.swift                  # ✅ Agent unit + integration tests
│   │   │   ├── AgentFailureTests.swift           # ✅ Failure handling tests
│   │   │   ├── AgentConcurrencyTests.swift       # ✅ Concurrency safety tests
│   │   │   └── ToolExecutionEngineTests.swift    # ✅ Tool execution engine tests (14 tests)
│   │   ├── MCP/                                  # ✅ MCP tests (64 tests)
│   │   │   ├── MCPValueConversionTests.swift    # 27 value conversion tests
│   │   │   ├── MCPToolTests.swift               # 7 tool wrapping tests
│   │   │   ├── MCPToolProxyTests.swift          # ✅ Proxy, filter, mode tests
│   │   │   ├── ServerConnectionTests.swift      # ✅ 14 tests (real impl + MockMCPClient)
│   │   │   ├── MCPCoordinatorTests.swift        # ✅ 13 tests (real impl + MockServerConnectionFactory)
│   │   │   ├── MCPManagerTests.swift            # ✅ 14 tests (TestMCPManager + MockCoordinator)
│   │   │   └── TestDoubles/                     # Mock infrastructure
│   │   │       ├── MockMCPClient.swift          # Mock for MCP SDK Client
│   │   │       ├── MockServerConnection.swift   # Mock ServerConnectionProtocol
│   │   │       ├── MockCoordinator.swift        # Mock MCPCoordinatorProtocol
│   │   │       ├── MCPTestFixtures.swift        # Test data factories
│   │   │       ├── MCPTestUtilities.swift       # Event collection helpers
│   │   │       └── MCPManagerTestHelpers.swift  # TestMCPManager
│   │   └── JSONValue/
│   │       └── ... (JSONValue tests)
│   └── YrdenMacrosTests/
│       └── YrdenMacrosTests.swift      # ✅ 35+ macro expansion tests
├── .env.template
└── .gitignore
```

---

## Design Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-01-22 | Model/Provider split | Follow PydanticAI, avoid N×M explosion |
| 2026-01-22 | JSONValue over [String: Any] | Sendable + Codable required |
| 2026-01-22 | Codable opt-in | Enable Apple features without requiring them |
| 2026-01-22 | Deps never Codable | Keep deps flexible (DB, HTTP clients) |
| 2026-01-22 | Tests fail on missing keys | No silent skipping |
| 2026-01-22 | Custom Codable for JSONValue | Synthesized Codable wraps values incorrectly |
| 2026-01-22 | Separate int/double cases | JSON Schema distinguishes integer vs number |
| 2026-01-22 | Test our code, not Apple's | JSONDecoder handles parsing, we test our wrapper |
| 2026-01-22 | Incremental implementation | Each feature tested before adding next; primitives → object → array → e2e |
| 2026-01-22 | All types Equatable+Hashable | Enables use in Sets/Dictionaries for caching, deduplication |
| 2026-01-22 | String in LLMError.networkError | Error protocol not Equatable; use String for description |
| 2026-01-22 | Custom Codable for enums | Avoid synthesized wrapped format; use role/type discriminators |
| 2026-01-22 | Request validation in Model extension | Catch capability mismatches before API call |
| 2026-01-22 | Model = API format, not LLM | Same LLM via different APIs needs different Model classes (e.g., Claude via Anthropic vs Bedrock) |
| 2026-01-22 | OpenRouter extends OpenAIChatModel | OpenRouter uses OpenAI-compatible format with extra metadata |
| 2026-01-22 | Internal wire format types | Keep AnthropicTypes internal, only expose public Model/Provider |
| 2026-01-22 | ToolCall.arguments as String | Provider-agnostic; Anthropic parses to JSONValue internally, serializes back to string |
| 2026-01-22 | SSE parsing in model | Each provider handles its own streaming format; no common SSE abstraction needed |
| 2026-01-22 | Model.name = API identifier | String that goes to API (base model ID or inference profile ID for Bedrock) |
| 2026-01-22 | listModels() returns ModelInfo | Rich metadata for discovery; provider-specific details in `metadata: JSONValue?` |
| 2026-01-22 | listModels() → AsyncThrowingStream | Lazy pagination for large catalogs; early exit support; caller decides caching |
| 2026-01-22 | CachedModelList actor | Opt-in caching with TTL; keeps Provider stateless and Sendable |
| 2026-01-22 | OpenAI same patterns as Anthropic | Validates Model/Provider split; same public types, different wire format |
| 2026-01-22 | Capability detection by model name | Simple prefix matching (gpt-4o, o1, o3); avoids API call to check capabilities |
| 2026-01-22 | o1 tests gated behind RUN_EXPENSIVE_TESTS | o1 models may require special access; validation tests run without API call |
| 2026-01-23 | Bedrock uses AWS SDK for Swift | SigV4 manual implementation error-prone; SDK handles credentials/refresh |
| 2026-01-23 | Bedrock structured output via tool forcing | Converse API has no native JSON mode; same pattern as Anthropic tool-based |
| 2026-01-23 | Test Bedrock with Claude + Nova | Cross-model family testing ensures API compatibility |
| 2026-01-23 | Agent uses output tool for structured types | Providers require object schemas for tools; String output uses text response |
| 2026-01-23 | AnyAgentTool type erasure | Enables heterogeneous tool collections while preserving type safety internally |
| 2026-01-23 | String: SchemaType extension | Allows Agent<Deps, String> to work without output tool (text response) |
| 2026-01-23 | ToolResult enum with retry case | Tools can signal LLM to retry with feedback; cleaner than throwing |
| 2026-01-23 | Agent as actor | Thread-safe state management for tool execution loop |
| 2026-01-25 | Protocol-based MCP architecture | ServerConnectionProtocol + MCPCoordinatorProtocol + MCPClientProtocol enable testing with mocks |
| 2026-01-25 | Factory injection for testability | MCPClientFactory and ServerConnectionFactory allow tests to inject mocks at layer boundaries |
| 2026-01-25 | Real implementations in tests | Tests use real ProtocolServerConnection/ProtocolMCPCoordinator with mocks injected, not mock-everything approach |
| 2026-01-25 | Event collection delay | collectEvents() adds 10ms delay after starting collector to avoid race conditions |
| 2026-01-25 | Buffer-aware event tests | Tests collect all events (including previous state changes) then filter for expected events |
| 2026-01-25 | Protocols require Actor | `ServerConnectionProtocol: Actor` and `MCPCoordinatorProtocol: Actor` enforce actor isolation at compile time - protocols don't provide race protection, actors do |
| 2026-01-25 | MCPToolProxy routes through coordinator | Tools never hold stale connection refs; coordinator handles reconnection transparently |
| 2026-01-25 | Timeout → retry, disconnect → failure | Timeout means LLM can try simpler request; disconnect is terminal for that call |
| 2026-01-25 | ToolFilter as composable enum | Recursive indirect cases (.and, .or, .not) enable complex filtering with Codable support |
| 2026-01-25 | lifted() for deps-free tools | AnyAgentTool<Void> can be lifted to AnyAgentTool<D> for use with agents that have deps |
| 2026-01-25 | Phase 0 before new features | Code review revealed 4× duplicated agent loop, dual MCP hierarchies, and test quality issues; must consolidate before adding complexity |
| 2026-01-25 | Unify agent execution loop | Single parameterized loop instead of 4 near-identical implementations prevents drift and simplifies maintenance |
| 2026-01-25 | Choose Protocol* MCP hierarchy | Deprecate old MCPServerConnection/MCPManager in favor of Protocol-based versions for consistency |
| 2026-01-25 | Keep ToolExecutionEngine extraction despite over-engineering | Isolates retry/timeout logic with good tests; observer pattern unifies run()/iter(); clean separation despite higher total line count |
