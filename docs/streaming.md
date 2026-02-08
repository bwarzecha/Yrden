# Streaming

Yrden provides streaming at two levels: **model-level** (raw LLM events) and **agent-level** (orchestrated events including tool execution). Both use Swift's `AsyncThrowingStream` and `for try await` pattern.

## StreamEvent (Model-Level)

`StreamEvent` represents raw events from a single LLM completion call. These are the building blocks -- content deltas, tool call lifecycle events, and a final done signal.

```swift
public enum StreamEvent: Sendable {
    case contentDelta(String, kind: ContentKind = .text)
    case toolCallStart(id: String, name: String)
    case toolCallDelta(argumentsDelta: String)
    case toolCallEnd(id: String)
    case done(CompletionResponse)
}
```

### ContentKind

Differentiates regular text from reasoning/thinking content (Anthropic extended thinking, OpenAI o-series reasoning).

```swift
public enum ContentKind: String, Sendable, Codable {
    case text      // regular visible content
    case thinking  // reasoning/thinking content
}
```

Defaults to `.text` for backward compatibility. Thinking content may be displayed differently in UIs (collapsed, styled, etc.).

### Event Flow Examples

**Text-only response:**
```
contentDelta("Hello")
contentDelta(" world")
contentDelta("!")
done(response)
```

**Tool call response:**
```
toolCallStart(id: "1", name: "search")
toolCallDelta(#"{"query":"#)
toolCallDelta(#""swift"}"#)
toolCallEnd(id: "1")
done(response)
```

**Mixed response (text + tool call):**
```
contentDelta("Let me search...")
toolCallStart(id: "1", name: "search")
toolCallDelta(...)
toolCallEnd(id: "1")
done(response)
```

The `.done` event is always last and contains the full `CompletionResponse` with all content blocks, stop reason, and usage.

### Model-Level Streaming

Use `model.stream()` to get raw streaming events from a single LLM call:

```swift
for try await event in model.stream("Tell me a story") {
    switch event {
    case .contentDelta(let text, let kind):
        if kind == .thinking { print("[thinking] ", terminator: "") }
        print(text, terminator: "")
    case .toolCallStart(_, let name):
        print("\nCalling \(name)...")
    case .toolCallDelta(let argsDelta):
        // Accumulate arguments JSON if needed
        break
    case .toolCallEnd(let id):
        print("Tool call \(id) complete")
    case .done(let response):
        print("\nDone: \(response.stopReason)")
    }
}
```

Model-level streaming is useful when you want direct control over a single LLM call without the agent loop. For most use cases, agent-level streaming is more practical.

## AgentStreamEvent (Agent-Level)

`AgentStreamEvent` wraps the full agent loop -- multiple model calls, tool execution, and final output -- into a single stream. It adds events that model-level streaming does not have: tool results, usage updates, and the finished run.

```swift
public enum AgentStreamEvent<Output: SchemaType>: Sendable {
    case contentDelta(String, kind: ContentKind = .text)
    case toolCallStart(id: String, name: String)
    case toolCallDelta(id: String, delta: String)
    case toolCallEnd(id: String)
    case toolResult(id: String, result: String)
    case usage(Usage)
    case finished(AgentRun<Output>)
}
```

Key differences from `StreamEvent`:

| Event | StreamEvent | AgentStreamEvent |
|-------|-------------|------------------|
| Content deltas | Same | Same |
| Tool call delta | `argumentsDelta:` only | `id:` + `delta:` |
| Tool results | Not present | `.toolResult(id:result:)` |
| Usage updates | Not present | `.usage(Usage)` |
| Completion | `.done(CompletionResponse)` | `.finished(AgentRun<Output>)` |

The `.finished` event is always last. It contains the full `AgentRun` with status (`.completed`, `.needsApproval`, `.iterationLimitReached`, `.usageLimitReached`), messages, usage, and output.

### Agent-Level Streaming

Use `agent.runStream()` to stream the entire agent loop:

```swift
for try await event in agent.runStream("Analyze data") {
    switch event {
    case .contentDelta(let text, _):
        print(text, terminator: "")
    case .toolCallStart(_, let name):
        print("\n[Calling \(name)...]")
    case .toolCallDelta(let id, let delta):
        // Tool argument fragments, useful for progress indication
        break
    case .toolCallEnd(let id):
        break
    case .toolResult(let id, let result):
        print("[Result: \(result.prefix(50))...]")
    case .usage(let usage):
        print("[Tokens: \(usage.totalTokens)]")
    case .finished(let run):
        if let output = run.output {
            print("\nFinal: \(output)")
        }
    }
}
```

### Message History

Pass previous messages to continue a conversation while streaming:

```swift
let run1 = try await agent.run("Hello")
let messages = run1.messages

for try await event in agent.runStream("Follow up", messageHistory: messages) {
    // same event handling as above
}
```

## Resuming a Paused Stream

When an agent run pauses (tools need approval, iteration limit reached), use `resumeStream` to continue with streaming:

```swift
// Initial run pauses for approval
let run = try await agent.run("Delete old files")

if case .needsApproval = run.status {
    // Resume with streaming, approving all pending tool calls
    let stream = agent.resumeStream(from: run, with: .approveAll(from: run))
    for try await event in stream {
        switch event {
        case .contentDelta(let text, _):
            print(text, terminator: "")
        case .toolResult(let id, let result):
            print("[Tool result: \(result.prefix(50))...]")
        case .finished(let run):
            print("\nCompleted: \(run.isCompleted)")
        default:
            break
        }
    }
}
```

The `resumeStream` method accepts the same `ResumeOptions` as `resume`:

```swift
// Approve all tools
agent.resumeStream(from: run, with: .approveAll(from: run))

// Selective decisions
agent.resumeStream(from: run, with: .decisions([
    callId1: .approved,
    callId2: .denied("Not safe to delete")
]))

// Continue past iteration limit
agent.resumeStream(from: run, with: .additionalIterations(5))
```

## Thinking Content in Streams

When using models with extended thinking (Anthropic Claude with thinking enabled, OpenAI o-series), thinking content arrives as `.contentDelta` events with `kind: .thinking`:

```swift
for try await event in agent.runStream("Solve this math problem") {
    switch event {
    case .contentDelta(let text, let kind):
        switch kind {
        case .thinking:
            // Internal reasoning, display in a collapsed section or debug panel
            thinkingBuffer.append(text)
        case .text:
            // Visible response to the user
            print(text, terminator: "")
        }
    default:
        break
    }
}
```

Thinking deltas always come before text deltas in a given model response. The full thinking content is also available on the `CompletionResponse` and `Message` types after the stream completes.

## Codable

`StreamEvent` and `ContentKind` are fully `Codable`. This means you can serialize stream events for logging, replay, or transport over a network.

`AgentStreamEvent` is `Sendable` but not `Codable` because it contains the generic `AgentRun<Output>` in its `.finished` case. The underlying `AgentRun` is `Codable` when `Output` is `Codable`.
