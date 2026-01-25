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

### 0.2 MCP: Consolidate Abstractions

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

- [ ] **0.2.1** Choose ONE hierarchy (recommend Protocol* versions) and deprecate other
- [ ] **0.2.2** Merge `MCPTool` and `MCPToolProxy` - share JSON parsing/conversion code
- [ ] **0.2.3** Split `MCPServerConnection` (935 lines) into:
  - `MCPConnectionLifecycle` - connect/disconnect/state
  - `MCPToolDiscovery` - tool listing and caching
  - `MCPTransportFactory` - stdio/HTTP/OAuth transport creation
- [ ] **0.2.4** Extract PATH augmentation (lines 707-723) to `SubprocessEnvironment` helper
- [ ] **0.2.5** Remove global singleton `MCPCallbackRouter.shared` - make injectable

**Success criteria:** One clear API path. No file over 400 lines. Tool abstraction is singular.

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

### 0.4 Test Quality Improvements

**Problem:** Tests verify mocks, not behavior. Complex test doubles hide bugs.

**Issues found:**
- Integration tests use loose assertions (`contains("hello")` vs exact match)
- Mock complexity rivals production code (300+ line `MockServerConnection`)
- Tests verify mock was called, not that behavior is correct
- Snapshot tests just verify you get back what you set

**Refactoring tasks:**

- [ ] **0.4.1** Replace loose assertions with exact expectations where possible
- [ ] **0.4.2** Simplify test doubles - each should be <50 lines
- [ ] **0.4.3** Split `TestMockModel` into single-purpose `SuccessModel`, `ErrorModel`, etc.
- [ ] **0.4.4** Add contract tests with recorded API fixtures (no real API calls)
- [ ] **0.4.5** Remove tests that only verify mock configuration returns mock configuration

**Success criteria:** Test doubles are simpler than production code. Assertions are specific.

---

### 0.5 Minor Cleanup

- [ ] **0.5.1** Extract `RunState.resume(from: PausedAgentRun)` factory
- [ ] **0.5.2** Consolidate error message strings to avoid drift between 4 locations
- [ ] **0.5.3** Cache compiled regex in `ToolFilter.pattern` (performance)
- [ ] **0.5.4** Replace string concatenation loop in `formatMCPToolResult` with `joined()`
- [ ] **0.5.5** Add `state.addResponse()` / `state.addToolResults()` helpers

---

### 0.6 Deliverables

- [x] Agent.swift under 1200 lines (was 1485 → now 1108) ✅
- [ ] ~~Agent.swift under 800 lines~~ (stretch goal abandoned - further extraction over-engineered)
- [ ] MCPServerConnection.swift under 400 lines (currently 935)
- [ ] No test double over 50 lines
- [x] Zero `print()` statements in production code ✅
- [x] Zero forced casts/unwraps without safety checks ✅
- [x] All existing tests still pass ✅

**New files from refactoring:**
- [x] ToolExecutionEngine.swift (211 lines) - tool execution with retry/timeout
- [x] AgentLoopObserver.swift (184 lines) - observer protocol for loop unification
- [x] ToolExecutionEngineTests.swift (480 lines) - 14 tests for engine

---

### Priority Order

```
0.3 Unsafe Code Fixes        [~1 day]   ✅ COMPLETE
0.1 Agent Duplication        [~2 days]  ✅ COMPLETE (1485 → 1108 lines, +395 in new files)
0.2 MCP Consolidation        [~2 days]  ← NEXT
0.4 Test Quality             [~1 day]
0.5 Minor Cleanup            [~0.5 day]
```

Remaining: ~3.5 days before resuming feature work

---

## Phase 1: Agent Failure Handling

**Goal:** Every failure mode at the Agent level is handled gracefully and tested.

### 1.1 Tool Failure Scenarios

Create `Tests/YrdenTests/Agent/AgentFailureTests.swift`:

| Test | Scenario | Expected Behavior |
|------|----------|-------------------|
| `toolThrowsError` | Tool throws Swift error | Error sent to model as tool result |
| `toolReturnsFailure` | Tool returns `.failure(error)` | Error sent to model as tool result |
| `toolReturnsRetry` | Tool returns `.retry(message)` | Retry message sent to model |
| `allToolsFail` | Every tool call fails | Agent completes with error after max iterations |
| `toolFailsThenSucceeds` | First call fails, retry succeeds | Agent continues normally |
| `toolTimeout` | Tool exceeds timeout | Timeout error sent to model |

Implementation needed:
- [ ] Add `timeout: Duration?` to `AgentTool` protocol
- [ ] Implement timeout wrapper in Agent tool execution
- [ ] Add `AgentError.toolTimeout(name:timeout:)` case

### 1.2 Model Response Failures

| Test | Scenario | Expected Behavior |
|------|----------|-------------------|
| `modelReturnsMalformedToolCall` | Invalid JSON in arguments | Parse error sent back, model retries |
| `modelCallsUnknownTool` | Tool name doesn't exist | Error sent back, model retries |
| `modelRefusesStructuredOutput` | Safety refusal | `AgentError.modelRefused` thrown |
| `modelReturnsPartialOutput` | Truncated at max_tokens | `AgentError.incompleteOutput` with partial data |
| `modelReturnsEmptyResponse` | No content, no tool calls | Retry or error based on config |

Implementation needed:
- [ ] Improve argument parsing error messages
- [ ] Add `AgentConfig.onEmptyResponse: .retry | .error`
- [ ] Surface partial output in error for recovery

### 1.3 Network/Provider Failures

