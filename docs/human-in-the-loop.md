# Human-in-the-Loop

Yrden supports human-in-the-loop patterns for tool approval, iteration limits, and usage limits. This allows you to gate dangerous operations, inspect agent behavior, and control resource consumption.

## Tool Approval

### Marking a Tool as Requiring Approval

Any tool can be marked as requiring approval before execution. There are two ways to do this:

**Wrap an existing tool:**
```swift
let safeTool = dangerousTool.requireApproval()
```

**Set it in the tool definition:**
```swift
struct DeleteTool: TypedTool {
    var name: String { "delete" }
    var description: String { "Delete files from disk" }
    var requiresApproval: Bool { true }

    func execute(context: ToolContext, arguments: DeleteArgs) async throws -> ToolResult<String> {
        // ...
    }
}
```

Both approaches result in the agent pausing before executing that tool, giving your application a chance to present the call to a human for review.

### How Approval Works with `run()`

When the agent encounters a tool that requires approval, `run()` returns an `AgentRun` with `.needsApproval` status instead of continuing:

```swift
let run = try await agent.run("Delete old files")

switch run.status {
case .needsApproval(let pending):
    for p in pending where p.requiresApproval {
        print("Tool '\(p.call.name)' wants to run with: \(p.call.arguments)")
    }

case .completed(let output):
    print(output)

case .iterationLimitReached(let limit):
    print("Hit iteration limit: \(limit)")

case .usageLimitReached(let limit):
    print("Hit usage limit: \(limit)")
}
```

The pending list contains all tool calls from that model response, not just those requiring approval. Filter by `requiresApproval` to show only the ones that need user action. Tools that do not require approval are auto-approved and will execute when you resume.

### Resuming with Decisions

After inspecting the pending tool calls, resume the run with your decisions:

**Approve all:**
```swift
let continued = try await agent.resume(from: run, with: .approveAll(from: run))
```

**Deny all:**
```swift
let continued = try await agent.resume(from: run, with: .denyAll(from: run, message: "Not permitted"))
```

**Mixed decisions (approve some, deny others, replace with cached results):**
```swift
let continued = try await agent.resume(from: run, with: .decisions([
    "call-1": .approved,
    "call-2": .denied("Not allowed"),
    "call-3": .replaced("Cached: file already exists")
]))
```

The decision keys are tool call IDs, found on each `PendingToolDecision.call.id`.

Any approval-requiring tool left without an explicit decision is automatically denied with the message "Tool call was not approved".

### PendingToolDecision

Each pending tool call is represented by a `PendingToolDecision`:

```swift
public struct PendingToolDecision {
    /// The tool call from the model.
    let call: ToolCall

    /// Whether this specific tool needs human approval.
    let requiresApproval: Bool

    /// Current decision state.
    var decision: Decision

    public enum Decision {
        /// Will execute (default for non-approval tools).
        case pending

        /// Will execute (explicit approval).
        case approved

        /// Won't execute; message sent back to model.
        case denied(String)

        /// Won't execute; synthetic result used instead.
        case replaced(String)
    }
}
```

### How Approval Works with `iter()`

The `iter()` API gives you fine-grained control at each phase of execution. Tool approval happens in the `.beforeTools` node:

```swift
for try await node in agent.iter("Delete files") {
    switch node {
    case .beforeTools(let ctx):
        for pending in ctx.pendingCalls where pending.requiresApproval {
            // Present to user and get their decision
            let userApproved = await askUser(pending.call)

            if userApproved {
                ctx.approve(pending.call)
            } else {
                ctx.deny(pending.call, message: "User declined")
            }
        }

    case .finished(let ctx):
        print(ctx.output)

    default:
        break
    }
}
```

With `iter()`, the agent does not pause automatically for approval. You are responsible for checking `requiresApproval` and making decisions before the iterator advances. If you do not call `approve()` or `deny()`, tools in `.pending` state execute normally.

