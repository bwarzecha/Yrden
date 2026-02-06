# Error Handling Design

> **Core principle:** Every error carries state. Customer handles errors via `iter()` API and resumes from state.

---

## 1. Error Categories

| Category | Source | Examples |
|----------|--------|----------|
| **Tool Errors** | Tool execution | Argument invalid, execution failed, timeout |
| **Model Errors** | LLM provider | Network, auth, rate limit, content filter, capacity |
| **Orchestration Errors** | Agent loop | Iteration limit, usage limit, cancellation |

---

## 2. Customer Actions

When an error occurs, the customer can:

| Action | How It Works |
|--------|--------------|
| **Let LLM handle** | Don't catch error - default behavior sends tool errors to LLM |
| **Retry same** | Resume from state, no changes |
| **Retry modified** | Resume from state with modified arguments/messages |
| **Switch model** | Resume from state with different model |
| **Abort** | Don't resume, propagate error |

**Key:** All actions except "abort" require resuming from state. The error must carry enough state.

---

## 3. State Requirements Per Error

### 3.1 Tool Errors

For customer to resume after tool error:

| State | Purpose | Current |
|-------|---------|---------|
| Iteration state | Resume loop | ✅ |
| Tool call ID | Identify which call failed | ✅ |
| Tool call in state | Modify args, inject result | ⚠️ Verify accessible |
| Partial output | Use partial work (timeout) | ❌ Missing |

**Resume scenarios:**
```swift
for try await event in agent.iter(prompt, deps: deps) {
    // ...
} catch let error as AgentError<Output> {
    switch error {
    case .toolError(let state, let toolCallID, let underlying):
        // Option 1: Retry same
        try await agent.resume(from: state)

        // Option 2: Retry with modified args
        var modifiedState = state
        modifiedState.modifyToolCall(id: toolCallID) { call in
            call.arguments["limit"] = 10  // Reduce limit
        }
        try await agent.resume(from: modifiedState)

        // Option 3: Skip tool, inject synthetic result
        var modifiedState = state
        modifiedState.injectToolResult(id: toolCallID, result: "[]")
        try await agent.resume(from: modifiedState)
    }
}
```

### 3.2 Model Errors

For customer to resume after model error:

| State | Purpose | Current |
|-------|---------|---------|
| Iteration state | Resume loop | ✅ |
| Messages sent | Retry with different model | ✅ (in state) |
| Retry-after hint | Know how long to wait | ⚠️ In error, not state |

**Resume scenarios:**
```swift
} catch let error as AgentError<Output> {
    switch error {
    case .modelError(let state, let underlying):
        if case .rateLimited(let retryAfter) = underlying as? LLMError {
            // Option 1: Wait and retry same model
            try await Task.sleep(for: retryAfter ?? .seconds(60))
            try await agent.resume(from: state)
        }

        if case .contextLengthExceeded = underlying as? LLMError {
            // Option 2: Switch to model with larger context
            let biggerAgent = Agent(model: claude100k, ...)
            try await biggerAgent.resume(from: state)
        }
    }
}
```

### 3.3 Orchestration Errors

For customer to resume after orchestration error:

| State | Purpose | Current |
|-------|---------|---------|
| Iteration state | Resume loop | ✅ |
| Current usage | Decide if can continue | ✅ |
| Limit that was hit | Know what to adjust | ✅ |

**Resume scenarios:**
```swift
} catch let error as AgentError<Output> {
    case .iterationLimitReached(let run):
        // Option 1: Continue with extended limit
        try await run.continueExecution(additionalIterations: 10)

        // Option 2: Switch to cheaper model
        let cheaperAgent = Agent(model: haiku, ...)
        try await cheaperAgent.resume(from: run.state)

    case .usageLimitReached(let run):
        // Switch to cheaper model
        let cheaperAgent = Agent(model: haiku, ...)
        try await cheaperAgent.resume(from: run.state)
}
```

---

## 4. Gap Analysis

### 4.1 What's Missing in Errors

