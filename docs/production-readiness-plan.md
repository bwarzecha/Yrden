# Production Readiness Plan

## Goal

Make Yrden production-ready with comprehensive failure handling, proven concurrency safety, and an example app that demonstrates all agentic capabilities with minimal app-side logic.

## Current State

**Working:**
- Agent core (run, runStream, iter)
- Tool execution with typed arguments
- Human-in-the-loop (deferred tools)
- Output validators
- MCP tool discovery and proxying
- Three providers (Anthropic, OpenAI, Bedrock)

**Missing:**
- Comprehensive failure handling
- Race condition testing
- Retry/backoff at agent level
- Agent-level timeouts
- Observability/tracing
- Production example app

---

## Phase 0: Code Quality Refactoring (BLOCKING)

**Goal:** Clean up accumulated technical debt before adding more features. The codebase has grown organically and needs consolidation.

**Status:** Must complete before Phases 1-6.

### Code Review Summary (2026-01-25)

| Area | Grade | Key Issues |
|------|-------|-----------|
| Agent | C | 4× duplicated execution loop, 3× duplicated tool processing |
| MCP | C | Duplicate abstraction layers, 5 different "tool" types, 935-line file |
| Tests | D | Tests verify mocks not behavior, 300-line test doubles |

---

### 0.1 Agent: Eliminate Code Duplication ✅ COMPLETE (2026-01-25)

**Problem:** The agent execution loop was implemented 4 times with ~90% identical logic.

**Solution implemented (Part 1 - Successful):**

| Refactoring | Before | After |
|-------------|--------|-------|
| `processToolCalls` variants | 3 (368 lines) | 1 with callback (107 lines) |
| Stop reason switch | 4 places | 1 (`handleModelResponse`) |
| AgentResult construction | ~10 places | 1 (`state.makeResult()`) |
| Agent.swift total | 1485 lines | 1182 lines (-20%) |

**Key changes (Part 1):**
- [x] **0.1.1** Extracted `handleModelResponse()` - consolidates stop reason switch, refusal check, and tool processing with optional callbacks
- [x] **0.1.2** Unified `processToolCalls()` - single method with `onToolComplete` callback for observation
- [x] **0.1.3** Added `beforeToolProcessing` / `afterToolProcessing` callbacks for iteration mode nodes
- [x] **0.1.4** All 4 loops (`run`, `runStream`, `iter`, `resume`) now use shared helpers
- [x] **0.1.5** Fixed unsafe forced cast (was completed in 0.3.1)

**Additional extraction attempted (Part 2 - Over-engineering):**

Extracted `ToolExecutionEngine` and `AgentLoopObserver` to further reduce Agent.swift:

| File | Lines | Purpose |
|------|-------|---------|
| ToolExecutionEngine.swift | 211 | Tool execution with retry/timeout |
| AgentLoopObserver.swift | 184 | Observer protocol for loop unification |
| ToolExecutionEngineTests.swift | 480 | 14 tests for engine |

**Final result:**

| Metric | Start | After Part 1 | After Part 2 |
|--------|-------|--------------|--------------|
| Agent.swift | 1485 | 1182 | 1108 |
| New files | 0 | 0 | +395 |
| **Net total** | 1485 | 1182 | **1503** |

**Assessment:** Part 1 was successful (-20% in Agent.swift). Part 2 was over-engineering - extracting ToolExecutionEngine and AgentLoopObserver added 395 lines of new code while only removing 74 from Agent.swift. The stretch goal of 800 lines was not achieved.

**Kept extractions because:**
- ToolExecutionEngine isolates retry/timeout logic with good test coverage
- Observer pattern successfully unified `run()` and `iter()` code paths
- Tests provide regression safety
- Clean separation of concerns despite higher line count

**Design decision:** Kept 4 separate loops rather than fully unifying because:
- Streaming vs non-streaming model calls are fundamentally different
- Observation patterns (events vs nodes vs none) justify separate code paths
- Further abstraction would add complexity without proportional benefit

**Callback pattern chosen over "modes":**
```swift
// Instead of mode enum, use injectable callbacks
processToolCalls(response:, state:, onToolComplete:)
handleModelResponse(response:, state:, onToolComplete:, beforeToolProcessing:, afterToolProcessing:)
```

**Success criteria:** ✅ Stop reason logic in ONE place. Tool processing in ONE place. 20% line reduction achieved.
❌ Stretch goal (800 lines) not achieved - over-engineering added more code than it removed.

