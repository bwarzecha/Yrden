# Context Management

Long-running agent tasks can exceed the model's context window. Yrden does not build context management into the library -- instead, the `iter()` API gives you mutable access to `state.messages` at the `beforeModel` phase, letting you implement context management at the application level.

This document describes a proven three-layer approach used in the [AgentCLI example](../Examples/AgentCLI/).

## The Problem

When an agent loop runs for many iterations (reading files, calling tools, accumulating results), the conversation history grows until it exceeds the model's context window. Without management, the API returns `maxTokensReached` and the run fails.

For example, a task like "explore ~/dev and describe every project" might accumulate hundreds of tool results across 20+ iterations, easily reaching 200K+ tokens.

## Architecture

Three layers run inside the `.beforeModel` handler, applied in order:

```
.beforeModel handler
  |
  +-- [Layer 1] Truncate old tool results     // if context > 50%
  |     Keep last 3 tool results full, truncate older ones
  |
  +-- [Layer 3] LLM compaction                // if context > 80%
  |     Side API call to summarize old conversation turns
  |
  +-- [Layer 2] Context pressure hints        // always checked
  |     Insert system message telling the LLM to be efficient/wrap up
  |
  +-- ctx.stream()                            // proceed with model call
```

All three layers modify `ctx.state.messages` directly. No library hooks or configuration needed.

## Using iter() for Context Management

The key insight: `BeforeModelContext` gives you mutable access to `state.messages` before each model call. This is the only hook you need.

```swift
let model = AnthropicModel(name: "claude-sonnet-4-5-20250929", provider: provider)
let maxContext = model.capabilities.maxContextTokens  // e.g., 200_000

let agent = try Agent<String>(
    model: model,
    systemPrompt: "You are a coding agent.",
    tools: tools.all,
    maxIterations: 50
)

for try await node in agent.iter("Explore ~/dev and describe each project") {
    switch node {
    case .beforeModel(let ctx):
        // Apply context management before each model call
        if let max = maxContext {
            await ContextManagement.apply(
                to: &ctx.state.messages,
                maxContextTokens: max,
                model: model
            )
        }

        // Stream the response
        for try await event in ctx.stream() {
            if case .contentDelta(let text, _) = event {
                print(text, terminator: "")
            }
        }

    case .beforeTools(let ctx):
        for try await event in ctx.stream() {
            // observe tool execution
        }

    case .afterTools(let ctx):
        // Monitor context usage per iteration
        let estimated = TokenEstimator.estimate(ctx.state.messages)
        if let max = maxContext {
            let pct = Double(estimated) / Double(max) * 100
            print("[context: ~\(String(format: "%.0f", pct))%]")
        }

    case .finished(let ctx):
        print("Done! Tokens: \(ctx.usage.totalTokens)")

    case .afterModel:
        break
    }
}
```

## Layer 1: Tool Result Truncation

The biggest source of context growth is tool results -- file contents, shell output, search results. Most of these are only relevant for the iteration they were produced in. Older results can be truncated without losing important information.

**Strategy:** Walk messages from the end. Keep the 3 most recent tool results intact. Truncate older ones to ~200 characters using a head+tail strategy (keep the beginning and end, cut the middle).

```swift
static func truncateOldToolResults(
    messages: inout [Message],
    preserveRecentCount: Int = 3
) {
    var toolResultCount = 0
    let maxLength = 200

    for i in stride(from: messages.count - 1, through: 0, by: -1) {
        switch messages[i] {
        case .toolResult(let id, let content):
            toolResultCount += 1
            if toolResultCount > preserveRecentCount && content.count > maxLength {
                messages[i] = .toolResult(
                    toolCallId: id,
                    content: OutputTruncation.truncate(content, maxLength: maxLength)
                )
            }

        case .toolResults(let entries):
            toolResultCount += 1
            if toolResultCount > preserveRecentCount {
                let truncated = entries.map { entry in
                    // Truncate each entry's text output
                    truncateEntry(entry, maxLength: maxLength)
                }
                messages[i] = .toolResults(truncated)
            }

        default:
            break
        }
    }
}
```

**When to trigger:** Context usage > 50%. At this point, older tool results are unlikely to be referenced again.

Yrden provides `OutputTruncation.truncate(_:maxLength:)` which uses a 60% head / 40% tail strategy -- the same utility used by built-in tools.

## Layer 2: Context Pressure Hints

As context fills up, inject system messages telling the LLM to change its behavior:

| Context Usage | Hint |
|--------------|------|
| < 50% | None |
| 50-74% | "Be efficient -- avoid reading files you've already seen." |
| 75-89% | "Start producing your final output now. Do not start new explorations." |
| 90%+ | "URGENT: You MUST finish immediately. Write your final answer now." |

