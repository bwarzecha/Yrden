# Swift Agent Design

Based on analysis of PydanticAI's implementation, this document outlines a Swift-native Agent design for Yrden.

## Core Concepts

### What an Agent Does

An Agent is an orchestration layer that:
1. Sends prompts to an LLM
2. Processes tool calls from the LLM response
3. Feeds tool results back to the LLM
4. Continues until the LLM provides a final answer
5. Validates and returns typed output

### Key PydanticAI Patterns to Translate

| PydanticAI | Swift Translation |
|------------|-------------------|
| `@agent.tool` decorator | `Tool` protocol conformance |
| `RunContext[Deps]` | `AgentContext<Deps>` struct |
| `ModelRetry` exception | `ToolResult.retry(message:)` |
| `iter()` async context manager | `AsyncSequence` conformance |
| `output_type` | Generic `Output: SchemaType` |
| `result_validator` | `OutputValidator` closure |
| Decorators for deps/no-deps tools | Protocol with optional context parameter |

---

## Type Design

### 1. AgentContext

Rich context passed to tools, similar to PydanticAI's RunContext.

```swift
/// Context available to tools during agent execution.
public struct AgentContext<Deps: Sendable>: Sendable {
    /// User-provided dependencies (database, API clients, etc.)
    public let deps: Deps

    /// The model being used for this run
    public let model: any Model

    /// Current message history
    public var messages: [Message] { get }

    /// Token/request usage so far
    public var usage: Usage { get }

    /// Number of retries for current tool call
    public let retries: Int

    /// Current tool call ID (when inside a tool)
    public let toolCallID: String?

    /// Current step in the run (increments each model call)
    public let runStep: Int

    /// Unique identifier for this run
    public let runID: String
}
```

### 2. Tool Protocol

```swift
/// A tool that can be called by the agent.
public protocol Tool<Deps>: Sendable {
    associatedtype Deps: Sendable = Void
    associatedtype Args: SchemaType
    associatedtype Output: Sendable

    /// Tool name (used by LLM to call it)
    var name: String { get }

    /// Description shown to LLM
    var description: String { get }

    /// Maximum retry attempts for this tool (default: 1)
    var maxRetries: Int { get }

    /// Execute the tool with given arguments.
    func call(
        context: AgentContext<Deps>,
        arguments: Args
    ) async throws -> ToolResult<Output>
}

extension Tool {
    public var maxRetries: Int { 1 }
}
```

### 3. ToolResult

Swift-native alternative to Python exceptions for control flow.

```swift
/// Result of a tool execution.
public enum ToolResult<T: Sendable>: Sendable {
    /// Tool succeeded with output
    case success(T)

    /// Tool failed, ask LLM to retry with feedback
    case retry(message: String)

    /// Tool failed permanently
    case failure(Error)

    /// Tool is deferred - needs external resolution
    /// (e.g., human approval, async operation)
    case deferred(id: String, reason: String)
}

// Convenience for tools that just return a value
extension ToolResult: ExpressibleByStringLiteral where T == String {
    public init(stringLiteral value: String) {
        self = .success(value)
    }
}
```

### 4. Agent Nodes (for iteration)

```swift
/// A node in the agent execution graph.
public enum AgentNode<Deps: Sendable, Output: SchemaType>: Sendable {
    /// Initial prompt from user
    case userPrompt(String)

    /// About to send request to model
    case modelRequest(request: CompletionRequest)

    /// Model responded, may have tool calls
    case modelResponse(response: CompletionResponse)

    /// About to execute tool calls
    case toolExecution(calls: [ToolCall])

    /// Tool execution completed
    case toolResults(results: [ToolCallResult])

    /// Run completed with final output
    case end(result: AgentResult<Output>)
}
```

### 5. AgentResult

```swift
/// Final result of an agent run.
public struct AgentResult<Output: SchemaType>: Sendable {
    /// The typed output
    public let output: Output

    /// Total token usage
    public let usage: Usage

    /// All messages in the conversation
    public let messages: [Message]

    /// Name of tool that produced output (nil if from text)
    public let outputToolName: String?

    /// Unique run identifier
    public let runID: String
}
```

---

## Agent Definition

### Basic Agent

```swift
public actor Agent<Deps: Sendable, Output: SchemaType> {
    // Configuration
    public let model: any Model
    public let systemPrompt: String
    public let tools: [any Tool<Deps>]
    public let outputValidators: [OutputValidator<Deps, Output>]

    // Limits
    public let maxIterations: Int
    public let usageLimits: UsageLimits?

    // End strategy
    public let endStrategy: EndStrategy

    public init(
        model: any Model,
        systemPrompt: String = "",
        tools: [any Tool<Deps>] = [],
        outputValidators: [OutputValidator<Deps, Output>] = [],
        maxIterations: Int = 10,
        usageLimits: UsageLimits? = nil,
        endStrategy: EndStrategy = .early
    ) { ... }
}
```

