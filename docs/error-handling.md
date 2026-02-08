# Error Handling

Yrden uses a layered error hierarchy. Each layer corresponds to a different level of the stack, from network/provider issues up to agent orchestration. All errors are `Sendable` and provide descriptive messages.

## Error Hierarchy

```
LLMError                    Provider / network level
  |
AgentError<Output>          Agent orchestration level
  |
ToolExecutionError          Tool execution level
StructuredOutputError       Structured output parsing level
```

### 1. LLMError -- Provider Level

Errors from the LLM provider (network failures, authentication, rate limits). These are thrown by `Model` implementations and may be retried automatically via `RetryConfig`.

```swift
public enum LLMError: Error {
    case rateLimited(retryAfter: TimeInterval?)
    case invalidAPIKey
    case contentFiltered(reason: String)
    case modelNotFound(String)
    case invalidRequest(String)
    case contextLengthExceeded(maxTokens: Int)
    case capabilityNotSupported(String)
    case networkError(String)
    case decodingError(String)
    case serverError(String)
}
```

**Handling example:**
```swift
do {
    let response = try await model.complete(request)
} catch let error as LLMError {
    switch error {
    case .rateLimited(let retryAfter):
        if let delay = retryAfter {
            try await Task.sleep(for: .seconds(delay))
        }
        // retry...
    case .contextLengthExceeded(let maxTokens):
        print("Context too long, max tokens: \(maxTokens)")
    case .invalidAPIKey:
        print("Check your API key")
    default:
        print("Provider error: \(error)")
    }
}
```

### 2. AgentError -- Orchestration Level

Errors from the agent loop. `AgentError` is generic over the output type (`AgentError<Output>`) because some variants carry `IterationState<Output>` or `AgentRun<Output>`.

#### Resumable Errors (carry IterationState)

These errors include the full iteration state, allowing you to resume execution with `agent.iter(from: state)`:

```swift
case cancelled(state: IterationState<Output>, during: CancelledOperation)
case modelError(state: IterationState<Output>, underlying: Error)
case modelRefusal(state: IterationState<Output>, refusal: String)
case validationFailed(state: IterationState<Output>, output: Output?, message: String)
case toolError(state: IterationState<Output>, toolName: String, underlying: Error)
case maxIterationsReached(state: IterationState<Output>)
case usageLimitExceeded(state: IterationState<Output>, limit: UsageLimit)
```

You can check if an error is resumable and extract its state:

```swift
if error.isResumable, let state = error.state {
    // Resume from this state
    for try await node in agent.iter(from: state) { ... }
}
```

#### Non-Resumable Errors

These indicate bugs or configuration problems. No valid state exists:

```swift
case internalError(String)
case invalidConfiguration(String)
```

#### run() API Errors

These carry `AgentRun<Output>` (not raw state) for convenient use with `resume()`:

```swift
case needsApproval(AgentRun<Output>)
case iterationLimitReached(AgentRun<Output>)
case usageLimitReached(AgentRun<Output>)
case invalidResume(String)
```

These are thrown by `AgentRun.result()` when the run stopped for a non-error reason (approval needed, limit reached). They let you use the simple throw-on-pause pattern:

```swift
do {
    let output = try await agent.run("Task").result()
} catch let error as AgentError<MyOutput> {
    switch error {
    case .needsApproval(let run):
        // Resume with decisions
        let continued = try await agent.resume(from: run, with: .approveAll(from: run))
    case .iterationLimitReached(let run):
        let continued = try await agent.resume(from: run, with: .additionalIterations(10))
    case .usageLimitReached(let run):
        print("Usage limit: cannot resume. Start a new run with continuingFrom:")
    default:
        print("Error: \(error)")
    }
}
```

### 3. ToolExecutionError -- Tool Level

Errors during tool execution. These are sent back to the model as error messages so it can adjust its approach:

```swift
public enum ToolExecutionError: Error {
    case custom(String)
    case argumentParsing(String)
    case argumentValidation(String)
    case toolNotFound(String)
}
```

When a tool throws `ToolExecutionError`, the agent wraps it in `AgentError.toolError` with the full state for recovery.

### 4. StructuredOutputError -- Parsing Level

Errors when extracting typed structured output from LLM responses. These occur after a successful API call but before the output can be used:

```swift
public enum StructuredOutputError: Error {
    case modelRefused(reason: String)
    case emptyResponse
    case unexpectedTextResponse(content: String)
    case unexpectedToolCall(toolName: String)
    case decodingFailed(json: String, underlyingError: Error)
    case incompleteResponse(partialJSON: String)
}
```

**Handling example:**
```swift
do {
    let result = try await model.generate(prompt, as: PersonInfo.self)
} catch let error as StructuredOutputError {
    switch error {
    case .modelRefused(let reason):
        print("Model refused: \(reason)")
    case .decodingFailed(let json, _):
        print("Failed to decode: \(json.prefix(200))")
    case .incompleteResponse(let partial):
        print("Response truncated: \(partial.suffix(100))")
    default:
        print("Structured output error: \(error)")
    }
}
```