```swift
static func contextPressureHint(
    estimatedTokens: Int,
    maxContextTokens: Int
) -> String? {
    let ratio = Double(estimatedTokens) / Double(maxContextTokens)

    if ratio >= 0.90 {
        return "URGENT: Context is nearly full. You MUST finish immediately."
    } else if ratio >= 0.75 {
        return "Important: Context is 75%+ full. Start producing your final output now."
    } else if ratio >= 0.50 {
        return "Note: You have used over half your context window. Be efficient."
    }

    return nil
}
```

Insert the hint as a system message directly into `state.messages`:

```swift
if let hint = contextPressureHint(estimatedTokens: estimate, maxContextTokens: max) {
    messages.append(.system(hint))
}
```

## Layer 3: LLM Compaction

When truncation is not enough (context still > 80%), summarize old conversation turns via a side LLM call.

**Strategy:**
1. Split messages into three segments: first user message, middle (to summarize), recent (last 4 messages)
2. Build a transcript of the middle section
3. Call `model.complete()` with a summarization prompt
4. Replace everything with: enriched first message + summary + recent messages

```swift
static func compactMessages(
    messages: inout [Message],
    model: any Model,
    preserveRecentTurns: Int = 4
) async throws {
    guard messages.count > preserveRecentTurns + 2 else { return }

    let splitPoint = max(1, messages.count - preserveRecentTurns)
    let middleMessages = Array(messages[1..<splitPoint])

    // Build transcript and summarize via side LLM call
    let transcript = buildTranscript(from: middleMessages)
    let summaryRequest = CompletionRequest(
        messages: [
            .system("Summarize the following conversation. Preserve key facts and decisions."),
            .user(transcript),
        ]
    )
    let response = try await model.complete(summaryRequest)
    let summary = response.content ?? "[Summary unavailable]"

    // Reconstruct: original task + summary + recent messages
    let originalPrompt = extractUserText(from: messages[0])
    var newMessages: [Message] = []
    newMessages.append(.user(
        "[Original task]\n\(originalPrompt)\n\n[Summary of earlier conversation]\n\(summary)"
    ))
    newMessages.append(contentsOf: messages[splitPoint...])
    messages = newMessages
}
```

**Trade-offs:**
- Extra API call costs time and tokens
- Summary may lose details the LLM needs later
- Uses the same model (could use a cheaper one in production)

## Token Estimation

For threshold decisions (50%, 75%, 90%), exact token counts are unnecessary. A simple character-based heuristic works:

```swift
enum TokenEstimator {
    static func estimate(_ messages: [Message]) -> Int {
        messages.reduce(0) { $0 + estimate($1) }
    }

    static func estimate(_ message: Message) -> Int {
        let overhead = 4  // per-message role/formatting overhead
        switch message {
        case .system(let text):
            return overhead + text.count / 4
        case .user(let parts):
            let chars = parts.reduce(0) { sum, part in
                switch part {
                case .text(let t): return sum + t.count
                case .image: return sum + 4000
                }
            }
            return overhead + chars / 4
        // ... similar for .assistant, .toolResult, .toolResults
        }
    }
}
```

The ~4 chars/token ratio is roughly correct for English text. It's ~20% inaccurate but sufficient for threshold-based decisions.

## Real-World Results

Tested with AgentCLI on progressively harder tasks:

| Task | Iterations | Tool Calls | Peak Context | Outcome |
|------|-----------|------------|-------------|---------|
| Read all Agent/ source files | 6 | 17 | 26% | Completed |
| Full code review of Sources/Yrden/ | 18 | 40 | 53% | Truncation triggered |
| Explore ~/dev (97 projects) | 24 | 24 | 29% | Completed |

All tasks completed successfully without hitting context limits. The truncation layer activated at 50% and kept context manageable. Compaction (Layer 3) was not needed for these tasks.

## Why Application-Level, Not Library-Level

Context management is **application-specific**:
- What to truncate depends on your tools and their output
- Pressure hint wording depends on your use case
- Compaction strategy depends on what information matters
- Some applications may want different thresholds or no compaction at all

The `iter()` API provides everything you need via `ctx.state.messages`. No library hooks, configuration structs, or special APIs required. Your application owns the policy; the library provides the mechanism.

## See Also

- [Agents -- Iteration](agents.md#iteration) -- How `iter()` and `BeforeModelContext` work
- [Agents -- Context Engineering](agents.md#context-engineering-beforemodel) -- Modifying messages before model calls
- [Examples/AgentCLI/](../Examples/AgentCLI/) -- Complete working implementation