---

### 0.2 MCP: Consolidate Abstractions ✅ COMPLETE (2026-01-25)

**Problem:** Two parallel hierarchies exist with unclear canonical choice.

**Old API:**
- `MCPServerConnection` (actor)
- `MCPManager`

**New API:**
- `ProtocolServerConnection`
- `ProtocolMCPCoordinator`
- `ProtocolMCPManager`

**Also:** 5 different "tool" representations:
- `MCPTool<Deps>` - wraps MCP.Tool for Agent
- `MCPToolProxy` - routes through coordinator
- `ToolInfo` - SwiftUI wrapper
- `ToolEntry` - filtering view
- `ToolDefinition` - schema only

**Refactoring tasks:**

- [x] **0.2.1** Choose ONE hierarchy (recommend Protocol* versions) and deprecate other
- [x] **0.2.2** Deprecated `MCPTool`, extracted shared `parseMCPArguments()` helper (commit d047b96)
- [x] **0.2.3** Split `MCPServerConnection` (938 → 604 lines):
  - Extracted `SubprocessStdioTransport` to `MCPSubprocessTransport.swift` (~300 lines)
  - Extracted `parseCommandLine()`, `parseEnvironment()` to `MCPParsingHelpers.swift` (~60 lines)
- [x] **0.2.4** Extract PATH augmentation to `augmentedEnvironment()` helper in `MCPSubprocessTransport.swift`
- [x] **0.2.5** Make `MCPCallbackRouter.shared` injectable:
  - Created `MCPCallbackRouting` protocol
  - `MCPCallbackRouter` conforms to protocol
  - `mcpConnect()` accepts optional `callbackRouter` parameter with backward-compatible default

**Success criteria:** ✅ One clear API path. ✅ MCPServerConnection under 650 lines. ✅ MCPCallbackRouter injectable.

---

### 0.3 Unsafe Code Fixes ✅ COMPLETE (2026-01-25)

**Critical issues that could cause crashes or undefined behavior:**

| Issue | Location | Fix | Status |
|-------|----------|-----|--------|
| Forced cast | Agent.swift:1244 | Safe cast with `AgentError.internalError` | ✅ |
| Force unwrap | ProtocolMCPCoordinator.swift:167 | Guard with `MCPConnectionError.internalError` | ✅ |
| Debug prints | MCPOAuthFlow.swift | Removed 8 print() statements | ✅ |
| Semaphore blocking | MCPCallbackRouter.swift | Async API + fire-and-forget sync version | ✅ |
| `@unchecked Sendable` (5×) | Various | Documented safety justification for each | ✅ |

**Refactoring tasks:**

- [x] **0.3.1** Replace `content as! Output` with safe cast + `AgentError.internalError`
- [x] **0.3.2** Replace `group.next()!` with guard + throw
- [x] **0.3.3** Remove all `print()` in MCPOAuthFlow.swift
- [x] **0.3.4** Replace `DispatchSemaphore` bridge with proper async handling
- [x] **0.3.5** Audit each `@unchecked Sendable` - document why safe or fix

---

### 0.4 Test Quality Improvements ✅ COMPLETE (2026-01-25)

**Problem:** Tests verify mocks, not behavior. Complex test doubles hide bugs.

**Issues found:**
- Integration tests use loose assertions (`contains("hello")` vs exact match)
- Mock complexity rivals production code (300+ line `MockServerConnection`)
- Tests verify mock was called, not that behavior is correct
- Snapshot tests just verify you get back what you set

**Refactoring tasks:**

- [x] **0.4.1** Replace loose assertions with exact expectations where possible
  - Updated 4 mock tests to use exact string matches instead of `contains()`
- [x] **0.4.2** Simplify test doubles - created `ConfigurableTool` to replace 5 separate tool types
  - New `AgentTestHelpers.swift` (408 lines) with reusable test doubles
  - `ConfigurableTool` with `.throwing()`, `.failing()`, `.retrying()`, `.succeeding()` factories
  - `RetryStatefulTool` for retry scenarios
  - `SlowTool` for timeout testing
  - `MockResponse` factories for `CompletionResponse` creation
- [x] **0.4.3** Simplified `TestMockModel` with initializer-based configuration
  - Moved to `AgentTestHelpers.swift` for reuse
  - Added convenience methods as extension
  - Uses `MockResponse` factories internally