You can also replace a tool call with a synthetic result to skip execution entirely:

```swift
ctx.replace(pending.call, withResult: "Cached: file already deleted")
```

## Iteration Limits

### Setting a Limit

The `maxIterations` parameter controls how many model-call-then-tool-execution cycles the agent performs before pausing:

```swift
let agent = try Agent<String>(model: model, maxIterations: 5)
```

Each iteration consists of one model call and (optionally) executing the tool calls from that response. When the limit is reached, `run()` returns with `.iterationLimitReached` status.

### Handling the Limit

```swift
let run = try await agent.run("Complex multi-step task")

if case .iterationLimitReached(let limit) = run.status {
    print("Paused after \(limit) iterations")
    print("Tokens used so far: \(run.usage.totalTokens)")

    // Allow more iterations to continue
    let continued = try await agent.resume(from: run, with: .additionalIterations(10))
}
```

### Using `.result()` for Simple Cases

If you want the simple "throw on pause" pattern, use `.result()`:

```swift
do {
    let output = try await agent.run("Task").result()
    print(output)
} catch let error as AgentError<String> {
    if case .iterationLimitReached(let run) = error {
        // Decide whether to continue
        let continued = try await agent.resume(from: run, with: .additionalIterations(10))
    }
}
```

## Usage Limits

### Setting Limits

Usage limits constrain total resource consumption across the entire run:

```swift
let agent = try Agent<String>(
    model: model,
    usageLimits: UsageLimits(
        maxTotalTokens: 10_000,
        maxToolCalls: 20
    )
)
```

Available limits:
- `maxInputTokens` - Maximum input tokens allowed
- `maxOutputTokens` - Maximum output tokens allowed
- `maxTotalTokens` - Maximum total tokens (input + output)
- `maxRequests` - Maximum number of model requests (iterations)
- `maxToolCalls` - Maximum number of tool calls executed

### Handling Usage Limits

When a usage limit is hit, the run stops and cannot be resumed (it would immediately hit the limit again):

```swift
let run = try await agent.run("Expensive task")

if case .usageLimitReached(let limit) = run.status {
    print("Hit limit: \(limit)")
    // e.g., "Total tokens: 10500/10000"

    // Cannot resume -- start a new run, optionally continuing the conversation
    let newRun = try await agent.run("Continue where you left off", continuingFrom: run)
}
```

The `continuingFrom:` parameter carries forward the message history from the previous run, so the model retains context from the prior conversation.

## Combining Patterns

These patterns compose naturally. An agent can have tool approval, iteration limits, and usage limits all at once:

```swift
let agent = try Agent<String>(
    model: model,
    tools: [
        searchTool,                          // no approval needed
        deleteTool.requireApproval(),         // requires approval
    ],
    maxIterations: 5,
    usageLimits: UsageLimits(maxTotalTokens: 50_000, maxToolCalls: 30)
)

let run = try await agent.run("Clean up old files")

switch run.status {
case .completed(let output):
    print("Done: \(output)")

case .needsApproval(let pending):
    // Show pending deletions to user, then resume
    let continued = try await agent.resume(from: run, with: .approveAll(from: run))

case .iterationLimitReached:
    let continued = try await agent.resume(from: run, with: .additionalIterations(5))

case .usageLimitReached(let limit):
    print("Budget exhausted: \(limit)")
}
```

## Serialization

Both `AgentRun` and `IterationState` conform to `Codable`, so you can serialize a paused run to disk and resume it later -- even across app launches:

```swift
// Save
let data = try JSONEncoder().encode(run)
try data.write(to: URL(fileURLWithPath: "paused-run.json"))

// Later...
let loaded = try JSONDecoder().decode(AgentRun<String>.self, from: data)
let continued = try await agent.resume(from: loaded, with: .approveAll(from: loaded))
```

This is particularly useful for approval workflows where a human reviewer may not be immediately available.
