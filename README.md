# Yrden

A Swift library for building AI agents with type-safe structured outputs.

> **Yrden** - A Witcher sign that creates a magical trap, binding entities within its bounds. Like the sign, this library *constrains* LLM outputs to Swift types.

## Features

- **Type-safe structured outputs** - `@Schema` macro generates JSON Schema from Swift types
- **Multi-provider support** - Anthropic, OpenAI, and AWS Bedrock with unified API
- **Typed extraction API** - `generate()` and `generateWithTool()` return decoded Swift types directly
- **Agent system** - Full agentic loop with `run()`, `runStream()`, and `iter()` execution modes
- **MCP integration** - Model Context Protocol for dynamic tool discovery from external servers
- **Streaming** - Full streaming support for both text and structured output
- **Tool calling** - Define tools with typed arguments, retry logic, and timeouts
- **Human-in-the-loop** - Deferred tool resolution with approval workflows

## Quick Start

### Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/bwarzecha/Yrden.git", from: "0.1.0")
]
```

Then add `"Yrden"` to your target's dependencies.

### Define Your Schema

```swift
import Yrden

@Schema(description: "Extracted person information")
struct PersonInfo {
    @Guide(description: "The person's full name")
    let name: String

    @Guide(description: "Age in years", .range(0...150))
    let age: Int

    let occupation: String
}
```

### Extract Structured Data

```swift
// OpenAI (native structured output)
let openai = OpenAIModel(
    name: "gpt-4o-mini",
    provider: OpenAIProvider(apiKey: "sk-...")
)

let result = try await openai.generate(
    "Dr. Sarah Chen is a 42-year-old neuroscientist.",
    as: PersonInfo.self
)

print(result.data.name)       // "Dr. Sarah Chen"
print(result.data.age)        // 42
print(result.data.occupation) // "neuroscientist"
print(result.usage.totalTokens)

// Anthropic (tool-based extraction)
let anthropic = AnthropicModel(
    name: "claude-haiku-4-5",
    provider: AnthropicProvider(apiKey: "sk-ant-...")
)

let result = try await anthropic.generateWithTool(
    "Marcus is a 35-year-old architect.",
    as: PersonInfo.self,
    toolName: "extract_person"
)
```

### Error Handling

```swift
do {
    let result = try await model.generate(prompt, as: PersonInfo.self)
} catch let error as StructuredOutputError {
    switch error {
    case .modelRefused(let reason):
        print("Model refused: \(reason)")
    case .decodingFailed(let json, let underlyingError):
        print("Invalid JSON: \(json)")
    case .incompleteResponse(let partial):
        print("Response truncated: \(partial)")
    case .emptyResponse:
        print("No response from model")
    default:
        print("Error: \(error)")
    }
}
```

## @Schema Macro

The `@Schema` macro generates JSON Schema from Swift types at compile time.

### Supported Types

| Swift Type | JSON Schema |
|------------|-------------|
| `String` | `{"type": "string"}` |
| `Int` | `{"type": "integer"}` |
| `Double` | `{"type": "number"}` |
| `Bool` | `{"type": "boolean"}` |
| `[T]` | `{"type": "array", "items": ...}` |
| `T?` | Same type, omitted from `required` |
| `@Schema struct` | Nested object |
| `enum: String` | `{"type": "string", "enum": [...]}` |
| `enum: Int` | `{"type": "integer", "enum": [...]}` |

### @Guide Constraints

```swift
@Schema
struct SearchQuery {
    @Guide(description: "Search terms")
    let query: String

    @Guide(description: "Max results", .range(1...100))
    let limit: Int

    @Guide(description: "Confidence threshold", .rangeDouble(0.0...1.0))
    let threshold: Double

    @Guide(description: "Sort order", .options(["relevance", "date"]))
    let sortBy: String

