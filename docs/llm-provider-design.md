# LLM Provider Design

> Design document for the Model/Provider architecture in Yrden.

## Overview

The LLM layer abstracts over multiple AI providers (Anthropic, OpenAI, OpenRouter, Bedrock, MLX) with a unified interface supporting streaming, tool calling, and structured output. Following PydanticAI's proven architecture, we separate **Model** (API format + capabilities) from **Provider** (connection + auth).

---

## Design Tenets

Core principles that guide architectural decisions:

| Tenet | Description | Rationale |
|-------|-------------|-----------|
| **Sendable everywhere** | All types crossing async boundaries are `Sendable` | Swift 6 concurrency safety |
| **Codable by default** | Core types (Message, ToolCall, AgentState) are `Codable` | Enables persistence, Handoff - but usage is opt-in |
| **Deps never Codable** | Dependencies are `Sendable` only, never serialized | Keeps deps flexible (DB connections, HTTP clients) |
| **Lazy initialization** | No I/O on construction, connections on first use | Enables extensions, widgets, fast startup |
| **State/behavior separation** | Observable state separate from execution logic | Enables SwiftUI binding, clean architecture |
| **Pausable execution** | Agent loop can checkpoint between steps | Enables Handoff, background resume |
| **Model-agnostic core** | Protocol doesn't assume network | Enables seamless cloud/on-device switching |

---

## Architecture: Model / Provider Split

Following PydanticAI's approach, we separate two concerns:

```
┌─────────────────────────────────────────────────────────────┐
│                         Model                               │
│  - Knows API format (Anthropic vs OpenAI vs Bedrock)        │
│  - Knows capabilities (tools, vision, temperature support)  │
│  - Implements complete() and stream()                       │
│  - Encodes requests, decodes responses                      │
│                                                             │
│  Contains:                                                  │
│  ┌───────────────────────────────────────────────────────┐  │
│  │              Provider (injected)                      │  │
│  │  - Connection details (baseURL)                       │  │
│  │  - Authentication method                              │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

**Why this split?**

| Use Case | Without Split | With Split |
|----------|---------------|------------|
| Direct Anthropic | `AnthropicProvider` | `AnthropicModel` + default provider |
| Azure OpenAI | `AzureOpenAIProvider` (new type) | `OpenAIChatModel` + `AzureProvider` |
| Ollama (local) | `OllamaProvider` (new type) | `OpenAIChatModel` + `LocalProvider` |
| Claude on Bedrock | `BedrockClaudeProvider` (new type) | `BedrockModel` + `BedrockProvider` |
| GPT-4 vs o1 | Same provider, flags for capabilities | Different Model types with correct capabilities |

The split avoids combinatorial explosion (N models × M backends) and centralizes capability handling per model family.

---

## Requirements

### Functional Requirements

1. **Multi-provider support** - Single interface works with Anthropic, OpenAI, OpenRouter, Bedrock, MLX (local)
2. **Streaming and non-streaming** - Both modes available, models implement both
3. **Tool calling** - Pass tool definitions, receive tool calls in response
4. **Structured output** - Request JSON output conforming to a schema
5. **Configuration** - Model selection, temperature, max tokens, stop sequences
6. **Capability awareness** - Models declare what they support (tools, vision, temperature)

### Non-Functional Requirements

1. **Swift 6 concurrency** - Full `Sendable` compliance, no data races
2. **Type safety** - Minimize `Any` types, use enums over stringly-typed values
3. **Testability** - Protocol-based for mocking, clear boundaries
4. **Extensibility** - New models/providers without changing core types
5. **Apple ecosystem ready** - Enable future Handoff, CloudKit, SwiftUI integration

---

## Constraints

### Provider API Differences

Each provider has different wire formats:

| Provider | Tool Format | Structured Output | Streaming |
|----------|-------------|-------------------|-----------|
| **Anthropic** | `tool_use` content blocks | `tool_use` or structured outputs beta | SSE |
| **OpenAI** | `tools` array, `function` type | `response_format` with `json_schema` | SSE |
| **Bedrock** | Converse API `toolConfig` | Tool-based | Converse stream |
| **OpenRouter** | OpenAI-compatible | Provider-dependent | SSE |
| **MLX** | Custom | Grammar-constrained | Callback |

Models handle format differences; Providers handle connection differences.

### Model Capability Differences

Even within the same provider, models have different capabilities:

| Model | Temperature | Tools | Vision | System Message |
|-------|-------------|-------|--------|----------------|
| Claude 3.5 | Yes | Yes | Yes | Yes |
| GPT-4o | Yes | Yes | Yes | Yes |
| o1/o3 | No | No | No | Limited |

Models declare their capabilities; the library validates requests against them.

### JSON Schema Subset

Not all JSON Schema features are supported across providers. We use the intersection:

- **Supported:** `type`, `properties`, `required`, `additionalProperties`, `enum`, `description`, `$ref`/`$defs`
- **Not supported:** `minimum`/`maximum`, `pattern`, `format`, `anyOf`/`allOf`

Constraints like ranges and patterns go into `description` field as hints, with local validation after response.

### Sendable Requirement

Swift 6 strict concurrency requires all types crossing async boundaries to be `Sendable`. This rules out `[String: Any]` for JSON representation.

---

## Design Decisions

### Decision 1: Model/Provider Split (PydanticAI-style)

**Choice:** Separate Model (format + capabilities) from Provider (connection + auth).

```swift
// Provider = connection configuration
public protocol Provider: Sendable {
    var baseURL: URL { get }
    func authenticate(_ request: inout URLRequest) async throws
}