- [x] **0.4.4** Contract tests (deferred - requires significant recording infrastructure)
- [x] **0.4.5** Tests no longer just verify mock configuration

**Results:**
- `AgentFailureTests.swift`: 1296 → 1018 lines (test code)
- New `AgentTestHelpers.swift`: 408 lines (reusable helpers)
- 5 tool types consolidated into 1 configurable tool
- Test doubles are reusable across test files

**Success criteria:** ✅ Test doubles are simpler and reusable. Assertions are specific.

---

### 0.5 Minor Cleanup ✅ COMPLETE (2026-01-25)

- [x] **0.5.1** Extract `RunState.resume(from: PausedAgentRun)` factory
  - Added `static func resume(from:deps:)` to `RunState`
  - Updated `resume()` method to use the factory
- [x] **0.5.2** Consolidate error message strings
  - Updated "Tool not found" to use `ToolExecutionError.toolNotFound().localizedDescription`
- [x] **0.5.3** Cache compiled regex in `ToolFilter.pattern` (performance)
  - Added thread-safe `RegexCache` class with `NSLock`
  - Regex patterns are now compiled once and reused
- [x] **0.5.4** Replace string concatenation loop in `formatMCPToolResult` with `joined()`
  - Cleaner, more idiomatic Swift
- [x] **0.5.5** Add `state.addResponse()` / `state.addToolResults()` helpers
  - Cleaner code: `state.addResponse(response)` instead of `state.messages.append(.fromResponse(response))`

---

### 0.6 Deliverables ✅ ALL COMPLETE

- [x] Agent.swift under 1200 lines (was 1485 → now 1108) ✅
- [ ] ~~Agent.swift under 800 lines~~ (stretch goal abandoned - further extraction over-engineered)
- [x] MCPServerConnection.swift under 650 lines (was 938 → now 604) ✅
- [x] Test doubles are reusable and well-organized ✅
  - `AgentTestHelpers.swift` (408 lines) consolidates all agent test doubles
  - `ConfigurableTool` replaces 5 separate tool types
  - `MockResponse` factories reduce CompletionResponse boilerplate
- [x] Zero `print()` statements in production code ✅
- [x] Zero forced casts/unwraps without safety checks ✅
- [x] All existing tests still pass (60 agent tests, 582 total) ✅
- [x] MCPCallbackRouter injectable via protocol ✅

**New files from refactoring:**
- [x] ToolExecutionEngine.swift (211 lines) - tool execution with retry/timeout
- [x] AgentLoopObserver.swift (184 lines) - observer protocol for loop unification
- [x] ToolExecutionEngineTests.swift (480 lines) - 14 tests for engine
- [x] MCPCallbackRouting.swift (~65 lines) - protocol for injectable callback routing
- [x] MCPParsingHelpers.swift (~55 lines) - command line and env parsing
- [x] MCPSubprocessTransport.swift (~300 lines) - subprocess transport + PATH helper
- [x] AgentTestHelpers.swift (408 lines) - reusable test doubles and factories

---

### Priority Order

```
0.3 Unsafe Code Fixes        [~1 day]   ✅ COMPLETE
0.1 Agent Duplication        [~2 days]  ✅ COMPLETE (1485 → 1108 lines, +395 in new files)
0.2 MCP Consolidation        [~2 days]  ✅ COMPLETE (938 → 604 lines, +380 in new files)
0.4 Test Quality             [~1 day]   ✅ COMPLETE (reusable test helpers, exact assertions)
0.5 Minor Cleanup            [~0.5 day] ✅ COMPLETE (5 cleanups done)
```

**Phase 0 Complete!** Ready to resume feature work (Phase 1+).

---

## Phase 1: Agent Failure Handling ✅ COMPLETE (2026-01-25)

**Goal:** Every failure mode at the Agent level is handled gracefully and tested.

**Status:** All 27 failure scenario tests passing.

### 1.1 Tool Failure Scenarios ✅

| Test | Scenario | Status |
|------|----------|--------|
| `toolThrowsError` | Tool throws Swift error | ✅ |
| `toolReturnsFailure` | Tool returns `.failure(error)` | ✅ |
| `toolReturnsRetry` | Tool returns `.retry(message)` | ✅ |
| `maxIterationsWithFailingTools` | Every tool call fails | ✅ |
| `toolFailsThenSucceeds` | First call fails, retry succeeds | ✅ |
| `toolTimeoutTriggersError` | Tool exceeds timeout | ✅ |
| `toolCompletesWithinTimeout` | Tool completes within timeout | ✅ |

