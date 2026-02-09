# Yrden Code Consolidation: Issue Deep Dive

> This document explains each consolidation issue in detail, with full code references, root cause analysis, and success criteria.

---

## Table of Contents

1. [Issue 1: Agent Loop Triple Duplication](#issue-1-agent-loop-triple-duplication)
2. [Issue 2: ToolOutput JSON Encoding Duplication](#issue-2-tooloutput-json-encoding-duplication)
3. [Issue 3: ToolCallAccumulator Duplication](#issue-3-toolcallaccumulator-duplication)
4. [Issue 4: Retry Infrastructure Inconsistency](#issue-4-retry-infrastructure-inconsistency)
5. [Issue 5: Bedrock Empty Stream Workaround](#issue-5-bedrock-empty-stream-workaround)
6. [Issue 6: StopReason Mapping Duplication](#issue-6-stopreason-mapping-duplication)
7. [Issue 7: HTTPClient.handleCommonStatus Unused](#issue-7-httpclienthandlecommonstatus-unused)

---

## Issue 1: Agent Loop Triple Duplication

### Priority: HIGH

### Problem Statement

The agent execution loop is implemented three times with ~90% identical control flow:

| Method | Location | Lines | Purpose |
|--------|----------|-------|---------|
| `runLoop()` | Agent.swift:575-647 | 72 | Canonical loop with observer pattern |
| `runStreamInternal()` | Agent.swift:164-223 | 59 | Streaming variant |
| `resume()` | Agent.swift:397-506 | 109 | Resume after deferral |

### Root Cause

The observer pattern was introduced in `runLoop()` to abstract event dispatch, but:
1. `runStreamInternal()` was written before/separately and uses direct `continuation.yield()`
2. `resume()` was added later for deferral support without reusing `runLoop()`
3. `StreamingLoopObserver` exists (Agent.swift:145-184) but is **never instantiated**

### Detailed Code Analysis

**Common skeleton shared by all three:**

```swift
while state.requestCount < maxIterations {
    // 1. Pre-call checks
    try checkCancellation()
    try checkUsageLimits(state: state)

    // 2. Build and send request
    let request = buildRequest(state: state, ...)
    let response = try await [completeWithRetry|streamModelResponse](request, ...)

    // 3. Update state
    state.requestCount += 1
    state.accumulateUsage(response.usage)
    state.addResponse(response)

    // 4. Handle response
    let action = try await handleModelResponse(response: response, state: &state, ...)

    // 5. Act on result
    switch action {
    case .returnOutput(let output):
        return [result]
    case .continueLoop:
        continue
    }
}
throw AgentError.maxIterationsReached(maxIterations)
```

**Differences:**

| Aspect | runLoop() | runStreamInternal() | resume() |
|--------|-----------|---------------------|----------|
| Model call | `completeWithRetry()` | `streamModelResponse()` | `completeWithRetry()` |
| Event dispatch | Observer callbacks | Direct `continuation.yield()` | None |
| Pre-loop setup | Create fresh RunState | Create fresh RunState | Restore from PausedAgentRun |
| Tool callbacks | 3 callbacks passed | 1 callback passed | No callbacks |

**The unused StreamingLoopObserver:**

```swift
// Agent.swift:145-184 - EXISTS BUT NEVER USED
private struct StreamingLoopObserver<Deps: Sendable, Output: SchemaType>: AgentLoopObserver {
    let continuation: AsyncThrowingStream<StreamEvent<Output>, Error>.Continuation

    func onLoopStart(prompt: String) { }
    func onBeforeModelCall(request: CompletionRequest) { }
    func onModelResponse(response: CompletionResponse, cumulativeUsage: Usage) {
        continuation.yield(.usage(cumulativeUsage))
    }
    // ... other methods that yield to continuation
}
```

This observer was designed to make `runStreamInternal()` unnecessary, but was never connected.

### Why This Matters

1. **Bug fixes need 3 places** - Any change to loop logic must be applied thrice
2. **Feature additions are fragmented** - New events need implementation in all variants
3. **Testing is incomplete** - Each path may have subtly different behavior
4. **Cognitive load** - Developers must understand 3 implementations

### Success Criteria

**MUST achieve:**
- [ ] Single loop implementation that all execution modes use
- [ ] `runStreamInternal()` reduced to: setup + call `runLoop()` with observer
- [ ] `resume()` reduced to: resolve tools + call `runLoop()` with observer
- [ ] Zero duplication of the while-loop structure
- [ ] All existing tests pass without modification

**MUST NOT:**
- [ ] Add adapter layers that translate between loop variants
- [ ] Create "mode" flags that branch inside the loop
- [ ] Duplicate observer callback logic

**Measurement:**
- Before: 240 lines across 3 methods (72 + 59 + 109)
- After: ~100 lines in single method + ~30 lines per variant for setup
- Net reduction: ~80 lines minimum

### Solution Approach

1. Fix `StreamingLoopObserver` to properly yield all events
2. Make `runStreamInternal()` call `runLoop(observer: StreamingLoopObserver(continuation))`
3. Make `resume()` resolve deferred tools upfront, then call `runLoop()`
4. Remove duplicated loop code from both methods

### Open Questions

- Does `streamModelResponse()` need to exist separately, or can streaming be handled purely through observer?
- What events does `StreamingLoopObserver` currently miss?

---

## Issue 2: ToolOutput JSON Encoding Duplication

### Priority: MEDIUM

### Problem Statement

The exact same JSON encoding logic appears in 3 providers:

```swift
content = (try? String(data: JSONEncoder().encode(json), encoding: .utf8)) ?? "{}"
```

### Locations

| Provider | File | Line |
|----------|------|------|
| Anthropic | AnthropicModel.swift | 163 |
| OpenAI | OpenAIModel.swift | 278 |
| Bedrock | BedrockModel.swift | 233 |

### Root Cause

When implementing tool result handling, each provider needed to serialize `JSONValue` to a string. The pattern was copy-pasted rather than extracted.

### Detailed Code Analysis

**Anthropic (AnthropicModel.swift:157-170):**
```swift
case .toolResults(let results):
    let blocks = results.map { entry -> AnthropicContentBlock in
        let content: String
        let isError: Bool
        switch entry.output {
        case .text(let text):
            content = text
            isError = false
        case .json(let json):
            content = (try? String(data: JSONEncoder().encode(json), encoding: .utf8)) ?? "{}"  // HERE
            isError = false
        case .error(let message):
            content = message
            isError = true
        }
        return .toolResult(toolUseId: entry.id, content: content, isError: isError)
    }
```

**OpenAI (OpenAIModel.swift:274-286):**
```swift
case .toolResults(let results):
    return results.map { entry in
        let content: String
        switch entry.output {
        case .text(let text):
            content = text
        case .json(let json):
            content = (try? String(data: JSONEncoder().encode(json), encoding: .utf8)) ?? "{}"  // HERE
        case .error(let message):
            content = "Error: \(message)"  // Note: Different error format!
        }
        return OpenAIMessage(role: MessageRole.tool, content: .text(content), tool_call_id: entry.id)
    }
```

**Bedrock (BedrockModel.swift:225-244):**
```swift
case .toolResults(let results):
    let blocks = results.map { entry -> BedrockRuntimeClientTypes.ContentBlock in
        let content: String
        let status: BedrockRuntimeClientTypes.ToolResultStatus?
        switch entry.output {
        case .text(let text):
            content = text
            status = nil
        case .json(let json):
            content = (try? String(data: JSONEncoder().encode(json), encoding: .utf8)) ?? "{}"  // HERE
            status = nil
        case .error(let message):
            content = message
            status = .error
        }
        // ...
    }
```

### Why NOT Full Extraction

The `.text` and `.error` cases differ by provider:
- **Anthropic**: Uses `isError: Bool` flag
- **OpenAI**: Prefixes error with `"Error: "`
- **Bedrock**: Uses `status: .error` enum

Only the `.json` case is truly identical.

### Success Criteria

**MUST achieve:**
- [ ] Single location for JSON encoding logic
- [ ] Helper is simple property/method, not a complex abstraction
- [ ] Providers use the helper directly without adapters

**MUST NOT:**
- [ ] Create protocol/inheritance hierarchy for ToolOutput conversion
- [ ] Force unified error handling (providers legitimately differ)
- [ ] Add parameters to handle provider-specific cases

**Measurement:**
- Before: 3 copies of identical encoding logic
- After: 1 helper + 3 call sites
- Encoding logic in exactly 1 place

### Solution Approach

Add computed property to `ToolOutput` in Tool.swift:

```swift
extension ToolOutput {
    /// Returns JSON string representation for .json case, nil otherwise
    var jsonString: String? {
        guard case .json(let json) = self else { return nil }
        return (try? String(data: JSONEncoder().encode(json), encoding: .utf8)) ?? "{}"
    }
}
```

Provider usage:
```swift
case .json:
    content = entry.output.jsonString ?? "{}"
```

---

## Issue 3: ToolCallAccumulator Duplication

### Priority: MEDIUM

### Problem Statement

Two nearly identical structs for accumulating streaming tool calls:

**Anthropic (AnthropicModel.swift:464-469):**
```swift
private struct ToolCallAccumulator {
    let id: String
    let name: String
    let blockIndex: Int
    var arguments: String = ""
}
```

**OpenAI (OpenAIModel.swift:958-964):**
```swift
private struct ToolCallAccumulator {
    var id: String = ""
    var name: String = ""
    var arguments: String = ""
    var started: Bool = false
    var ended: Bool = false
}
```

### Root Cause

Streaming tool call accumulation was implemented independently for each provider. The core need (accumulate id, name, arguments) is identical, but tracking metadata differs.

### Detailed Analysis

**Core fields (identical purpose):**
- `id: String` - Tool call identifier
- `name: String` - Tool name
- `arguments: String` - Accumulated JSON arguments

**Provider-specific fields:**
- Anthropic's `blockIndex: Int` - Tracks position in content blocks array
- OpenAI's `started/ended: Bool` - Tracks lifecycle state

**Usage pattern (both providers):**
```swift
// On tool call start
accumulators.append(ToolCallAccumulator(id: id, name: name, ...))

// On arguments delta
accumulators[index].arguments += delta

// On completion
let toolCalls = accumulators.map { ToolCall(id: $0.id, name: $0.name, arguments: $0.arguments) }
```

### Success Criteria

**MUST achieve:**
- [ ] Single struct definition shared by both providers
- [ ] Provider-specific fields are optional or handled cleanly
- [ ] No runtime cost for unused fields

**MUST NOT:**
- [ ] Create inheritance hierarchy (Accumulator -> AnthropicAccumulator)
- [ ] Use generics with associated types for metadata
- [ ] Add protocol conformance complexity

**Measurement:**
- Before: 2 struct definitions (~15 lines each)
- After: 1 struct definition (~15 lines)
- Both providers import and use same type

### Solution Approach

Create shared struct in new file `Sources/Yrden/Providers/StreamingHelpers.swift`:

```swift
/// Accumulates streaming tool call data across chunks
struct ToolCallAccumulator {
    var id: String = ""
    var name: String = ""
    var arguments: String = ""

    // Lifecycle tracking (used by OpenAI)
    var started: Bool = false
    var ended: Bool = false

    // Position tracking (used by Anthropic)
    var index: Int = 0

    mutating func appendArguments(_ delta: String) {
        arguments += delta
    }

    func toToolCall() -> ToolCall? {
        guard !id.isEmpty, !name.isEmpty else { return nil }
        return ToolCall(id: id, name: name, arguments: arguments)
    }
}
```

The unused fields (e.g., `started` in Anthropic) have negligible cost (Bool = 1 byte).

---

## Issue 4: Retry Infrastructure Inconsistency

### Priority: MEDIUM-HIGH

### Problem Statement

Retry infrastructure exists but only OpenAI uses it:

| Provider | Uses RetryConfig | Retries 429 | Retries 500+ | Parses Retry-After |
|----------|-----------------|-------------|--------------|-------------------|
| OpenAI | Yes | Yes | Yes | Yes |
| Anthropic | **No** | Partial | No | No |
| Bedrock | **No** | Via SDK? | No | No |

### Root Cause

OpenAI implementation followed Python SDK patterns which include comprehensive retry. Anthropic was implemented earlier/simpler. Bedrock delegates to AWS SDK.

### Detailed Analysis

**RetryConfig definition (Retry.swift:25-65):**
```swift
public struct RetryConfig: Sendable {
    public let maxRetries: Int
    public let baseDelay: Duration
    public let maxDelay: Duration
    public let retriableStatusCodes: Set<Int>  // Default: [408, 409, 429, 500, 502, 503, 504]

    public func execute<T>(_ operation: () async throws -> T) async throws -> T {
        // Exponential backoff with jitter
    }
}
```

**OpenAI usage (OpenAIModel.swift:74, 94):**
```swift
func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
    try await retryConfig.execute {
        try await completeInternal(request)
    }
}
```

**Anthropic handling (AnthropicModel.swift:282-304):**
```swift
private func handleHTTPStatus(_ statusCode: Int, data: Data) throws {
    switch statusCode {
    case 200..<300: return
    case 401: throw LLMError.invalidAPIKey
    case 429: throw LLMError.rateLimited(retryAfter: nil)  // No retry, no Retry-After parsing!
    case 400: throw LLMError.invalidRequest(parseErrorMessage(data))
    case 404: throw LLMError.modelNotFound(name)
    default: throw LLMError.networkError("HTTP \(statusCode): \(parseErrorMessage(data))")
    }
}
```

**What Anthropic misses:**
1. No automatic retry on 429 (rate limit)
2. No retry on 500+ (server errors)
3. No parsing of `Retry-After` header
4. No exponential backoff

### Why This Matters

Production reliability. Rate limits happen. Server errors happen. Without retry:
- Users see errors for transient issues
- Application must implement retry at higher level
- Inconsistent behavior between providers

### Success Criteria

**MUST achieve:**
- [ ] Anthropic uses RetryConfig like OpenAI does
- [ ] Both providers parse Retry-After header for 429
- [ ] Same set of status codes trigger retry
- [ ] Configuration is optional (can disable retry)

**MUST NOT:**
- [ ] Force retry on Bedrock (SDK may already retry)
- [ ] Change retry behavior for existing OpenAI users
- [ ] Add retry middleware that wraps all providers

**Measurement:**
- Anthropic handles 429 with backoff: Yes/No
- Anthropic handles 500+ with retry: Yes/No
- Both providers respect Retry-After: Yes/No

### Solution Approach

1. Add `retryConfig: RetryConfig?` parameter to `AnthropicModel.init()`
2. Wrap `completeInternal()` and `streamInternal()` in `retryConfig?.execute {}`
3. Parse Retry-After header in `handleHTTPStatus()`
4. Update `AnthropicProvider` to pass default RetryConfig

### Open Questions

- Does Bedrock's AWS SDK already retry internally?
- Should we document expected retry behavior per provider?

---

## Issue 5: Bedrock Empty Stream Workaround

### Priority: MEDIUM

### Problem Statement

Bedrock silently returns empty response when stream is unavailable:

**Location: BedrockModel.swift:372-382**
```swift
guard let stream = output.stream else {
    // No stream available - emit empty done event before finishing
    let emptyResponse = CompletionResponse(
        content: nil,
        toolCalls: [],
        stopReason: .endTurn,
        usage: Usage(inputTokens: 0, outputTokens: 0)
    )
    continuation.yield(.done(emptyResponse))
    continuation.finish()
    return
}
```

### Root Cause

AWS Bedrock's `converseStream()` returns `Optional<Stream>`. When `nil`, instead of failing, the code returns an empty "success" response.

### Why This is Wrong

1. **Silent failure** - Caller thinks request succeeded
2. **Wrong usage data** - Shows 0 tokens when we don't know actual usage
3. **No retry opportunity** - Error would trigger retry; "success" doesn't
4. **Debugging nightmare** - Empty responses with no explanation

### Success Criteria

**MUST achieve:**
- [ ] Stream unavailability throws an error
- [ ] Error message explains what happened
- [ ] Caller can catch and retry if desired

**MUST NOT:**
- [ ] Fall back to non-streaming silently (would be surprising behavior)
- [ ] Add complex recovery logic

**Measurement:**
- `stream == nil` results in: Error thrown (not empty response)

### Solution Approach

Replace silent fallback with error:

```swift
guard let stream = output.stream else {
    throw LLMError.networkError(
        "Bedrock streaming unavailable - converseStream returned nil stream"
    )
}
```

---

## Issue 6: StopReason Mapping Duplication

### Priority: LOW

### Problem Statement

Each provider has its own `mapStopReason()` function with the same pattern:

**Anthropic (AnthropicModel.swift:254-266):**
```swift
private func mapStopReason(_ reason: String?) -> StopReason {
    switch reason {
    case "end_turn": return .endTurn
    case "tool_use": return .toolUse
    case "max_tokens": return .maxTokens
    case "stop_sequence": return .stopSequence
    default: return .endTurn
    }
}
```

**OpenAI (OpenAIModel.swift:356-379):**
```swift
private func mapStopReason(_ reason: String?, content: String? = nil, stopSequences: [String]? = nil) -> StopReason {
    switch reason {
    case "stop":
        if let stopSequences = stopSequences, !stopSequences.isEmpty { return .stopSequence }
        return .endTurn
    case "tool_calls": return .toolUse
    case "length": return .maxTokens
    case "content_filter": return .contentFiltered
    default: return .endTurn
    }
}
```

### Root Cause

Each provider has different stop reason strings from their API. Mapping was implemented inline rather than as StopReason factory methods.

### Success Criteria

**MUST achieve:**
- [ ] Mapping logic lives on `StopReason` type
- [ ] Each provider calls factory method instead of switch
- [ ] Provider-specific strings are constants, not inline literals

**MUST NOT:**
- [ ] Create complex mapping infrastructure
- [ ] Lose provider-specific logic (OpenAI's stopSequences check)

**Measurement:**
- `mapStopReason` methods removed from providers: Yes/No
- Mapping logic in single location (StopReason extension): Yes/No

### Solution Approach

Add to Completion.swift:

```swift
extension StopReason {
    static func from(anthropic reason: String?) -> StopReason {
        switch reason {
        case "end_turn": return .endTurn
        case "tool_use": return .toolUse
        case "max_tokens": return .maxTokens
        case "stop_sequence": return .stopSequence
        default: return .endTurn
        }
    }

    static func from(openAI reason: String?, hasStopSequences: Bool = false) -> StopReason {
        switch reason {
        case "stop": return hasStopSequences ? .stopSequence : .endTurn
        case "tool_calls": return .toolUse
        case "length": return .maxTokens
        case "content_filter": return .contentFiltered
        default: return .endTurn
        }
    }

    static func from(bedrock reason: BedrockStopReason?) -> StopReason {
        // Similar mapping
    }
}
```

---

## Issue 7: HTTPClient.handleCommonStatus Unused

### Priority: LOW (DEFER)

### Problem Statement

`HTTPClient.handleCommonStatus()` exists but no provider uses it.

**Location: HTTPClient.swift:101-120**
```swift
static func handleCommonStatus(
    _ statusCode: Int,
    modelName: String,
    data: Data,
    parseError: (Data) -> String
) throws -> Int? {
    switch statusCode {
    case 200..<300: return nil  // Success
    case 401: throw LLMError.invalidAPIKey
    case 404: throw LLMError.modelNotFound(modelName)
    default: return statusCode  // Provider handles
    }
}
```

### Root Cause

Each provider evolved independently and implemented its own status handling. The shared helper was added later but never integrated.

### Why Defer

1. **Low impact** - Each provider's handling is ~30 lines
2. **Different needs** - OpenAI checks for context length in 400 errors
3. **Forced abstraction** - Making it work for all providers may reduce flexibility
4. **Higher priorities** - Issues 1-5 have more impact

### Success Criteria (When Addressed)

**MUST achieve:**
- [ ] Providers use shared helper for common cases (401, 404)
- [ ] Provider-specific handling remains possible

**MUST NOT:**
- [ ] Force all status handling through single function
- [ ] Lose provider-specific error parsing

### Current Action

Add documentation comment explaining why it's unused:

```swift
/// Common HTTP status handling for LLM providers.
///
/// NOTE: Currently unused. Each provider implements its own handling because:
/// - OpenAI needs special 400 handling for context length errors
/// - Providers have different error response formats
/// - Retry integration differs per provider
///
/// Consider using for new providers or after retry consolidation (Issue 4).
static func handleCommonStatus(...) { ... }
```

---

## Cross-Cutting Concerns

### Testing Strategy

Each issue should be verified with:

1. **Unit tests** - For extracted helpers (ToolOutput.jsonString, StopReason.from)
2. **Integration tests** - Provider tests still pass
3. **Behavioral tests** - Agent loop produces same events as before

### Migration Safety

Changes should be:
- **Incremental** - One issue at a time
- **Reversible** - If tests fail, can roll back
- **Observable** - Log/trace changes for debugging

### Documentation

After each change:
- Update this document with completion status
- Note any deviations from plan
- Record lessons learned