    @Guide(description: "Tags to filter", .count(1...10))
    let tags: [String]?
}
```

Constraints are included in the schema description (e.g., "Must be between 1 and 100") since most LLM providers don't support JSON Schema validation keywords.

## Providers

### Anthropic

```swift
let provider = AnthropicProvider(apiKey: "sk-ant-...")
let model = AnthropicModel(name: "claude-haiku-4-5", provider: provider)

// Use generateWithTool() for structured output
let result = try await model.generateWithTool(
    prompt,
    as: MySchema.self,
    toolName: "extract"
)
```

### OpenAI

```swift
let provider = OpenAIProvider(apiKey: "sk-...")
let model = OpenAIModel(name: "gpt-4o-mini", provider: provider)

// Use generate() for native structured output
let result = try await model.generate(prompt, as: MySchema.self)
```

## Examples

Run the included examples:

```bash
# Schema generation (no API keys needed)
swift run BasicSchema

# Structured output with LLMs (requires API keys)
export OPENAI_API_KEY=sk-...
export ANTHROPIC_API_KEY=sk-ant-...
swift run StructuredOutput
```

## Running Tests

```bash
# Unit tests (no API keys needed)
swift test

# Integration tests (requires API keys)
export $(cat .env | grep -v '^#' | xargs) && swift test
```

## Agent System

The Agent orchestrates tool use and produces typed output:

```swift
@Schema struct MathResult {
    let expression: String
    let result: Int
}

struct CalculatorTool: AgentTool {
    @Schema struct Args { let expression: String }

    var name: String { "calculator" }
    var description: String { "Evaluate a mathematical expression" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        // ... evaluate expression ...
        return .success(result)
    }
}

let agent = Agent<Void, MathResult>(
    model: model,
    systemPrompt: "You are a math assistant.",
    tools: [AnyAgentTool(CalculatorTool())],
    maxIterations: 5
)

// Simple execution
let result = try await agent.run("What is 5 + 3?", deps: ())

// Streaming execution
for try await event in agent.runStream("Analyze data", deps: ()) {
    switch event {
    case .contentDelta(let text): print(text, terminator: "")
    case .toolCallStart(let name, _): print("\n[Calling \(name)...]")
    case .result(let result): print("\nFinal: \(result.output)")
    default: break
    }
}

// Iterable execution for fine-grained control
for try await node in agent.iter("Process request", deps: ()) {
    switch node {
    case .toolExecution(let calls):
        // Inspect/approve tool calls before execution
        for call in calls { print("About to execute: \(call.name)") }
    case .end(let result):
        print("Done: \(result.output)")
    default: break
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

let mcpTools: [AnyAgentTool<Void>] = try await server.discoverTools()

let agent = Agent<Void, String>(
    model: model,
    tools: mcpTools,  // MCP tools work like any other tool
    systemPrompt: "You can use git commands."
)
```

## Status

🔧 Active development - Core functionality complete, API stabilizing.

**Implemented:**
- ✅ `@Schema` macro for structs and enums
- ✅ `@Guide` macro for descriptions and constraints
- ✅ Anthropic provider (tool-based structured output)
- ✅ OpenAI provider (native structured output)
- ✅ AWS Bedrock provider (Converse API)
- ✅ Typed API (`generate()`, `generateWithTool()`)
- ✅ Streaming support throughout
- ✅ Comprehensive error handling
- ✅ Agent system with `run()`, `runStream()`, `iter()` execution modes
- ✅ Tool execution with retry policies and timeouts
- ✅ Output validators with automatic retry
- ✅ Human-in-the-loop (deferred tool resolution)
- ✅ MCP integration for dynamic tool discovery
- ✅ 580+ tests across all components

**In Progress:**
- API polish and documentation
- Additional MCP server support
- Example application

**Planned:**
- Skills system (Anthropic-style reusable capabilities)
- Multi-agent handoffs
- Additional providers (OpenRouter, local models)

## License

Apache 2.0