| Test | Scenario | Expected Behavior |
|------|----------|-------------------|
| `networkErrorDuringCompletion` | Connection fails | Retry with backoff or surface error |
| `rateLimitHit` | 429 response | Automatic backoff and retry |
| `streamInterrupted` | Connection drops mid-stream | Retry from last known state or error |
| `providerTimeout` | No response within timeout | Retry or surface timeout error |

Implementation needed:
- [ ] Add `AgentConfig.retryPolicy: RetryPolicy`
- [ ] Implement exponential backoff in agent loop
- [ ] Add circuit breaker for repeated failures
- [ ] Track retry count in `AgentContext`

### 1.4 Deliverables

- [ ] `AgentFailureTests.swift` - 15+ failure scenario tests
- [ ] `RetryPolicy` type with exponential backoff
- [ ] `AgentConfig` extended with retry/timeout settings
- [ ] All existing tests still pass

---

## Phase 2: Concurrency Safety

**Goal:** Prove the Agent is safe under concurrent access patterns.

### 2.1 Race Condition Tests

Create `Tests/YrdenTests/Agent/AgentConcurrencyTests.swift`:

| Test | Scenario | Expected Behavior |
|------|----------|-------------------|
| `concurrentToolExecution` | Multiple tools run in parallel | All complete, results collected correctly |
| `cancellationMidToolExecution` | Task cancelled while tool running | Tool cancelled, agent throws CancellationError |
| `cancellationMidStream` | Task cancelled during streaming | Stream terminates cleanly |
| `multipleIterConsumers` | Two tasks iterate same agent | Error or serialized access |
| `runWhileRunning` | Call run() while already running | Error (agent busy) |
| `toolModifiesAgentState` | Tool tries to call agent methods | Compile-time or runtime protection |

Implementation needed:
- [ ] Add `isBusy` state to Agent
- [ ] Document thread-safety guarantees
- [ ] Ensure tool execution is isolated

### 2.2 MCP Race Conditions

Create `Tests/YrdenTests/MCP/MCPConcurrencyTests.swift`:

| Test | Scenario | Expected Behavior |
|------|----------|-------------------|
| `concurrentToolCalls` | Multiple tools called simultaneously | All routed correctly |
| `disconnectDuringToolCall` | Server disconnects mid-call | Tool returns failure, agent handles |
| `reconnectDuringToolCall` | Reconnection starts mid-call | In-flight call fails, next succeeds |
| `toolCallDuringReconnect` | Tool called while reconnecting | Waits or fails fast |
| `rapidConnectDisconnect` | Fast connect/disconnect cycles | State machine handles correctly |

Implementation needed:
- [ ] Review coordinator state machine for gaps
- [ ] Add connection state check before tool call
- [ ] Test event ordering under load

### 2.3 Deliverables

- [ ] `AgentConcurrencyTests.swift` - 10+ concurrency tests
- [ ] `MCPConcurrencyTests.swift` - 10+ MCP concurrency tests
- [ ] Documentation of thread-safety guarantees
- [ ] No race conditions under stress testing

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

## Phase 4: MCP Robustness

**Goal:** MCP connections are resilient and recoverable.

### 4.1 Connection Resilience

| Feature | Description |
|---------|-------------|
| Auto-reconnect | Reconnect on disconnect with backoff |
| Health checks | Periodic ping to detect dead connections |
| Connection pooling | Reuse connections across tool calls |
| Graceful degradation | Continue with available servers if one fails |

Implementation:
- [ ] Add `reconnectPolicy` to `ServerSpec`
- [ ] Implement health check ping
- [ ] Add `MCPManager.availableTools()` that filters by connected servers

### 4.2 Tool Call Resilience

| Feature | Description |
|---------|-------------|
| Per-tool timeout | Different tools can have different timeouts |
| Tool-level retry | Retry failed tool calls before reporting to model |
| Fallback tools | Define fallback if primary tool unavailable |

Implementation:
- [ ] Add `ToolProxy.timeout` and `ToolProxy.retries`
- [ ] Implement tool-level retry in proxy
- [ ] Add `ToolFallback` type for fallback chains

### 4.3 MCP Alerts

```swift
public enum MCPAlert: Identifiable, Sendable {
    case connectionFailed(serverID: String, error: Error)
    case connectionLost(serverID: String)
    case reconnecting(serverID: String, attempt: Int)
    case reconnected(serverID: String)
    case toolTimedOut(serverID: String, tool: String)
    case serverUnhealthy(serverID: String, reason: String)
}

// In MCPManager
@Published public var alerts: [MCPAlert] = []
public func dismissAlert(_ alert: MCPAlert)
```

### 4.4 Deliverables

- [ ] Auto-reconnect with configurable policy
- [ ] Health check mechanism
- [ ] `MCPAlert` for UI notification
- [ ] Tool-level timeout and retry
- [ ] Tests for all resilience features

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
Phase 0: Code Quality Refactoring   [~6.5 days]  ← BLOCKING
    ├── 0.3 Unsafe fixes            [~1 day]
    ├── 0.1 Agent duplication       [~2 days]
    ├── 0.2 MCP consolidation       [~2 days]
    ├── 0.4 Test quality            [~1 day]
    └── 0.5 Minor cleanup           [~0.5 day]

Phase 1: Agent Failure Handling     [~3 days]
    └── Tests first, then implementation

Phase 2: Concurrency Safety         [~2 days]
    └── Tests prove safety

Phase 3: Observability              [~2 days]
    └── Delegate, trace, metrics

Phase 4: MCP Robustness             [~2 days]
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

- [ ] 50+ failure scenario tests passing
- [ ] 20+ concurrency tests passing
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
