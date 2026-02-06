# Design: Agent Execution API

> High-level agent execution API built on the `iter()` primitive, providing convenient `run()` and `runStream()` methods with automatic limit checking, validation retry, and unified continuation.

## Table of Contents

1. [Problem Statement](#problem-statement)
2. [Design Goals](#design-goals)
3. [Architecture: Layered on iter()](#architecture-layered-on-iter)
4. [Part 1: AgentRun Type](#part-1-agentrun-type)
5. [Part 2: Unified Resume API](#part-2-unified-resume-api)
6. [Part 3: Validation Retry](#part-3-validation-retry)
7. [Part 4: Cross-Agent Resume](#part-4-cross-agent-resume)
8. [Part 5: How run() Uses iter()](#part-5-how-run-uses-iter)
9. [Streaming API](#streaming-api)
10. [Error Recovery with Checkpoints](#error-recovery-with-checkpoints)
11. [Type Summary](#type-summary)
12. [Migration Guide](#migration-guide)
13. [Tradeoffs](#tradeoffs)
14. [Implementation Plan](#implementation-plan)
15. [Appendix: Research](#appendix-research)

---

## Problem Statement

The current Yrden agent execution API has several issues affecting usability and correctness.

### Issue 1: Exception-Driven Control Flow for Expected Outcomes

```swift
// Current API: Expected outcomes throw exceptions
do {
    let result = try await agent.run("...", deps: ())
} catch let error as AgentError {
    if case .hasDeferredTools(let paused) = error { ... }      // Expected: tools need approval
    if case .maxIterationsExceeded(let paused) = error { ... } // Expected: hit iteration limit
    if case .usageLimitExceeded(let kind) = error { ... }      // Expected: hit usage limit
}
```

**Why this is wrong:**

Approvals, iteration limits, and usage limits are **expected operational outcomes**, not errors. Using exceptions conflates "something went wrong" with "user action needed."

### Issue 2: State Loss on Pause Conditions

When `usageLimitExceeded` fires, the exception carries only `UsageLimit`:

```swift
case .usageLimitExceeded(let kind):
    // We know we hit a limit, but:
    // - What messages were accumulated?
    // - How many tokens were actually used?
    // ALL LOST.
```

### Issue 3: Redundant Continuation Methods

```swift
// Two methods that do conceptually similar things:
func resume(paused: PausedAgentRun, resolutions: [ResolvedTool], deps: Deps)
func continueRun(paused: PausedAgentRun, additionalIterations: Int, deps: Deps)
```

---

## Design Goals

1. **Expected outcomes are return values.** Approvals, limits — modeled as enum cases, not exceptions.

2. **No state loss.** Messages, usage, counts always available regardless of how the run ended.

3. **Built on iter().** Leverage the low-level `iter()` primitive (see [IteratorAPI.md](IteratorAPI.md)) for all execution.

4. **Minimal type translation.** Reuse types from IteratorAPI directly — no redundant parallel types.

5. **Unified continuation.** One `resume()` method with options.

6. **Simple case stays simple.** `agent.run(...).output` or `.result()` for common cases.

---

## Architecture: Layered on iter()

`run()` and `runStream()` are convenience APIs built on the `iter()` primitive:

```
┌─────────────────────────────────────────────────────────────────┐
│  High-Level API: run() / runStream()                            │
│                                                                 │
│  Adds:                                                          │
│  - Usage limit checking (before model calls)                    │
│  - Iteration limit checking (after tool results)                │
│  - Validation retry with configurable limit                     │
│  - Auto-pause for requiresApproval tools                        │
│  - Cross-agent resume validation                                │
│  - Returns AgentRun with semantic Status                        │
└───────────────────────────────┬─────────────────────────────────┘
                                │ uses
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  Low-Level API: iter()  (see IteratorAPI.md)                    │
│                                                                 │
│  Provides:                                                      │
│  - Phase-by-phase control (beforeModel, afterModel, etc.)       │
│  - Serializable IterationState checkpoints                      │
│  - Tool approval via PendingToolDecision                        │
│  - Optional streaming at each phase                             │
│  - No automatic limit checking                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Key principle:** `iter()` is the source of truth. `run()` adds policy on top.

### What iter() Provides (from IteratorAPI.md)

| Type | Purpose |
|------|---------|
| `IterationState<Output>` | Serializable checkpoint with phase, messages, usage |
| `PendingToolDecision` | Tool call + `requiresApproval` flag + `decision` |
| `PendingToolDecision.Decision` | `.pending`, `.approved`, `.denied(String)`, `.replaced(String)` |
| `BeforeModelContext` | Mutable context for beforeModel phase |
| `AfterToolsContext` | Mutable context for afterTools phase |
| `FinishedContext` | Final state with output |

### What run() Adds

| Feature | Implementation |
|---------|----------------|
| Usage limits | Check `ctx.state.usage` at `beforeModel`, return early if exceeded |
| Iteration limits | Check `ctx.state.iteration` at `afterTools`, return early if exceeded |
| Auto-pause for approval | Check `requiresApproval` at `beforeTools`, exit loop if any need approval |
| Validation retry | Retry on `ValidationRetry` up to `maxValidationRetries` (default: 3) |
| Cross-agent validation | Verify pending tool calls have available tools on resume |
| Semantic status | Wrap iter()'s `IterationState` with WHY the run stopped |

---

## Part 1: AgentRun Type

### Design: Embed IterationState

`AgentRun` embeds `IterationState` from IteratorAPI directly, avoiding field duplication:

```swift
/// The result of running an agent — a complete, serializable checkpoint.
///
/// `AgentRun` wraps `IterationState` (from iter()) and adds semantic status
/// explaining WHY the run stopped, not just WHERE it stopped.
///
/// This is Codable for cross-session persistence.
public struct AgentRun<Output: SchemaType>: Sendable, Codable {

    // MARK: - Core State (from iter())

    /// Complete checkpoint state from iter().
    /// Contains: runID, messages, usage, iteration, toolCallCount, phase.
    public let state: IterationState<Output>

    // MARK: - Status

    /// Why this run stopped, with associated continuation data.
    public let status: Status

    /// How an agent run ended.
    public enum Status: Sendable, Codable {
        /// Run completed successfully with output.
        case completed(Output)

        /// Run paused — tools need human approval before continuing.
        /// Contains ALL pending tool decisions (including those not needing approval).
        /// Filter by `requiresApproval` to show only those needing user action.
        case needsApproval([PendingToolDecision])

        /// Run paused — iteration limit was reached.
        /// State contains the last completed iteration; ready to continue.
        case iterationLimitReached(limit: Int)

        /// Run stopped — a usage limit was reached.
        /// State preserved for inspection; cannot resume (would hit limit again).
        case usageLimitReached(UsageLimit)
    }

    // MARK: - Convenience Accessors

    /// Unique identifier for this run (stable across resume calls).
    public var runID: String { state.runID }

    /// All messages accumulated during the run.
    public var messages: [Message] { state.messages }

    /// Total token usage for the run.
    public var usage: Usage { state.usage }

    /// Current iteration number (0-indexed).
    public var iteration: Int { state.iteration }

    /// Number of tool calls executed.
    public var toolCallCount: Int { state.toolCallCount }

    /// The output if status is `.completed`, nil otherwise.
    public var output: Output? {
        if case .completed(let output) = status { return output }
        return nil
    }

    /// Whether the run completed successfully.
    public var isCompleted: Bool {
        if case .completed = status { return true }
        return false
    }

    /// Whether the run can be resumed.
    public var canResume: Bool {
        switch status {
        case .completed, .usageLimitReached:
            return false
        case .needsApproval, .iterationLimitReached:
            return true
        }
    }

    /// Pending tool decisions if status is `.needsApproval`, empty otherwise.
    public var pendingApprovals: [PendingToolDecision] {
        if case .needsApproval(let pending) = status { return pending }
        return []
    }

    /// Tools that specifically require user approval.
    public var toolsRequiringApproval: [PendingToolDecision] {
        pendingApprovals.filter { $0.requiresApproval }
    }
}
```

### Why Embed IterationState?

| Approach | Pros | Cons |
|----------|------|------|
| **Embed** (chosen) | Zero translation on pause/resume, trivial serialization | AgentRun.status may seem redundant with state.phase |
| **Duplicate fields** | Cleaner public API | Translation on every pause/resume, divergence risk |

The apparent redundancy is actually valuable:
- `state.phase` tells you WHERE in the loop: `.beforeTools(calls:)`
- `status` tells you WHY you stopped: `.needsApproval` vs `.usageLimitReached`

You could be at the same phase but stopped for different reasons.

### Convenience API

```swift
extension AgentRun {
    /// Get the output, throwing if not completed.
    ///
    /// Use this when you want the simple "throw on pause" behavior:
    /// ```swift
    /// let output = try agent.run("task", deps: ()).result()
    /// ```
    public func result() throws -> Output {
        switch status {
        case .completed(let output):
            return output
        case .needsApproval:
            throw AgentError.needsApproval(self)
        case .iterationLimitReached:
            throw AgentError.iterationLimitReached(self)
        case .usageLimitReached:
            throw AgentError.usageLimitReached(self)
        }
    }
}
```

**Note:** Error cases now carry `AgentRun` instead of partial state, so no information is lost.

### Usage Patterns

**Simple case:**
```swift
// Throws if not completed
let output = try await agent.run("Hello", deps: ()).result()
```

**Handle all outcomes:**
```swift
let run = try await agent.run("Delete files", deps: myDeps)

switch run.status {
case .completed(let output):
    print("Done: \(output)")

case .needsApproval(let pending):
    // Show tools needing approval to user
    for p in pending where p.requiresApproval {
        print("Tool \(p.call.name) needs approval")
    }
    // Later: resume with decisions

case .iterationLimitReached(let limit):
    print("Hit iteration limit at \(limit)")
    print("Tokens used: \(run.usage.totalTokens)")  // State preserved!
    // Later: resume with additional iterations

case .usageLimitReached(let kind):
    print("Hit usage limit: \(kind)")
    print("Messages so far: \(run.messages.count)")  // State preserved!
}
```

---

## Part 2: Unified Resume API

### Design: Reuse Decision Type from IteratorAPI

Resume options use `PendingToolDecision.Decision` directly — no parallel `Resolution` type:

```swift
/// Options for continuing a paused run.
public struct ResumeOptions: Sendable {
    /// Updated decisions for pending tools (for `.needsApproval` status).
    /// Key is the tool call ID, value is the new decision.
    public var decisions: [String: PendingToolDecision.Decision]?

    /// Additional iterations to allow (for `.iterationLimitReached` status).
    public var additionalIterations: Int?

    // MARK: - Initializers

    public init(
        decisions: [String: PendingToolDecision.Decision]? = nil,
        additionalIterations: Int? = nil
    ) {
        self.decisions = decisions
        self.additionalIterations = additionalIterations
    }

    // MARK: - Factory Methods

    /// Approve specific tool calls by ID.
    public static func approve(_ callIds: [String]) -> ResumeOptions {
        ResumeOptions(decisions: Dictionary(uniqueKeysWithValues: callIds.map { ($0, .approved) }))
    }

    /// Approve all pending tool calls.
    public static func approveAll(from run: AgentRun<some SchemaType>) -> ResumeOptions {
        let ids = run.pendingApprovals.map { $0.call.id }
        return approve(ids)
    }

    /// Deny specific tool calls with a message.
    public static func deny(_ callIds: [String], message: String) -> ResumeOptions {
        ResumeOptions(decisions: Dictionary(uniqueKeysWithValues: callIds.map { ($0, .denied(message)) }))
    }

    /// Replace tool calls with synthetic results.
    public static func replace(_ replacements: [String: String]) -> ResumeOptions {
        ResumeOptions(decisions: replacements.mapValues { .replaced($0) })
    }

    /// Provide explicit decisions for each tool call.
    public static func decisions(_ decisions: [String: PendingToolDecision.Decision]) -> ResumeOptions {
        ResumeOptions(decisions: decisions)
    }

    /// Allow additional iterations.
    public static func additionalIterations(_ count: Int) -> ResumeOptions {
        ResumeOptions(additionalIterations: count)
    }
}
```

### Resume Method

```swift
extension Agent {
    /// Continue a paused run with appropriate options.
    ///
    /// The required options depend on `run.status`:
    /// - `.needsApproval`: provide decisions via `.approve()`, `.deny()`, or `.decisions()`
    /// - `.iterationLimitReached`: provide `.additionalIterations(N)`
    ///
    /// Throws `AgentError.invalidResume` if options don't match status.
    public func resume(
        from run: AgentRun<Output>,
        with options: ResumeOptions,
        deps: Deps
    ) async throws -> AgentRun<Output>
}
```

### Implementation

```swift
public func resume(
    from run: AgentRun<Output>,
    with options: ResumeOptions,
    deps: Deps
) async throws -> AgentRun<Output> {
    switch run.status {
    case .needsApproval:
        guard let decisions = options.decisions else {
            throw AgentError.invalidResume(
                "Status is .needsApproval but no decisions provided."
            )
        }

        // Get pending calls from state.phase
        guard case .beforeTools(var calls) = run.state.phase else {
            throw AgentError.invalidResume("State phase mismatch: expected .beforeTools")
        }

        // Apply user's decisions
        for (id, decision) in decisions {
            if let index = calls.firstIndex(where: { $0.call.id == id }) {
                calls[index].decision = decision
            }
        }

        // Create updated state and continue iteration
        let updatedState = run.state.with(phase: .beforeTools(calls: calls))
        return try await continueIteration(from: updatedState, deps: deps)

    case .iterationLimitReached:
        guard let additional = options.additionalIterations else {
            throw AgentError.invalidResume(
                "Status is .iterationLimitReached but no additionalIterations provided."
            )
        }

        // Continue with increased limit
        return try await continueIteration(
            from: run.state,
            deps: deps,
            maxIterations: maxIterations + additional
        )

    case .completed:
        throw AgentError.invalidResume("Cannot resume a completed run.")

    case .usageLimitReached:
        throw AgentError.invalidResume(
            "Cannot resume after usage limit. Start a new run with continuingFrom: instead."
        )
    }
}
```

### Usage

```swift
let run = try await agent.run("Delete files", deps: myDeps)

switch run.status {
case .needsApproval(let pending):
    // Approve all
    let continued = try await agent.resume(
        from: run,
        with: .approveAll(from: run),
        deps: myDeps
    )

    // Or approve specific ones
    let continued = try await agent.resume(
        from: run,
        with: .approve(["call-1", "call-2"]),
        deps: myDeps
    )

    // Or mixed decisions
    let continued = try await agent.resume(
        from: run,
        with: .decisions([
            "call-1": .approved,
            "call-2": .denied("Not permitted"),
            "call-3": .replaced("Cached result here")
        ]),
        deps: myDeps
    )

case .iterationLimitReached:
    let continued = try await agent.resume(
        from: run,
        with: .additionalIterations(10),
        deps: myDeps
    )

default:
    break
}
```

---

## Part 3: Validation Retry

### Design: Validation Does NOT Consume Iterations

When output validation fails, the agent retries without consuming an iteration. This keeps the mental model simple: **iterations = tool execution rounds**.

```
Iteration 1: beforeModel → afterModel → validate → FAIL → retry message → beforeModel → afterModel → validate → PASS → finished
```

The retry loop happens *within* a single iteration.

### Configuration

```swift
public actor Agent<Deps: Sendable, Output: SchemaType> {
    /// Maximum validation retry attempts before giving up.
    /// Default: 3
    public let maxValidationRetries: Int

    public init(
        model: any Model,
        systemPrompt: String = "",
        tools: [AnyAgentTool<Deps>] = [],
        maxIterations: Int = 10,
        maxValidationRetries: Int = 3,  // NEW
        usageLimits: UsageLimits? = nil
    ) {
        // ...
    }
}
```

### Behavior

| Scenario | Result |
|----------|--------|
| Validation passes | Continue normally |
| Validation fails, retries < max | Inject feedback, retry model call |
| Validation fails, retries >= max | Throw `AgentError.validationFailed` |

### Example

```swift
let agent = Agent<Void, Report>(
    model: claude,
    maxIterations: 10,        // Tool execution rounds
    maxValidationRetries: 3   // Per-output validation attempts
)

// Validator throws ValidationRetry to signal retry
let validator = OutputValidator<Void, Report> { _, report in
    guard report.sections.count >= 3 else {
        throw ValidationRetry("Report must have at least 3 sections")
    }
    return report
}
```

### Why This Design?

| Option | Pros | Cons |
|--------|------|------|
| **Retry does NOT consume iteration** (chosen) | `maxIterations` means tool rounds, predictable | Need separate `maxValidationRetries` |
| **Retry DOES consume iteration** | Single limit | Surprising: "I set 10 iterations but it stopped after 3 tool calls" |

Users expect `maxIterations` to control tool execution budget, not validation retries.

---

## Part 4: Cross-Agent Resume

### Design: Minimal Validation

When resuming from state with a different agent (e.g., switching to a cheaper model), validation is intentionally minimal and lenient.

### Validation Rules

| Scenario | Action |
|----------|--------|
| Pending tool call for missing tool | ❌ Fail with `invalidConfiguration` |
| Historical tool references in messages | ✅ Allow (just history) |
| Tool name exists but schema differs | ✅ Allow, let execution fail → LLM fixes |
| Different output type | ✅ Allow (compiler enforces via generics anyway) |
| Extra tools in new agent | ✅ Allow (superset is fine) |

### Implementation

```swift
extension Agent {
    func validateResumeCompatibility(with state: IterationState<Output>) throws {
        // Only check: pending tool calls must have available tools
        if case .beforeTools(let pendingCalls) = state.phase {
            for call in pendingCalls where call.decision == .pending || call.decision == .approved {
                guard tools.contains(where: { $0.name == call.toolName }) else {
                    throw AgentError.invalidConfiguration(
                        "Cannot resume: tool '\(call.toolName)' not available"
                    )
                }
            }
        }
        // Everything else: let it fail naturally, errors go back to LLM
    }
}
```

### Use Cases

**Switch to cheaper model after hitting iteration limit:**
```swift
let expensiveAgent = Agent(model: claude, tools: tools)
let cheaperAgent = Agent(model: haiku, tools: tools)

do {
    for try await _ in expensiveAgent.iter("Task", deps: deps) { }
} catch let error as AgentError<Output> {
    if case .maxIterationsReached(let state) = error {
        // Continue with cheaper model
        for try await node in cheaperAgent.iter(from: state, deps: deps) {
            if case .finished(let ctx) = node { return ctx.output }
        }
    }
}
```

**Retry with different model after rate limit:**
```swift
} catch let error as AgentError<Output> {
    if case .modelError(let state, let underlying) = error,
       case LLMError.rateLimited = underlying as? LLMError {
        // Switch to backup model
        for try await node in backupAgent.iter(from: state, deps: deps) { ... }
    }
}
```

### Why Minimal Validation?

| Approach | Pros | Cons |
|----------|------|------|
| **Minimal** (chosen) | Flexible, supports diverse scenarios | May fail at runtime |
| **Strict schema validation** | Catches issues early | Brittle, prevents valid use cases |

Runtime failures are recoverable — they become error results that the LLM can adapt to. Strict validation would prevent legitimate scenarios like tool version upgrades.

---

## Part 5: How run() Uses iter()

### Design: Single Loop Implementation

Both `run()` and `resume()` need the same loop logic. To avoid duplication and bugs, we extract the loop into a single `executeLoop()` method:

```swift
extension Agent {
    // MARK: - Public Entry Points

    /// Start a new run with a prompt.
    public func run(_ prompt: String, deps: Deps) async throws -> AgentRun<Output> {
        try await executeLoop(
            iterator: iter(prompt, deps: deps),
            deps: deps,
            maxIterations: maxIterations
        )
    }

    // MARK: - Internal Continuation

    /// Continue from a saved state (used by resume()).
    private func continueIteration(
        from state: IterationState<Output>,
        deps: Deps,
        maxIterations: Int? = nil
    ) async throws -> AgentRun<Output> {
        try await executeLoop(
            iterator: iter(from: state, deps: deps),
            deps: deps,
            maxIterations: maxIterations ?? self.maxIterations
        )
    }

    // MARK: - Shared Loop Logic

    /// Single implementation of the agent loop.
    /// Both run() and continueIteration() delegate to this method.
    private func executeLoop(
        iterator: AgentIterator<Deps, Output>,
        deps: Deps,
        maxIterations: Int
    ) async throws -> AgentRun<Output> {
        for await node in iterator {
            switch node {
            case .beforeModel(let ctx):
                // Check usage limits BEFORE model call
                if let limitKind = checkUsageLimits(ctx.state.usage) {
                    return AgentRun(state: ctx.state, status: .usageLimitReached(limitKind))
                }
                // Continue iteration - model call happens on next advance

            case .afterModel:
                break  // Model has responded, continue to tool processing or finish

            case .beforeTools(let ctx):
                // Check for tools needing approval
                if ctx.pendingCalls.contains(where: { $0.requiresApproval }) {
                    return AgentRun(state: ctx.state, status: .needsApproval(ctx.pendingCalls))
                }
                // No approvals needed - tools will execute

            case .afterTools(let ctx):
                // Check iteration limit
                if ctx.state.iteration >= maxIterations {
                    return AgentRun(
                        state: ctx.state,
                        status: .iterationLimitReached(limit: maxIterations)
                    )
                }
                // Continue to next iteration

            case .finished(let finished):
                return AgentRun(state: finished.state, status: .completed(finished.output))
            }
        }

        // Should never reach here - iter() always ends with .finished or throws
        fatalError("Iterator ended unexpectedly")
    }
}
```

### Why Single Implementation?

| Problem with Duplication | Solution |
|-------------------------|----------|
| Logic diverges over time | One place to maintain |
| Bugs in one copy but not other | Same code path for all cases |
| "Same switch but slightly different" | Differences are parameters, not logic |

The **only** differences between `run()` and `continueIteration()` are:
1. How to get the iterator: `iter(prompt, deps:)` vs `iter(from: state, deps:)`
2. What iteration limit to use: `self.maxIterations` vs potentially adjusted limit

Everything else — limit checking, hooks, approval checks — must be identical.

### Key Points

1. **Limits are run()'s responsibility** — iter() doesn't check limits
2. **Approval check happens at beforeTools** — if any tool has `requiresApproval`, pause
3. **State capture is trivial** — just `ctx.state`, already serializable
4. **No type translation** — `PendingToolDecision` flows through unchanged
5. **Single loop implementation** — no duplicated logic to diverge

---

## Streaming API

### AgentStreamEvent

```swift
public enum AgentStreamEvent<Output: SchemaType>: Sendable {
    // Model streaming (parameter order matches IteratorAPI's ModelStreamEvent)
    case contentDelta(String)
    case toolCallStart(id: String, name: String)
    case toolCallDelta(id: String, delta: String)
    case toolCallEnd(id: String)

    // Tool execution
    case toolResult(id: String, result: String)

    // Metrics
    case usage(Usage)

    // Terminal
    case finished(AgentRun<Output>)
}
```

### runStream Implementation

Like `run()`, streaming uses a shared implementation to avoid logic duplication:

```swift
extension Agent {
    // MARK: - Public Entry Points

    public func runStream(
        _ prompt: String,
        deps: Deps
    ) -> AsyncThrowingStream<AgentStreamEvent<Output>, Error> {
        executeStreamLoop(
            iterator: iter(prompt, deps: deps),
            deps: deps,
            maxIterations: maxIterations
        )
    }

    public func resumeStream(
        from run: AgentRun<Output>,
        with options: ResumeOptions,
        deps: Deps
    ) -> AsyncThrowingStream<AgentStreamEvent<Output>, Error> {
        // Apply decisions and get updated state (same as resume())
        // ...then delegate to shared loop
        executeStreamLoop(
            iterator: iter(from: updatedState, deps: deps),
            deps: deps,
            maxIterations: adjustedLimit
        )
    }

    // MARK: - Shared Stream Loop

    private func executeStreamLoop(
        iterator: AgentIterator<Deps, Output>,
        deps: Deps,
        maxIterations: Int
    ) -> AsyncThrowingStream<AgentStreamEvent<Output>, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for await node in iterator {
                        switch node {
                        case .beforeModel(let ctx):
                            // Check limits
                            if let limitKind = checkUsageLimits(ctx.state.usage) {
                                let run = AgentRun(state: ctx.state, status: .usageLimitReached(limitKind))
                                continuation.yield(.finished(run))
                                continuation.finish()
                                return
                            }

                            // Stream model response using iter()'s streaming
                            for await event in ctx.stream() {
                                switch event {
                                case .contentDelta(let text):
                                    continuation.yield(.contentDelta(text))
                                case .toolCallStart(let id, let name):
                                    continuation.yield(.toolCallStart(id: id, name: name))
                                case .toolCallDelta(let id, let delta):
                                    continuation.yield(.toolCallDelta(id: id, delta: delta))
                                case .toolCallEnd(let id):
                                    continuation.yield(.toolCallEnd(id: id))
                                }
                            }

                        case .beforeTools(let ctx):
                            // Same approval check as batch version
                            if ctx.pendingCalls.contains(where: { $0.requiresApproval }) {
                                let run = AgentRun(state: ctx.state, status: .needsApproval(ctx.pendingCalls))
                                continuation.yield(.finished(run))
                                continuation.finish()
                                return
                            }

                            // Stream tool execution using iter()'s streaming
                            for await event in ctx.stream() {
                                if case .toolCompleted(let call, let result, _) = event {
                                    continuation.yield(.toolResult(id: call.id, result: result))
                                }
                            }

                        case .afterTools(let ctx):
                            continuation.yield(.usage(ctx.state.usage))

                            if ctx.state.iteration >= maxIterations {
                                let run = AgentRun(state: ctx.state, status: .iterationLimitReached(limit: maxIterations))
                                continuation.yield(.finished(run))
                                continuation.finish()
                                return
                            }

                        case .afterModel:
                            break

                        case .finished(let finished):
                            let run = AgentRun(state: finished.state, status: .completed(finished.output))
                            continuation.yield(.finished(run))
                            continuation.finish()
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
```

**Note:** The decision logic (limit checks, approval checks) is identical to the batch `executeLoop()`. The only difference is that streaming versions:
1. Call `ctx.stream()` to get streaming events
2. Yield events to the continuation
3. Return `AsyncThrowingStream` instead of awaiting completion

### Complete API Surface

```swift
// Starting new conversations
func run(_ prompt: String, deps: Deps) async throws -> AgentRun<Output>
func runStream(_ prompt: String, deps: Deps) -> AsyncThrowingStream<AgentStreamEvent<Output>, Error>

// Continuing conversations from previous run (status-aware)
func run(_ prompt: String, deps: Deps, continuingFrom: AgentRun<Output>) async throws -> AgentRun<Output>
func runStream(_ prompt: String, deps: Deps, continuingFrom: AgentRun<Output>) -> AsyncThrowingStream<AgentStreamEvent<Output>, Error>

// Resuming paused runs (resolve pending state without new prompt)
func resume(from: AgentRun<Output>, with: ResumeOptions, deps: Deps) async throws -> AgentRun<Output>
func resumeStream(from: AgentRun<Output>, with: ResumeOptions, deps: Deps) -> AsyncThrowingStream<AgentStreamEvent<Output>, Error>
```

---

## Error Recovery with Checkpoints

### Principle: All iter() Errors Carry State

The underlying `iter()` primitive follows the error-with-state pattern (see [IteratorAPI.md](IteratorAPI.md#error-handling)). Every error thrown by `iter()` — except truly fatal configuration errors — carries an `IterationState<Output>` checkpoint:

```swift
public enum AgentError<Output: SchemaType>: Error {
    // Recoverable errors - all carry IterationState checkpoint
    case cancelled(state: IterationState<Output>, during: CancelledOperation)
    case modelError(state: IterationState<Output>, underlying: Error)
    case modelRefusal(state: IterationState<Output>, refusal: String)
    case validationFailed(state: IterationState<Output>, output: Output?, message: String)
    case toolError(state: IterationState<Output>, toolName: String, underlying: Error)
    case maxIterationsReached(state: IterationState<Output>)
    case usageLimitExceeded(state: IterationState<Output>, limit: UsageLimit)

    // Fatal errors - cannot recover
    case internalError(String)
    case invalidConfiguration(String)
}
```

### How run() Handles Errors from iter()

`run()` distinguishes between:
1. **Expected pauses** → Returned as `AgentRun.Status` cases
2. **Actual errors** → Propagated as `AgentError` (but still carrying state)

```
┌─────────────────────────────────────────────────────────────────┐
│  iter() throws AgentError                                       │
│  (Always carries IterationState checkpoint)                     │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  run() layer                                                    │
│                                                                 │
│  ┌─────────────────────┐    ┌─────────────────────────────────┐│
│  │ Expected pauses:    │    │ Actual errors:                  ││
│  │ • needsApproval     │    │ • modelError(state:...)         ││
│  │ • iterationLimit    │    │ • modelRefusal(state:...)       ││
│  │ • usageLimit        │    │ • toolError(state:...)          ││
│  │                     │    │ • validationFailed(state:...)   ││
│  │ → AgentRun.Status   │    │ • cancelled(state:...)          ││
│  │   (return value)    │    │                                 ││
│  └─────────────────────┘    │ → Propagate as throw            ││
│                             │   (state preserved in error)    ││
│                             └─────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

### Recovering from Errors

Because errors carry `IterationState`, callers can recover even from failures:

```swift
do {
    let run = try await agent.run("Analyze data", deps: myDeps)
    print("Output: \(run.output!)")
} catch let error as AgentError<Report> {
    switch error {
    case .modelError(let state, let underlying):
        // State is preserved! Can retry or save for later
        print("Model failed after \(state.iteration) iterations")
        print("Messages so far: \(state.messages.count)")

        // Option 1: Retry from checkpoint with different model
        let retryRun = try await backupAgent.run(
            from: state,
            deps: myDeps
        )

    case .toolError(let state, let toolName, let underlying):
        // Tool failed but state is preserved
        print("Tool \(toolName) failed: \(underlying)")

        // Option 2: Continue conversation acknowledging the error
        let continued = try await agent.run(
            "The \(toolName) tool failed. Please try a different approach.",
            deps: myDeps,
            continuingFrom: AgentRun(state: state, status: .iterationLimitReached(limit: 0))
        )

    case .cancelled(let state, let during):
        // Cancellation always resumable due to atomic transitions
        print("Cancelled during: \(during)")

        // Can resume later
        let resumed = try await agent.resume(
            from: AgentRun(state: state, status: .iterationLimitReached(limit: 0)),
            with: .additionalIterations(10),
            deps: myDeps
        )

    case .validationFailed(let state, let output, let message):
        // Even validation failures preserve state
        print("Validation failed: \(message)")
        if let invalidOutput = output {
            print("Invalid output was: \(invalidOutput)")
        }

    case .internalError, .invalidConfiguration:
        // These are truly fatal - no recovery possible
        throw error

    default:
        throw error
    }
}
```

### run() Error Cases (Convenience Wrappers)

For the `result()` convenience method, errors wrap `AgentRun` for easy access:

```swift
extension AgentRun {
    public func result() throws -> Output {
        switch status {
        case .completed(let output):
            return output
        case .needsApproval:
            throw AgentError.needsApproval(self)      // Carries full AgentRun
        case .iterationLimitReached:
            throw AgentError.iterationLimitReached(self)  // Carries full AgentRun
        case .usageLimitReached:
            throw AgentError.usageLimitReached(self)      // Carries full AgentRun
        }
    }
}
```

**Note:** These `run()`-level errors carry `AgentRun` (which embeds `IterationState`), while `iter()`-level errors carry `IterationState` directly. Both provide the same recovery capability.

---

## Conversation Continuation

### Using AgentRun as History

```swift
extension Agent {
    /// Continue a conversation from a previous run.
    ///
    /// This handles incomplete state properly:
    /// - If previous run needs approval, pending tools are auto-cancelled
    /// - Messages are preserved and new prompt is added
    public func run(
        _ prompt: String,
        deps: Deps,
        continuingFrom previous: AgentRun<Output>
    ) async throws -> AgentRun<Output> {
        var messages = previous.messages

        // Handle incomplete state
        if case .needsApproval(let pending) = previous.status {
            // Auto-cancel pending tools
            for p in pending {
                messages.append(.toolResult(
                    toolCallId: p.call.id,
                    content: "[Tool call '\(p.call.name)' was cancelled - conversation continued]"
                ))
            }
        }

        // Start new run with history
        return try await run(prompt, deps: deps, messageHistory: messages)
    }
}
```

### Three Ways to Use an AgentRun

| Action | When | Method |
|--------|------|--------|
| **Resume** | Resolve pending state (same request) | `agent.resume(from: run, with: options, deps:)` |
| **Continue** | Add new user message (new request) | `agent.run("new prompt", deps:, continuingFrom: run)` |
| **Abandon** | Discard the run | Don't use it |

---

## Type Summary

### Types from IteratorAPI (reused directly, no translation)

| Type | Purpose |
|------|---------|
| `IterationState<Output>` | Serializable checkpoint state |
| `IterationState.Phase` | Where in the loop (beforeModel, afterModel, etc.) |
| `PendingToolDecision` | Tool call + requiresApproval + decision |
| `PendingToolDecision.Decision` | .pending, .approved, .denied, .replaced |
| `BeforeModelContext<Deps, Output>` | Mutable context for beforeModel phase |
| `AfterModelContext<Deps, Output>` | Context for afterModel phase |
| `BeforeToolsContext<Deps, Output>` | Mutable context for beforeTools phase |
| `AfterToolsContext<Deps, Output>` | Mutable context for afterTools phase |
| `FinishedContext<Deps, Output>` | Final state with output |
| `AgentError<Output>` | Error enum with checkpoint state (see below) |
| `CancelledOperation` | What operation was cancelled |

### AgentError (from IteratorAPI)

The unified error type carries `IterationState` checkpoint for recovery:

| Case | Payload | Recoverable |
|------|---------|-------------|
| `.cancelled` | `state: IterationState`, `during: CancelledOperation` | ✅ |
| `.modelError` | `state: IterationState`, `underlying: Error` | ✅ |
| `.modelRefusal` | `state: IterationState`, `refusal: String` | ✅ |
| `.validationFailed` | `state: IterationState`, `output: Output?`, `message: String` | ✅ |
| `.toolError` | `state: IterationState`, `toolName: String`, `underlying: Error` | ✅ |
| `.maxIterationsReached` | `state: IterationState` | ✅ |
| `.usageLimitExceeded` | `state: IterationState`, `limit: UsageLimit` | ✅ |
| `.internalError` | `String` | ❌ |
| `.invalidConfiguration` | `String` | ❌ |

### Types Defined in AgentExecutionAPI

| Type | Purpose |
|------|---------|
| `AgentRun<Output>` | Wraps IterationState + semantic Status |
| `AgentRun.Status` | Why run stopped (completed, needsApproval, limits) |
| `ResumeOptions` | Options for resume() method |
| `AgentStreamEvent` | Events for runStream() |

### run()-Level Errors (for result() convenience method)

These wrap `AgentRun` (not just `IterationState`) for easier access:

| Error Case | Payload | When Thrown |
|------------|---------|-------------|
| `AgentError.needsApproval` | `AgentRun` | `result()` called on `.needsApproval` status |
| `AgentError.iterationLimitReached` | `AgentRun` | `result()` called on `.iterationLimitReached` status |
| `AgentError.usageLimitReached` | `AgentRun` | `result()` called on `.usageLimitReached` status |
| `AgentError.invalidResume` | `String` | Invalid `ResumeOptions` for status |

### Types Eliminated (vs previous design)

| Removed Type | Replacement |
|--------------|-------------|
| `AgentResult<Output>` | `AgentRun.Status.completed` |
| `PausedAgentRun` | `AgentRun` (embeds IterationState) |
| `PauseReason` | `AgentRun.Status` cases |
| `PendingToolCall` | `PendingToolDecision` (from IteratorAPI) |
| `DeferredToolCall` | Not needed (requiresApproval flag sufficient) |
| `ResolvedTool` | `[String: Decision]` in ResumeOptions |
| `Resolution` | `PendingToolDecision.Decision` |
| `IterationSnapshot` | Use iter() contexts directly |
| `EngineerContext` | Access via context objects (ctx.state.usage, etc.) |

---

## Migration Guide

### Success Path Tests

```swift
// Before
let result = try await agent.run("prompt", deps: ())
#expect(result.output == "expected")

// After (explicit check)
let run = try await agent.run("prompt", deps: ())
guard let output = run.output else {
    Issue.record("Expected .completed")
    return
}
#expect(output == "expected")

// After (.result() throws on pause)
let output = try await agent.run("prompt", deps: ()).result()
#expect(output == "expected")
```

### Pause Handling Tests

```swift
// Before
do {
    _ = try await agent.run("prompt", deps: ())
} catch let error as AgentError {
    guard case .hasDeferredTools(let paused) = error else { return }
    #expect(paused.pendingCalls.count == 1)
}

// After
let run = try await agent.run("prompt", deps: ())
guard case .needsApproval(let pending) = run.status else {
    Issue.record("Expected .needsApproval")
    return
}
#expect(pending.count == 1)
```

### Resume Calls

```swift
// Before
let result = try await agent.resume(paused: paused, resolutions: resolutions, deps: myDeps)

// After
let run = try await agent.resume(from: previousRun, with: .approveAll(from: previousRun), deps: myDeps)

// Or with specific decisions
let run = try await agent.resume(
    from: previousRun,
    with: .decisions(["call-1": .approved, "call-2": .denied("No")]),
    deps: myDeps
)
```

### Streaming

```swift
// Before
for try await event in agent.runStream("prompt", deps: ()) {
    switch event {
    case .result(let result):
        print(result.output)
    // ...
    }
}

// After
for try await event in agent.runStream("prompt", deps: ()) {
    switch event {
    case .finished(let run):
        if let output = run.output {
            print(output)
        }
    // ...
    }
}
```

---

## Tradeoffs

### Strengths

| Benefit | Details |
|---------|---------|
| **Built on iter()** | Single source of truth, consistent behavior |
| **Zero type translation** | Reuses IteratorAPI types directly (PendingToolDecision, Decision, contexts) |
| **No state loss** | AgentRun embeds complete IterationState |
| **Expected outcomes are return values** | Compiler forces handling all Status cases |
| **Serializable everywhere** | IterationState is already Codable |
| **Simple case stays simple** | `.result()` preserves throw-on-pause pattern |
| **Cross-agent resume** | Minimal validation allows flexible model switching |

### Limitations

| Limitation | Mitigation |
|------------|------------|
| **AgentRun.status vs state.phase** | Different semantics: WHY vs WHERE — both useful |
| **Breaking change** | Migration guide provided, `.result()` eases transition |

---

## Implementation Plan

### Phase 1: Ensure IteratorAPI Types are Public

1. Verify `IterationState`, `PendingToolDecision`, `Decision` are public
2. Verify all context types (`BeforeModelContext`, etc.) are public
3. Add any missing convenience methods to context types

### Phase 2: Core Types

1. Add `AgentRun<Output>` struct embedding `IterationState`
2. Add `AgentRun.Status` enum
3. Add `ResumeOptions` struct with factory methods
4. Add `AgentError` cases that carry `AgentRun`

### Phase 3: Validation Retry

1. Add `maxValidationRetries` parameter to Agent (default: 3)
2. Implement retry loop within iteration
3. Throw `validationFailed` when retries exhausted

### Phase 4: Cross-Agent Resume

1. Add `validateResumeCompatibility()` method
2. Check pending tool calls have available tools
3. Call validation in `iter(from:)` entry point

### Phase 5: Agent Methods Using iter()

1. Implement `run()` as loop over iter()
2. Implement `resume()` using iter(from:)
3. Implement `run(_:continuingFrom:)` for conversation continuation

### Phase 6: Streaming

1. Add `AgentStreamEvent` with `.finished(AgentRun)`
2. Implement `runStream()` using iter() with ctx.stream()
3. Implement `resumeStream()`

### Phase 7: Migration

1. Deprecate old types with availability attributes
2. Update all tests per migration guide
3. Update documentation

---

## Appendix: Research

This design was informed by comprehensive research of 8 popular agent frameworks. See [AgentSDKResearch/](AgentSDKResearch/) for details.

### Key Insights Applied

| SDK Pattern | Problem | Yrden Solution |
|-------------|---------|----------------|
| **PydanticAI**: `UsageLimitExceeded` exception | State loss on limits | `AgentRun` embeds complete `IterationState` |
| **OpenAI**: `MaxTurnsExceeded` partial state | Users can't access partial results | `AgentRun` always has messages/usage |
| **LangGraph**: Direct state mutation | Powerful but complex | `iter()` provides low-level control |
| **Vercel AI**: Separate stream/generate APIs | API proliferation | `run()`/`runStream()` both built on `iter()` |

---

## Document History

| Date | Change |
|------|--------|
| 2026-02-03 | Initial comprehensive design |
| 2026-02-04 | Aligned with IteratorAPI: embed IterationState, reuse all iter() types directly |
| 2026-02-04 | Refactored to single `executeLoop()` / `executeStreamLoop()` to avoid logic duplication; fixed AgentStreamEvent parameter order to match IteratorAPI |
| 2026-02-04 | Added Error Recovery with Checkpoints section; documented how run() handles iter() errors with IterationState; updated Type Summary with AgentError enum details |
| 2026-02-05 | Removed ContextEngineer and AgentLoopObserver (deferred to future design); added Part 3: Validation Retry with maxValidationRetries (default: 3); added Part 4: Cross-Agent Resume with minimal validation rules |
