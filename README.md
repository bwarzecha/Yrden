# Yrden

A Swift library for building AI agents with type-safe structured outputs.

> **Yrden** -- A Witcher sign that creates a magical trap, binding entities within its bounds. Like the sign, this library *constrains* LLM outputs to Swift types.

## Features

- **Multi-provider support** -- Anthropic, OpenAI, AWS Bedrock, and local models (Ollama, LM Studio) with a unified API
- **Type-safe structured outputs** -- `@Schema` macro generates JSON Schema from Swift types at compile time
- **Agent system** -- Full agentic loop with `run()`, `runStream()`, and `iter()` execution modes
- **Tool calling** -- Define tools with typed arguments, retry logic, timeouts, and human approval
- **MCP integration** -- Model Context Protocol for dynamic tool discovery from external servers
- **Streaming** -- Stream text deltas, tool call arguments, tool results, and usage updates as they happen
- **Swift 6 concurrency** -- Actor-based agent, `Sendable` tools, structured concurrency throughout

## Quick Start

### Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/bwarzecha/Yrden.git", from: "0.1.0")
]
```

Then add `"Yrden"` to your target's dependencies.

### Hello World

```swift
import Yrden

let provider = AnthropicProvider(apiKey: "sk-ant-...")
let model = AnthropicModel(name: "claude-sonnet-4-5-20250514", provider: provider)

let response = try await model.complete("Where does 'hello world' come from?")
print(response.content ?? "")
```

For OpenAI:

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

## Structured Output

The `@Schema` macro generates JSON Schema from Swift types at compile time. The `@Guide` macro adds descriptions and constraints.

```swift
import Yrden

@Schema(description: "Support response to the customer")
struct SupportResult {
    @Guide(description: "Advice given to the customer")
    let supportAdvice: String

    @Guide(description: "Whether to block their card")
    let blockCard: Bool

    @Guide(description: "Risk level from 0 to 10", .range(0...10))
    let risk: Int
}
```

Supported types: `String`, `Int`, `Double`, `Bool`, `[T]`, `T?`, nested `@Schema` structs, and `enum: String` / `enum: Int`.

Constraints (`.range()`, `.count()`, `.options()`, `.pattern()`) are embedded in schema descriptions since most providers don't support JSON Schema validation keywords directly.

## Agent with Tools

```swift
@Schema
struct BalanceArgs {
    @Guide(description: "Whether to include pending transactions")
    let includePending: Bool
}

struct CustomerBalance: TypedTool {
    typealias Args = BalanceArgs

    var name: String { "customer_balance" }
    var description: String { "Returns the customer's current account balance." }

    func execute(
        context: ToolContext,
        arguments: BalanceArgs
    ) async throws -> ToolResult<String> {
        if arguments.includePending {
            return .success("$123.45 (including $15.00 pending)")
        }
        return .success("$108.45")
    }
}

let agent = try Agent<SupportResult>(
    model: model,
    systemPrompt: """
        You are a bank support agent. Be concise and helpful.
        Assess risk level for each customer interaction.
        """,
    tools: [CustomerBalance()]
)

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
        if case .completed(let output) = run.status {
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

## MCP Integration

Connect to MCP servers for dynamic tool discovery:

```swift
let server = try await MCPServerConnection.stdio(
    command: "uvx",
    arguments: ["mcp-server-git", "--repository", "/path/to/repo"]
)

let mcpTools = try await server.tools()

let agent = try Agent<String>(
    model: model,
    tools: mcpTools,
    systemPrompt: "You can use git commands."
)
```

## Providers

| Provider | Setup | Structured Output |
|----------|-------|-------------------|
| **Anthropic** | `AnthropicProvider(apiKey:)` | Tool-based extraction |
| **OpenAI** | `OpenAIProvider(apiKey:)` | Native `response_format` |
| **AWS Bedrock** | `BedrockProvider(region:, profile:)` | Converse API |
| **Local** (Ollama, LM Studio) | `LocalProvider(baseURL:)` | OpenAI-compatible |

## Documentation

Full documentation is available in the [docs/](docs/) directory:

- [Getting Started](docs/index.md) -- Overview, Hello World, bank support example
- [Agents](docs/agents.md) -- Execution modes, lifecycle, usage limits, validators
- [Models & Providers](docs/models.md) -- Provider setup, capabilities, streaming
- [Tools](docs/tools.md) -- TypedTool protocol, approval, retries, built-in tools
- [Structured Output](docs/output.md) -- `@Schema`, `@Guide`, validation
- [Streaming](docs/streaming.md) -- StreamEvent types, agent streaming
- [MCP](docs/mcp.md) -- Connections, OAuth, dynamic tool discovery
- [Human-in-the-Loop](docs/human-in-the-loop.md) -- Approval workflows, pause/resume
- [Testing](docs/testing.md) -- FakeModel, testing agents and tools

An LLM-friendly version is available at [docs/llms.txt](docs/llms.txt).

## Examples

```bash
# Schema generation (no API keys needed)
swift run BasicSchema

# Structured output with LLMs (requires API keys)
export OPENAI_API_KEY=sk-...
export ANTHROPIC_API_KEY=sk-ant-...
swift run StructuredOutput

# Full agent CLI
swift run AgentCLI
```

## License

Apache 2.0
