# Structured Output

Yrden provides type-safe structured output from LLMs. Instead of parsing free-text responses, you define Swift types and the library guarantees the LLM response conforms to your schema.

Structured output works at two levels:

- **Model level** -- call `model.generate()` or `model.generateWithTool()` directly for one-shot extraction.
- **Agent level** -- `Agent<Output>` handles structured output automatically as part of the agentic loop.

## SchemaType Protocol

All structured output types must conform to `SchemaType`:

```swift
public protocol SchemaType: Codable, Sendable {
    static var jsonSchema: JSONValue { get }
}
```

`SchemaType` extends both `Codable` (for JSON decoding) and `Sendable` (for Swift 6 concurrency safety). The `jsonSchema` property returns a `JSONValue` representation of the JSON Schema that providers use to constrain model output.

`String` conforms to `SchemaType` by default, producing `{"type": "string"}`. This allows agents with `Agent<String>` to work as simple text-output agents without requiring a custom schema type.

## Defining Schema Types

### The @Schema Macro

The `@Schema` macro generates `SchemaType` conformance and the `jsonSchema` property at compile time:

```swift
@Schema
struct Person {
    let name: String
    let age: Int
}
```

This generates a JSON Schema equivalent to:

```json
{
  "type": "object",
  "properties": {
    "name": { "type": "string" },
    "age": { "type": "integer" }
  },
  "required": ["name", "age"],
  "additionalProperties": false
}
```

Add a top-level description with the `description` parameter:

```swift
@Schema(description: "User profile data")
struct UserProfile {
    let name: String
    let age: Int
}
```

### The @Guide Macro

`@Guide` adds descriptions and constraints to individual properties:

```swift
@Schema(description: "Search parameters")
struct SearchQuery {
    @Guide(description: "Natural language search query")
    let query: String

    @Guide(description: "Maximum results to return", .range(1...100))
    let limit: Int

    @Guide(description: "Minimum relevance score", .rangeDouble(0.0...1.0))
    let threshold: Double

    @Guide(description: "Tags to filter by", .count(1...10))
    let tags: [String]?

    @Guide(description: "Output format", .options(["pdf", "doc", "txt"]))
    let format: String

    @Guide(description: "Identifier pattern", .pattern("^[a-z]+$"))
    let slug: String
}
```

Constraints are embedded in the JSON Schema `description` field as natural language hints. This is the universal subset approach -- it works across all providers (Anthropic, OpenAI, Bedrock) regardless of which JSON Schema features they individually support.

### SchemaConstraint Types

| Constraint | Description | Example |
|---|---|---|
| `.range(ClosedRange<Int>)` | Integer range (inclusive) | `.range(1...100)` |
| `.rangeDouble(ClosedRange<Double>)` | Double range (inclusive) | `.rangeDouble(0.0...1.0)` |
| `.minimum(Int)` | Minimum integer value | `.minimum(0)` |
| `.maximum(Int)` | Maximum integer value | `.maximum(255)` |
| `.count(ClosedRange<Int>)` | Array element count range | `.count(1...10)` |
| `.exactCount(Int)` | Exact array element count | `.exactCount(5)` |
| `.options([String])` | Enum-like string options | `.options(["a", "b", "c"])` |
| `.pattern(String)` | Regex pattern for strings | `.pattern("^[a-z]+$")` |

### Supported Swift Types

| Swift Type | JSON Schema | Notes |
|---|---|---|
| `String` | `{"type": "string"}` | |
| `Int` | `{"type": "integer"}` | |
| `Double` | `{"type": "number"}` | |
| `Bool` | `{"type": "boolean"}` | |
| `[T]` | `{"type": "array", "items": ...}` | `T` must be a supported type |
| `T?` | Same type, omitted from `required` | |
| `@Schema struct` | `{"type": "object", ...}` | Nested structured types |
| `enum E: String` | `{"type": "string", "enum": [...]}` | String raw value enums |
| `enum E: Int` | `{"type": "integer", "enum": [...]}` | Integer raw value enums |

## Model-Level Structured Output

The `Model` type provides two approaches for generating structured output directly. The choice depends on the provider.

### Native Structured Output (OpenAI)

OpenAI models support native structured output via `response_format`. Use `model.generate()`:

```swift
@Schema
struct PersonInfo {
    let name: String
    let age: Int
}

let model = OpenAIModel(provider: openai, modelID: "gpt-4o")

let result: TypedResponse<PersonInfo> = try await model.generate(
    "Extract: John is 30 years old",
    as: PersonInfo.self
)

print(result.data.name)           // "John"
print(result.data.age)            // 30
print(result.usage.totalTokens)   // Token count
print(result.stopReason)          // .endTurn
print(result.rawJSON)             // Raw JSON for debugging
```

### Tool-Based Structured Output (Anthropic)

Anthropic models use `tool_use` for structured output. Use `model.generateWithTool()`:

```swift
let model = AnthropicModel(provider: anthropic, modelID: "claude-sonnet-4-20250514")

let result = try await model.generateWithTool(
    "Extract: John is 30 years old",
    as: PersonInfo.self,
    toolName: "extract_person"
)

print(result.data.name)  // "John"
```

The `toolName` parameter defaults to `"extract"`. A custom `toolDescription` can also be provided.

### With Message Arrays

Both methods have variants that accept a full `[Message]` array instead of a simple prompt string:

```swift
let messages: [Message] = [
    .system("You extract structured data from text."),
    .user("John is 30 years old and lives in NYC.")
]

// Native
let result = try await model.generate(messages: messages, as: PersonInfo.self)

// Tool-based
let result = try await model.generateWithTool(messages: messages, as: PersonInfo.self)
```

### Streaming Structured Output

Both approaches support streaming. Events arrive as they are generated, with the complete JSON available at the end:

```swift
for try await event in model.generateStream("Extract person info from: John is 30", as: PersonInfo.self) {
    switch event {
    case .contentDelta(let delta, _):
        print(delta, terminator: "")
    case .done(let response):
        // Decode the final response
        let typed = try model.extractAndDecode(from: response, as: PersonInfo.self, expectToolCall: false)
        print(typed.data.name)
    default:
        break
    }
}
```

For tool-based streaming, use `generateStreamWithTool()`. Tool arguments arrive via `toolCallDelta` events.

## TypedResponse

All structured output methods return a `TypedResponse<T>`:

```swift
public struct TypedResponse<T: SchemaType> {
    /// The decoded typed data.
    public let data: T

    /// Token usage for this request.
    public let usage: Usage

    /// Why the model stopped generating.
    public let stopReason: StopReason

    /// Raw JSON string before decoding (useful for debugging).
    public let rawJSON: String
}
```

## Agent-Level Structured Output

`Agent<Output>` automatically handles structured output as part of the agentic loop. The generic parameter specifies the output type:

```swift
@Schema(description: "Analysis report")
struct Report {
    let summary: String
    let findings: [String]
    let score: Double
}

let agent = try Agent<Report>(
    model: model,
    systemPrompt: "You are a data analyst."
)

let run = try await agent.run("Analyze Q4 sales data")
let report: Report = try run.result()

print(report.summary)
print(report.findings)
print(report.score)
```

For simple text output agents, use `Agent<String>`:

```swift
let agent = try Agent<String>(
    model: model,
    systemPrompt: "You are a helpful assistant."
)

let run = try await agent.run("What is the capital of France?")
let answer: String = try run.result()
```

The agent uses a tool-based approach internally, creating an output tool named `"final_result"` with the schema of the `Output` type. If a user-defined tool has the same name, Yrden automatically appends a numeric suffix to avoid collisions.

## Output Validators

Output validators run after the LLM produces structured output but before returning to the caller. They can validate, transform, or reject the output:

```swift
let validator = OutputValidator<Report> { context, report in
    guard report.sections.count >= 3 else {
        throw ValidationRetry("Report must have at least 3 sections")
    }
    return report
}

let agent = try Agent<Report>(
    model: model,
    outputValidators: [validator],
    maxValidationRetries: 3
)
```

When a validator throws `ValidationRetry`, the error message is sent back to the LLM as feedback, and the LLM tries again. This continues up to `maxValidationRetries` times (default: 3).

Validators can also transform the output by returning a modified value:

```swift
let normalizer = OutputValidator<Report> { context, report in
    var normalized = report
    // Normalize or enrich the output before returning
    return normalized
}
```

Multiple validators run in order. Each receives the output from the previous validator.

## Error Handling

Structured output operations can throw `StructuredOutputError` for parsing and validation failures:

```swift
public enum StructuredOutputError: Error {
    /// Model explicitly refused to generate output (safety/policy reasons).
    case modelRefused(reason: String)

    /// Model returned an empty response.
    case emptyResponse

    /// Expected a tool call but received text content.
    case unexpectedTextResponse(content: String)

    /// Expected native structured output but received a tool call.
    case unexpectedToolCall(toolName: String)

    /// JSON decoding failed -- response was JSON but did not match the schema.
    case decodingFailed(json: String, underlyingError: Error)

    /// Response was truncated due to max tokens limit.
    case incompleteResponse(partialJSON: String)
}
```

Handle these errors explicitly:

```swift
do {
    let result = try await model.generate(prompt, as: PersonInfo.self)
    print(result.data.name)
} catch let error as StructuredOutputError {
    switch error {
    case .modelRefused(let reason):
        print("Model refused: \(reason)")
    case .decodingFailed(let json, _):
        print("Failed to decode: \(json)")
    case .incompleteResponse(let partial):
        print("Response truncated: \(partial)")
    default:
        print("Structured output error: \(error)")
    }
} catch let error as LLMError {
    print("Provider error: \(error)")
}
```

`StructuredOutputError` is separate from `LLMError`. `LLMError` covers provider and network failures. `StructuredOutputError` covers parsing and validation failures after a successful response.

## Provider Compatibility

Yrden uses a universal JSON Schema subset that works across all providers:

| Feature | Anthropic | OpenAI | Bedrock | Yrden |
|---|---|---|---|---|
| Basic types (string, integer, number, boolean) | Yes | Yes | Yes | Yes |
| `enum` (primitive values) | Yes | Yes | Yes | Yes |
| `required` | Yes | Yes | Yes | Yes |
| `additionalProperties: false` | Required | Required | Yes | Always set |
| `description` | Yes | Yes | Yes | Yes |
| `$ref` / `$defs` (internal) | Yes | Yes | Varies | Yes |

Features like `minimum`, `maximum`, `pattern`, and `format` are not reliably supported across all providers. Yrden encodes these as natural language hints in the `description` field instead, ensuring compatibility everywhere.
