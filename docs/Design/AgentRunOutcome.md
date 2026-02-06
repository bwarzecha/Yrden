# Design: AgentRunOutcome — Replacing Exception-Driven Control Flow

## Problem

`Agent.run()`, `resume()`, and `continueRun()` currently throw exceptions for three expected operational outcomes:

| Outcome | Current behavior | Why it's wrong |
|---------|-----------------|----------------|
| Tools need approval | `throw AgentError.hasDeferredTools(PausedAgentRun)` | Approval is expected, not exceptional |
| Usage limit reached | `throw AgentError.usageLimitExceeded(UsageLimit)` | Hitting a budget is normal operation |
| Iteration limit reached | `throw AgentError.maxIterationsExceeded(PausedAgentRun)` | Reaching a limit is expected |

### What's wrong with exceptions here

1. **Semantic mismatch.** These aren't errors — they're expected states that every caller must handle. Using `throw` says "something went wrong" when nothing went wrong.

2. **Callers must use `do/catch` for normal flow.** Every use of `run()` requires a catch block that pattern-matches `AgentError` cases, mixing genuine errors (network failures) with operational outcomes (limits hit).

3. **State loss on usage limits.** When `usageLimitExceeded` fires, the exception only carries `UsageLimit` — the conversation history, token counts, and run metadata are lost. PydanticAI and OpenAI Agents SDK both have [open](https://github.com/pydantic/pydantic-ai/issues/1083) [issues](https://community.openai.com/t/how-to-get-partial-response-from-agent-when-hitting-maxturnsexceeded/1273913) from users who can't access partial results after limit exceptions.

4. **No exhaustive checking.** The compiler can't enforce that callers handle all outcomes — `catch` blocks can silently ignore cases.

### What should still throw

Genuine failures that indicate something is actually wrong:
- `LLMError` — network failures, API errors, rate limits
- `AgentError.unexpectedModelBehavior` — model returned garbage
- `AgentError.retriesExhausted` — LLM retries failed
- `AgentError.internalError` — library bug
- `CancellationError` — task was cancelled

---

## Solution

Replace the three exception-based outcomes with a return type.

### Core type: `AgentRunOutcome<Output>`

A struct that always carries run metadata, with a `Status` enum for what happened:

```swift
public struct AgentRunOutcome<Output: SchemaType>: Sendable {
    /// What happened.
    public let status: Status

    /// Conversation messages up to the point of completion or pause.
    public let messages: [Message]

    /// Accumulated token usage.
    public let usage: Usage

    /// Number of model requests made.
    public let requestCount: Int

    /// Number of tool calls executed.
    public let toolCallCount: Int

    /// Unique identifier for this run.
    public let runID: String

    public enum Status: Sendable {
        /// Agent completed — output is available.
        case completed(Output, outputToolName: String?)

        /// Tools need human approval before execution can continue.
        case needsApproval([PendingToolCall])

        /// Iteration limit was reached.
        case iterationLimitReached(limit: Int)

        /// A usage limit was reached.
        case usageLimitReached(UsageLimit)
    }
}
```

### Why a struct with a status enum (not a flat enum)

Run metadata (messages, usage, counts, runID) is useful regardless of outcome. A flat enum like `.completed(AgentResult)` / `.paused(PausedAgentRun)` forces callers to unwrap the right case just to access metadata. The struct gives metadata always, and the status tells you what happened.

### What this replaces

- **`PausedAgentRun`** — eliminated. The outcome struct carries the same fields (messages, usage, counts, runID, pendingCalls).
- **`AgentError.hasDeferredTools`** — becomes `status: .needsApproval(pendingCalls)`.
- **`AgentError.usageLimitExceeded`** — becomes `status: .usageLimitReached(kind)`.
- **`AgentError.maxIterationsExceeded`** — becomes `status: .iterationLimitReached(limit:)`.
- **`PauseReason`** — eliminated. The `Status` enum replaces it.

### What stays unchanged

- **`AgentResult<Output>`** — kept for streaming (`AgentStreamEvent.result`) and iteration (`AgentNode.end`) APIs. The outcome struct can produce one via a computed property.
- **Genuine errors** — still thrown. `LLMError`, `AgentError.unexpectedModelBehavior`, etc.

---

## API: End-User Experience

### Simple run — just want the output

```swift
let outcome = try await agent.run("Summarize this", deps: ())
guard let output = outcome.output else {
    print("Agent didn't complete: \(outcome.status)")
    return
}
print(output)
```

Or for callers who are certain the agent will complete (no limits, no approval tools):

```swift
let result = try await agent.run("Summarize this", deps: ()).result()
print(result.output)
// .result() throws AgentError.unexpectedPause if the agent paused
```

### Handle approvals

```swift
let outcome = try await agent.run("Delete files", deps: myDeps)

switch outcome.status {
case .completed(let output, _):
    print("Done: \(output)")

case .needsApproval(let pendingCalls):
    // Show user what needs approval
    for pending in pendingCalls {
        print("Tool \(pending.toolCall.name): \(pending.deferral.reason)")
    }
    let resolutions = await getUserApprovals(pendingCalls)
    let resumed = try await agent.resume(from: outcome, resolutions: resolutions, deps: myDeps)
    // resumed is also an AgentRunOutcome — could pause again

case .iterationLimitReached(let limit):
    print("Reached \(limit) iterations")

case .usageLimitReached(let kind):
    print("Hit limit: \(kind)")
}
```

### Handle usage limits

```swift
let outcome = try await agent.run("Analyze data", deps: myDeps)

if case .usageLimitReached(let kind) = outcome.status {
    print("Hit \(kind)")
    print("Tokens used: \(outcome.usage.totalTokens)")
    print("Requests made: \(outcome.requestCount)")
    // Messages are preserved — can start new run with history
    let followUp = try await agent.run(
        "Continue analysis",
        deps: myDeps,
        messageHistory: outcome.messages
    )
}
```

### Continue after iteration limit

```swift
let outcome = try await agent.run("Complex task", deps: myDeps)

if case .iterationLimitReached = outcome.status {
    print("Paused after \(outcome.requestCount) iterations, \(outcome.usage.totalTokens) tokens")
    let continued = try await agent.continueRun(
        from: outcome,
        additionalIterations: 10,
        deps: myDeps
    )
    // continued is also an AgentRunOutcome — might hit limit again
}
```

### Chain runs with message history

```swift
// Works regardless of how the previous run ended
let first = try await agent.run("First question", deps: myDeps)
let second = try await agent.run("Follow up", deps: myDeps, messageHistory: first.messages)
```

### Streaming

```swift
for try await event in agent.runStream("Analyze data", deps: myDeps) {
    switch event {
    case .contentDelta(let text):
        print(text, terminator: "")
    case .toolCallStart(let name, _):
        print("\n[Calling \(name)...]")
    case .toolResult(let id, let result):
        print("[Result: \(result.prefix(50))...]")
    case .finished(let outcome):
        // Single terminal event — check outcome.status
        if let output = outcome.output {
            print("\nDone: \(output)")
        } else {
            print("\nPaused: \(outcome.status)")
        }
    case .usage(let usage):
        break // token tracking
    default:
        break
    }
}
```

The stream replaces `.result(AgentResult<Output>)` with `.finished(AgentRunOutcome<Output>)` — one terminal event that carries the full outcome. No exceptions for limits or approvals during streaming.

---

## Convenience API

### `.output` — optional extraction

```swift
extension AgentRunOutcome {
    /// The completed output, or nil if the agent paused.
    public var output: Output? {
        if case .completed(let output, _) = status { return output }
        return nil
    }

    /// Whether the agent completed successfully.
    public var isCompleted: Bool {
        if case .completed = status { return true }
        return false
    }

    /// Pending tool calls (empty if not .needsApproval).
    public var pendingCalls: [PendingToolCall] {
        if case .needsApproval(let calls) = status { return calls }
        return []
    }
}
```

### `.result()` — throwing extraction

```swift
extension AgentRunOutcome {
    /// Extract a typed AgentResult, throwing if the agent paused.
    ///
    /// Use this when you expect the agent to complete and want to
    /// propagate unexpected pauses as errors.
    public func result() throws -> AgentResult<Output> {
        guard case .completed(let output, let toolName) = status else {
            throw AgentError.unexpectedPause(self)
        }
        return AgentResult(
            output: output,
            usage: usage,
            messages: messages,
            outputToolName: toolName,
            runID: runID,
            requestCount: requestCount,
            toolCallCount: toolCallCount
        )
    }
}
```

---

## Method Signatures

### Before

```swift
public func run(_ prompt: String, deps: Deps, messageHistory: [Message] = [])
    async throws -> AgentResult<Output>

public func resume(paused: PausedAgentRun, resolutions: [ResolvedTool], deps: Deps)
    async throws -> AgentResult<Output>

public func continueRun(paused: PausedAgentRun, additionalIterations: Int, deps: Deps)
    async throws -> AgentResult<Output>
```

### After

```swift
public func run(_ prompt: String, deps: Deps, messageHistory: [Message] = [])
    async throws -> AgentRunOutcome<Output>

public func resume(from outcome: AgentRunOutcome<Output>, resolutions: [ResolvedTool], deps: Deps)
    async throws -> AgentRunOutcome<Output>

public func continueRun(from outcome: AgentRunOutcome<Output>, additionalIterations: Int, deps: Deps)
    async throws -> AgentRunOutcome<Output>
```

`resume()` validates at runtime that the outcome has `.needsApproval` status. `continueRun()` validates `.iterationLimitReached`. Both throw `AgentError.internalError` if called with the wrong status.

### Streaming — after

```swift
// AgentStreamEvent replaces .result with .finished
public enum AgentStreamEvent<Output: SchemaType>: Sendable {
    case contentDelta(String)
    case toolCallStart(name: String, id: String)
    case toolCallDelta(id: String, delta: String)
    case toolCallEnd(id: String)
    case toolResult(id: String, result: String)
    case usage(Usage)
    case finished(AgentRunOutcome<Output>)  // was: result(AgentResult<Output>)
}
```

---

## Types Eliminated

| Type | Replacement |
|------|------------|
| `PausedAgentRun` | `AgentRunOutcome` (same fields) |
| `PauseReason` | `AgentRunOutcome.Status` (same cases) |
| `AgentError.hasDeferredTools` | `Status.needsApproval` |
| `AgentError.usageLimitExceeded` | `Status.usageLimitReached` |
| `AgentError.maxIterationsExceeded` | `Status.iterationLimitReached` |

## Types Kept

| Type | Why |
|------|-----|
| `AgentResult<Output>` | Used by `AgentNode.end` in iter(). Produced by `.result()` convenience. |
| `PendingToolCall` | Still needed — carried inside `Status.needsApproval`. |
| `ResolvedTool` | Still needed — passed to `resume()`. |
| `DeferredToolCall` | Still needed — inside `PendingToolCall`. |
| `UsageLimit` | Still needed — carried inside `Status.usageLimitReached`. |

---

## Tradeoffs

### Strengths

- **Expected outcomes are return values.** The compiler forces callers to handle all `Status` cases via `switch`.
- **Metadata always available.** Messages, usage, counts — accessible regardless of how the run ended. No state loss.
- **Fewer types.** `PausedAgentRun` and `PauseReason` eliminated. One type captures all outcomes.
- **Natural chaining.** `outcome.messages` works for follow-up runs regardless of status.
- **Simple case is simple.** `guard let output = outcome.output` or `.result()` for callers who don't need pause handling.

### Limitations

- **`resume()` / `continueRun()` accept any outcome.** A caller could pass a completed outcome to `resume()`. This is a runtime error, not a compile-time error. Acceptable because the current API has the same limitation (you can construct `PausedAgentRun` manually).
- **`output` is optional.** The simple case requires unwrapping. Mitigated by `.result()` and `guard let`.
- **Breaking change.** Every caller of `run()`, `resume()`, `continueRun()` needs updating. Test churn is significant (~127 call sites). Mitigated by `.result()` making most success-path changes mechanical.

---

## Migration

### Test migration pattern

Tests expecting success:
```swift
// Before:
let result = try await agent.run("prompt", deps: ())
#expect(result.output == "expected")

// After (option A — guard let):
let outcome = try await agent.run("prompt", deps: ())
guard let output = outcome.output else {
    Issue.record("Expected .completed"); return
}
#expect(output == "expected")

// After (option B — .result()):
let result = try await agent.run("prompt", deps: ()).result()
#expect(result.output == "expected")
```

Tests expecting pause:
```swift
// Before:
do {
    _ = try await agent.run("prompt", deps: ())
    Issue.record("Expected error")
} catch let error as AgentError {
    guard case .hasDeferredTools(let paused) = error else { return }
    #expect(paused.pendingCalls.count == 1)
}

// After:
let outcome = try await agent.run("prompt", deps: ())
guard case .needsApproval(let pendingCalls) = outcome.status else {
    Issue.record("Expected .needsApproval"); return
}
#expect(pendingCalls.count == 1)
```