| Gap | Blocks | Fix |
|-----|--------|-----|
| Tool call not accessible in state | "Retry modified" action | Ensure state exposes tool call by ID |
| Partial output not tracked | Using partial work on timeout | Add `partialOutput: String?` to timeout |

### 4.2 What's Missing in Resume API

| Gap | Blocks | Fix |
|-----|--------|-----|
| Can't resume with different model | "Switch model" action | `agent.resume(from:)` or `otherAgent.resume(from:)` |
| Can't modify tool call by ID | "Retry modified" action | `state.modifyToolCall(id:)` |
| Can't inject synthetic tool result | "Skip tool" action | `state.injectToolResult(id:)` |

### 4.3 Design Questions

1. **How to resume with different model?**
   - Option A: `agent.resume(from: state, model: newModel)`
   - Option B: Create new agent, call `newAgent.resume(from: state)`
   - Recommendation: Option B - cleaner, no special API

2. **How to modify state before resume?**
   - State needs to be mutable or have modifier methods
   - `state.modifyPendingToolCall()`, `state.injectToolResult()`
   - Or: State is value type, customer creates modified copy

3. **Should tool errors throw by default?**
   - Current: Tool errors become tool results (sent to LLM)
   - This is good default - LLM can often recover
   - Customer can check tool results in iterator if they want to intercept

---

## 5. Proposed Changes

### 5.1 Ensure Tool Call Accessible in State

```swift
// Error carries tool call ID
case toolError(state: IterationState<Output>, toolCallID: ToolCallID, underlying: Error)

// State must allow accessing/modifying tool call by ID
// IterationState needs: func toolCall(id: ToolCallID) -> ToolCall?
```

### 5.2 Add State Modification Methods

```swift
extension IterationState {
    /// Modify arguments for a pending tool call before resume
    mutating func modifyToolCall(
        id: ToolCallID,
        modify: (inout ToolCall) -> Void
    )

    /// Inject a synthetic result for a tool call, skipping execution
    mutating func injectToolResult(
        id: ToolCallID,
        result: String
    )

    /// Remove a pending tool call (skip it entirely)
    mutating func removeToolCall(id: ToolCallID)
}
```

### 5.3 Resume with Different Agent

```swift
// Already works if state is model-agnostic
let cheaperAgent = Agent(model: haiku, tools: tools)
let result = try await cheaperAgent.resume(from: state)
```

**Question:** Is `IterationState` model-agnostic? Does it contain model-specific data (like Anthropic cache IDs)?

---

## 6. Summary

| Requirement | Status | Action |
|-------------|--------|--------|
| Every error carries state | ✅ | - |
| Error includes tool call ID | ✅ | - |
| State exposes tool call by ID | ⚠️ | Verify accessible for modification |
| State includes partial output | ❌ | Add for timeout case |
| Can resume from state | ✅ | - |
| Can resume with different model | ⚠️ | Verify state is model-agnostic |
| Can modify state before resume | ❌ | Add `modifyToolCall(id:)` etc. |

**No hooks needed.** Error handling happens via:
1. Catch error from `iter()`
2. Inspect state in error
3. Optionally modify state
4. Resume from (modified) state

---

## Appendix A: Tool Error Catalog

### A.1 Local Function Tools

| Error Type | Recoverable | LLM Can Retry | Notes |
|------------|-------------|---------------|-------|
| **Argument Parsing** | | | |
| Invalid JSON syntax | No | No | LLM produced malformed JSON |
| Type mismatch | Yes | Yes | Wrong type for field |
| Missing required field | Yes | Yes | Field absent |
| Value out of range | Yes | Yes | Constraint violated |
| **Execution** | | | |
| Tool threw error | Yes | Depends | Business logic failure |
| Assertion/crash | No | No | Bug in tool |
| Dependency unavailable | Yes | Yes | External service down |
| **Timeout** | | | |
| Exceeded timeout | Partial | Maybe | May have partial output |
| Hung indefinitely | No | Maybe | Needs kill |
| Blocked on I/O | Partial | Maybe | Waiting for external |
| **Resources** | | | |
| Memory exhaustion | No | No | Process may crash |
| File descriptor exhaustion | Partial | Later | Retry after cleanup |