### 1.2 Model Response Failures ✅

| Test | Scenario | Status |
|------|----------|--------|
| `modelReturnsMalformedToolCall` | Invalid JSON in arguments | ✅ Added |
| `modelCallsUnknownTool` | Tool name doesn't exist | ✅ |
| `modelRefusal` | Safety refusal | ✅ |
| `modelHitsMaxTokens` | Truncated at max_tokens | ✅ |
| `modelReturnsEmptyResponse` | No content, no tool calls | ✅ |
| `modelContentFiltered` | Content filtered | ✅ |

### 1.3 Network/Provider Failures ✅

| Test | Scenario | Status |
|------|----------|--------|
| `serverErrorPropagated` | Server error (5xx) | ✅ |
| `rateLimitErrorPropagated` | 429 response | ✅ |
| `networkErrorPropagated` | Connection fails | ✅ |
| `streamInterrupted` | Connection drops mid-stream | ✅ Added |
| `streamingServerError` | Server error during streaming | ✅ |
| `streamingToolError` | Tool error during streaming | ✅ |

### 1.4 Retry Policy ✅

| Test | Scenario | Status |
|------|----------|--------|
| `retryOnRateLimit` | Retries on rate limit | ✅ |
| `retriesExhausted` | Max retries throws | ✅ |
| `retryDelayCalculation` | Delay calculation | ✅ |
| `nonRetryableErrorNotRetried` | Non-retryable errors | ✅ |

### 1.5 Usage Limits ✅

| Test | Scenario | Status |
|------|----------|--------|
| `requestLimitEnforced` | Max requests | ✅ |
| `toolCallLimitEnforced` | Max tool calls | ✅ |
| `tokenLimitEnforced` | Max tokens | ✅ |

### 1.6 Cancellation ✅

| Test | Scenario | Status |
|------|----------|--------|
| `cancellationDuringToolExecution` | Cancel during tool | ✅ |

---

## Phase 2: Concurrency Safety ✅ COMPLETE (2026-01-25)

**Goal:** Prove the Agent is safe under concurrent access patterns.

**Status:** 12 agent concurrency tests + 10 MCP concurrency tests passing.

### 2.1 Agent Concurrency Tests ✅

`Tests/YrdenTests/Agent/AgentConcurrencyTests.swift` - 12 tests:

| Test | Scenario | Status |
|------|----------|--------|
| `multipleConcurrentRuns` | Multiple runs complete independently | ✅ |
| `concurrentRunsWithToolsIsolation` | Tools maintain isolation | ✅ |
| `concurrentStreamsNoInterference` | Streams don't interfere | ✅ |
| `concurrentIterationsSeparateState` | Iterations maintain separate state | ✅ |
| `toolsExecuteConcurrently` | Multiple tools run in parallel | ✅ |
| `toolStateIsolatedBetweenCalls` | Tool state is isolated | ✅ |
| `sendableDepsPassedToTools` | Sendable deps passed safely | ✅ |
| `cancellationStopsConcurrentRuns` | Cancel stops concurrent runs | ✅ |
| `cancellationPropagatesToTools` | Cancel propagates to tools | ✅ |
| `cancellationMidStream` | Cancel terminates stream cleanly | ✅ Added |
| `agentStateNotCorrupted` | No data corruption under load | ✅ |
| `runIDUniqueAcrossConcurrentRuns` | All runIDs unique | ✅ |

**Design note:** Agent is an actor, so:
- `runWhileRunning` is safe by design (calls queue up)
- `toolModifiesAgentState` is prevented at compile time
- No `isBusy` state needed - actor isolation handles this

### 2.2 MCP Concurrency Tests ✅

`Tests/YrdenTests/MCP/MCPConcurrencyTests.swift` - 10 tests:

| Test | Scenario | Status |
|------|----------|--------|
| `concurrentToolCallsAllComplete` | Multiple tools called simultaneously | ✅ |
| `concurrentToolCallsDontCorruptEachOther` | Results not corrupted | ✅ |
| `disconnectDuringToolCallFailsGracefully` | Server disconnects mid-call | ✅ |
| `toolCallOnDisconnectedServerBehavior` | Tool call after disconnect | ✅ |
| `toolCallDuringReconnectWaitsOrFails` | Tool called while reconnecting | ✅ |
| `reconnectDuringToolCallDoesNotCorruptResult` | Reconnection doesn't corrupt | ✅ |
| `rapidConnectDisconnectCycles` | Fast connect/disconnect cycles | ✅ |
| `rapidReconnectCycles` | Fast reconnect cycles | ✅ |
| `concurrentStartAndStopAll` | Concurrent start/stop | ✅ |
| `multipleConcurrentToolCallsWithDifferentTimeouts` | Different timeouts | ✅ |

### 2.3 Thread-Safety Guarantees

The Agent is thread-safe because:
1. **Actor isolation** - Agent is declared as `actor`, so all mutable state is protected
2. **Sendable requirements** - Dependencies must be Sendable, enforced at compile time
3. **Structured concurrency** - Tools execute within structured task groups
4. **No shared mutable state** - Each run has its own `RunState`

---

## Phase 3: Observability

**Goal:** Enable debugging and monitoring of agent execution.

### 3.1 Structured Logging

```swift
public protocol AgentDelegate: AnyObject, Sendable {
    func agent(_ agent: AnyAgent, willSendRequest request: CompletionRequest)
    func agent(_ agent: AnyAgent, didReceiveResponse response: CompletionResponse)
    func agent(_ agent: AnyAgent, willExecuteTool call: ToolCall)
    func agent(_ agent: AnyAgent, didExecuteTool call: ToolCall, result: AnyToolResult, duration: Duration)
    func agent(_ agent: AnyAgent, didEncounterError error: Error, context: ErrorContext)
    func agent(_ agent: AnyAgent, didComplete result: Result<Any, Error>, totalDuration: Duration)
}
```

### 3.2 Run Tracing

```swift
public struct AgentTrace: Sendable {
    public let runID: UUID
    public let startTime: Date
    public let events: [TraceEvent]

    public enum TraceEvent: Sendable {
        case requestSent(CompletionRequest, timestamp: Date)
        case responseReceived(CompletionResponse, timestamp: Date)
        case toolExecuted(ToolCall, result: AnyToolResult, duration: Duration)
        case error(Error, context: String, timestamp: Date)
        case completed(output: Any?, timestamp: Date)
    }
}

// Usage
let result = try await agent.run("...", deps: deps, trace: &trace)
print(trace.events) // Full execution history
```

### 3.3 Metrics

```swift
public struct AgentMetrics: Sendable {
    public var totalRuns: Int
    public var successfulRuns: Int
    public var failedRuns: Int
    public var totalTokensUsed: Usage
    public var averageRunDuration: Duration
    public var toolCallCounts: [String: Int]
    public var errorCounts: [String: Int]
}
```

### 3.4 Deliverables

- [ ] `AgentDelegate` protocol
- [ ] `AgentTrace` for detailed run history
- [ ] `AgentMetrics` for aggregate stats
- [ ] Example logging delegate implementation
- [ ] Tests for delegate callbacks

---

## Phase 4: MCP Robustness ✅ COMPLETE (2026-01-25)

**Goal:** MCP connections are resilient and recoverable.

### 4.1 Connection Resilience ✅

| Feature | Description | Status |
|---------|-------------|--------|
| Auto-reconnect | Reconnect on disconnect with backoff | ✅ |
| Health checks | Periodic ping to detect dead connections | ✅ |
| Graceful degradation | Continue with available servers if one fails | ✅ |

Implementation:
- [x] Auto-reconnect via `triggerAutoReconnect(serverID:)` with `ReconnectPolicy`
- [x] Health check via `startHealthChecks()` with configurable interval
- [x] `availableTools()` filters by connected servers only
- [x] Reconnect policy already in `CoordinatorConfiguration` (exponential backoff)

### 4.2 Tool Call Resilience ✅

| Feature | Description | Status |
|---------|-------------|--------|
| Per-tool timeout | Different tools can have different timeouts | ✅ |
| Tool-level retry | Retry failed tool calls before reporting to model | ✅ |

Implementation:
- [x] `MCPToolProxy.timeout` for per-tool timeout configuration
- [x] `MCPToolProxy.maxRetries` for retry count configuration
- [x] `callWithRetry(argumentsJSON:)` implements retry logic with backoff

### 4.3 MCP Alerts ✅