// Model = full implementation, uses Provider
public protocol Model: Sendable {
    var name: String { get }
    var capabilities: ModelCapabilities { get }

    func complete(_ request: CompletionRequest) async throws -> CompletionResponse
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error>
}
```

**Rationale:**
- Avoids N×M type explosion (models × backends)
- Centralizes capability checking per model family
- Matches proven PydanticAI architecture
- Enables: Azure OpenAI, Ollama, Bedrock with multiple model families

**Alternatives considered:**
- Single `LLMProvider` type - rejected due to combinatorial complexity with Azure, Bedrock, local models

### Decision 2: Swift API Surface (TBD)

The Model/Provider split is the architecture. How we expose it to users is a secondary API design choice. Options under consideration:

**Option A: Configuration Struct (URLSession-style)**
```swift
let model = OpenAIChatModel("gpt-4o", configuration: .azure(endpoint: url, credential: cred))
```

**Option B: Static Factory Methods**
```swift
let model = OpenAIChatModel.azure("gpt-4o", endpoint: url, credential: cred)
```

**Option C: Namespace Enums**
```swift
let model = Models.OpenAI.azure("gpt-4o", endpoint: url, credential: cred)
```

**Decision:** Defer until implementation. All options preserve the same architecture.

### Decision 3: Request Type with Convenience Overloads

**Choice:** Single `CompletionRequest` struct with protocol extension overloads.

```swift
public struct CompletionRequest: Codable, Sendable {
    public let messages: [Message]
    public let tools: [ToolDefinition]?
    public let outputSchema: JSONValue?
    public let config: CompletionConfig

    public init(
        messages: [Message],
        tools: [ToolDefinition]? = nil,
        outputSchema: JSONValue? = nil,
        config: CompletionConfig = .default
    ) { ... }
}
```

**Rationale:**
- Many optional parameters make method signatures unwieldy
- Request type is extensible without breaking API
- Convenience overloads provide simple entry points

### Decision 4: Models Implement Both Streaming and Non-Streaming

**Choice:** Models implement `complete()` and `stream()` separately.

**Rationale:**
- Some providers have optimized non-streaming endpoints
- Streaming always has overhead (parsing SSE, accumulating)
- Models can choose most efficient path

### Decision 5: Fine-Grained Streaming Events

**Choice:** Detailed event enum for real-time UI updates.

```swift
public enum StreamEvent: Codable, Sendable {
    case contentDelta(String)
    case toolCallStart(id: String, name: String)
    case toolCallDelta(argumentsDelta: String)
    case toolCallEnd(id: String)
    case done(CompletionResponse)
}
```

**Rationale:**
- Tool call streaming matters for UX
- Matches native provider event granularity
- Coarse events lose information

### Decision 6: Closed Message Enum

**Choice:** Fixed enum for message types.

```swift
public enum Message: Codable, Sendable {
    case system(String)
    case user([ContentPart])
    case assistant(String, toolCalls: [ToolCall])
    case toolResult(toolCallId: String, content: String)
}