### A.2 MCP Tools (Separate Process)

| Error Type | Recoverable | LLM Can Retry | Notes |
|------------|-------------|---------------|-------|
| **Process** | | | |
| Spawn failed | No | No | Config error |
| Process crashed | Partial | Yes | Reconnect and retry |
| Process OOM killed | Partial | Yes | Reconnect and retry |
| Pipe broken | Yes | Yes | Reconnect |
| **Protocol** | | | |
| Invalid JSON-RPC | Partial | Maybe | Protocol error |
| Unknown method | No | No | Tool doesn't exist |
| Version mismatch | No | No | Incompatible server |
| **Execution** | | | |
| Tool returned error | Yes | Yes | Server reported failure |
| Server disconnected mid-call | Partial | Yes | Reconnect, maybe retry |
| Response too large | Partial | Maybe | May need to limit |

### A.3 HTTP/Remote Tools

| Error Type | Recoverable | LLM Can Retry | Notes |
|------------|-------------|---------------|-------|
| **Network** | | | |
| DNS failure | Yes | Yes | Retry with backoff |
| Connection refused | Yes | Yes | Service may be down |
| Connection timeout | Yes | Yes | Retry or increase timeout |
| TLS error | Maybe | No | Certificate issue |
| **HTTP Status** | | | |
| 400 Bad Request | Maybe | Yes | Fix request |
| 401 Unauthorized | No | No | Auth config error |
| 403 Forbidden | No | No | Permission error |
| 404 Not Found | No | No | Wrong endpoint |
| 408 Request Timeout | Yes | Yes | Retry |
| 429 Rate Limited | Yes | Yes | Retry after delay |
| 5xx Server Error | Yes | Yes | Retry with backoff |

---

## Appendix B: Model Error Catalog

### B.1 By Error Type

| Error Type | Retryable | Switch Model | Notes |
|------------|-----------|--------------|-------|
| **Network** | | | |
| Connection failed | Yes | Yes | Retry with backoff |
| Request timeout | Yes | Yes | Retry or switch |
| **Auth** | | | |
| Invalid API key | No | No | Config error |
| Expired token | No | No | Refresh needed |
| Insufficient permissions | No | No | Config error |
| **Rate Limiting** | | | |
| Rate limited | Yes | Yes | Respect Retry-After |
| Quota exceeded | No | Yes | Billing issue |
| **Content** | | | |
| Input filtered | No | Maybe | Modify input |
| Output filtered | Yes | Maybe | Retry with rephrasing |
| **Capacity** | | | |
| Context too long | No | Yes | Switch to larger model |
| Max tokens reached | Yes | Maybe | Increase limit or continue |
| **Service** | | | |
| Server error (5xx) | Yes | Yes | Retry with backoff |
| Service unavailable | Yes | Yes | Retry or switch |
| Model not found | No | Yes | Wrong model ID |

### B.2 By Provider

| Provider | Rate Limit | Context Limit | Notable Quirks |
|----------|------------|---------------|----------------|
| **Anthropic** | 429 + Retry-After | 200K | Requires message alternation |
| **OpenAI** | 429 + Retry-After | 128K (GPT-4o) | o1 models: no streaming, no tools |
| **AWS Bedrock** | ThrottlingException | Model-dependent | IAM auth, region-specific |
| **Azure OpenAI** | 429 + Retry-After | Same as OpenAI | Deployment names, aggressive filtering |
| **Google Vertex** | 429 | 2M (Gemini 1.5) | Different safety settings |
| **OpenRouter** | 429 | Model-dependent | Aggregated limits, provider routing |

---

## Appendix C: Orchestration Error Catalog

| Error Type | Carries State | Resume Options |
|------------|---------------|----------------|
| **Iteration limit** | Yes | Continue with more iterations, switch model |
| **Usage limit (tokens)** | Yes | Switch to cheaper model |
| **Usage limit (requests)** | Yes | Switch model, wait |
| **Cancellation** | Yes | Resume if desired |
| **Approval required** | Yes | Approve and continue, deny and skip |
