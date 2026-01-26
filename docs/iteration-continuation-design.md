# Iteration Continuation Design

## Overview

This document describes the design for allowing users to continue an agent run when the maximum iteration limit is reached, rather than losing all state.

## Problem Statement

Currently, when an agent reaches `maxIterations`, it throws `AgentError.maxIterationsReached(Int)` and all execution state is lost. This is problematic because:

1. **Wasted work**: Long-running agents lose all progress
2. **No user control**: Users cannot decide to continue if the agent is making progress
3. **No visibility**: Users don't see how many tokens were consumed before failure

## Solution

Extend the existing `PausedAgentRun` mechanism (used for deferred tool approvals) to also capture state when max iterations is reached, allowing users to continue with additional iterations.

## API Design

### PauseReason Enum

```swift
public extension PausedAgentRun {
    enum PauseReason: Sendable, Equatable {
        /// Paused due to deferred tool calls awaiting resolution.
        case deferredTools

        /// Paused because max iterations was reached.
        case maxIterationsReached(limit: Int)

        /// Helper to extract iteration limit if applicable.
        public var iterationLimit: Int? {
            if case .maxIterationsReached(let limit) = self {
                return limit
            }
            return nil
        }
    }
}
```

### Extended PausedAgentRun

```swift
public struct PausedAgentRun: Sendable {
    public let runID: String
    public let messages: [Message]
    public let usage: Usage
    public let requestCount: Int
    public let toolCallCount: Int
    public let pendingCalls: [PendingToolCall]

    /// Why the agent was paused.
    public let reason: PauseReason

    public init(
        runID: String,
        messages: [Message],
        usage: Usage,
        requestCount: Int,
        toolCallCount: Int,
        pendingCalls: [PendingToolCall],
        reason: PauseReason = .deferredTools  // Default for backward compatibility
    ) { ... }
}
```

### New Error Case

```swift
public enum AgentError: Error, Sendable {
    // Existing (kept for backward compatibility)
    case maxIterationsReached(Int)

    // New: includes full state for continuation
    case maxIterationsExceeded(PausedAgentRun)
}
```

### Continuation Methods

```swift
extension Agent {
    /// Continue a paused agent run with additional iterations.
    ///
    /// Use this when the agent was paused due to `maxIterationsExceeded`.
    /// The agent will continue from where it left off with the specified
    /// additional iterations allowed.
    ///
    /// - Parameters:
    ///   - paused: The paused run state from `AgentError.maxIterationsExceeded`
    ///   - additionalIterations: Extra iterations to allow
    ///   - deps: Dependencies for tool execution
    /// - Returns: Final result with typed output
    /// - Throws: `AgentError.maxIterationsExceeded` if limit hit again
    public func continueRun(
        paused: PausedAgentRun,
        additionalIterations: Int,
        deps: Deps
    ) async throws -> AgentResult<Output>

    /// Streaming variant for continuation.
    public nonisolated func continueRunStream(
        paused: PausedAgentRun,
        additionalIterations: Int,
        deps: Deps
    ) -> AsyncThrowingStream<AgentStreamEvent<Output>, Error>
}
```

## Usage Example

### Basic Usage

```swift
do {
    let result = try await agent.run("Complex analysis task", deps: myDeps)
    print("Completed: \(result.output)")
} catch let error as AgentError {
    switch error {
    case .maxIterationsExceeded(let paused):
        print("Paused after \(paused.requestCount) iterations")
        print("Tokens used: \(paused.usage.totalTokens)")

        // User decides to continue
        let result = try await agent.continueRun(
            paused: paused,
            additionalIterations: 10,
            deps: myDeps
        )
        print("Completed: \(result.output)")

    case .maxIterationsReached(let count):
        // Legacy handling (no state available)
        print("Failed after \(count) iterations")

    default:
        throw error
    }
}
```

### Streaming with Continuation

```swift
func runWithContinuation() async throws -> String {
    var currentPaused: PausedAgentRun? = nil

    while true {
        let stream: AsyncThrowingStream<AgentStreamEvent<String>, Error>

        if let paused = currentPaused {
            stream = agent.continueRunStream(
                paused: paused,
                additionalIterations: 10,
                deps: deps
            )
        } else {
            stream = agent.runStream("Complex task", deps: deps)
        }

        do {
            for try await event in stream {
                switch event {
                case .contentDelta(let text):
                    print(text, terminator: "")
                case .result(let result):
                    return result.output
                default:
                    break
                }
            }
        } catch let error as AgentError {
            if case .maxIterationsExceeded(let paused) = error {
                // Ask user if they want to continue
                if await userWantsToContinue(paused: paused) {
                    currentPaused = paused
                    continue
                }
            }
            throw error
        }
    }
}
```

## UI Integration (YrdenExample)

### PausedIterationInfo

```swift
struct PausedIterationInfo {
    let iterationsUsed: Int
    let iterationLimit: Int
    let tokensUsed: Int
    let toolCallsUsed: Int
}
```

### IterationLimitBanner

A banner displayed when the agent pauses due to max iterations:

```
┌─────────────────────────────────────────────────────┐
│ ⟳ Iteration limit reached                          │
│                                                     │
│ Iterations used:    10 / 10                        │
│ Tokens consumed:    15.2K                          │
│ Tool calls made:    8                              │
│                                                     │
│ Continue with additional iterations?                │
│                                                     │
│ [+5]  [+10]  [+20]                    [Stop]       │
└─────────────────────────────────────────────────────┘
```

## Implementation Notes

### State Preservation

When max iterations is reached, the following state is captured in `PausedAgentRun`:

| Field | Description |
|-------|-------------|
| `runID` | Same run ID for traceability |
| `messages` | Full conversation history |
| `usage` | Accumulated token usage |
| `requestCount` | Model requests made so far |
| `toolCallCount` | Tool calls executed so far |
| `pendingCalls` | Empty (no pending tools) |
| `reason` | `.maxIterationsReached(limit: N)` |

### Continuation Behavior

1. `continueRun` restores state from `PausedAgentRun`
2. New iteration limit = `paused.requestCount + additionalIterations`
3. Loop continues from last message in conversation
4. If new limit reached, throws `maxIterationsExceeded` again with updated state
5. Usage continues to accumulate across continuations

### Backward Compatibility

- Old `maxIterationsReached(Int)` case is kept but deprecated
- Existing code catching this case continues to work
- New `PausedAgentRun.init` has default `reason: .deferredTools`
- Existing deferred tools code unaffected

## Tradeoffs

### Advantages

1. **Full state preservation** - No work lost when limit hit
2. **User control** - Customers decide whether to continue
3. **Visibility** - Usage stats help informed decisions
4. **Consistent pattern** - Reuses `PausedAgentRun` infrastructure

### Disadvantages

1. **Memory overhead** - Full message history held in paused state
2. **Added complexity** - `PausedAgentRun` now serves two purposes
3. **No auto-continue** - Requires user interaction

## Future Considerations

1. **Hard cap**: Add `maxTotalIterations` to prevent infinite continuation
2. **Auto-continue policy**: Allow configuration for non-interactive scenarios
3. **Compression**: Consider compressing message history for very long conversations