public enum ContentPart: Codable, Sendable {
    case text(String)
    case image(Data, mimeType: String)
}
```

**Rationale:**
- LLM APIs have fixed message structures
- Exhaustive `switch` catches missing cases at compile time
- No need for extensibility

### Decision 7: JSONValue for Schema Representation

**Choice:** Recursive enum instead of `[String: Any]` or `Data`.

```swift
public enum JSONValue: Sendable, Codable, Equatable {
    case string(String)
    case number(Double)
    case int(Int)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}
```

**Rationale:**
- `Sendable` compliant (required for Swift 6)
- `Codable` compliant (enables persistence)
- Type-safe, can inspect and transform
- Works for both static schemas (`@Schema`) and dynamic (MCP)

### Decision 8: Typed Error Enum

**Choice:** Specific error cases for actionable handling.

```swift
public enum LLMError: Error, Sendable {
    case rateLimited(retryAfter: TimeInterval?)
    case invalidAPIKey
    case contentFiltered(reason: String)
    case modelNotFound(String)
    case invalidRequest(String)
    case contextLengthExceeded(maxTokens: Int)
    case capabilityNotSupported(String)  // e.g., "temperature not supported by o1"
    case networkError(Error)
    case decodingError(Error)
}
```

**Rationale:**
- Rate limiting needs specific handling (retry with backoff)
- Capability errors help users understand model limitations
- Agent loop can make decisions based on error type

### Decision 9: Unified Tool System

**Choice:** Single `Tool` protocol with `JSONValue` arguments, `TypedTool` as convenience layer.

```swift
public protocol Tool: Sendable {
    var definition: ToolDefinition { get }
    func execute(_ arguments: JSONValue) async throws -> ToolOutput
}

public protocol TypedTool: Tool {
    associatedtype Arguments: SchemaType
    associatedtype Output: Sendable
    func execute(_ arguments: Arguments) async throws -> Output
}
```

**Rationale:**
- All tool sources (inline, MCP, dynamic) use same protocol
- Agent loop has single code path
- `TypedTool` provides compile-time safety without separate system

### Decision 10: Codable Opt-In for Serialization

**Choice:** Core types are `Codable`, but serialization features are opt-in.

```swift
// All core types are Codable
public enum Message: Codable, Sendable { ... }
public struct AgentState: Codable, Sendable { ... }

// But Deps are NOT required to be Codable
public struct Agent<Deps: Sendable, Output: SchemaType> {
    // Deps just needs Sendable
}

// Serialization is opt-in
let state = agent.currentState
let data = try JSONEncoder().encode(state)  // User chooses to serialize

// Resume provides fresh deps (not serialized)
agent.restore(savedState)
let result = try await agent.run("Continue", deps: freshDeps)
```

**Rationale:**
- Codable on types costs nothing if unused
- Enables persistence, Handoff, CloudKit for users who want it
- Deps stay flexible (database connections, HTTP clients)
- State (conversation) serializable, resources (deps) reconstructed

---

## Type Definitions

### Model Protocol

```swift
public protocol Model: Sendable {
    var name: String { get }
    var capabilities: ModelCapabilities { get }

    func complete(_ request: CompletionRequest) async throws -> CompletionResponse
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

public struct ModelCapabilities: Sendable, Codable {
    public let supportsTemperature: Bool
    public let supportsTools: Bool
    public let supportsVision: Bool
    public let supportsStructuredOutput: Bool
    public let supportsSystemMessage: Bool
    public let maxContextTokens: Int?

    public static let claude35 = ModelCapabilities(
        supportsTemperature: true,
        supportsTools: true,
        supportsVision: true,
        supportsStructuredOutput: true,
        supportsSystemMessage: true,
        maxContextTokens: 200_000
    )

