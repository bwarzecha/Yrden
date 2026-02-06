# Design: Iterator API (iter())

> Step-by-step control over agent execution with universal checkpoints, streaming, and tool approval.

## Table of Contents

1. [Problem Statement](#problem-statement)
2. [Design Goals](#design-goals)
3. [Core Concepts](#core-concepts)
4. [Execution Timing](#execution-timing)
5. [State Mutation](#state-mutation)
6. [Atomic State Transitions](#atomic-state-transitions)
7. [Error Handling](#error-handling)
8. [API Design](#api-design)
9. [Node Types](#node-types)
10. [Streaming](#streaming)
11. [Tool Approval Flow](#tool-approval-flow)
12. [State Serialization](#state-serialization)
13. [Integration with Existing APIs](#integration-with-existing-apis)
14. [Implementation Details](#implementation-details)
15. [ToolExecutionEngine Integration](#toolexecutionengine-integration)
16. [Examples](#examples)
17. [Tradeoffs](#tradeoffs)
18. [Open Questions](#open-questions)

---

## Problem Statement

The current agent execution model (`run()`, `runStream()`) provides two modes:
1. **Batch execution** - Run to completion, get result
2. **Streaming execution** - Observe events as they happen

Neither provides **step-by-step control**:
- Inspect state between operations
- Modify messages before model calls
- Approve/deny tool calls dynamically
- Pause at any point and resume later (even across sessions)

### Real-World Needs

| Use Case | Current API | Gap |
|----------|-------------|-----|
| Cost approval before expensive model call | ❌ Not possible | Can't pause before model call |
| Dynamic tool approval based on context | Partial (requiresApproval flag) | Can't approve based on args/context |
| Context compaction before model call | ❌ Observer is read-only | Can't modify messages |
| Review tool results before adding to context | ❌ Not possible | Can't intercept results |
| Pause for user input mid-conversation | ❌ Not possible | Can't pause at arbitrary points |
| Resume execution next day | Partial (PausedAgentRun) | Only for specific pause reasons |

### Research: PydanticAI's iter()

PydanticAI provides `iter()` with node types:
- `UserPromptNode` - Initial prompt
- `ModelRequestNode` - About to call LLM (supports `.stream()`)
- `CallToolsNode` - About to execute tools (supports `.stream()`)
- `End` - Completed

**Limitations:**
- Iterator is session-bound (not serializable)
- Cannot modify tool arguments
- Cannot inject messages mid-iteration

**Yrden improvement:** Every node carries complete, serializable state for cross-session resume.

---

## Design Goals

1. **Pre-execution checkpoints** - Nodes represent pending operations, not completed ones
2. **Streaming at each node** - Optional `.stream()` method for token/event observation
3. **Mutable state** - Modify messages, approve/deny tools between iterations
4. **Serializable everywhere** - Any checkpoint can be saved and resumed later
5. **Low-level primitive** - Building block for higher-level APIs (`run()`, `runStream()`)
6. **Type-safe** - Compiler enforces correct usage patterns

### Architectural Layer

`iter()` is a **low-level primitive**. Higher-level APIs are built on top of it:

```
┌─────────────────────────────────────────────────────────────────┐
│  High-Level API: run() / runStream()                            │
│  Returns: AgentRun<Output>                                      │
│  Built on: iter() or shared loop core                           │
└───────────────────────────────┬─────────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────────┐
│  Low-Level API: iter()                                          │
│  Returns: Nodes with IterationState                             │
│  Purpose: Step-by-step control, custom workflows                │
└─────────────────────────────────────────────────────────────────┘
```

The `iter()` API does **not** return `AgentRun` — that's a higher-level concept. Instead, it yields nodes with `IterationState` that can be used to:
- Continue in-session
- Serialize for cross-session resume
- Extract final output when finished

---

## Core Concepts

### Iteration vs Streaming

| Concept | Purpose | Granularity |
|---------|---------|-------------|
| **Iteration** | Control flow, decision points | Phase-level (before/after operations) |
| **Streaming** | Observation, UI updates | Token/event-level (within operations) |

These are **orthogonal**:
- Iteration gives you decision points
- Streaming gives you visibility into what happens between decision points

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────────┐
│ beforeModel     │ ──► │ [streaming tokens]   │ ──► │ afterModel      │
│ (decision)      │     │ (observation)        │     │ (decision)      │
└─────────────────┘     └──────────────────────┘     └─────────────────┘
```

### Phase Model

Four stable checkpoints in each iteration:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Agent Loop Iteration                      │
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │ beforeModel │───►│ afterModel  │───►│ beforeTools │───►      │
│  │             │    │             │    │             │          │
│  │ Can modify  │    │ Can inspect │    │ Can approve/│          │
│  │ messages    │    │ response    │    │ deny/modify │          │
│  └─────────────┘    └─────────────┘    └─────────────┘          │
│        │                  │                  │                   │
│        │ stream()         │                  │ stream()          │
│        ▼                  │                  ▼                   │
│  [token events]           │           [tool events]              │
│                           │                                      │
│                           │                                      │
│  ┌─────────────┐          │                                      │
│  │ afterTools  │◄─────────┴──────────────────────────────────   │
│  │             │                                                 │
│  │ Can modify  │                                                 │
│  │ results     │                                                 │
│  └─────────────┘                                                 │
│        │                                                         │
│        ▼                                                         │
│  [next iteration or finished]                                    │
└─────────────────────────────────────────────────────────────────┘
```

### Why Pre and Post-Execution Phases?

**Pre-execution phases** (beforeModel, beforeTools):
- Decision points - can prevent execution
- Modification points - can change inputs
- Streaming points - can observe execution

**Post-execution phases** (afterModel, afterTools):
- Inspection points - can analyze results
- Modification points - can transform outputs before they enter context
- Checkpoint points - stable state for serialization

---

## Execution Timing

### Critical Principle: Nodes are Yielded BEFORE Execution

When you receive a node, the operation has **NOT happened yet**:

| Node | What's Pending | What Just Completed |
|------|----------------|---------------------|
| `beforeModel` | Model call | (previous iteration's tool results added to messages) |
| `afterModel` | Tool processing | Model call |
| `beforeTools` | Tool execution | (model already responded) |
| `afterTools` | Next iteration | Tool execution |
| `finished` | Nothing | Everything |

### Execution Flow Diagram

```
1. Iterator yields beforeModel(ctx)
   └─► Model NOT called yet
   └─► ctx.state.messages = what WILL be sent

2. User code runs in switch case:
   ├─► Can modify ctx.state.messages
   ├─► Can call ctx.stream() which TRIGGERS execution
   └─► Or just continue loop (execution happens on advance)

3. User code ends (loop continues to next iteration)
   ├─► If stream() was called: response already available internally
   └─► If stream() NOT called: model.complete() called NOW

4. Iterator yields afterModel(ctx)
   └─► Model HAS responded
   └─► ctx.response = the full response

5. User code runs...

6. Loop continues → beforeTools or finished
```

### When Does Execution Actually Happen?

There are **two triggers** for execution:

| Trigger | When | Streaming? |
|---------|------|------------|
| `ctx.stream()` | Immediately when called | ✅ Yes |
| Loop advances | When `for await` continues | ❌ No (batch) |

```swift
case .beforeModel(let ctx):
    // Execution has NOT happened yet

    // Option A: Trigger with streaming
    for await event in ctx.stream() {  // ← Execution starts HERE
        print(event)
    }
    // Execution complete, response stored internally

    // Option B: Don't call stream(), just continue
    break
    // Execution happens when loop advances to get next node
```

### Timeline Example

```swift
for await node in agent.iter("Task", deps: deps) {
    switch node {
    case .beforeModel(let ctx):          // ← Node yielded, model NOT called
        ctx.state.messages.append(...)    // ← Modify messages
        for await _ in ctx.stream() { }   // ← Model EXECUTES here (streaming)
        // Stream done, response stored

    case .afterModel(let ctx):            // ← Node yielded, response available
        print(ctx.response.content)       // ← Inspect response
        // No execution pending at this node

    case .beforeTools(let ctx):           // ← Node yielded, tools NOT executed
        ctx.approve(ctx.pendingCalls[0])  // ← Make decisions
        for await _ in ctx.stream() { }   // ← Tools EXECUTE here (streaming)

    case .afterTools(let ctx):            // ← Node yielded, results available
        ctx.replaceResult(...)            // ← Modify results
        // Results will be added to messages when loop advances

    case .finished(let finished):         // ← All done
        print(finished.output)
    }
}
```

---

## State Mutation

### Mutation Mechanism

Context objects are **classes (reference types)**, so mutations are immediately visible:

```swift
case .beforeModel(let ctx):
    ctx.state.messages.append(...)  // ← Mutation immediate, visible to iterator
```

### When Do Mutations Take Effect?

**Key principle:** Calling `stream()` or advancing iteration **snapshots** the current state for execution. Mutations after that point don't affect the in-flight operation.

```
Timeline for beforeModel:
───────────────────────────────────────────────────────────────────
        │                    │                         │
        ▼                    ▼                         ▼
   Node yielded         stream() called           Stream ends
        │                    │                         │
        │◄── mutations ─────►│                         │
        │    affect THIS     │◄── mutations here ─────►│
        │    model call      │    DON'T affect call    │
        │                    │    (already sent)       │
```

### Mutation Rules by Phase

| Phase | Mutations Affect |
|-------|------------------|
| `beforeModel` (before stream/advance) | THIS model call |
| `beforeModel` (during/after stream) | Stored state only, not the sent request |
| `afterModel` | Stored state (no pending operation) |
| `beforeTools` (before stream/advance) | THIS tool execution (decisions) |
| `beforeTools` (during/after stream) | Stored state only |
| `afterTools` | Results that go into messages for next iteration |

### Edge Case: Modifications During Streaming

```swift
case .beforeModel(let ctx):
    ctx.state.messages.append(.system("Extra context"))  // ✅ Affects model call

    for await event in ctx.stream() {
        // Model request already sent with "Extra context"

        ctx.state.messages.append(.system("More"))  // ⚠️ Does NOT affect current call
        // This mutation persists in state, but the model already received the request
    }
```

**Behavior:** Allowed but rarely useful. The mutation affects the stored state but not the in-flight operation.

**Best practice:** Make all modifications BEFORE calling `stream()` or advancing iteration.

### Edge Case: Serialization During Streaming

```swift
for await event in ctx.stream() {
    let data = try JSONEncoder().encode(ctx.state)  // ⚠️ Partial state
}
```

**Behavior:** You CAN serialize, but you get inconsistent state:
- `state.phase` still shows `beforeModel` (operation in progress)
- Response not yet available

**Best practice:** Only serialize at stable points — after stream completes or in post-execution phases.

### Mutation Summary

```swift
case .beforeModel(let ctx):
    // ✅ SAFE: Modify before execution
    ctx.state.messages = compact(ctx.state.messages)
    ctx.state.messages.append(.system("Context"))

    for await event in ctx.stream() {
        // ⚠️ AVOID: Modifying during streaming
        // Works but doesn't affect current operation
    }

    // ✅ SAFE: Read after execution
    // (but modifications still don't affect what was sent)

case .afterTools(let ctx):
    // ✅ SAFE: Modify results before they enter messages
    ctx.replaceResult(forCallId: "xyz", with: "Summary: ...")
    // This DOES affect what goes into messages for next iteration
```

---

## Atomic State Transitions

### Principle: Operations Are Atomic

State only transitions to the next phase when an operation FULLY completes. During execution, state remains at the "before" phase.

```
┌─────────────────────────────────────────────────────────────────┐
│  State Timeline During Model Call                               │
│                                                                 │
│  state.phase = .beforeModel                                     │
│         │                                                       │
│         │  ← Cancel here? State is STILL .beforeModel           │
│         │    Resume = retry the model call                      │
│         ▼                                                       │
│  [model call executes...]                                       │
│         │                                                       │
│         │  ← Cancel here? State is STILL .beforeModel           │
│         │    In-flight request may complete, but we ignore it   │
│         ▼                                                       │
│  state.phase = .afterModel(response)  ← Atomic transition       │
└─────────────────────────────────────────────────────────────────┘
```

### State During Operations

| Operation | State During Execution | State After Success |
|-----------|------------------------|---------------------|
| Model call | `.beforeModel` | `.afterModel(response)` |
| Tool execution | `.beforeTools(calls)` | `.afterTools(results)` |
| Model streaming | `.beforeModel` | `.afterModel(response)` |
| Tool streaming | `.beforeTools(calls)` | `.afterTools(results)` |

### Why Atomic Transitions?

1. **Always resumable**: Cancel at any point = state is last completed phase
2. **No partial states**: State is never "in the middle" of an operation
3. **Simple mental model**: Phases are checkpoints, operations are atomic
4. **Idempotent resume**: Resuming always means "retry from this phase"

### Implications for Tools

When cancelled during tool execution:
- State is `.beforeTools(calls)` with all pending decisions
- Resume = re-execute ALL tools (even if some completed before cancel)
- This is the user's responsibility to handle (idempotent tools, or accept re-execution)

For tools with side effects, users should either:
1. Make tools idempotent
2. Check `context.isRetry` (or similar) and handle accordingly
3. Accept that tools may run multiple times on retry

---

## Error Handling

### All Errors Carry Resumable State

Every error (except truly fatal ones) includes the last valid `IterationState`. **Errors are checkpoints with a reason attached.**

```swift
public enum AgentError<Output: SchemaType>: Error, Sendable {
    // MARK: - Resumable errors (all carry IterationState)

    /// Task was cancelled during execution.
    case cancelled(state: IterationState<Output>, during: CancelledOperation)

    /// Model API call failed or response is unusable.
    /// Underlying can be:
    /// - LLMError (network, rate limit, API-level content filter, etc.)
    /// - ResponseUnusable (maxTokens, response-level content filter, empty)
    case modelError(state: IterationState<Output>, underlying: Error)

    /// Model explicitly refused via refusal field (OpenAI-specific).
    /// Note: Only thrown when `response.refusal != nil`. Anthropic doesn't
    /// have this field - "refusals" come as regular content.
    case modelRefusal(state: IterationState<Output>, refusal: String)

    /// Output validation failed.
    case validationFailed(state: IterationState<Output>, output: Output?, message: String)

    /// Tool execution failed.
    /// Underlying can be:
    /// - ToolTimeoutError (execution exceeded timeout)
    /// - DecodingError (invalid arguments)
    /// - Tool's own error
    case toolError(state: IterationState<Output>, toolName: String, underlying: Error)

    /// Agent reached max iterations without completing.
    case maxIterationsReached(state: IterationState<Output>)

    /// Usage limit exceeded (tokens, requests, tool calls).
    case usageLimitExceeded(state: IterationState<Output>, limit: UsageLimit)

    // MARK: - Non-resumable errors

    case internalError(String)
    case invalidConfiguration(String)

    // MARK: - run() API errors (carry AgentRun for convenience)

    /// Thrown by AgentRun.result() when tools need approval.
    case needsApproval(AgentRun<Output>)

    /// Thrown by AgentRun.result() when iteration limit reached.
    case iterationLimitReached(AgentRun<Output>)

    /// Thrown by AgentRun.result() when usage limit reached.
    case usageLimitReached(AgentRun<Output>)

    /// Invalid resume options for the current status.
    case invalidResume(String)
}

public enum CancelledOperation: Codable, Sendable {
    case modelCall
    case toolExecution(completed: [ToolCallResult], pending: [ToolCall])
    case streaming(tokensReceived: Int)
    case phaseTransition
}

/// Response was received but is unusable (not an API failure).
public enum ResponseUnusable: Error, Sendable {
    /// Response was truncated due to max tokens limit.
    case maxTokensReached(partialContent: String?)
    /// Response was filtered by content policy (stopReason == .contentFiltered).
    case contentFiltered
    /// Response has no content, no tools, and no refusal.
    case emptyResponse
}

/// Tool execution timed out.
public struct ToolTimeoutError: Error, Sendable {
    public let toolName: String
    public let timeout: Duration
}
```

### Provider-Specific Behaviors

Different providers handle refusals and content filtering differently:

| Provider | Refusal Mechanism | Content Filter |
|----------|-------------------|----------------|
| **OpenAI** | `response.refusal` field | `stopReason = .contentFiltered` or API error |
| **Anthropic** | Text in `response.content` | Handled at API level (throws `LLMError`) |
| **Bedrock** | Text in `response.content` | `guardrailIntervened` stop reason |

**Important:** `modelRefusal` is only thrown when `response.refusal != nil`. This is
currently only populated by OpenAI. When Anthropic Claude "refuses", it returns the
refusal as regular content - this is **not an error**, it's a valid response the
agent should process normally.

### Model Error Taxonomy

| Scenario | Error Type | Underlying |
|----------|------------|------------|
| Network failure | `.modelError` | `LLMError.networkError` |
| Rate limited | `.modelError` | `LLMError.rateLimited` |
| API content filter | `.modelError` | `LLMError.contentFiltered` |
| Response truncated | `.modelError` | `ResponseUnusable.maxTokensReached` |
| Response filtered | `.modelError` | `ResponseUnusable.contentFiltered` |
| Empty response | `.modelError` | `ResponseUnusable.emptyResponse` |
| OpenAI refusal field set | `.modelRefusal` | N/A (refusal in error) |

### Error State Matrix

| Error | State Phase | What Resume Means |
|-------|-------------|-------------------|
| `cancelled` | Last completed phase | Continue from checkpoint |
| `modelError` | `.beforeModel` | Retry the model call |
| `modelRefusal` | `.afterModel` (with refusal) | User decides next step |
| `validationFailed` | `.afterModel` (with invalid) | Modify prompt, retry |
| `toolError` | `.beforeTools` | Retry all tools |
| `maxIterationsReached` | Current phase | Increase limit, continue |
| `usageLimitExceeded` | Current phase | User decides |

### Why Every Error Has State?

1. **No manual checkpointing**: User doesn't need to save state at every phase
2. **Natural error handling**: Catch block has everything needed to resume
3. **Never lose progress**: Framework preserves state automatically
4. **Consistent pattern**: All errors work the same way

### Example: Automatic Retry with Checkpointing

```swift
func runWithRetry() async throws -> Output {
    var checkpoint: IterationState<Output>? = nil

    for attempt in 1...3 {
        do {
            let iter = checkpoint.map { agent.iter(from: $0, deps: deps) }
                                ?? agent.iter("Task", deps: deps)
            for try await node in iter {
                if case .finished(let ctx) = node { return ctx.output }
            }
            fatalError("Unreachable")
        } catch let error as AgentError<Output> {
            checkpoint = error.state  // ALL errors have state
            if shouldRetry(error) { continue }
            throw error
        }
    }
    fatalError("Unreachable")
}
```

---

## API Design

### Entry Points

```swift
extension Agent {
    /// Iterate through agent execution step-by-step.
    ///
    /// Returns an `AgentIterator` that yields nodes at each phase.
    /// Each node contains complete state that can be serialized and resumed.
    public func iter(
        _ prompt: String,
        deps: Deps,
        messageHistory: [Message] = []
    ) -> AgentIterator<Deps, Output>

    /// Resume iteration from a previously saved state.
    ///
    /// Use this to continue execution across sessions:
    /// 1. Save `node.state` when pausing
    /// 2. Later, call `iter(from: savedState, deps: deps)` to continue
    public func iter(
        from state: IterationState<Output>,
        deps: Deps
    ) -> AgentIterator<Deps, Output>
}
```

### AgentIterator

```swift
/// Iterator for step-by-step agent execution.
///
/// Conforms to `AsyncSequence` for use with `for await`:
/// ```swift
/// for await node in agent.iter("Task", deps: deps) {
///     switch node {
///     case .beforeModel(let ctx): ...
///     case .afterModel(let ctx): ...
///     case .beforeTools(let ctx): ...
///     case .afterTools(let ctx): ...
///     case .finished(let finished): print(finished.output)
///     }
/// }
/// ```
public struct AgentIterator<Deps: Sendable, Output: SchemaType>: AsyncSequence {
    public typealias Element = AgentNode<Deps, Output>

    public func makeAsyncIterator() -> AsyncIterator

    public struct AsyncIterator: AsyncIteratorProtocol {
        public mutating func next() async throws -> AgentNode<Deps, Output>?
    }
}
```

### IterationState

```swift
/// Complete state at any iteration checkpoint.
///
/// This struct captures everything needed to:
/// 1. Continue execution in the current session
/// 2. Serialize and resume in a future session
/// 3. Understand what happened so far
///
/// ## Serialization
/// `IterationState` is `Codable` for cross-session persistence:
/// ```swift
/// // Save checkpoint
/// let data = try JSONEncoder().encode(node.state)
/// try data.write(to: checkpointURL)
///
/// // Resume later
/// let savedState = try JSONDecoder().decode(IterationState<MyOutput>.self, from: data)
/// for await node in agent.iter(from: savedState, deps: newDeps) { ... }
/// ```
public struct IterationState<Output: SchemaType>: Codable, Sendable {
    /// Unique identifier for this run (stable across iterations).
    public let runID: String

    /// Conversation messages accumulated so far.
    /// Mutable to allow context engineering.
    public var messages: [Message]

    /// Accumulated token usage.
    public let usage: Usage

    /// Current iteration number (0-indexed).
    public let iteration: Int

    /// Number of tool calls executed so far.
    public let toolCallCount: Int

    /// Current phase within the iteration.
    public let phase: Phase

    /// Phase within an iteration.
    public enum Phase: Codable, Sendable {
        /// About to send request to model.
        /// `messages` contains what will be sent.
        case beforeModel

        /// Model has responded.
        /// Associated value contains the full response.
        case afterModel(response: CompletionResponse)

        /// About to execute tool calls.
        /// Associated value contains calls with their approval decisions.
        /// Decisions are preserved across serialization for cross-session resume.
        case beforeTools(calls: [PendingToolDecision])

        /// Tools have been executed.
        /// Associated value contains the results.
        case afterTools(results: [ToolCallResult])
    }

    // MARK: - Copy Methods

    /// Creates a copy with a different phase.
    ///
    /// Useful for updating tool decisions before resuming:
    /// ```swift
    /// guard case .beforeTools(var calls) = state.phase else { ... }
    /// calls[0].decision = .approved
    /// let updatedState = state.with(phase: .beforeTools(calls: calls))
    /// ```
    public func with(phase newPhase: Phase) -> IterationState<Output> {
        IterationState(
            runID: runID,
            messages: messages,
            usage: usage,
            iteration: iteration,
            toolCallCount: toolCallCount,
            phase: newPhase
        )
    }
}

/// A pending tool call with its approval decision.
///
/// Decisions are serializable, allowing cross-session approval workflows:
/// save state, let user review, resume with decisions intact.
public struct PendingToolDecision: Codable, Sendable {
    /// The tool call from the model.
    public let call: ToolCall

    /// Whether this tool was marked as requiring approval in its definition.
    /// Exposed for informational purposes — iter() doesn't auto-defer based on this.
    public let requiresApproval: Bool

    /// Current decision for this tool call.
    public var decision: Decision

    public enum Decision: Codable, Sendable {
        case pending          // Will execute (default)
        case approved         // Will execute (explicit approval)
        case denied(String)   // Won't execute, message sent to model
        case replaced(String) // Won't execute, synthetic result used
    }
}
```

### AgentNode

```swift
/// A node in the agent execution graph.
///
/// Each node represents a decision point where you can:
/// - Inspect current state
/// - Modify state before proceeding
/// - Stream execution (for beforeModel, beforeTools)
/// - Serialize and resume later
public enum AgentNode<Deps: Sendable, Output: SchemaType>: Sendable {
    /// About to call the model.
    case beforeModel(BeforeModelContext<Deps, Output>)

    /// Model has responded.
    case afterModel(AfterModelContext<Deps, Output>)

    /// About to execute tools.
    case beforeTools(BeforeToolsContext<Deps, Output>)

    /// Tools have been executed.
    case afterTools(AfterToolsContext<Deps, Output>)

    /// Execution completed with final output.
    case finished(FinishedContext<Deps, Output>)
}
```

### FinishedContext

```swift
/// Context when iteration completes successfully.
///
/// Contains the final output and complete state.
/// This is a LOW-LEVEL result — higher-level APIs (run()) wrap this in AgentRun.
public struct FinishedContext<Deps: Sendable, Output: SchemaType>: Sendable {
    /// Final iteration state (includes all messages, usage, etc.)
    public let state: IterationState<Output>

    /// The structured output extracted from the model response.
    public let output: Output

    /// Convenience: total token usage
    public var usage: Usage { state.usage }

    /// Convenience: all messages in conversation
    public var messages: [Message] { state.messages }

    /// Convenience: run identifier
    public var runID: String { state.runID }
}
```

---

## Node Types

### BeforeModelContext

```swift
/// Context for the beforeModel phase.
///
/// At this point:
/// - `state.messages` contains what will be sent to the model
/// - You can modify messages (context engineering)
/// - You can call `stream()` to observe token generation
/// - Continuing iteration will execute the model call
public final class BeforeModelContext<Deps: Sendable, Output: SchemaType>: @unchecked Sendable {
    /// Current iteration state. Mutable for context engineering.
    public var state: IterationState<Output>

    /// User-provided dependencies.
    public let deps: Deps

    /// Stream the model response with token-by-token events.
    ///
    /// After streaming completes, the next iteration yields `afterModel`.
    /// If you don't call `stream()`, the model executes without streaming
    /// when iteration continues.
    ///
    /// ```swift
    /// case .beforeModel(let ctx):
    ///     // Optionally modify messages
    ///     ctx.state.messages = compact(ctx.state.messages)
    ///
    ///     // Stream tokens
    ///     for await event in ctx.stream() {
    ///         print(event.delta, terminator: "")
    ///     }
    /// ```
    public func stream() -> AsyncThrowingStream<ModelStreamEvent, Error>
}

/// Events during model streaming.
public enum ModelStreamEvent: Sendable {
    /// Text content delta.
    case contentDelta(String)

    /// Tool call started.
    case toolCallStart(id: String, name: String)

    /// Tool call arguments delta.
    case toolCallDelta(id: String, delta: String)

    /// Tool call completed.
    case toolCallEnd(id: String)
}
```

### AfterModelContext

```swift
/// Context for the afterModel phase.
///
/// At this point:
/// - Model has responded
/// - `response` contains the full completion response
/// - You can inspect usage, content, tool calls
/// - Continuing iteration will process tool calls (or finish if none)
public final class AfterModelContext<Deps: Sendable, Output: SchemaType>: @unchecked Sendable {
    /// Current iteration state.
    public var state: IterationState<Output>

    /// User-provided dependencies.
    public let deps: Deps

    /// The model's response.
    public var response: CompletionResponse {
        guard case .afterModel(let resp) = state.phase else {
            fatalError("Invalid phase for AfterModelContext")
        }
        return resp
    }
}
```

### BeforeToolsContext

```swift
/// Context for the beforeTools phase.
///
/// At this point:
/// - Model requested tool calls
/// - You can approve, deny, or replace each tool call
/// - You can call `stream()` to observe tool execution events
/// - Continuing iteration executes approved tools
public final class BeforeToolsContext<Deps: Sendable, Output: SchemaType>: @unchecked Sendable {
    /// Current iteration state.
    public var state: IterationState<Output>

    /// User-provided dependencies.
    public let deps: Deps

    /// Pending tool calls with their decisions.
    public private(set) var pendingCalls: [PendingToolDecision]

    /// Approve a tool call for execution.
    public func approve(_ call: ToolCall)

    /// Deny a tool call with a message sent back to the model.
    public func deny(_ call: ToolCall, message: String)

    /// Replace a tool call with a synthetic result (skip execution).
    public func replace(_ call: ToolCall, withResult result: String)

    /// Stream tool execution events.
    ///
    /// Yields events as tools execute (respecting approval decisions).
    /// Denied tools emit `.toolDenied` events immediately.
    public func stream() -> AsyncThrowingStream<ToolStreamEvent, Error>
}

// Note: PendingToolDecision is defined in the API Design section above (line ~492)

/// Events during tool execution streaming.
public enum ToolStreamEvent: Sendable {
    /// Tool started execution.
    case toolStarted(call: ToolCall)

    /// Tool was denied by user.
    case toolDenied(call: ToolCall, message: String)

    /// Tool execution progress (for long-running tools).
    case toolProgress(callId: String, update: String)

    /// Tool completed execution successfully.
    /// Note: The result may contain an error message FROM the tool,
    /// but the execution itself succeeded.
    case toolCompleted(call: ToolCall, result: String, duration: Duration)

    /// Tool execution itself failed (timeout, parsing error, exception).
    /// This is distinct from toolCompleted with an error result:
    /// - toolCompleted: Tool ran and returned (possibly an error message)
    /// - toolFailed: Tool execution machinery failed
    case toolFailed(call: ToolCall, error: String, duration: Duration)
}

/// Result of a single tool call execution.
///
/// Used in `afterTools` phase and stored in `IterationState.Phase.afterTools`.
public struct ToolCallResult: Codable, Sendable {
    /// The original tool call from the model.
    public let call: ToolCall

    /// The result of execution.
    public let result: ToolResult

    /// How long the tool took to execute.
    public let duration: Duration

    /// Possible outcomes of tool execution.
    public enum ToolResult: Codable, Sendable {
        /// Tool executed successfully and returned output.
        case success(String)

        /// Tool was denied by user (didn't execute).
        case denied(message: String)

        /// Tool was replaced with synthetic result (didn't execute).
        case replaced(result: String)

        /// Tool execution failed (timeout, exception, etc.).
        case failed(error: String)
    }

    /// Convenience: the output string regardless of result type.
    /// For denied/failed, returns the message/error.
    public var output: String {
        switch result {
        case .success(let s): return s
        case .denied(let m): return "Tool denied: \(m)"
        case .replaced(let r): return r
        case .failed(let e): return "Tool failed: \(e)"
        }
    }
}
```

### AfterToolsContext

```swift
/// Context for the afterTools phase.
///
/// At this point:
/// - Tools have been executed (or denied/replaced)
/// - Results are in `results`
/// - You can modify results before they're added to messages
/// - Continuing iteration adds results to messages and starts next iteration
public final class AfterToolsContext<Deps: Sendable, Output: SchemaType>: @unchecked Sendable {
    /// Current iteration state.
    public var state: IterationState<Output>

    /// User-provided dependencies.
    public let deps: Deps

    /// Tool execution results. Mutable for modification.
    public var results: [ToolCallResult] {
        get {
            guard case .afterTools(let r) = state.phase else { return [] }
            return r
        }
        set {
            // Update phase with new results
        }
    }

    /// Replace a tool result with a summary or transformed version.
    public func replaceResult(forCallId id: String, with newResult: String)

    /// Remove a tool result entirely (won't be added to messages).
    public func removeResult(forCallId id: String)
}
```

---

## Streaming

### Design: Streaming is Opt-in at Decision Points

Streaming happens **between** phases, during operation execution:

```
beforeModel ──┬── stream() called ──► [tokens...] ──► afterModel
              │
              └── stream() NOT called ──► (execute) ──► afterModel
```

### How stream() Works

1. **Calling `stream()` triggers execution** with streaming
2. **Events yield** as the operation progresses
3. **After stream completes**, continue iteration to get next node
4. **If you don't call `stream()`**, iteration continues and executes without streaming

```swift
case .beforeModel(let ctx):
    // Option 1: Stream tokens
    for await event in ctx.stream() {
        updateUI(event)
    }
    // After streaming, next iteration gives afterModel

    // Option 2: Don't stream
    // Just continue iteration - model executes without streaming
```

### Implementation: Tracking Execution State

The context tracks whether execution already happened:

```swift
public final class BeforeModelContext<...> {
    private var executed: Bool = false
    private var response: CompletionResponse?

    public func stream() -> AsyncThrowingStream<ModelStreamEvent, Error> {
        precondition(!executed, "stream() called after execution already completed")
        executed = true

        return AsyncThrowingStream { continuation in
            Task {
                // Stream from model
                for try await event in self.model.stream(self.request) {
                    // Forward events
                    // Store final response
                }
            }
        }
    }

    // Called by iterator when advancing
    internal func executeIfNeeded() async throws -> CompletionResponse {
        if let response = self.response {
            return response  // Already executed via stream()
        }
        executed = true
        return try await model.complete(request)
    }
}
```

---

## Tool Approval Flow

### Default Behavior

Without explicit decisions, pending tools execute:

```swift
case .beforeTools(let ctx):
    // All tools in ctx.pendingCalls have .pending decision
    // Continuing iteration executes all of them
    break
```

### Explicit Approval

```swift
case .beforeTools(let ctx):
    for pending in ctx.pendingCalls {
        switch pending.call.name {
        case "delete_file":
            // Always deny dangerous tools
            ctx.deny(pending.call, message: "File deletion not permitted")

        case "send_email":
            // Ask user
            if await userApproves(pending.call) {
                ctx.approve(pending.call)
            } else {
                ctx.deny(pending.call, message: "User declined")
            }

        case "expensive_api":
            // Use cached result
            if let cached = cache[pending.call.arguments] {
                ctx.replace(pending.call, withResult: cached)
            }

        default:
            break  // Keep .pending (will execute)
        }
    }

    // Stream to see execution progress
    for await event in ctx.stream() {
        switch event {
        case .toolDenied(let call, let msg):
            print("✗ \(call.name): \(msg)")
        case .toolStarted(let call):
            print("▶ \(call.name)")
        case .toolCompleted(let call, _):
            print("✓ \(call.name)")
        }
    }
```

### What the Model Sees

| Decision | Executes? | Result sent to model |
|----------|-----------|----------------------|
| `.pending` / `.approved` | ✅ Yes | Actual tool result |
| `.denied(message)` | ❌ No | `"Tool denied: {message}"` |
| `.replaced(result)` | ❌ No | `"{result}"` |

The model always receives a "result" for each tool it called - either real or synthetic.

---

## State Serialization

### Codable Requirements

For `IterationState` to be `Codable`, all nested types must be:

| Type | Status | Notes |
|------|--------|-------|
| `String`, `Int` | ✅ Built-in | runID, iteration, toolCallCount |
| `Message` | ✅ Must be Codable | Already JSON-based |
| `Usage` | ✅ Must be Codable | Simple struct |
| `CompletionResponse` | ✅ Must be Codable | Add conformance |
| `ToolCall` | ✅ Must be Codable | Already Codable |
| `ToolCallResult` | ✅ Must be Codable | Contains Codable types |

### Serialization Boundaries

**Can serialize at:**
- `beforeModel` - Before any execution
- `afterModel` - Complete response available
- `beforeTools` - Tool calls known, not executed
- `afterTools` - Results available

**Cannot serialize at:**
- Mid-token during streaming
- Mid-tool execution

### Cross-Session Resume

```swift
// Session 1: Run until user needs to approve
for await node in agent.iter("Delete old files", deps: deps) {
    switch node {
    case .beforeTools(let ctx):
        // User needs to think about this
        let data = try JSONEncoder().encode(ctx.state)
        try data.write(to: checkpointURL)
        print("Checkpoint saved. Review and resume later.")
        return  // Exit iteration

    default:
        break
    }
}

// Session 2 (next day):
let data = try Data(contentsOf: checkpointURL)
let savedState = try JSONDecoder().decode(IterationState<MyOutput>.self, from: data)

// User reviewed and decided
for await node in agent.iter(from: savedState, deps: newDeps) {
    switch node {
    case .beforeTools(let ctx):
        // Now approve based on user's decision
        for pending in ctx.pendingCalls {
            if userApprovedTool(pending.call.name) {
                ctx.approve(pending.call)
            } else {
                ctx.deny(pending.call, message: "User rejected after review")
            }
        }

    case .finished(let finished):
        print("Completed: \(finished.output)")

    default:
        break
    }
}
```

---

## Integration with Existing APIs

### Relationship to run() and runStream()

| API | Control | Streaming | Use Case |
|-----|---------|-----------|----------|
| `run()` | None | No | Simple batch execution |
| `runStream()` | None | Yes | Real-time UI updates |
| `iter()` | Full | Optional | Complex workflows, approvals |

`iter()` is the most powerful but most verbose. Use `run()`/`runStream()` for simple cases.

### Relationship to AgentRun

`iter()` is a **lower-level primitive** than `AgentRun`:

| Concept | Level | Purpose |
|---------|-------|---------|
| `IterationState` | Low | Raw checkpoint state |
| `FinishedContext` | Low | Iteration completed with output |
| `AgentRun` | High | Rich result type with status enum |

The higher-level `run()` API:
1. Uses `iter()` (or shared loop) internally
2. Wraps the result in `AgentRun` with status handling
3. Provides `resume()` for continuation

If you use `iter()` directly, you work with `IterationState` and `FinishedContext`. You can build your own continuation logic or convert to `AgentRun` if needed.

---

## Implementation Details

### Actor Isolation

`Agent` is an actor. `iter()` returns a struct that captures necessary state:

```swift
extension Agent {
    public nonisolated func iter(
        _ prompt: String,
        deps: Deps,
        messageHistory: [Message] = []
    ) -> AgentIterator<Deps, Output> {
        AgentIterator(
            agent: self,
            initialPrompt: prompt,
            deps: deps,
            messageHistory: messageHistory
        )
    }
}
```

The iterator holds a reference to the actor and makes isolated calls:

```swift
public struct AgentIterator<...>: AsyncSequence {
    private let agent: Agent<Deps, Output>
    private var state: IterationState<Output>?

    public struct AsyncIterator: AsyncIteratorProtocol {
        public mutating func next() async throws -> AgentNode<Deps, Output>? {
            // Make isolated calls to agent for execution
            return try await agent.nextNode(from: &state)
        }
    }
}
```

### Context as Reference Type

Contexts are classes (reference types) so mutations are visible:

```swift
case .beforeModel(let ctx):
    ctx.state.messages.append(...)  // Mutation visible to iterator

    for await event in ctx.stream() {
        // Stream uses the modified messages
    }
```

Using `@unchecked Sendable` because:
- Context is only accessed from one task at a time
- Iterator controls access lifecycle

### Execution Tracking

The iterator tracks whether execution happened at each node:

```swift
internal actor IteratorState<...> {
    var currentPhase: IterationState<Output>.Phase
    var executed: Bool = false

    func markExecuted() {
        executed = true
    }

    func advanceToNextPhase() async throws -> AgentNode<...>? {
        if !executed {
            // Execute the operation
            try await executeCurrentPhase()
        }
        // Move to next phase
        return try await computeNextNode()
    }
}
```

---

## ToolExecutionEngine Integration

The `iter()` API integrates with `ToolExecutionEngine` for tool execution while providing full control over approval decisions. This section details the execution model.

### Per-Tool Timeout

Timeouts are configured **per-tool**, not globally. Different tools have different execution profiles:
- Instant tools: database lookups, calculations
- Medium tools: API calls, file operations
- Long-running tools: agent-to-agent calls, complex computations

```swift
public struct AnyAgentTool<Deps: Sendable>: Sendable {
    public let name: String
    public let description: String
    public let definition: ToolDefinition
    public let requiresApproval: Bool

    /// Per-tool timeout. nil = use engine default or no timeout.
    public let timeout: Duration?
}
```

The engine applies timeouts with precedence:
1. Tool-level timeout (if set)
2. Engine default timeout (if set)
3. No timeout

```swift
private func executeWithTimeout(...) async throws -> AnyToolResult {
    let effectiveTimeout = tool.timeout ?? self.defaultTimeout

    guard let timeout = effectiveTimeout else {
        return try await tool.call(...)  // No timeout
    }
    // ... timeout logic with TaskGroup racing
}
```

### Execution Strategy

Tool execution supports multiple strategies via `ToolExecutionEngine`:

```swift
public enum ExecutionStrategy: Sendable {
    /// Execute tools one at a time, in order.
    case sequential

    /// Execute all tools concurrently.
    case parallel

    /// Execute up to N tools concurrently (semaphore pattern).
    case parallelLimit(Int)
}

public struct ToolExecutionEngine<Deps: Sendable>: Sendable {
    private let tools: [AnyAgentTool<Deps>]
    private let defaultTimeout: Duration?
    private let strategy: ExecutionStrategy

    public func executeAll(
        calls: [ToolCall],
        baseContext: AgentContext<Deps>
    ) async throws -> BatchResult {
        switch strategy {
        case .sequential:
            return try await executeSequentially(...)
        case .parallel:
            return try await executeInParallel(...)
        case .parallelLimit(let limit):
            return try await executeWithLimit(..., limit: limit)
        }
    }
}
```

**Parallel execution** uses `TaskGroup`:

```swift
private func executeInParallel(...) async throws -> BatchResult {
    try await withThrowingTaskGroup(
        of: (call: ToolCall, result: AnyToolResult, duration: Duration).self
    ) { group in
        for call in calls {
            group.addTask {
                let start = ContinuousClock.now
                let result = await self.executeSingle(call: call, ...)
                return (call, result, ContinuousClock.now - start)
            }
        }

        var results: [(ToolCall, AnyToolResult, Duration)] = []
        for try await item in group {
            results.append(item)
        }

        // Sort by original order for deterministic results
        let callOrder = Dictionary(uniqueKeysWithValues:
            calls.enumerated().map { ($1.id, $0) })
        results.sort { callOrder[$0.0.id, default: 0] < callOrder[$1.0.id, default: 0] }

        return BatchResult(results: results, stoppedOnDeferral: false)
    }
}
```

### Failure Behavior: Errors as Results

**Principle:** Tool failures are data, not exceptions. All tool errors are passed back to the LLM as result content.

```swift
private func executeSingle(
    call: ToolCall,
    context: AgentContext<Deps>
) async -> AnyToolResult {  // Note: returns, not throws
    guard let tool = tools.first(where: { $0.name == call.name }) else {
        return .failure(ToolExecutionError.toolNotFound(call.name))
    }

    do {
        return try await executeWithTimeout(tool: tool, ...)
    } catch is CancellationError {
        // Propagate cancellation — this IS catastrophic
        throw AgentError.cancelled
    } catch {
        // Everything else becomes a failure result for LLM
        return .failure(error)
    }
}
```

**What throws vs what returns:**

| Condition | Behavior |
|-----------|----------|
| Tool not found | `.failure(toolNotFound)` — LLM can correct |
| Argument parsing failed | `.failure(argumentParsing)` — LLM can correct |
| Tool threw an error | `.failure(error)` — LLM sees error message |
| Tool timed out | `.failure(timeout)` — LLM sees timeout message |
| Task cancelled | `throw AgentError.cancelled` — propagates |
| System failure (OOM, etc.) | Propagates — truly catastrophic |

This design ensures the agent loop continues unless something truly unrecoverable happens. The LLM receives error context and can adapt its strategy.

### iter() Integration Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│  iter() receives model response with tool calls                          │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Yields: beforeTools(ctx)                                                │
│  ctx.pendingCalls = all tool calls with decision = .pending             │
│  ctx.pendingCalls[i].requiresApproval = from tool definition            │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  User code makes decisions:                                              │
│    ctx.approve(call)  → decision = .approved                            │
│    ctx.deny(call, msg) → decision = .denied(msg)                        │
│    ctx.replace(call, result) → decision = .replaced(result)            │
│    (no action) → decision stays .pending (will execute)                 │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  User calls ctx.stream() OR iteration advances                          │
│                                                                         │
│  iter() partitions by decision:                                         │
│    toExecute: .pending or .approved → send to ToolExecutionEngine       │
│    toDeny: .denied(msg) → synthetic result: "Tool denied: {msg}"        │
│    toReplace: .replaced(result) → synthetic result: "{result}"          │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  ToolExecutionEngine.executeAll(toExecute, strategy: configured)        │
│                                                                         │
│  - Each tool runs with its own timeout                                  │
│  - Failures become .failure results (not thrown)                        │
│  - Cancellation propagates up                                           │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Merge all results (preserving original call order):                     │
│    - Engine results: .success or .failure                               │
│    - Denied: .success("Tool denied: {message}")                         │
│    - Replaced: .success("{synthetic_result}")                           │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Yields: afterTools(ctx)                                                 │
│  ctx.results = all results (can be modified before messages update)     │
└─────────────────────────────────────────────────────────────────────────┘
```

### Streaming Events During Parallel Execution

When `ctx.stream()` is called and execution strategy is parallel, events naturally interleave as tools complete at different times:

```swift
// Inside BeforeToolsContext.stream()
public func stream() -> AsyncThrowingStream<ToolStreamEvent, Error> {
    AsyncThrowingStream { continuation in
        Task {
            // 1. Emit denied/replaced immediately (no execution needed)
            for pending in self.deniedCalls {
                continuation.yield(.toolDenied(
                    call: pending.call,
                    message: pending.denyMessage
                ))
            }
            for pending in self.replacedCalls {
                continuation.yield(.toolCompleted(
                    call: pending.call,
                    result: pending.replacementResult,
                    duration: .zero
                ))
            }

            // 2. Execute approved tools via engine (parallel or sequential)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for call in self.toExecute {
                    group.addTask {
                        // Emit start event
                        continuation.yield(.toolStarted(call: call))

                        // Execute with per-tool timeout
                        let start = ContinuousClock.now
                        let result = await self.engine.executeSingle(...)
                        let duration = ContinuousClock.now - start

                        // Emit completion event
                        switch result {
                        case .success(let value):
                            continuation.yield(.toolCompleted(
                                call: call, result: value, duration: duration
                            ))
                        case .failure(let error):
                            continuation.yield(.toolFailed(
                                call: call,
                                error: error.localizedDescription,
                                duration: duration
                            ))
                        case .deferred:
                            // Should not happen in iter() — approval handled above
                            break
                        }
                    }
                }
                try await group.waitForAll()
            }

            continuation.finish()
        }
    }
}
```

**Event ordering with parallel execution:**

```swift
// 3 tools executing in parallel, tool_B finishes first
toolStarted(tool_A)
toolStarted(tool_B)
toolStarted(tool_C)
toolCompleted(tool_B, result: "...", duration: 50ms)
toolCompleted(tool_C, result: "...", duration: 120ms)
toolCompleted(tool_A, result: "...", duration: 200ms)
```

This provides real-time visibility into execution progress. If sequential ordering is needed for UI purposes, the consumer can buffer and sort by original call order.

### Engine Configuration in Agent

The agent configures its `ToolExecutionEngine` at initialization:

```swift
public actor Agent<Deps: Sendable, Output: SchemaType> {
    // ... existing properties ...

    /// Execution strategy for tool calls.
    public let executionStrategy: ExecutionStrategy

    /// Tool execution engine (lazily constructed).
    private var toolEngine: ToolExecutionEngine<Deps> {
        ToolExecutionEngine(
            tools: tools,
            defaultTimeout: toolTimeout,
            strategy: executionStrategy
        )
    }
}
```

For `iter()`, the strategy can be overridden per-call if needed, or inherited from the agent configuration.

---

## Examples

### Basic Iteration

```swift
for await node in agent.iter("Analyze this data", deps: myDeps) {
    switch node {
    case .beforeModel(let ctx):
        print("About to call model with \(ctx.state.messages.count) messages")

    case .afterModel(let ctx):
        print("Model responded: \(ctx.response.content?.prefix(100) ?? "")")

    case .beforeTools(let ctx):
        print("About to execute \(ctx.pendingCalls.count) tools")

    case .afterTools(let ctx):
        print("Got \(ctx.results.count) results")

    case .finished(let finished):
        print("Done: \(finished.output)")
        print("Total tokens: \(finished.usage.totalTokens)")
    }
}
```

### Streaming with Context Modification

```swift
for await node in agent.iter("Write a story", deps: deps) {
    switch node {
    case .beforeModel(let ctx):
        // Compact if too many messages
        if ctx.state.messages.count > 50 {
            ctx.state.messages = keepRecent(ctx.state.messages, count: 20)
        }

        // Stream tokens
        for await event in ctx.stream() {
            if case .contentDelta(let text) = event {
                print(text, terminator: "")
            }
        }
        print()

    case .finished(let finished):
        print("\n\nFinal output: \(finished.output)")

    default:
        break
    }
}
```

### Dynamic Tool Approval

```swift
for await node in agent.iter("Manage my files", deps: deps) {
    switch node {
    case .beforeTools(let ctx):
        for pending in ctx.pendingCalls {
            // Check against allowlist
            if dangerousTools.contains(pending.call.name) {
                // Ask user
                print("Tool '\(pending.call.name)' wants to: \(pending.call.arguments)")
                print("Allow? (y/n)")

                if readLine() == "y" {
                    ctx.approve(pending.call)
                } else {
                    ctx.deny(pending.call, message: "User denied")
                }
            }
        }

        // Stream execution
        for await event in ctx.stream() {
            switch event {
            case .toolStarted(let call):
                print("▶ \(call.name)...")
            case .toolCompleted(let call, _):
                print("✓ \(call.name)")
            case .toolDenied(let call, let msg):
                print("✗ \(call.name): \(msg)")
            default:
                break
            }
        }

    case .finished(let finished):
        print("Done: \(finished.output)")

    default:
        break
    }
}
```

### Cross-Session Checkpoint

```swift
// Save checkpoint when user needs time
func saveCheckpoint(_ state: IterationState<MyOutput>) throws {
    let data = try JSONEncoder().encode(state)
    try data.write(to: checkpointURL)
}

// Resume from checkpoint
func resumeFromCheckpoint() async throws -> MyOutput {
    let data = try Data(contentsOf: checkpointURL)
    let state = try JSONDecoder().decode(IterationState<MyOutput>.self, from: data)

    for await node in agent.iter(from: state, deps: freshDeps) {
        switch node {
        case .finished(let finished):
            return finished.output
        default:
            break  // Continue through phases
        }
    }

    fatalError("Should have finished")
}
```

---

## Tradeoffs

### Strengths

| Benefit | Details |
|---------|---------|
| **Maximum control** | Inspect/modify at every decision point |
| **Serializable anywhere** | Cross-session resume from any checkpoint |
| **Streaming flexibility** | Choose when and whether to stream |
| **Dynamic approval** | Context-aware tool decisions |
| **Type-safe** | Compiler enforces node handling |

### Limitations

| Limitation | Mitigation |
|------------|------------|
| **Verbosity** | Use `run()` for simple cases |
| **Reference semantics** | Clear documentation on mutation |
| **Cannot pause mid-stream** | Only stable checkpoints are serializable |
| **Learning curve** | Examples and documentation |

### Comparison with Alternatives

**vs PydanticAI iter():**
- ✅ Serializable state (they're session-bound)
- ✅ Post-execution phases (afterModel, afterTools)
- ✅ Mutable state
- ⚠️ More types/complexity

**vs LangGraph checkpoints:**
- ✅ Simpler (no graph model)
- ✅ Linear iteration
- ⚠️ Less flexible routing

**vs ContextEngineer hooks:**
- ✅ More control (approval, pause)
- ⚠️ More verbose for simple cases

---

## Open Questions

### 1. Should afterModel Be Optional?

PydanticAI doesn't have an afterModel phase - it goes directly from ModelRequestNode to CallToolsNode.

**Argument for keeping afterModel:**
- Allows inspection before processing
- Natural checkpoint for serialization
- Cost tracking before tool execution

**Argument for removing:**
- Simpler API
- Tool calls are part of model response anyway

**Current decision:** Keep afterModel for flexibility.

### 2. Parallel Tool Execution Streaming

When tools execute in parallel, how should streaming work?

**Option A:** Interleaved events
```swift
// Events from multiple tools interleaved
toolStarted(tool_A)
toolStarted(tool_B)
toolCompleted(tool_B, ...)
toolCompleted(tool_A, ...)
```

**Option B:** Sequential presentation
```swift
// Wait for all, then present in order
toolStarted(tool_A)
toolCompleted(tool_A, ...)
toolStarted(tool_B)
toolCompleted(tool_B, ...)
```

**Current decision:** Option A (interleaved) - more real-time.

### 3. Error Handling in Nodes ✅ RESOLVED

**Decision:** All errors carry resumable state. See [Error Handling](#error-handling) section.

The error itself IS the checkpoint. No need for a special error node type — thrown errors include `IterationState` directly:

```swift
do {
    for try await node in agent.iter("Task", deps: deps) { ... }
} catch let error as AgentError<MyOutput> {
    // ALL resumable errors have .state
    let checkpoint = error.state
    // Can save and resume later
}
```

This combines the simplicity of Option A (throw) with the state preservation of Option B (via attached state).

---

## Design Decisions Log

### Decision: iter() Returns IterationState, Not AgentRun

**Context:** Should `iter()` end with `AgentRun` like `run()` does?

**Decision:** No. `iter()` is a lower-level primitive that returns `FinishedContext` with `IterationState`. `AgentRun` is a higher-level concept for the `run()` API.

**Rationale:**
- Clear separation of abstraction layers
- `iter()` users want raw control, not wrapped results
- Higher-level APIs can build on `iter()` and add their own result wrapping

### Decision: Contexts are Classes (Reference Types)

**Context:** How should state mutations work in the `for await` loop?

**Decision:** Context objects (`BeforeModelContext`, etc.) are classes, so mutations are immediately visible.

**Rationale:**
- Swift's `for await` receives values; structs would require explicit commit
- Reference semantics allow natural mutation: `ctx.state.messages.append(...)`
- `@unchecked Sendable` is safe because contexts are only accessed from one task

### Decision: Mutations During Streaming Are Allowed But Don't Affect Current Operation

**Context:** What happens if you modify `ctx.state` while streaming?

**Decision:** Allow it, but document that it doesn't affect the in-flight operation.

**Rationale:**
- Adding runtime checks adds complexity
- The behavior is well-defined (mutations persist, just don't affect current request)
- Best practice is to modify before `stream()`, which is natural anyway

### Decision: Four Phases (Before/After Model, Before/After Tools)

**Context:** PydanticAI only has pre-execution nodes. Do we need post-execution phases?

**Decision:** Yes. Include `afterModel` and `afterTools` phases.

**Rationale:**
- `afterModel`: Allows inspection before tool processing, natural checkpoint
- `afterTools`: Allows result modification before messages update
- More flexibility for context engineering use cases
- Serialization at any phase is cleaner

### Decision: Empty Model Response Handling

**Context:** What happens when model returns no content and no tool calls?

**Decision:** Treat it like any other response — attempt output extraction normally.

**Behavior:**
- `String` output: Return empty string `""`
- Structured output: Attempt to parse/validate empty content
  - If type accepts empty (unlikely): succeed
  - If validation fails: validation error fed back to model, loop continues

**Rationale:**
- Consistent handling — no special-casing for empty responses
- Validation errors are already part of the retry flow
- Model gets feedback and can correct itself

### Decision: Error Serialization as String

**Context:** `ToolCallResult` may contain errors, but `Error` isn't `Codable`.

**Decision:** Serialize errors as their `localizedDescription` string.

**Rationale:**
- Error type information is rarely needed after serialization
- Error message is what matters for model feedback and debugging
- Can upgrade to `CodableError` wrapper later if needed

### Decision: Tool Denial Message Format

**Context:** What exact message does the model see when a tool is denied?

**Decision:** Format is `"Tool denied: {message}"` where `{message}` is the user-provided reason.

**Rationale:**
- Consistent, parsable format
- Clear signal to model that denial was intentional
- Model can adapt behavior based on the reason

### Decision: Output Tool is Invisible in Approval Flow

**Context:** Should output tool calls appear in `beforeTools.pendingCalls`?

**Decision:** No. Output tools are processed automatically and never appear in the approval flow.

**Rationale:**
- Output tool is a structured output mechanism, not a real tool
- Validation errors are already fed back to the model automatically
- Keeps `beforeTools` focused on actual tool execution decisions

**Phase transitions:**
| Response | Next Phase |
|----------|------------|
| Valid output tool | `finished` |
| Invalid output tool | `beforeModel` (with validation error) |
| Regular tools only | `beforeTools` |
| Output + regular (early) | `finished` |
| Output + regular (exhaustive) | `beforeTools` then `finished` |

### Decision: Cancellation is Cooperative and Resumable

**Context:** What happens when the Task running iteration is cancelled?

**Decision:** Cancellation throws `AgentError.cancelled` with the last valid state attached. Combined with atomic state transitions, state is ALWAYS valid and resumable.

**Behavior:**
- Cancellation is checked at phase boundaries (cooperative)
- When cancelled, the error carries `IterationState` at the last completed phase
- Because of atomic transitions, state is NEVER partial
- User can resume from the attached state at any time

**Rationale:**
- Atomic transitions mean state is never "in the middle" of an operation
- Error carries the checkpoint automatically
- User doesn't need manual state tracking at every phase
- Natural error handling becomes checkpoint handling

### Decision: All Errors Are Checkpoints

**Context:** Should errors carry state for resumability?

**Decision:** Yes. Every error (except `internalError` and `invalidConfiguration`) carries `IterationState`.

**Rationale:**
- Every error happens at a valid state — there's always a prior checkpoint
- User decides what to do: retry, modify and retry, accept partial, or abort
- Framework never loses progress
- Errors become "checkpoints with a reason"
- Simplifies retry patterns dramatically (see [Error Handling](#error-handling))

### Decision: Full Context Copy on Execution

**Context:** How is state isolation achieved when `stream()` is called?

**Decision:** The entire context (messages, etc.) is copied when execution begins.

**Rationale:**
- Clean isolation between sent request and stored state
- Mutations during streaming don't cause confusion
- Swift COW makes this efficient (no actual copy unless mutation occurs)

### Decision: Message History Validation is User Responsibility

**Context:** Should we validate `messageHistory` passed to `iter()`?

**Decision:** User is responsible for valid message sequences.

**Contract:**
- Do NOT include system prompt (agent prepends it)
- Messages must form valid conversation (alternating roles, tool results after calls)
- Invalid sequences may cause provider errors

**Rationale:**
- Validation adds overhead for common valid cases
- Users often know their data is valid

### Decision: Usage Available at Every Phase

**Context:** Users need to check token consumption to make decisions (add context warnings, stop early, etc.).

**Decision:** `state.usage` is available and updated at each phase.

**Update timing:**
| Phase | `state.usage` Contains |
|-------|----------------------|
| `beforeModel` | Accumulated from previous iterations |
| `afterModel` | Updated with this model call's tokens |
| `beforeTools` | Same as afterModel |
| `afterTools` | Same (tool execution doesn't consume model tokens) |

**Use case:**
```swift
case .beforeModel(let ctx):
    if ctx.state.usage.totalTokens > 50_000 {
        ctx.state.messages.append(.system("Running low on context. Be concise."))
    }
```

### Decision: iter() Ignores requiresApproval But Exposes It

**Context:** Tools can have `requiresApproval: true` flag. How does `iter()` handle this?

**Decision:** `iter()` ignores the flag for execution behavior (no auto-deferral), but exposes it in `PendingToolDecision` so users can implement their own approval logic.

**API:**
```swift
public struct PendingToolDecision: Codable, Sendable {
    public let call: ToolCall
    public let requiresApproval: Bool  // From tool definition
    public var decision: Decision
    // ...
}
```

**Usage:**
```swift
case .beforeTools(let ctx):
    for pending in ctx.pendingCalls {
        if pending.requiresApproval {
            // Implement custom approval logic
            if await getUserApproval(pending.call) {
                ctx.approve(pending.call)
            } else {
                ctx.deny(pending.call, message: "User declined")
            }
        }
    }
```

**Rationale:**
- `iter()` is for manual control — user decides everything
- `requiresApproval` is a convenience for `run()`/`runStream()` (triggers deferral)
- Exposing the flag lets users build their own approval workflows

### Decision: Per-Tool Timeout

**Context:** Should timeout be global (engine-level) or per-tool?

**Decision:** Per-tool timeout with engine default as fallback.

**Rationale:**
- Different tools have vastly different execution profiles
- Database lookup: milliseconds
- API call: seconds
- Agent-to-agent call: minutes
- A single global timeout cannot accommodate this range
- Tools know their expected duration better than the engine

**Implementation:**
```swift
let effectiveTimeout = tool.timeout ?? engine.defaultTimeout ?? nil
```

### Decision: Configurable Execution Strategy (Sequential vs Parallel)

**Context:** Should tools execute one-at-a-time or concurrently?

**Decision:** Configurable via `ExecutionStrategy` enum. The engine should not force either approach.

**Options:**
- `.sequential` — One tool at a time, in order
- `.parallel` — All tools concurrently via TaskGroup
- `.parallelLimit(N)` — Up to N concurrent tools

**Rationale:**
- Some use cases need deterministic ordering (debugging, logging)
- Some use cases benefit from parallelism (independent API calls)
- Agent-to-agent scenarios may need limited parallelism (resource constraints)
- Design should not prevent either approach

**Default:** `.parallel` for maximum throughput, since tool results are sorted back to original order anyway.

### Decision: Tool Failures Are Results, Not Exceptions

**Context:** When a tool fails (timeout, error, invalid args), should the engine throw or return a failure result?

**Decision:** Tool failures return `.failure(error)` results. Only truly catastrophic failures (cancellation, system errors) throw.

**Rationale:**
- Tool errors are expected and recoverable — the LLM can adapt
- Passing errors as results keeps the agent loop running
- The LLM receives error context and can try a different approach
- Throwing would abort the entire batch, losing partial progress
- This matches the principle that errors are data, not exceptions

**What throws:**
- `CancellationError` — Task was cancelled, must propagate
- System failures (OOM, etc.) — Truly unrecoverable

**What returns as `.failure`:**
- Tool not found
- Argument parsing/validation errors
- Tool execution errors
- Timeouts

---

## Document History

| Date | Change |
|------|--------|
| 2026-02-04 | Initial comprehensive design based on research discussion |
| 2026-02-04 | Added execution timing, mutation rules, layer separation clarifications |
| 2026-02-04 | Added ToolExecutionEngine integration: per-tool timeout, execution strategies, failure behavior, integration flow |
| 2026-02-04 | Added atomic state transitions, error-with-state pattern, cancellation is now resumable |
