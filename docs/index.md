# Yrden

**Type-safe AI agents for Swift.**

Yrden is a Swift library for building production AI agents, inspired by [PydanticAI](https://ai.pydantic.dev/). It constrains LLM outputs to Swift types and binds agent execution to structured, type-safe patterns.

Named after the [Witcher sign](https://witcher.fandom.com/wiki/Yrden) that creates a magical constraining circle -- like the sign, Yrden *constrains* LLM outputs to your Swift types and *binds* agent execution to structured patterns.

```swift
import Yrden

let provider = AnthropicProvider(apiKey: "sk-ant-...")
let model = AnthropicModel(name: "claude-sonnet-4-5-20250514", provider: provider)

let response = try await model.complete("Where does 'hello world' come from?")
print(response.content ?? "")
```

## Why Use Yrden

1. **Multi-provider support** -- Anthropic (Claude), OpenAI (GPT-4o, GPT-5, o-series), AWS Bedrock, and local models via Ollama, LM Studio, or vLLM. Switch providers without changing your agent code.

2. **Type-safe structured outputs** -- `@Schema` and `@Guide` macros generate JSON Schema at compile time. The LLM is constrained to produce valid JSON matching your Swift types. No manual schema writing, no runtime reflection.

3. **Three execution modes** -- `run()` for simple fire-and-forget, `runStream()` for real-time streaming, `iter()` for step-by-step control with inspect/modify at every phase.

4. **Tool calling with typed arguments** -- Define tools as Swift structs with typed arguments and results. The `TypedTool` protocol handles JSON encoding/decoding automatically.

5. **Human-in-the-loop** -- Mark tools as requiring approval with `.requireApproval()`. The agent pauses, you inspect the call, approve or deny, then resume.

6. **MCP integration** -- Connect to MCP servers for dynamic tool discovery. Supports stdio and HTTP transports with OAuth authentication.

7. **Built-in tools** -- `ShellTool`, `ReadFileTool`, and `WriteFileTool` with configurable security boundaries (allowed directories, denied paths).

8. **Usage limits** -- Cap token consumption, request count, and tool calls to prevent runaway costs. The agent pauses cleanly when limits are reached.

9. **Streaming throughout** -- Not just text deltas. Stream tool call arguments, tool execution results, and usage updates as they happen.

10. **Swift 6 concurrency** -- Actor-based `Agent`, `Sendable` tools, structured concurrency throughout. No data races.

11. **Codable state** -- `AgentRun` and `IterationState` are fully `Codable`. Serialize agent state to disk, resume later, or hand off between processes.

## Hello World

The simplest way to use Yrden is direct model completion:

```swift
import Yrden

let provider = AnthropicProvider(apiKey: "sk-ant-...")
let model = AnthropicModel(name: "claude-sonnet-4-5-20250514", provider: provider)

let response = try await model.complete("Where does 'hello world' come from?")
print(response.content ?? "")
```

This sends a single prompt and returns the response. No agent loop, no tools -- just a direct LLM call.

For OpenAI models:

```swift
let provider = OpenAIProvider(apiKey: "sk-...")
let model = OpenAIModel(name: "gpt-4o", provider: provider)

let response = try await model.complete("Where does 'hello world' come from?")
print(response.content ?? "")
```

For local models via Ollama or LM Studio:

```swift
let provider = LocalProvider(baseURL: URL(string: "http://localhost:11434/v1")!)
let model = LocalModel(name: "llama3.2", provider: provider)

let response = try await model.complete("Where does 'hello world' come from?")
print(response.content ?? "")
```

## Tools and Structured Output

Here is a more complete example -- a bank support agent that uses tools and returns structured output:

```swift
import Yrden

// 1. Define structured output with @Schema
@Schema(description: "Support response to the customer")
struct SupportResult {
    @Guide(description: "Advice given to the customer")
    let supportAdvice: String

    @Guide(description: "Whether to block their card")
    let blockCard: Bool

    @Guide(description: "Risk level from 0 to 10", .range(0...10))
    let risk: Int
}

// 2. Define tool argument types
@Schema
struct BalanceArgs {
    @Guide(description: "Whether to include pending transactions")
    let includePending: Bool
}

// 3. Define a tool
struct CustomerBalance: TypedTool {
    typealias Args = BalanceArgs

    var name: String { "customer_balance" }
    var description: String { "Returns the customer's current account balance." }

    func execute(
        context: ToolContext,
        arguments: BalanceArgs
    ) async throws -> ToolResult<String> {
        // In a real app, query your database here
        if arguments.includePending {
            return .success("$123.45 (including $15.00 pending)")
        }
        return .success("$108.45")
    }
}

// 4. Create the agent
let agent = try Agent<SupportResult>(
    model: model,
    systemPrompt: """
        You are a bank support agent. Be concise and helpful.
        Assess risk level for each customer interaction.
        """,
    tools: [CustomerBalance()]
)

// 5. Run it
let run = try await agent.run("What is my account balance?")

switch run.status {
case .completed(let result):
    print(result.supportAdvice)  // "Your current balance is $108.45..."
    print(result.blockCard)      // false
    print(result.risk)           // 0
case .needsApproval(let pending):
    print("Tools need approval: \(pending.map(\.call.name))")
case .iterationLimitReached(let limit):
    print("Hit iteration limit: \(limit)")
case .usageLimitReached(let limit):
    print("Hit usage limit: \(limit)")
}
```

The `@Schema` macro generates the JSON Schema that the LLM uses to structure its response. The `@Guide` macro adds descriptions and constraints -- the range constraint on `risk` is embedded in the schema description and validated locally after decoding.

The agent loop handles the orchestration: it sends the prompt to the LLM, the LLM decides to call `customer_balance`, the agent executes the tool, feeds the result back, and the LLM produces the final structured output.

## Streaming

For real-time output, use `runStream()`:

```swift
for try await event in agent.runStream("What is my balance?") {
    switch event {
    case .contentDelta(let text, _):
        print(text, terminator: "")
    case .toolCallStart(_, let name):
        print("\n[Calling \(name)...]")
    case .toolResult(let id, let result):
        print("[Result: \(result.prefix(50))...]")
    case .finished(let run):
        if let output = run.output {
            print("\nRisk level: \(output.risk)")
        }
    default:
        break
    }
}
```

## Step-by-Step Control

For full control over every phase, use `iter()`:

```swift
for try await node in agent.iter("Delete old backups") {
    switch node {
    case .beforeModel(let ctx):
        print("About to call model (step \(ctx.state.iteration))")
    case .afterModel(let ctx):
        print("Model responded")
    case .beforeTools(let ctx):
        // Inspect and approve tool calls
        for pending in ctx.pendingCalls {
            print("Tool: \(pending.call.name)")
            ctx.approve(pending.call)
        }
    case .afterTools(let ctx):
        print("Tools executed, \(ctx.state.toolCallCount) total calls")
    case .finished(let ctx):
        print("Done: \(ctx.output)")
    }
}
```

## `llms.txt`

The Yrden documentation is available in an LLM-friendly format following the [`llms.txt` convention](https://llmstxt.org/). If you are building tools or agents that need to reference these docs programmatically, the consolidated documentation is available at `docs/llms.txt` in the repository.

## Next Steps

- [Agents](agents.md) -- Full agent configuration, execution modes, and lifecycle
- [Models](models.md) -- Provider setup for Anthropic, OpenAI, Bedrock, and local models
- [Tools](tools.md) -- Defining tools, typed arguments, approval, retries
- [Structured Output](output.md) -- `@Schema`, `@Guide`, and output validation
- [Streaming](streaming.md) -- Streaming events, stream + structured output
- [Context Management](context-management.md) -- Handling long-running tasks that approach context limits
- [MCP](mcp.md) -- Connecting to MCP servers for dynamic tools
- [Built-in Tools](built-in-tools.md) -- ShellTool, ReadFileTool, WriteFileTool
- [Human-in-the-Loop](human-in-the-loop.md) -- Approval workflows, pause/resume
- [Error Handling](error-handling.md) -- LLMError, AgentError, StructuredOutputError, retry
- [Testing](testing.md) -- Test architecture, FakeModel, cross-provider tests