### End Strategy

```swift
/// Strategy for handling multiple tool calls.
public enum EndStrategy: Sendable {
    /// Stop as soon as output tool is called (ignore other tool calls)
    case early

    /// Execute all tool calls, even if output tool is included
    case exhaustive
}
```

### Usage Limits

```swift
/// Limits on agent execution.
public struct UsageLimits: Sendable {
    /// Maximum input tokens
    public var maxInputTokens: Int?

    /// Maximum output tokens
    public var maxOutputTokens: Int?

    /// Maximum total tokens
    public var maxTotalTokens: Int?

    /// Maximum model requests (iterations)
    public var maxRequests: Int?

    /// Maximum tool calls
    public var maxToolCalls: Int?
}
```

---

## Execution Methods

### Simple Run

```swift
extension Agent {
    /// Run the agent and return typed output.
    public func run(
        _ prompt: String,
        deps: Deps,
        messageHistory: [Message] = []
    ) async throws -> AgentResult<Output>
}

// Usage
let agent = Agent<MyDeps, Report>(
    model: anthropic,
    systemPrompt: "You are a research assistant.",
    tools: [searchTool, calculatorTool]
)

let result = try await agent.run(
    "Analyze Q4 sales trends",
    deps: MyDeps(database: db)
)
print(result.output.summary)
```

### Streaming Run

```swift
extension Agent {
    /// Run with streaming events.
    public func runStream(
        _ prompt: String,
        deps: Deps,
        messageHistory: [Message] = []
    ) -> AsyncThrowingStream<AgentStreamEvent<Output>, Error>
}

/// Events emitted during streaming.
public enum AgentStreamEvent<Output: SchemaType>: Sendable {
    /// Text content delta
    case contentDelta(String)

    /// Tool call started
    case toolCallStart(name: String, id: String)

    /// Tool call arguments delta
    case toolCallDelta(id: String, delta: String)

    /// Tool call completed
    case toolCallEnd(id: String)

    /// Tool result available
    case toolResult(id: String, result: String)

    /// Usage update
    case usage(Usage)

    /// Final result (last event)
    case result(AgentResult<Output>)
}

// Usage
for try await event in agent.runStream("Analyze sales", deps: myDeps) {
    switch event {
    case .contentDelta(let text):
        print(text, terminator: "")
    case .toolCallStart(let name, _):
        print("\n[Calling \(name)...]")
    case .result(let result):
        print("\n\nFinal: \(result.output)")
    default:
        break
    }
}
```

### Iterable Run (Full Control)

```swift
extension Agent {
    /// Run with manual control over each step.
    public func iter(
        _ prompt: String,
        deps: Deps,
        messageHistory: [Message] = []
    ) -> AgentRun<Deps, Output>
}

/// Async sequence over agent execution nodes.
public struct AgentRun<Deps: Sendable, Output: SchemaType>: AsyncSequence {
    public typealias Element = AgentNode<Deps, Output>

    /// The final result (available after iteration completes)
    public var result: AgentResult<Output>? { get }

    /// Current context
    public var context: AgentContext<Deps> { get }

    /// All messages so far
    public var messages: [Message] { get }

    /// Current usage
    public var usage: Usage { get }

    /// Manually advance to next node.
    public func next(
        _ node: AgentNode<Deps, Output>
    ) async throws -> AgentNode<Deps, Output>
}

// Usage: Basic iteration
for try await node in agent.iter("Analyze sales", deps: myDeps) {
    switch node {
    case .toolExecution(let calls):
        // Inspect tool calls before execution
        for call in calls {
            print("About to call: \(call.name)")
        }
    case .modelResponse(let response):
        // Inspect raw model response
        print("Model said: \(response.content ?? "")")
    case .end(let result):
        print("Done: \(result.output)")
    default:
        break
    }
}

// Usage: Human-in-the-loop approval
for try await node in agent.iter("Delete user data", deps: myDeps) {
    switch node {
    case .toolExecution(let calls):
        for call in calls where call.name == "delete_data" {
            let approved = await requestHumanApproval(call)
            if !approved {
                // Skip dangerous tool
                continue
            }
        }
    default:
        break
    }
}

// Usage: Manual stepping
let run = agent.iter("Query database", deps: myDeps)
var node = run.nextNode

while case .end = node {
    // Inspect, modify, or skip nodes
    if case .toolExecution(let calls) = node {
        // Could modify arguments here
    }
    node = try await run.next(node)
}
```