    public static let o1 = ModelCapabilities(
        supportsTemperature: false,
        supportsTools: false,
        supportsVision: false,
        supportsStructuredOutput: false,
        supportsSystemMessage: false,  // Limited
        maxContextTokens: 128_000
    )
}
```

### Provider Protocol

```swift
public protocol Provider: Sendable {
    var baseURL: URL { get }
    func authenticate(_ request: inout URLRequest) async throws
}

// OpenAI-compatible providers
public protocol OpenAICompatibleProvider: Provider {}

public struct OpenAIProvider: OpenAICompatibleProvider {
    public let apiKey: String
    public var baseURL: URL { URL(string: "https://api.openai.com/v1")! }
}

public struct AzureOpenAIProvider: OpenAICompatibleProvider {
    public let endpoint: URL
    public let credential: AzureCredential
    public var baseURL: URL { endpoint }
}

public struct LocalProvider: OpenAICompatibleProvider {
    public let baseURL: URL
    public init(port: Int = 11434) {
        self.baseURL = URL(string: "http://localhost:\(port)/v1")!
    }
}
```

### Request/Response Types

```swift
public struct CompletionRequest: Codable, Sendable {
    public let messages: [Message]
    public let tools: [ToolDefinition]?
    public let outputSchema: JSONValue?
    public let config: CompletionConfig
}

public struct CompletionConfig: Codable, Sendable {
    public let temperature: Double?
    public let maxTokens: Int?
    public let stopSequences: [String]?

    public static let `default` = CompletionConfig()
}

public struct CompletionResponse: Codable, Sendable {
    public let content: String?
    public let toolCalls: [ToolCall]
    public let stopReason: StopReason
    public let usage: Usage
}

public enum StopReason: Codable, Sendable {
    case endTurn
    case toolUse
    case maxTokens
    case stopSequence
    case contentFiltered
}

public struct Usage: Codable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
}
```

### Message Types

```swift
public enum Message: Codable, Sendable {
    case system(String)
    case user([ContentPart])
    case assistant(String, toolCalls: [ToolCall])
    case toolResult(toolCallId: String, content: String)

    public static func user(_ text: String) -> Message {
        .user([.text(text)])
    }
}

public enum ContentPart: Codable, Sendable {
    case text(String)
    case image(Data, mimeType: String)
}
```

### Tool Types

```swift
public struct ToolDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
}

public struct ToolCall: Codable, Sendable {
    public let id: String
    public let name: String
    public let arguments: String  // Raw JSON from LLM
}

public enum ToolOutput: Codable, Sendable {
    case text(String)
    case json(JSONValue)
    case error(String)
}
```

---

## Convenience API

Protocol extensions provide simple entry points:

```swift
extension Model {
    // Simple string prompt
    public func complete(_ prompt: String) async throws -> CompletionResponse {
        try await complete(CompletionRequest(messages: [.user(prompt)]))
    }

    // Messages only
    public func complete(messages: [Message]) async throws -> CompletionResponse {
        try await complete(CompletionRequest(messages: messages))
    }

    // With tools
    public func complete(_ prompt: String, tools: [ToolDefinition]) async throws -> CompletionResponse {
        try await complete(CompletionRequest(messages: [.user(prompt)], tools: tools))
    }

    // With structured output
    public func complete<T: SchemaType>(_ prompt: String, outputType: T.Type) async throws -> CompletionResponse {
        try await complete(CompletionRequest(messages: [.user(prompt)], outputSchema: T.jsonSchema))
    }