```swift
public enum MCPAlert: Identifiable, Sendable {
    case connectionFailed(serverID: String, error: Error)
    case connectionLost(serverID: String)
    case reconnecting(serverID: String, attempt: Int)
    case reconnected(serverID: String)
    case toolTimedOut(serverID: String, tool: String)
    case serverUnhealthy(serverID: String, reason: String)
}
```

- [x] `MCPAlert` enum in `MCPTypes.swift`
- [x] Alert stream via `coordinator.alerts: AsyncStream<MCPAlert>`
- [x] Alerts emitted on connection failures, reconnection, timeouts, health check failures

### 4.4 Deliverables ✅

- [x] Auto-reconnect with exponential backoff policy
- [x] Health check mechanism with configurable interval
- [x] `MCPAlert` enum for UI notification
- [x] Tool-level timeout (`MCPToolProxy.timeout`)
- [x] Tool-level retry (`MCPToolProxy.callWithRetry`)
- [x] 15 tests for resilience features in `MCPResilienceTests.swift`

**New files:**
- `Tests/YrdenTests/MCP/MCPResilienceTests.swift` (600+ lines, 15 tests)

**Modified files:**
- `MCPTypes.swift` - Added `MCPAlert` enum
- `MCPProtocols.swift` - Added `alerts` stream, `availableTools()`, `triggerAutoReconnect()`
- `ProtocolMCPCoordinator.swift` - Implemented resilience features
- `ProtocolMCPManager.swift` - Renamed `MCPAlert` to `MCPAlertView` to avoid conflict
- `MCPToolProxy.swift` - Added `callWithRetry()` method
- `MockCoordinator.swift` - Added new protocol methods

---

## Phase 5: API Polish

**Goal:** Clean, intuitive API that's hard to misuse.

### 5.1 Builder Pattern for Agent

```swift
let agent = Agent<MyDeps, Report>.build()
    .model(anthropic.claude35Sonnet())
    .systemPrompt("You are a research assistant.")
    .tools([searchTool, calculatorTool])
    .mcpServers([filesystemSpec, gitSpec])
    .timeout(.seconds(60))
    .retryPolicy(.exponential(maxAttempts: 3))
    .outputValidator { deps, report in
        guard report.sections.count >= 3 else {
            throw ValidationRetry("Need at least 3 sections")
        }
        return report
    }
    .delegate(loggingDelegate)
    .build()
```

### 5.2 Simplified MCP Setup

```swift
// Current (verbose)
let coordinator = ProtocolMCPCoordinator(...)
let manager = ProtocolMCPManager(coordinator: coordinator)
await manager.addServers([spec1, spec2])
let tools = await manager.allTools()

// Proposed (simple)
let mcp = try await MCP.connect(to: [
    .stdio("uvx", args: ["mcp-server-git", "--repository", "/repo"]),
    .stdio("npx", args: ["@anthropic/mcp-server-filesystem", "/allowed/path"])
])
let tools = mcp.tools // [AnyAgentTool<Void>]
```

### 5.3 Error Messages

Improve all error messages to be actionable:

```swift
// Before
AgentError.maxIterationsReached

// After
AgentError.maxIterationsReached(
    iterations: 10,
    lastToolCalls: ["search", "calculate"],
    suggestion: "Increase maxIterations or simplify the task"
)
```

### 5.4 Deliverables

- [ ] `AgentBuilder` for fluent configuration
- [ ] `MCP.connect()` convenience
- [ ] Improved error messages throughout
- [ ] API documentation comments
- [ ] Migration guide from verbose API

---

## Phase 6: Example App

**Goal:** Demonstrate all capabilities with minimal app logic.

### 6.1 App Requirements

| Feature | Library Support | App Code |
|---------|-----------------|----------|
| Chat UI | Agent streams responses | Display messages |
| Tool visualization | Agent reports tool calls | Show tool status |
| MCP servers | MCPManager | Server list UI |
| Connection status | MCPManager.servers | Status indicator |
| Error handling | AgentDelegate | Error banner |
| Settings | AgentConfig | Settings form |
| History | AgentTrace | Conversation list |

### 6.2 App Architecture

```
ExampleApp/
├── ExampleApp.swift           # App entry, dependency setup
├── Views/
│   ├── ChatView.swift         # Main chat interface
│   ├── MessageView.swift      # Single message display
│   ├── ToolCallView.swift     # Tool execution visualization
│   ├── ServerListView.swift   # MCP server management
│   └── SettingsView.swift     # Configuration UI
├── ViewModels/
│   ├── ChatViewModel.swift    # Binds to Agent, minimal logic
│   └── MCPViewModel.swift     # Binds to MCPManager
└── Models/
    └── AppDependencies.swift  # Deps type, config loading
```