## Supporting Error Types

### CancelledOperation

When an agent run is cancelled, the error includes what operation was in progress:

```swift
public enum CancelledOperation {
    case modelCall
    case toolExecution(completed: [ToolCallResult], pending: [ToolCall])
    case streaming(tokensReceived: Int)
    case phaseTransition
}
```

This lets you understand how much work completed before cancellation. For example, if cancelled during tool execution, `completed` tells you which tools finished and `pending` tells you which were still queued.

### ResponseUnusable

The model returned a response, but it cannot be used to continue the agent loop. Used as the `underlying` error in `AgentError.modelError`:

```swift
public enum ResponseUnusable: Error {
    case maxTokensReached(partialContent: String?)
    case contentFiltered
    case emptyResponse
}
```

### ToolTimeoutError

A tool exceeded its timeout. Used as the `underlying` error in `AgentError.toolError`:

```swift
public struct ToolTimeoutError: Error {
    let toolName: String
    let timeout: Duration
}

// Example: tool "search" timed out after 30 seconds
ToolTimeoutError(toolName: "search", timeout: .seconds(30))
```

### UsageLimit

Describes which specific limit was exceeded:

```swift
public enum UsageLimit {
    case inputTokens(used: Int, limit: Int)
    case outputTokens(used: Int, limit: Int)
    case totalTokens(used: Int, limit: Int)
    case requests(used: Int, limit: Int)
    case toolCalls(used: Int, limit: Int)
}
```

`UsageLimit` conforms to `CustomStringConvertible`, so you can print it directly:
```swift
print(limit) // "Total tokens: 10500/10000"
```

## Error Handling Patterns

### Pattern 1: Simple (throw on pause)

Use `.result()` to get the output or throw. Best for scripts and simple applications:

```swift
let output = try await agent.run("Summarize this document").result()
```

### Pattern 2: Switch on Status

Check `run.status` for all possible outcomes. Best for applications that handle pauses gracefully:

```swift
let run = try await agent.run("Analyze data")

switch run.status {
case .completed(let output):
    return output
case .needsApproval(let pending):
    // show UI for approval
case .iterationLimitReached:
    // offer to continue
case .usageLimitReached(let limit):
    // show budget message
}
```

### Pattern 3: iter() with Error Recovery

Catch errors from the iterator and resume from state:

```swift
do {
    for try await node in agent.iter("Complex task") {
        if case .finished(let ctx) = node {
            return ctx.output
        }
    }
} catch let error as AgentError<MyOutput> {
    switch error {
    case .modelError(let state, let underlying):
        print("Model failed: \(underlying)")
        // Retry from the same state
        for try await node in agent.iter(from: state) {
            if case .finished(let ctx) = node { return ctx.output }
        }

    case .toolError(let state, let toolName, let underlying):
        print("Tool '\(toolName)' failed: \(underlying)")
        // Could modify state and retry

    case .usageLimitExceeded(let state, let limit):
        print("Hit \(limit) at iteration \(state.iteration)")

    case .cancelled(let state, let during):
        print("Cancelled during \(during)")

    default:
        throw error
    }
}
```

## HTTP Retry

Provider-level transient errors (429 rate limits, 5xx server errors) are retried automatically by `RetryConfig`. This is configured per model, not per agent:

```swift
let config = RetryConfig(
    maxRetries: 3,
    initialDelay: 0.5,
    maxDelay: 30,
    jitterFactor: 0.25
)

let model = OpenAIModel(
    name: "gpt-4o",
    provider: provider,
    retryConfig: config
)
```

Retriable HTTP status codes:
- **408** Request Timeout
- **409** Conflict (lock timeout)
- **429** Rate Limited
- **500+** Server Errors

The retry uses exponential backoff with jitter. If the server provides a `Retry-After` header, that value is respected (up to 60 seconds).

Built-in presets:
- `RetryConfig.default` -- 2 retries, 0.5s initial delay
- `RetryConfig.none` -- no retries
- `RetryConfig.aggressive` -- 5 retries, 1s initial delay, 60s max

Non-retriable errors (authentication, invalid request, context length exceeded) are thrown immediately without retry.

## Error Flow Summary

```
HTTP request fails (transient)
  -> RetryConfig retries automatically
  -> If exhausted: LLMError thrown

HTTP request fails (permanent)
  -> LLMError thrown immediately

Model responds but unusable
  -> ResponseUnusable wrapped in AgentError.modelError

Model refuses (safety)
  -> AgentError.modelRefusal with state

Tool fails
  -> AgentError.toolError with state

Tool times out
  -> ToolTimeoutError wrapped in AgentError.toolError

Output validation fails
  -> AgentError.validationFailed with state

Iteration limit reached
  -> AgentRun.status == .iterationLimitReached (run API)
  -> AgentError.maxIterationsReached (iter API)

Usage limit reached
  -> AgentRun.status == .usageLimitReached (run API)
  -> AgentError.usageLimitExceeded (iter API)

Structured output parsing fails
  -> StructuredOutputError thrown
```
