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

### Phase 1: Foundation
1. **Package setup** with macro target
2. **`@Schema` macro** - JSON schema generation from Swift types
3. **Provider protocol** + Anthropic implementation
4. **Basic types**: Message, ToolCall, Response

### Phase 2: Core Agent
5. **Tool protocol** with typed arguments
6. **Basic agent loop** (non-iterable first)
7. **Streaming** throughout

### Phase 3: Advanced Control
8. **Iterable agent loop** (`.iter()`)
9. **Retry/rejection** handling (`ToolRejection`)
10. **Result validators**

### Phase 4: Ecosystem
11. **Additional providers**: OpenAI, OpenRouter, Bedrock
12. **MLX** local model support
13. **MCP client**
14. **Sandbox execution**

### Phase 5: Skills & Polish
15. **Skills system** - Anthropic-style reusable capabilities
16. **Multi-agent handoffs**
17. **Guardrails**
18. **Usage limits**
19. **Documentation & examples**

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