---

## Output Validation

```swift
/// Validates and optionally transforms agent output.
public struct OutputValidator<Deps: Sendable, Output: SchemaType>: Sendable {
    public let validate: @Sendable (
        AgentContext<Deps>,
        Output
    ) async throws -> Output
}

extension OutputValidator {
    /// Create a validator that can request retry.
    public static func retrying(
        _ validate: @escaping @Sendable (AgentContext<Deps>, Output) async throws -> Output
    ) -> OutputValidator {
        OutputValidator { context, output in
            do {
                return try await validate(context, output)
            } catch let error as ValidationRetry {
                // Signal retry to agent
                throw AgentError.outputValidationFailed(error.message)
            }
        }
    }
}

/// Throw this from validator to request retry.
public struct ValidationRetry: Error {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

// Usage
let agent = Agent<MyDeps, Report>(
    model: anthropic,
    outputValidators: [
        .retrying { context, report in
            guard report.sections.count >= 3 else {
                throw ValidationRetry("Report must have at least 3 sections")
            }
            return report
        }
    ]
)
```

---

## Tool Definition Examples

### Basic Tool (No Dependencies)

```swift
struct CalculatorTool: Tool {
    typealias Deps = Void

    @Schema(description: "Calculator arguments")
    struct Args: SchemaType {
        @Guide(description: "Math expression to evaluate")
        let expression: String
    }

    var name: String { "calculator" }
    var description: String { "Evaluate mathematical expressions" }

    func call(
        context: AgentContext<Void>,
        arguments: Args
    ) async throws -> ToolResult<String> {
        // Evaluate expression...
        return .success("42")
    }
}
```

### Tool with Dependencies

```swift
struct SearchTool: Tool {
    typealias Deps = AppDependencies

    @Schema(description: "Search parameters")
    struct Args: SchemaType {
        let query: String
        let limit: Int?
    }

    var name: String { "search" }
    var description: String { "Search the knowledge base" }
    var maxRetries: Int { 3 }

    func call(
        context: AgentContext<AppDependencies>,
        arguments: Args
    ) async throws -> ToolResult<String> {
        do {
            let results = try await context.deps.searchClient.search(
                arguments.query,
                limit: arguments.limit ?? 10
            )
            return .success(results.formatted())
        } catch {
            return .retry(message: "Search failed: \(error). Try a different query.")
        }
    }
}
```

### Tool with Approval

```swift
struct DeleteTool: Tool {
    typealias Deps = AdminContext

    @Schema
    struct Args: SchemaType {
        let resourceID: String
        let confirmation: String
    }

    var name: String { "delete_resource" }
    var description: String { "Permanently delete a resource" }

    func call(
        context: AgentContext<AdminContext>,
        arguments: Args
    ) async throws -> ToolResult<String> {
        // Check if we have approval
        guard context.deps.hasApproval(for: arguments.resourceID) else {
            return .deferred(
                id: "delete_\(arguments.resourceID)",
                reason: "Requires admin approval to delete \(arguments.resourceID)"
            )
        }

        try await context.deps.database.delete(arguments.resourceID)
        return .success("Deleted \(arguments.resourceID)")
    }
}
```

---

## Deferred Tool Resolution

For tools that need external completion (human approval, async operations):

```swift
/// Pending deferred tool calls.
public struct DeferredToolCalls: Sendable {
    /// Tools awaiting external results
    public let pending: [PendingToolCall]

    /// Tools awaiting approval
    public let awaitingApproval: [PendingToolCall]
}

public struct PendingToolCall: Sendable {
    public let id: String
    public let toolName: String
    public let arguments: String
    public let reason: String
}

extension Agent {
    /// Resume a run with resolved deferred tools.
    public func resume(
        runID: String,
        resolvedTools: [String: String],  // id -> result
        deps: Deps
    ) async throws -> AgentResult<Output>
}

// Usage
let result = try await agent.run("Delete old files", deps: adminDeps)

// Check if any tools were deferred
if case .deferred(let pending) = result {
    // Get human approval
    for call in pending.awaitingApproval {
        let approved = await ui.requestApproval(
            "Approve \(call.toolName) on \(call.arguments)?"
        )
        if approved {
            resolvedTools[call.id] = "approved"
        } else {
            resolvedTools[call.id] = "denied"
        }
    }

    // Resume with resolutions
    let finalResult = try await agent.resume(
        runID: result.runID,
        resolvedTools: resolvedTools,
        deps: adminDeps
    )
}
```

