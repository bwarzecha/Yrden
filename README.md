# Yrden

A Swift library for building AI agents with type-safe structured outputs.

> **Yrden** - A Witcher sign that creates a magical trap, binding entities within its bounds. Like the sign, this library *constrains* LLM outputs to Swift types.

## Features

- **Type-safe structured outputs** - `@Schema` macro generates JSON Schema from Swift types
- **Multi-provider support** - Anthropic and OpenAI with unified API
- **Typed extraction API** - `generate()` and `generateWithTool()` return decoded Swift types directly
- **Streaming** - Full streaming support for both text and structured output
- **Tool calling** - Define tools with typed arguments

## Quick Start

### Installation

```swift
dependencies: [
    .package(url: "https://github.com/bwarzecha/Yrden.git", from: "0.1.0")
]
```

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

## Status

🚧 Early development - API subject to change.

**Implemented:**
- ✅ `@Schema` macro for structs and enums
- ✅ `@Guide` macro for descriptions and constraints
- ✅ Anthropic provider (tool-based structured output)
- ✅ OpenAI provider (native structured output)
- ✅ Typed API (`generate()`, `generateWithTool()`)
- ✅ Streaming support
- ✅ Comprehensive error handling

**Planned:**
- Agent loop with tool execution
- MCP (Model Context Protocol) integration
- Additional providers (Bedrock, OpenRouter, local models)
- Runtime constraint validation

## License

Apache 2.0
