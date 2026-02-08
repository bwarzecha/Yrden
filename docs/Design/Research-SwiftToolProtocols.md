# Research: How Swift AI Libraries Handle Tool Type Erasure

> Research conducted 2026-02-07. Covers all major Swift agentic AI libraries and Apple's FoundationModels framework.

## Summary

Every library except AgentSDK-Swift uses Swift existentials (`[any Tool]`) for heterogeneous tool collections. None use dependency injection on the tool protocol. Yrden's two-tier approach (`Tool` base + `TypedTool` refinement) is unique and most similar to SwiftAgents' `AnyJSONTool`/`Tool` split.

---

## 1. Apple FoundationModels (iOS 26 / macOS 26)

**Source:** [developer.apple.com/documentation/foundationmodels/tool](https://developer.apple.com/documentation/foundationmodels/tool)

### Tool Protocol

```swift
protocol Tool<Arguments, Output>: Sendable {
    associatedtype Arguments: ConvertibleFromGeneratedContent
    associatedtype Output: PromptRepresentable

    var name: String { get }
    var description: String { get }
    var parameters: GenerationSchema { get }
    var includesSchemaInInstructions: Bool { get }

    func call(arguments: Arguments) async throws -> Output
}
```

### Storage

```swift
let session = LanguageModelSession(tools: [GetWeather(), FindRestaurants()])
// tools: [any Tool] — plain existential array
```

### Key Design Decisions

- **Two primary associated types** (`Arguments`, `Output`) — both erased in `[any Tool]`
- **No type erasure wrapper** — relies on Swift existential opening (SE-0352)
- **No dependency injection** — tools capture deps as stored properties
- **Schema from `@Generable` macro** on the Arguments struct
- **`@Guide` macro** for per-property constraints (`.count()`, `.range()`, `.anyOf()`)
- **`PartiallyGenerated`** type (all fields optional) for streaming structured output
- **Return type is `ToolOutput`** — simple string/structured content wrapper, no failure/deferred semantics

### Tool Definition Example

```swift
struct GetWeather: Tool {
    let name = "getWeather"
    let description = "Return current temperature for a city"

    @Generable
    struct Arguments {
        @Guide(description: "The city to check weather for")
        var city: String
    }

    func call(arguments: Arguments) async throws -> ToolOutput {
        let weather = try await WeatherService.shared.weather(for: arguments.city)
        return ToolOutput("\(arguments.city): \(weather.currentWeather.temperature.value) C")
    }
}
```

### References

- [Meet the Foundation Models framework - WWDC25](https://developer.apple.com/videos/play/wwdc2025/286/)
- [Deep dive into the Foundation Models framework - WWDC25](https://developer.apple.com/videos/play/wwdc2025/301/)
- [Expanding generation with tool calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling)

---

## 2. SwiftAI (mi12labs)

**Source:** [github.com/mi12labs/SwiftAI](https://github.com/mi12labs/SwiftAI)

### Tool Protocol

```swift
protocol Tool: Sendable {
    associatedtype Arguments: Generable
    associatedtype Output: PromptRepresentable

    var name: String { get }
    var description: String { get }
    static var parameters: Schema { get }

    func call(arguments: Arguments) async throws -> Output
    func call(_ data: Data) async throws -> any PromptRepresentable  // JSON bridge
}
```

### Storage

```swift
actor Chat<LLMType: LLM> {
    let tools: [any Tool]
}
```

### Key Design Decisions

- **Two associated types** (`Arguments`, `Output`), stored as `[any Tool]` existentials
- **Two `call` methods**: typed one for users, JSON `Data` one for the runtime
- **Default implementation** of `call(_ data:)` decodes JSON into typed `Arguments`
- **No dependency injection** — no context parameter
- **Schema from their own `@Generable` macro** → `Schema` enum → provider-specific JSON
- **`Schema` is a recursive enum** with constraints (`.range()`, `.pattern()`, `.anyOf()`)
- **Constraints sent as real JSON Schema keywords** to OpenAI (unlike Yrden's description-only approach)
- **Tool dispatch**: linear scan by name, calls JSON bridge method

### Tool Execution

```swift
func execute(toolCall: Message.ToolCall) async throws -> Message.ToolOutput {
    guard let tool = tools.first(where: { $0.name == toolCall.toolName }) else {
        throw LLMError.generalError("Tool '\(toolCall.toolName)' not found")
    }
    let argumentsData = toolCall.arguments.jsonString.data(using: .utf8) ?? Data()
    let result = try await tool.call(argumentsData)  // JSON-based call
    return .init(id: toolCall.id, toolName: toolCall.toolName, chunks: result.chunks)
}
```

### References

- [SwiftAI GitHub](https://github.com/mi12labs/SwiftAI)
- [SwiftAI on Hacker News](https://news.ycombinator.com/item?id=45052200)

---

## 3. SwiftAgent (1amageek)

**Source:** [github.com/1amageek/SwiftAgent](https://github.com/1amageek/SwiftAgent)

### Tool Protocol

Re-exports Apple's `FoundationModels.Tool` (or `OpenFoundationModels.Tool` for cross-platform):

```swift
#if USE_OTHER_MODELS
@_exported import OpenFoundationModels
public typealias Tool = OpenFoundationModels.Tool
#else
@_exported import FoundationModels
public typealias Tool = FoundationModels.Tool
#endif
```

### Storage

```swift
enum ToolConfiguration: Sendable {
    case preset(ToolPreset)
    case allowlist([any Tool])
    case custom([any Tool])
    case disabled
}
```

### Key Design Decisions

- **Existential opening for dispatch** — the critical pattern:

```swift
// Generic helper recovers concrete type from existential
private func executeToolWithHelper<T: Tool>(_ tool: T, arguments: GeneratedContent) async throws -> String {
    let typedArguments = try T.Arguments(arguments)  // existential opening recovers T
    let output = try await tool.call(arguments: typedArguments)
    return output.promptRepresentation.content
}
```

- **`Step` + `Tool` unification** — any `Step` that also conforms to `Tool` gets automatic bridging
- **`AnyStep` type erasure exists for Steps** but NOT for Tools
- **MCP via `MCPDynamicTool`** — concrete struct with `Arguments = GeneratedContent` (raw JSON)
- **`@resultBuilder`** for declarative tool composition
- **`ToolProvider` protocol** for factory-based tool creation

### MCP Integration

```swift
struct MCPDynamicTool: Tool, Sendable {
    typealias Arguments = GeneratedContent  // raw JSON
    typealias Output = String

    let name: String  // "mcp__servername__toolname"
    let description: String
}

extension MCPClient {
    func tools() async throws -> [MCPDynamicTool] { ... }
}
```

### References

- [SwiftAgent GitHub](https://github.com/1amageek/SwiftAgent)
- [SwiftAgent Forum Discussion](https://forums.swift.org/t/swiftagent-a-swift-native-agent-sdk-inspired-by-foundationmodels-and-using-its-tools/81634)
- [OpenFoundationModels](https://github.com/1amageek/OpenFoundationModels)

---

## 4. SwiftAgents (christopherkarani)

**Source:** [github.com/christopherkarani/SwiftAgents](https://github.com/christopherkarani/SwiftAgents)

### Three-Layer Tool System

**Layer 1: `AnyJSONTool` — Dynamic ABI (no associated types)**

```swift
protocol AnyJSONTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: [ToolParameter] { get }
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue
}
```

**Layer 2: `Tool` — Typed Protocol (with associated types)**

```swift
protocol Tool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Encodable & Sendable
    var name: String { get }
    var description: String { get }
    func execute(_ input: Input) async throws -> Output
}
```

**Layer 3: `AnyTool` — Concrete Type Eraser (box pattern)**

```swift
struct AnyTool: AnyJSONTool, Sendable {
    private var box: any AnyToolBox
    init(_ tool: some AnyJSONTool) { box = ToolBox(tool) }
    init(_ tool: some Tool) { box = ToolBox(AnyJSONToolAdapter(tool)) }
}
```

### Key Design Decisions

- **Most similar to Yrden's two-tier approach** (`AnyJSONTool` ≈ `Tool`, `Tool` ≈ `TypedTool`)
- **`AnyJSONToolAdapter<T: Tool>`** bridges typed → JSON (like Yrden's `TypedTool.call()` default)
- **Registry stores `[String: any AnyJSONTool]`** keyed by name
- **`ToolArgumentProcessor`** handles LLM quirks (e.g., `"42"` instead of `42`)
- **Input/output guardrails** on tools
- **Manual `[ToolParameter]`** for schema — no macro

### Bridging Pattern

```swift
struct AnyJSONToolAdapter<T: Tool>: AnyJSONTool, Sendable {
    let tool: T
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let input: T.Input = try SendableValue.dictionary(arguments).decode()
        let output = try await tool.execute(input)
        return try SendableValue(encoding: output)
    }
}
```

### References

- [SwiftAgents GitHub](https://github.com/christopherkarani/SwiftAgents)

---

## 5. AgentSDK-Swift (fumito-ito)

**Source:** [github.com/fumito-ito/AgentSDK-Swift](https://github.com/fumito-ito/AgentSDK-Swift)

### Tool Definition: Concrete Struct (Not a Protocol)

```swift
struct Tool<Context>: Sendable {
    let name: String
    let description: String
    let parameters: [Parameter]
    let availability: Availability
    private let executeClosure: @Sendable (ToolParameters, RunContext<Context>) async throws -> Any
}

typealias ToolParameters = [String: Any]
```

### Storage

```swift
// Homogeneous — all tools are the same concrete type
final class Agent<Context> {
    var tools: [Tool<Context>]
}
```

### Key Design Decisions

- **No protocol, no associated types** — sidesteps the problem entirely
- **Closure-based execution** — arguments `[String: Any]`, return `Any`
- **No type safety** on arguments or outputs
- **Manual `[Parameter]` array** for schema — no macro
- **Tool definitions not actually sent to the model** (hardcoded `nil` in OpenAI adapter)
- **`functionTool<Input: Decodable>()`** factory adds decode-time typing but no schema generation
- **`Availability` enum** for conditional tool enabling (`.always`, `.disabled`, `.whenEnabled`)
- **Only library with DI** — `RunContext<Context>` passed to execute closure

### Typed Factory

```swift
func functionTool<Context, Input: Decodable, Output>(
    name: String,
    description: String,
    function: @Sendable @escaping (Input, RunContext<Context>) async throws -> Output
) -> Tool<Context> {
    Tool(name: name, description: description) { parameters, runContext in
        let data = try JSONSerialization.data(withJSONObject: parameters)
        let input = try JSONDecoder().decode(Input.self, from: data)
        return try await function(input, runContext)
    }
}
```

### References

- [AgentSDK-Swift GitHub](https://github.com/fumito-ito/AgentSDK-Swift)
- [FunctionCalling Macro Library](https://github.com/fumito-ito/FunctionCalling) (separate project, not integrated)

---

## Comparison Matrix

| Aspect | Apple FM | SwiftAI | SwiftAgent | SwiftAgents | AgentSDK | **Yrden (proposed)** |
|--------|----------|---------|------------|-------------|----------|-----------|
| **Tool type** | Protocol (2 ATs) | Protocol (2 ATs) | Protocol (Apple's) | 2 protocols + struct | Concrete struct | Protocol (0 ATs on base) |
| **Storage** | `[any Tool]` | `[any Tool]` | `[any Tool]` | `[any AnyJSONTool]` | `[Tool<Ctx>]` | `[any Tool]` |
| **Type erasure** | Existentials | Existentials | Existentials | Box pattern | Not needed | Existentials |
| **JSON bridge** | Framework | `call(_ data:)` | Generic helper | `AnyJSONToolAdapter` | Closure | `call(argumentsJSON:)` |
| **Dependency injection** | None | None | None | None | `RunContext<Ctx>` | None (dropped) |
| **Schema source** | `@Generable` | `@Generable` | `@Generable` | Manual | Manual | `SchemaType` protocol |
| **Retry support** | None | None | None | None | None | `RetryingTool` wrapper |
| **Approval support** | None | None | None | None | None | `ApprovalRequired` + deferred |
| **Tool wrappers** | None | None | Result builder | Guardrails | Availability | `Retrying`, `Approval` |
| **Failure semantics** | throw | throw | throw | throw | throw | `ToolResult` (.success/.failure/.deferred) |

---

## Key Takeaways for Yrden

1. **`[any Tool]` existentials are the standard** — Apple, SwiftAI, and SwiftAgent all use them. Dropping `Deps` aligns Yrden with the ecosystem: `[any Tool]` instead of `[any Tool<Deps>]`.

2. **No library has DI on the tool protocol** — Apple, SwiftAI, SwiftAgent, SwiftAgents all pass zero context to tools. AgentSDK-Swift passes `RunContext<Context>` but via a concrete struct, not a protocol. Tools capture deps as stored properties.

3. **Two-tier protocol design is unique to Yrden** — closest parallel is SwiftAgents' `AnyJSONTool`/`Tool` split. Yrden's approach is more ergonomic because the JSON bridge lives on the base protocol as a default implementation.

4. **Retry/approval/deferred is a genuine differentiator** — no other library has these semantics. `ToolResult<T>` with explicit failure signaling and deferred execution sets Yrden apart.

5. **Existential opening works** — SwiftAgent demonstrates the `<T: Tool>` generic helper pattern for recovering concrete types from existentials. This is what Yrden's `TypedTool.call()` default does internally.

6. **`LiftedTool` becomes unnecessary** if `Deps` is dropped — no need to convert `Tool<Void>` to `Tool<D>` when all tools are just `any Tool`.

7. **`SimpleTool` becomes the only user-facing protocol** if `Deps` is dropped — `TypedTool` still exists (for `Args`/`Output`) but `SimpleTool` is equivalent since there's no `Deps` to constrain.
