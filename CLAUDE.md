# Yrden - PydanticAI for Swift

> **Yrden** - A Witcher sign that creates a magical trap/circle, binding and constraining entities within its bounds. Like the sign, this library *constrains* LLM outputs to your Swift types and *binds* agent execution to structured, type-safe patterns.

## Project Vision

Build a production-grade Swift library that brings PydanticAI's capabilities to the Apple ecosystem. This is an open-source, general-purpose library for building AI agents with:

- **Multi-provider support**: Anthropic, OpenAI, OpenRouter, Bedrock, MLX (local)
- **Type-safe structured outputs**: Via Swift macros (`@Schema`)
- **Agentic loop with full control**: Iterable, pausable, observable execution
- **MCP (Model Context Protocol)**: Dynamic tool discovery from external servers
- **Sandboxed tool execution**: Isolated environments for untrusted tools
- **Streaming throughout**: Not just responses, but the entire agent loop
- **Skills system**: Anthropic-style reusable skills/commands that extend agent capabilities

---

## Development Quick Reference

### Running Tests with API Keys

```bash
# Load .env and run all tests
export $(cat .env | grep -v '^#' | xargs) && swift test

# Run specific provider tests
export $(cat .env | grep -v '^#' | xargs) && swift test --filter "OpenAI"
export $(cat .env | grep -v '^#' | xargs) && swift test --filter "Anthropic"

# Run expensive tests (o1 models, etc.)
export $(cat .env | grep -v '^#' | xargs) RUN_EXPENSIVE_TESTS=1 && swift test

# List OpenAI models
export $(cat .env | grep -v '^#' | xargs) && swift test --filter "listAllModels"
```

### Environment File (.env)

```bash
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
```

### JSONValue Gotchas

When working with `JSONValue` (our JSON type for schemas and LLM responses):

```swift
// JSONValue cases: .null, .bool, .int, .double, .string, .array, .object

// ❌ Wrong: Dictionary subscript returns optional
guard case .string(let s) = obj["key"] else { ... }

// ✅ Right: Unwrap first, then pattern match
guard let value = obj["key"], case .string(let s) = value else { ... }

// ❌ Wrong: Assuming "integer" schema returns .int
guard case .int(let n) = obj["age"] else { ... }

// ✅ Right: Handle both int and double (JSON doesn't distinguish)
let age: Int
switch obj["age"] {
case .int(let i)?: age = i
case .double(let d)?: age = Int(d)
default: throw Error("not a number")
}
```

### Structured Output (OpenAI)

```swift
let schema: JSONValue = [
    "type": "object",
    "properties": [
        "name": ["type": "string"],
        "score": ["type": "number"]
    ],
    "required": ["name", "score"],
    "additionalProperties": false  // Required for strict mode!
]

let request = CompletionRequest(
    messages: [.user("Extract info from: John scored 95")],
    outputSchema: schema
)
// Response is guaranteed valid JSON matching schema
```

---

## Why Build This?

### The Gap in Swift Ecosystem

No existing Swift library combines all the pieces needed for production AI agents. After extensive research (January 2025), here's what exists:

| Library | Structured Output | Agent Loop | Multi-Provider | MCP | Loop Control |
|---------|------------------|------------|----------------|-----|--------------|
| **SwiftAI** (mi12labs) | ✅ `@Generable` | ❌ Chat only | ✅ OpenAI, MLX, Apple | ❓ Unclear | ❌ |
| **SwiftAgent** (forums) | ✅ `@Generable` | ✅ Basic | ❌ OpenAI only | ❌ | ❌ |
| **AgentSDK-Swift** | ❓ | ✅ Basic | ❌ OpenAI only | ❌ | ❌ |
| **swift-llm** (getgrinta) | ❌ Strings | ✅ Basic | ❌ OpenAI only | ❌ | ❌ |
| **LLM.swift** | ✅ `@Generatable` | ❌ | ❌ Local only | ❌ | ❌ |

### What PydanticAI Provides (Our Reference)

PydanticAI is the gold standard we're replicating:

```python
# Dependency injection
agent = Agent[MyDeps, OutputType](
    'anthropic:claude-sonnet',
    system_prompt="You are helpful.",
)

# Type-safe tools with retries
@agent.tool(retries=3)
async def search(ctx: RunContext[MyDeps], query: str) -> str:
    return await ctx.deps.search_client.search(query)

# Fine-grained loop control
async with agent.iter(prompt, deps=deps) as run:
    async for node in run:
        # Inspect/modify each step
        # Pause for human approval
        # Inject custom logic
        pass

# Result validation with automatic retry
@agent.result_validator
async def validate(ctx: RunContext[MyDeps], result: OutputType) -> OutputType:
    if not valid(result):
        raise ModelRetry("Try again with more detail")
    return result
```

Key PydanticAI features to replicate:
- **`.iter()` / `.next()`** - Manual loop stepping
- **`RunContext[DepsType]`** - Typed dependency injection
- **`ModelRetry`** - Signal LLM to retry from tools/validators
- **`@agent.tool(retries=N)`** - Automatic retry with reflection
- **Dynamic system prompts** - Runtime context injection
- **Multi-agent handoffs** - Agents calling other agents
- **Usage limits** - Token/request/tool-call caps
- **Event streaming** - Observable execution events

Features beyond PydanticAI:
- **Skills system** - Anthropic-style reusable, composable capabilities
- **MCP integration** - Dynamic tool discovery from external servers
- **Sandbox execution** - Isolated environments for untrusted tools

---

## Existing Libraries - Detailed Analysis

### SwiftAI (mi12labs) - Best Structured Output
GitHub: https://github.com/mi12labs/SwiftAI

**Has:**
- `@Generable` macro for type-safe structured outputs
- `@Guide` attribute for field constraints (patterns, ranges, counts)
- Tool protocol with typed arguments
- Streaming (text and structured)
- Multiple providers (OpenAI, Apple on-device, MLX)

**Missing:**
- No agent loop (just Chat for conversations)
- No Anthropic, Bedrock, OpenRouter
- No MCP
- No loop control

**Useful pattern - Schema macro:**
```swift
@Generable
struct UserProfile {
    @Guide(description: "Valid username", .pattern("^[a-zA-Z][a-zA-Z0-9_]{2,}$"))
    let username: String

    @Guide(description: "Age in years", .minimum(13), .maximum(120))
    let age: Int
}
```

### SwiftAgent (Swift Forums) - Best Agent Architecture
Forum: https://forums.swift.org/t/swiftagent-a-swift-native-agent-sdk-inspired-by-foundationmodels-and-using-its-tools/81634