---

## Structured Output Modes

How structured output works varies by provider:

```swift
/// How to get structured output from the model.
public enum OutputMode: Sendable {
    /// Use native JSON mode (OpenAI response_format)
    case native

    /// Use a tool call (Anthropic tool_use)
    case tool(name: String, description: String)

    /// Let the library choose based on model capabilities
    case auto
}

extension Agent {
    /// Configure output mode.
    public func withOutputMode(_ mode: OutputMode) -> Agent
}

// Usage
let agent = Agent<Deps, Report>(model: anthropic)
    .withOutputMode(.tool(name: "submit_report", description: "Submit final report"))
```

---

## Multi-Agent Handoffs

Agents can delegate to other agents:

```swift
struct DelegateToAgent<SubDeps: Sendable, SubOutput: SchemaType>: Tool {
    let targetAgent: Agent<SubDeps, SubOutput>
    let depsMapper: (Deps) -> SubDeps

    var name: String { "delegate_to_\(targetAgent.name)" }
    var description: String { "Hand off to \(targetAgent.name)" }

    func call(
        context: AgentContext<Deps>,
        arguments: DelegateArgs
    ) async throws -> ToolResult<String> {
        let subDeps = depsMapper(context.deps)
        let result = try await targetAgent.run(
            arguments.task,
            deps: subDeps
        )
        // Encode sub-agent output as string for parent
        return .success(String(describing: result.output))
    }
}

// Usage
let researchAgent = Agent<Deps, ResearchResult>(...)
let writingAgent = Agent<Deps, Article>(...)

let orchestrator = Agent<Deps, FinalOutput>(
    tools: [
        DelegateToAgent(targetAgent: researchAgent) { $0 },
        DelegateToAgent(targetAgent: writingAgent) { $0 }
    ]
)
```

---

## Error Handling

```swift
/// Errors that can occur during agent execution.
public enum AgentError: Error, Sendable {
    /// Model returned unexpected response format
    case unexpectedModelBehavior(String)

    /// Output validation failed
    case outputValidationFailed(String)

    /// Usage limit exceeded
    case usageLimitExceeded(UsageLimitKind)

    /// Maximum iterations reached
    case maxIterationsReached(Int)

    /// Tool execution failed permanently
    case toolExecutionFailed(toolName: String, error: Error)

    /// No output produced
    case noOutput

    /// Run was cancelled
    case cancelled
}

public enum UsageLimitKind: Sendable {
    case inputTokens(used: Int, limit: Int)
    case outputTokens(used: Int, limit: Int)
    case totalTokens(used: Int, limit: Int)
    case requests(used: Int, limit: Int)
    case toolCalls(used: Int, limit: Int)
}
```

---

## Implementation Phases

### Phase 1: Core Agent Loop
1. Basic `Agent` actor with `run()` method
2. `Tool` protocol with simple execution
3. `ToolResult` enum
4. Message history management
5. Basic error handling

### Phase 2: Streaming
1. `runStream()` method
2. `AgentStreamEvent` enum
3. Progressive content delivery

### Phase 3: Iteration Control
1. `iter()` method returning `AgentRun`
2. `AgentNode` enum
3. Manual stepping with `next()`
4. Node inspection and modification

### Phase 4: Advanced Features
1. Output validators
2. Deferred tool resolution
3. Usage limits
4. Multi-agent handoffs

### Phase 5: Polish
1. Comprehensive error messages
2. Observability hooks
3. Testing utilities

---

## Key Differences from PydanticAI

| Aspect | PydanticAI | Yrden |
|--------|------------|-------|
| Tool definition | `@agent.tool` decorator | `Tool` protocol conformance |
| Retry signal | `raise ModelRetry(msg)` | `return .retry(message:)` |
| Context manager | `async with agent.iter()` | `for await node in agent.iter()` |
| Deps injection | `RunContext[Deps]` | `AgentContext<Deps>` |
| Type safety | Runtime Pydantic | Compile-time Swift generics |
| Tool registration | Dynamic via decorators | Static via initializer |
| Async model | Python asyncio | Swift structured concurrency |

---

## Open Questions

1. **Tool registration syntax** - Should we support result builders for a more declarative API?
   ```swift
   Agent {
       SearchTool()
       CalculatorTool()
   }
   ```

2. **Deps type erasure** - How to handle heterogeneous tools with different Deps types?

3. **Streaming output validation** - Should partial outputs be validated during streaming?

4. **Cancellation** - How does cancellation propagate through the agent loop?

5. **Conversation persistence** - Should the agent manage message serialization?