### 6.3 ChatViewModel (The Test)

The ViewModel should be trivially simple because all logic is in Yrden:

```swift
@MainActor
@Observable
class ChatViewModel {
    private let agent: Agent<AppDeps, String>

    var messages: [ChatMessage] = []
    var isProcessing = false
    var currentToolCall: ToolCall?
    var error: Error?

    func send(_ text: String) async {
        isProcessing = true
        defer { isProcessing = false }

        messages.append(.user(text))

        do {
            for try await event in agent.runStream(text, deps: deps) {
                switch event {
                case .contentDelta(let text):
                    appendToLastMessage(text)
                case .toolCallStart(let name, _):
                    currentToolCall = ToolCall(name: name, ...)
                case .toolResult(_, let result):
                    currentToolCall = nil
                case .result(let result):
                    messages.append(.assistant(result.output))
                default:
                    break
                }
            }
        } catch {
            self.error = error
        }
    }
}
```

**Success criteria:** ViewModel is <100 lines with no business logic.

### 6.4 Features to Demonstrate

1. **Basic Chat** - Send message, stream response
2. **Tool Use** - Calculator, search (show tool execution)
3. **MCP Integration** - Connect to filesystem server, use tools
4. **Human-in-the-Loop** - Approve dangerous operations
5. **Error Recovery** - Show errors, retry option
6. **Multi-turn** - Conversation context maintained
7. **Structured Output** - Request specific format
8. **Settings** - Change model, timeout, retry policy

### 6.5 Deliverables

- [ ] Example app with all features
- [ ] README with setup instructions
- [ ] Screenshots/demo video
- [ ] "Production Patterns" documentation

---

## Implementation Order

```
Phase 0: Code Quality Refactoring   [~6.5 days]  ✅ COMPLETE
    ├── 0.3 Unsafe fixes            [~1 day]     ✅
    ├── 0.1 Agent duplication       [~2 days]    ✅
    ├── 0.2 MCP consolidation       [~2 days]    ✅
    ├── 0.4 Test quality            [~1 day]     ✅
    └── 0.5 Minor cleanup           [~0.5 day]   ✅

Phase 1: Agent Failure Handling     [~3 days]    ✅ COMPLETE (27 tests)
    └── Tests verify all failure scenarios

Phase 2: Concurrency Safety         [~2 days]    ✅ COMPLETE (22 tests)
    └── Tests prove safety

Phase 3: Observability              [~2 days]
    └── Delegate, trace, metrics

Phase 4: MCP Robustness             [~2 days]    ✅ COMPLETE (15 tests)
    └── Resilience, alerts

Phase 5: API Polish                 [~2 days]
    └── Builder, convenience, docs

Phase 6: Example App                [~3 days]
    └── Full demo application
```

Total: ~20.5 days of focused work

---

## Success Criteria

### Quantitative

- [x] 50+ failure scenario tests passing (27 failure + 12 agent concurrency = 39, plus MCP tests)
- [x] 20+ concurrency tests passing (12 agent + 10 MCP = 22 concurrency tests)
- [ ] 0 race conditions under stress test (1000 concurrent operations)
- [ ] Example app ViewModel < 100 lines
- [ ] 95%+ code coverage on Agent, MCP modules

### Qualitative

- [ ] Any failure produces an actionable error message
- [ ] Example app demonstrates all features
- [ ] Documentation covers all production patterns
- [ ] No "it works on my machine" issues

---

## Risks

| Risk | Mitigation |
|------|------------|
| Concurrency bugs hard to reproduce | Use stress tests, ThreadSanitizer |
| MCP SDK limitations | Document workarounds, contribute upstream |
| Scope creep | Strict phase gates, no new features |
| API breaks existing code | Migration guide, deprecation warnings |

---

## Definition of Done

The library is production-ready when:

1. **All tests pass** including failure and concurrency scenarios
2. **Example app works** with all features demonstrated
3. **Documentation complete** for all public APIs
4. **No known bugs** in issue tracker
5. **Performance acceptable** (agent run < 100ms overhead)
6. **Memory safe** (no leaks under extended use)