    // Streaming
    public func stream(_ prompt: String) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(CompletionRequest(messages: [.user(prompt)]))
    }
}
```

---

## Apple Ecosystem Opportunities

The architecture enables future Apple-specific features (not required for v1, but design doesn't preclude them):

| Feature | Enabled By | Description |
|---------|------------|-------------|
| **Handoff** | Codable state | Continue conversation across Mac/iPhone/iPad |
| **CloudKit sync** | Codable state | Automatic conversation backup across devices |
| **SwiftUI binding** | Observable state | Reactive UI without glue code |
| **Siri/Shortcuts** | Lightweight init | Expose agent capabilities to system |
| **Background tasks** | Pausable execution | Long agent tasks survive app suspension |
| **On-device models** | Model-agnostic protocol | MLX/CoreML with same interface as cloud |
| **Share extension** | Lightweight init | Share content directly to agent |

These require no architectural changes - just additional implementation.

---

## Validation Flow

```
┌─────────────────────────────────────────────────────────────┐
│  1. LLM returns tool call / structured output               │
│     Raw JSON string                                         │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  2. Parse JSON → JSONValue                                  │
│     Validates JSON syntax                                   │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  3. Schema validation                                       │
│     JSONValue against ToolDefinition.inputSchema            │
│     Checks: types, required fields, enum values             │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  4. For TypedTool: Decode + Constraint validation           │
│     JSONDecoder → Swift type                                │
│     SchemaType.validate() for @Guide constraints            │
└───────────────────────────┬─────────────────────────────────┘
                            │
              ┌─────────────┴─────────────┐
              │                           │
           Valid                       Invalid
              │                           │
              ▼                           ▼
         Execute                 Return error to LLM
                                 (retry opportunity)
```

---

## Risks and Open Questions

### Risk 1: Streaming + Structured Output Compatibility

**Concern:** Not all providers support streaming while enforcing structured output.

**Status:** Needs POC testing with each provider.

**Mitigation:** May need to buffer stream and validate at end, or disable streaming for structured output on some providers.

### Risk 2: JSON Schema Validator Implementation

**Concern:** Need runtime JSON Schema validation for tool arguments.

**Options:**
1. Build minimal validator (only features we use)
2. Use existing Swift library
3. Skip validation, trust LLM (risky)

**Status:** Need to evaluate existing libraries or scope minimal implementation.

### Risk 3: Provider-Specific Edge Cases

**Concern:** Each provider has quirks not captured in abstraction.

**Examples:**
- Anthropic requires `additionalProperties: false`
- OpenAI strict mode has specific requirements
- Bedrock tool format differs significantly

**Mitigation:** Model implementations handle quirks, tests verify behavior.

### Risk 4: Bedrock Model Format Variations

**Concern:** Bedrock hosts multiple model families (Claude, Llama, Cohere) - do they all use the same Converse API format?

**Status:** Need to verify Bedrock Converse API handles all model families uniformly.

### Risk 5: AsyncThrowingStream Cancellation

**Concern:** Proper cleanup when stream is cancelled mid-response.

**Status:** Need to verify HTTP client handles cancellation correctly.

---

## Testing Strategy

### Unit Tests (No Network)

- `JSONValue` encoding/decoding
- `Message` construction and Codable round-trip
- `CompletionRequest` defaults
- `ModelCapabilities` validation
- Schema validation logic
- Error type coverage

### Integration Tests (Real Providers)

Shared test cases run against all models:

1. Simple completion (text response)
2. Multi-turn conversation
3. Tool call (single)
4. Tool call (multiple)
5. Structured output
6. Streaming text
7. Streaming tool calls
8. Error handling (invalid API key, rate limit simulation)
9. Capability validation (e.g., temperature on o1 should warn/error)

### Model Capability Flags

Tests skip unsupported features per model based on `ModelCapabilities`.

---

## Implementation Order

1. **Core types** - `JSONValue`, `Message`, `CompletionRequest`, `CompletionResponse`, `ModelCapabilities`
2. **Protocols** - `Model`, `Provider` with convenience extensions
3. **Anthropic model** - Primary development target
4. **Integration tests** - Against Anthropic
5. **OpenAI model** - Validates abstraction, different capabilities
6. **Provider variants** - Azure, Local (Ollama)
7. **Remaining models** - Bedrock, MLX

---

## References

- [PydanticAI Models](https://ai.pydantic.dev/models/) - Architecture inspiration
- [Anthropic Messages API](https://docs.anthropic.com/en/api/messages)
- [OpenAI Chat Completions](https://platform.openai.com/docs/api-reference/chat)
- [AWS Bedrock Converse](https://docs.aws.amazon.com/bedrock/latest/userguide/conversation-inference.html)