**Has:**
- Actual agent loop with iterative refinement
- `@SessionSchema` macro for compile-time transcript safety
- `PromptContext` protocol (like dependency injection)
- `ToolRunRejection` for graceful retries (like PydanticAI's `ModelRetry`)
- Adapter pattern for providers

**Missing:**
- Only OpenAI provider
- No fine-grained loop control
- No MCP
- No multi-agent handoffs
- Alpha status

**Useful pattern - Tool rejection:**
```swift
func call(arguments: Arguments) async throws -> String {
    guard isValid(arguments) else {
        throw ToolRunRejection("Invalid input, try different parameters")
    }
    return result
}
```

### AgentSDK-Swift - Has Guardrails & Handoffs
GitHub: https://github.com/fumito-ito/AgentSDK-Swift

**Has:**
- `AgentRunner` with agent loop
- Input guardrails (`InputLengthGuardrail`)
- Multi-agent handoffs via `Handoff.withKeywords()`
- Typed context passing

**Missing:**
- OpenAI only
- Early development
- Limited documentation

**Useful pattern - Handoffs:**
```swift
let agent = Agent(
    handoffs: [
        Handoff.withKeywords(["weather"], to: weatherAgent),
        Handoff.withKeywords(["calendar"], to: calendarAgent)
    ]
)
```

### LLM.swift - Best Local Model Support
GitHub: https://github.com/eastriverlee/LLM.swift

**Has:**
- `@Generatable` macro (100% reliable structured output)
- Hooks: `preprocess`, `postprocess`, `update` callbacks
- Direct llama.cpp integration
- Mature (2 years, 38 releases)

**Missing:**
- Local models only (no API providers)
- No agent loop
- No tool calling

**Useful pattern - Lifecycle hooks:**
```swift
bot.preprocess = { input, history in
    return transformedInput
}
bot.update = { delta in
    // Stream token updates
}
bot.postprocess = { output in
    // Final processing
}
```

---

## Architecture Design

### Package Structure

```
Yrden/
├── Package.swift
├── Sources/
│   ├── Yrden/                    # Core library
│   │   ├── Agent.swift           # Main Agent<Deps, Output> type
│   │   ├── AgentLoop.swift       # Iterable execution loop
│   │   ├── Context.swift         # RunContext for DI
│   │   ├── Tool.swift            # Tool protocol & execution
│   │   ├── Streaming.swift       # Streaming primitives
│   │   └── Types.swift           # Message, ToolCall, etc.
│   │
│   ├── YrdenMacros/              # Macro implementations
│   │   ├── SchemaMacro.swift     # @Schema macro
│   │   └── GuideMacro.swift      # @Guide attribute
│   │
│   ├── Providers/                # LLM provider implementations
│   │   ├── Provider.swift        # Protocol definition
│   │   ├── Anthropic/
│   │   ├── OpenAI/
│   │   ├── OpenRouter/
│   │   ├── Bedrock/
│   │   └── MLX/
│   │
│   ├── MCP/                      # Model Context Protocol
│   │   ├── MCPClient.swift
│   │   ├── MCPTool.swift
│   │   └── MCPTransport.swift
│   │
│   ├── Sandbox/                  # Isolated tool execution
│   │   ├── Sandbox.swift
│   │   └── SandboxedTool.swift
│   │
│   └── Skills/                   # Anthropic-style skills
│       ├── Skill.swift           # Skill protocol
│       ├── SkillRegistry.swift   # Discovery & management
│       └── BuiltInSkills/        # Common skills
│
└── Tests/
```

### Core Protocols

```swift
// Provider abstraction
protocol LLMProvider {
    func complete(
        messages: [Message],
        tools: [ToolDefinition]?,
        output: (any SchemaType.Type)?
    ) async throws -> Response

    func stream(
        messages: [Message],
        tools: [ToolDefinition]?,
        output: (any SchemaType.Type)?
    ) -> AsyncThrowingStream<StreamEvent, Error>
}

// Schema generation (via macro)
protocol SchemaType: Codable {
    static var jsonSchema: JSONSchema { get }
}

// Tool definition
protocol Tool<Context> {
    associatedtype Arguments: SchemaType
    associatedtype Output

    var name: String { get }
    var description: String { get }

    func call(context: Context, arguments: Arguments) async throws -> Output
}

// Agent loop control
protocol AgentNode {
    // Represents a step in the agent loop
}

struct AgentIterator<Deps, Output>: AsyncSequence {
    // Allows: for await node in agent.iter(prompt) { ... }
}
```

### Streaming Model

Stream everything, not just final responses:

```swift
enum StreamEvent {
    case messageStart(id: String)
    case contentDelta(String)
    case contentEnd

    case toolCallStart(id: String, name: String)
    case toolCallArgumentsDelta(String)
    case toolCallEnd

    case toolResultStart(toolCallId: String)
    case toolResultDelta(String)
    case toolResultEnd

    case error(Error)
    case done
}
```

### Agent Loop Design

```swift
class Agent<Deps, Output: SchemaType> {
    let provider: any LLMProvider
    let tools: [any Tool<Deps>]
    let systemPrompt: String

    // Simple execution
    func run(_ prompt: String, deps: Deps) async throws -> Output

    // Streaming execution
    func runStream(_ prompt: String, deps: Deps) -> AsyncThrowingStream<StreamEvent, Error>

    // Full control - iterate through each step
    func iter(_ prompt: String, deps: Deps) -> AgentIterator<Deps, Output>
}

// Usage
import Yrden

let agent = Agent<MyDeps, Report>(
    provider: AnthropicProvider(apiKey: "..."),
    tools: [searchTool, calculatorTool],
    systemPrompt: "You are a research assistant."
)

// Option 1: Simple
let report = try await agent.run("Analyze Q4 sales", deps: myDeps)

// Option 2: Streaming
for try await event in agent.runStream("Analyze Q4 sales", deps: myDeps) {
    switch event {
    case .contentDelta(let text): print(text, terminator: "")
    case .toolCallStart(_, let name): print("Calling \(name)...")
    default: break
    }
}

// Option 3: Full control
for try await node in agent.iter("Analyze Q4 sales", deps: myDeps) {
    switch node {
    case .toolCall(let call):
        // Inspect, approve, modify before execution
        if needsApproval(call) {
            let approved = await requestHumanApproval(call)
            if !approved { continue }
        }
    case .response(let partial):
        // Stream partial responses
    }
}
```

### MCP Integration

```swift
// Connect to MCP server
let mcpClient = try await MCPClient.connect(
    transport: .stdio(command: "uvx", args: ["mcp-server-filesystem"])
)

// Discover tools dynamically
let mcpTools = try await mcpClient.listTools()

// Use in agent
let agent = Agent(
    provider: anthropic,
    tools: localTools + mcpTools,  // Combine local and MCP tools
    systemPrompt: "..."
)
```

### Sandbox Execution

```swift
// Wrap untrusted tools
let sandboxedTool = SandboxedTool(
    tool: codeExecutionTool,
    sandbox: .process(
        timeout: .seconds(30),
        memoryLimit: .megabytes(512),
        networkAccess: false
    )
)
```

### Skills System

Anthropic-style skills - reusable, composable capabilities that extend agent behavior:

```swift
// Define a skill
struct CodeReviewSkill: Skill {
    let name = "code-review"
    let description = "Review code for bugs, style, and best practices"

    // Skills can have their own tools
    var tools: [any Tool] {
        [lintTool, analyzeTool]
    }

    // Skills can define system prompt extensions
    var systemPrompt: String {
        """
        When reviewing code:
        1. Check for security vulnerabilities
        2. Identify performance issues
        3. Suggest improvements
        """
    }

    // Skills can intercept and transform requests
    func preprocess(_ input: String) -> String {
        "Review the following code:\n\n\(input)"
    }
}

// Register skills with an agent
let agent = Agent<MyDeps, Review>(
    provider: anthropic,
    tools: [baseTool],
    skills: [CodeReviewSkill(), RefactorSkill()],  // Composable
    systemPrompt: "You are a code assistant."
)

// Invoke skill explicitly
let review = try await agent.runSkill("code-review", input: code, deps: myDeps)

// Or let agent choose based on context
let result = try await agent.run("Please review this code: \(code)", deps: myDeps)
```

Skills enable:
- **Reusable behaviors** across agents
- **Composable capabilities** - mix and match
- **Domain-specific extensions** - coding, writing, analysis, etc.
- **Skill discovery** - agents can list and select appropriate skills

---

## Implementation Priorities

### Phase 1: Providers & Testing Foundation
Start with providers to enable integration testing from day one.

1. **Package setup** with test targets
2. **Basic types**: Message, ToolCall, Response, errors
3. **`LLMProvider` protocol** - Core abstraction
4. **Providers** (each with integration tests):
   - `AnthropicProvider` - tool_use + structured outputs beta
   - `OpenAIProvider` - response_format with strict mode
   - `OpenAICompatibleProvider` - Ollama, vLLM, LM Studio, etc.
   - `OpenRouterProvider` - Multi-model aggregator
   - `BedrockProvider` - AWS Converse API
   - `MLXProvider` - Local models on Apple Silicon
5. **Integration test suite** - Shared test cases across all providers

### Phase 2: Schema Generation
6. **`@Schema` macro** - JSON schema from Swift types
7. **`@Guide` macro** - Descriptions and constraints
8. **Local constraint validation**
9. **Schema correctness tests** - JSON Schema Test Suite subset

### Phase 3: Core Agent
10. **Tool protocol** with typed arguments
11. **Basic agent loop** (non-iterable first)
12. **Streaming** throughout

### Phase 4: Advanced Control
13. **Iterable agent loop** (`.iter()`)
14. **Retry/rejection** handling (`ToolRejection`)
15. **Result validators**

### Phase 5: Ecosystem
16. **MCP client**
17. **Sandbox execution**

### Phase 6: Skills & Polish
19. **Skills system** - Anthropic-style reusable capabilities
20. **Multi-agent handoffs**
21. **Guardrails**
22. **Usage limits**
23. **Documentation & examples**

### Provider Summary

| Provider | Backend | Structured Output Method |
|----------|---------|-------------------------|
| `AnthropicProvider` | Anthropic API | tool_use or structured outputs |
| `OpenAIProvider` | OpenAI API | response_format + strict |
| `OpenAICompatibleProvider` | Any OpenAI-compatible | response_format (varies) |
| `OpenRouterProvider` | OpenRouter | provider-dependent |
| `BedrockProvider` | AWS Bedrock | Converse API tools |
| `MLXProvider` | Local MLX (Apple Silicon) | Outlines/grammar-based |

---

## Swift vs PydanticAI Patterns

### Patterns That Don't Translate Well

| PydanticAI Pattern | Problem in Swift | Swift Alternative |
|-------------------|------------------|-------------------|
| `@agent.tool` decorator | No decorators in Swift | Protocol conformance + result builders |
| Runtime schema introspection | Swift is compiled, no reflection | `@Schema` macro generates at compile time |
| `async with agent.iter()` | Context managers don't exist | `for await` with `AsyncSequence` + structured concurrency |
| `ModelRetry` exception | Swift doesn't use exceptions for control flow | Return `Result<T, ToolError>` or typed errors |
| Dynamic tool registration | Can't add methods at runtime | Tool registry with type-erased wrappers |
| Union return types | No union types | Enums with associated values |
| Pydantic validators | Runtime validation | Compile-time via macros + `Codable` |

### Swift-Native Alternatives

**Tool Definition:**
```swift
// Protocol-based with result builders
struct SearchTool: Tool {
    typealias Arguments = SearchArgs
    typealias Output = String

    func call(context: Context, arguments: SearchArgs) async throws -> String { ... }
}

@AgentBuilder
var agent: Agent<MyDeps, Report> {
    SearchTool()
    CalculatorTool()
}
```

**Retry/Rejection (typed errors, not exceptions):**
```swift
enum ToolResult<T> {
    case success(T)
    case retry(String)  // Ask LLM to retry with feedback
    case failure(Error)
}
```

**Streaming Loop Control (native AsyncSequence):**
```swift
for await node in agent.stream(prompt, deps: deps) {
    switch node {
    case .toolCall(let call): // Can break, continue, or inject
    case .delta(let text): ...
    }
}
```

### Key Architectural Decisions

1. **Compile-time over runtime** - Use macros for schema, not reflection
2. **Structured concurrency** - `AsyncSequence` + actors for thread safety
3. **Type-safe errors** - Enums over exceptions
4. **Protocol-oriented tools** - Composable, testable
5. **Result builders** - Declarative agent configuration (optional)

---

## @Schema Specification (v1)

### Design Rationale

After researching provider support (January 2026), we found that Anthropic, OpenAI, and AWS Bedrock each support **different subsets** of JSON Schema. The only reliable approach is to use the **intersection** of supported features:

| Feature | Anthropic | OpenAI | Bedrock | Yrden |
|---------|-----------|--------|---------|-------|
| Basic types | ✅ | ✅ | ✅ | ✅ |
| `enum` (primitives) | ✅ | ✅ | ✅ | ✅ |
| `required` | ✅ | ✅ | ✅ | ✅ |
| `additionalProperties: false` | ✅ Required | ✅ Required | ✅ | ✅ |
| `description` | ✅ | ✅ | ✅ | ✅ |
| `$ref` / `$defs` (internal) | ✅ | ✅ | ❓ | ✅ |
| `minimum` / `maximum` | ❌ | ❌ | ❌ | ❌ In description |
| `minLength` / `maxLength` | ❌ | ❌ | ❌ | ❌ In description |
| `pattern` | ⚠️ Limited | ❌ | ❌ | ❌ In description |
| `format` | ⚠️ Some | ❌ | ❌ | ❌ In description |
| `anyOf` / `allOf` | ⚠️ Limited | ⚠️ Limited | ❌ | ❌ Avoid |
| Recursive schemas | ❌ | ❌ | ❌ | ❌ |

**Strategy:** Generate universal schema subset. Constraints go into `description` field as hints, then validate locally after LLM response.

### Supported Swift Types

| Swift Type | JSON Schema | Notes |
|------------|-------------|-------|
| `String` | `{ "type": "string" }` | |
| `Int` | `{ "type": "integer" }` | |
| `Double` | `{ "type": "number" }` | |
| `Bool` | `{ "type": "boolean" }` | |
| `[T]` | `{ "type": "array", "items": ... }` | T must be supported |
| `T?` | Same type, omitted from `required` | |
| `@Schema struct` | `{ "type": "object", ... }` or `$ref` | Nested types |
| `enum E: String` | `{ "type": "string", "enum": [...] }` | Raw value enums |
| `enum E: Int` | `{ "type": "integer", "enum": [...] }` | |

**Not Supported (v1):**
- Enums with associated values
- Recursive types
- `Date`, `URL`, `UUID` (use String + validation)
- Dictionaries `[String: T]`

### Macros

#### `@Schema`

Type-level macro for structs and enums.

```swift
@Schema
struct SearchQuery {
    let query: String
    let limit: Int
}

@Schema(description: "Parameters for searching the knowledge base")
struct SearchQuery {
    // ...
}
```

**Generates:**
1. `static var jsonSchema: [String: Any]` - The JSON Schema dictionary
2. `static var constraints: SchemaConstraints` - For local validation
3. `extension SearchQuery: SchemaType` - Protocol conformance

#### `@Guide`

Property-level macro for descriptions and constraints.

```swift
@Schema(description: "Tool for searching documents")
struct SearchQuery {
    @Guide(description: "Natural language search query")
    let query: String

    @Guide(description: "Maximum results to return", .range(1...100))
    let limit: Int

    @Guide(description: "Minimum relevance score", .range(0.0...1.0))
    let threshold: Double

    @Guide(description: "Tags to filter by", .count(1...10))
    let tags: [String]?

    @Guide(description: "Sort order", .options(["relevance", "date", "title"]))
    let sortBy: String
}
```

#### Constraint Types

```swift
// Numeric ranges
.range(1...100)           // "Must be between 1 and 100"
.range(1...)              // "Must be at least 1"
.range(...100)            // "Must be at most 100"

// Array counts
.count(5)                 // "Must have exactly 5 items"
.count(1...10)            // "Must have between 1 and 10 items"

// String options (enum-like without Swift enum)
.options(["a", "b", "c"]) // "Must be one of: a, b, c"

// Regex pattern (docs + local validation only)
.pattern("^[a-z]+$")      // "Must match pattern: ^[a-z]+$"
```

### Generated Output Example

```swift
@Schema(description: "Search parameters")
struct SearchQuery {
    @Guide(description: "Search terms")
    let query: String

    @Guide(description: "Max results", .range(1...50))
    let limit: Int

    @Guide(description: "Filter by type", .options(["pdf", "doc"]))
    let fileType: String?
}
```

**Generates JSON Schema:**

```json
{
  "type": "object",
  "description": "Search parameters",
  "properties": {
    "query": {
      "type": "string",
      "description": "Search terms"
    },
    "limit": {
      "type": "integer",
      "description": "Max results. Must be between 1 and 50."
    },
    "fileType": {
      "type": "string",
      "description": "Filter by type. Must be one of: pdf, doc."
    }
  },
  "required": ["query", "limit"],
  "additionalProperties": false
}
```

**Generates constraints metadata:**

```swift
static let constraints: SchemaConstraints = [
    "limit": .range(1...50),
    "fileType": .options(["pdf", "doc"])
]
```

### Validation Flow

```
┌─────────────────────────────────────────────────────────────┐
│  1. LLM Response (JSON)                                     │
│     Provider enforces: types, required fields, structure    │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  2. JSON Decode                                             │
│     Swift's Codable: type conversion                        │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  3. Constraint Validation                                   │
│     Yrden validates: ranges, counts, options, patterns      │
└───────────────────────────┬─────────────────────────────────┘
                            │
              ┌─────────────┴─────────────┐
              │                           │
           Valid                       Invalid
              │                           │
              ▼                           ▼
         Return T              throw ValidationError
                               → ModelRetry with message
                               → "limit must be between 1 and 50, got 200"
```

### Protocol Definition

```swift
/// Marker protocol for types with JSON Schema representation.
/// Conformance is generated by the @Schema macro.
public protocol SchemaType: Codable, Sendable {
    /// JSON Schema dictionary (universal subset).
    static var jsonSchema: [String: Any] { get }

    /// Constraints for local validation.
    static var constraints: SchemaConstraints { get }

    /// Validates an instance against constraints.
    /// Returns nil if valid, or error message if invalid.
    static func validate(_ instance: Self) -> ValidationError?
}

public struct SchemaConstraints {
    // Property name → Constraint
    let constraints: [String: Constraint]
}

public enum Constraint {
    case range(ClosedRange<Double>)
    case rangeFrom(Double)
    case rangeThrough(Double)
    case count(ClosedRange<Int>)
    case exactCount(Int)
    case options([String])
    case pattern(String)
}
```

---

## Risks and Unknowns

### High-Risk Items (De-risk First)

| Risk | Impact | Uncertainty | Status |
|------|--------|-------------|--------|
| **Macro JSON Schema generation** | High | High | ⏳ Needs POC |
| **Streaming + Structured output** | High | Medium | ⏳ Needs POC |
| **Swift 6 Sendable/Actor model** | High | Medium | ⏳ Needs POC |
| **Tool type erasure** | Medium | Medium | ⏳ Needs POC |

### POC 1: Schema Macro

**Goal:** Validate we can generate JSON Schema from Swift types at compile time.

```swift
@Schema
struct UserProfile {
    let name: String
    let age: Int?
    let tags: [String]
    let status: Status  // enum
}

// Must generate:
// {
//   "type": "object",
//   "properties": {
//     "name": { "type": "string" },
//     "age": { "type": "integer" },
//     "tags": { "type": "array", "items": { "type": "string" } },
//     "status": { "type": "string", "enum": ["active", "inactive"] }
//   },
//   "required": ["name", "tags", "status"]
// }
```

**Unknowns:**
- Nested `@Schema` types - can macro see other macros?
- Enum handling - raw values vs associated values
- Recursive types

**Success criteria:** Generate valid schema for struct with String, Int, Optional, Array, nested struct, enum.

### POC 2: Streaming + Structured Output

**Goal:** Verify providers support streaming while enforcing structured output.

```swift
for await chunk in provider.stream(
    messages: [...],
    output: UserProfile.self
) {
    // Do we get deltas? Or just final result?
}
```

**Unknowns:**
- Anthropic: `tool_use` blocks stream, but does JSON mode?
- OpenAI: `response_format` with streaming?
- May need to buffer and parse at end

**Success criteria:** Stream partial JSON from Anthropic, parse valid struct at end.

### POC 3: Concurrent Agent Loop

**Goal:** Validate actor-based agent loop with Sendable tools.

```swift
actor AgentLoop<Deps: Sendable, Output> {
    func run(_ prompt: String, deps: Deps) async throws -> Output {
        // Can tools be called from here?
        // How do we pass non-Sendable context?
    }
}
```

**Unknowns:**
- Tool execution isolation
- Callback patterns for streaming
- Cancellation handling

**Success criteria:** Execute tool from actor, return result, no data races.

### POC 4: Type-Erased Tool Registry

**Goal:** Verify heterogeneous tool collections work.

```swift
protocol AnyTool {
    var name: String { get }
    var schema: [String: Any] { get }
    func callErased(context: Any, arguments: Data) async throws -> String
}

struct TypedToolWrapper<T: Tool>: AnyTool { ... }
```

**Success criteria:** Store `[any AnyTool]`, call correct implementation, preserve type safety.

### Open Questions

1. **Streaming tradeoff:** If we can't stream structured output, do we:
   - Stream text, validate at end?
   - Skip streaming for structured responses?
   - Use `tool_use` for structure (streamable) vs JSON mode?

2. **Macro scope:** Build full macro ourselves vs. depend on existing (SwiftAI's `@Generable`)?

3. **Provider abstraction:** Thin wrapper vs. full normalization? (Anthropic's tool format ≠ OpenAI's)

---

## Testing Strategy

### Three-Layer Test Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: Schema Correctness                                │
│  "Does our JSON Schema subset match the spec?"              │
│                                                             │
│  • Validate against official JSON Schema Test Suite         │
│  • Only features we support (type, properties, enum, etc.)  │
│  • No network, pure logic                                   │
│  • Fast, runs on every commit                               │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 2: Provider Integration                              │
│  "Do real providers accept our schemas?"                    │
│                                                             │
│  • Same test cases run against ALL providers                │
│  • Real API calls (Anthropic, OpenAI, Bedrock)              │
│  • Capability flags skip unsupported features               │
│  • Runs in CI with secrets, daily or on release             │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: Local Constraint Validation                       │
│  "Do our constraints catch invalid data?"                   │
│                                                             │
│  • Unit tests for each constraint type                      │
│  • Edge cases: boundaries, empty, null                      │
│  • No network, fast                                         │
└─────────────────────────────────────────────────────────────┘
```

### Layer 1: Schema Correctness

Use the official [JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite) to validate our subset.

**Test files to include (Draft 7):**
- `type.json` - Basic type validation
- `properties.json` - Object properties
- `required.json` - Required fields
- `additionalProperties.json` - Must be false
- `enum.json` - Primitive enums
- `items.json` - Array items
- `ref.json` - Internal $ref
- `definitions.json` - $defs

**Test files to skip:**
- `minimum.json`, `maximum.json` - We use description hints
- `pattern.json`, `format.json` - Not universally supported
- `anyOf.json`, `allOf.json` - Avoided in our subset

### Layer 2: Provider Integration

**Key principle:** One test suite, multiple providers. Same test cases run against every provider implementation.

**Provider capabilities** gate which tests run:
```swift
struct ProviderCapabilities: OptionSet {
    static let nestedSchemas  // $ref / $defs support
    static let imageInput     // Vision/image in prompt
    // Add as needed
}
```

**Test case categories:**
- Basic types (String, Int, Double, Bool)
- Multiple fields
- Optional fields (present and absent)
- Arrays (populated and empty)
- String enums
- Nested objects (capability-gated)
- Description with constraint hints

**Providers tested:**
- `AnthropicProvider` (uses tool_use or structured outputs)
- `OpenAIProvider` (uses response_format)
- `BedrockProvider` (uses Converse API tools)

### Layer 3: Local Validation

Test each constraint type:
- `.range()` - Boundaries, negative, overflow
- `.count()` - Empty, exact, min/max
- `.options()` - Valid, invalid, case sensitivity
- `.pattern()` - Matches, non-matches, empty

### Test Principles

1. **Real providers for integration** - Don't mock LLM responses
2. **Shared test cases** - Providers vary in implementation, not test logic
3. **Capability skipping** - Skip tests for unsupported features, don't fail
4. **Cost-aware** - Use cheapest models (Haiku, GPT-4o-mini) in CI
5. **Deterministic prompts** - Low temperature, explicit expected values

### Secret Management

```bash
# Local: .env file (gitignored)
ANTHROPIC_API_KEY=sk-...
OPENAI_API_KEY=sk-...
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...

# GitHub: Repository secrets
# Settings > Secrets > Actions
```

### CI Workflows

```yaml
# Unit tests - every push
swift test --filter "SchemaTests|ValidationTests"

# Integration tests - daily or on release
swift test --filter Integration
```

### References

- [JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
- [JSONSchema.swift](https://github.com/kylef/JSONSchema.swift) - Validator for testing
- [PydanticAI Testing](https://ai.pydantic.dev/testing/) - TestModel pattern

---

## Development Setup

### Local Development with Axii

To iterate on this package while developing Axii:

```swift
// In Axii's Package.swift or via Xcode
dependencies: [
    .package(path: "../Yrden")
]
```

Changes to Yrden are immediately reflected in Axii builds.

### Package.swift Skeleton

```swift
// swift-tools-version: 5.10
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Yrden",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Yrden", targets: ["Yrden"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "510.0.0"),
    ],
    targets: [
        .target(
            name: "Yrden",
            dependencies: ["YrdenMacros"]
        ),
        .macro(
            name: "YrdenMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "YrdenTests",
            dependencies: ["Yrden"]
        ),
    ]
)
```

---

## References

### PydanticAI Documentation
- Agents: https://ai.pydantic.dev/agents/
- Tools: https://ai.pydantic.dev/tools/
- Output: https://ai.pydantic.dev/output/

### Existing Swift Libraries
- SwiftAI: https://github.com/mi12labs/SwiftAI
- SwiftAgent: https://forums.swift.org/t/swiftagent-a-swift-native-agent-sdk-inspired-by-foundationmodels-and-using-its-tools/81634
- AgentSDK-Swift: https://github.com/fumito-ito/AgentSDK-Swift
- LLM.swift: https://github.com/eastriverlee/LLM.swift
- swift-llm: https://github.com/getgrinta/swift-llm

### MCP Specification
- https://modelcontextprotocol.io/

---

## Naming

**Yrden** - from The Witcher (Wiedźmin) saga by Andrzej Sapkowski.

The Yrden sign creates a magical circle that constrains and binds entities within its bounds. This metaphor fits perfectly:

| Yrden (Witcher Sign) | This Library |
|---------------------|--------------|
| Magic circle/trap | Schema constraints |
| Binds entities in place | Binds LLM output to Swift types |
| Structured, geometric | Structured output |
| Protective barrier | Type safety |
| Controls what's inside | Controls response format |

Sister project: **Axii** (also a Witcher sign - mind influence) is a macOS voice-to-text app that will use Yrden for its LLM capabilities.
