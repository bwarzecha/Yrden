# Models and Providers

Yrden separates **Model** (API format, capabilities, request/response encoding) from **Provider** (authentication, connection, model discovery). This avoids an N x M type explosion and enables reuse -- for example, the OpenAI Chat Completions format works with OpenAI direct, Azure, Ollama, LM Studio, and vLLM, all with different Providers but the same wire format.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Provider Protocol](#provider-protocol)
- [Model Protocol](#model-protocol)
- [Built-in Providers](#built-in-providers)
  - [AnthropicProvider](#anthropicprovider)
  - [OpenAIProvider](#openaiprovider)
  - [BedrockProvider](#bedrockprovider)
  - [LocalProvider](#localprovider)
- [ModelCapabilities](#modelcapabilities)
  - [Predefined Capability Sets](#predefined-capability-sets)
- [Model Discovery](#model-discovery)
- [CachedModelList](#cachedmodellist)
- [Convenience Methods on Model](#convenience-methods-on-model)
- [Streaming](#streaming)
- [Request Validation](#request-validation)
- [CompletionConfig](#completionconfig)
- [ForeignThinkingBehavior](#foreignthinkingbehavior)
- [Retry Configuration](#retry-configuration)
- [Error Handling](#error-handling)

---

## Architecture Overview

```
Provider (auth + connection)      Model (API format + capabilities)
┌─────────────────────────┐      ┌──────────────────────────────┐
│ AnthropicProvider        │─────>│ AnthropicModel               │
│   - API key auth         │      │   - Messages API format      │
│   - x-api-key header     │      │   - Claude capabilities      │
│   - api.anthropic.com    │      │   - SSE streaming            │
└─────────────────────────┘      └──────────────────────────────┘

┌─────────────────────────┐      ┌──────────────────────────────┐
│ OpenAIProvider           │─────>│ OpenAIModel                  │
│   - Bearer token auth    │      │   - Chat Completions format  │
│   - api.openai.com       │      │   - Responses API routing    │
└─────────────────────────┘      └──────────────────────────────┘

┌─────────────────────────┐      ┌──────────────────────────────┐
│ LocalProvider            │─────>│ LocalModel                   │
│   - No auth              │      │   - Chat Completions format  │
│   - localhost:11434/v1   │      │   - Conservative defaults    │
└─────────────────────────┘      └──────────────────────────────┘

┌─────────────────────────┐      ┌──────────────────────────────┐
│ BedrockProvider          │─────>│ BedrockModel                 │
│   - AWS SigV4 signing    │      │   - Converse API format      │
│   - SDK-managed auth     │      │   - Multi-family detection   │
└─────────────────────────┘      └──────────────────────────────┘
```

This separation enables:
- **Azure OpenAI**: OpenAI wire format + Azure auth (custom Provider)
- **Ollama**: OpenAI wire format + no auth (LocalProvider)
- **Bedrock Claude**: Claude capabilities + AWS credentials (BedrockProvider)
- **Easy testing**: Mock providers for unit tests

---

## Provider Protocol

```swift
public protocol Provider: Sendable {
    /// Base URL for API requests.
    /// Model implementations append paths to this URL:
    /// - `/chat/completions` for OpenAI format
    /// - `/messages` for Anthropic format
    var baseURL: URL { get }

    /// Add authentication to a request.
    /// Called before each API request.
    func authenticate(_ request: inout URLRequest) async throws

    /// List available models from this provider.
    /// Returns a lazy stream -- models are fetched page-by-page as consumed.
    func listModels() -> AsyncThrowingStream<ModelInfo, Error>
}
```

There is also a marker protocol for providers that use the OpenAI-compatible API format:

```swift
public protocol OpenAICompatibleProvider: Provider {}
```

`OpenAIProvider` and `LocalProvider` both conform to `OpenAICompatibleProvider`, allowing `OpenAIModel` and `LocalModel` to share the `ChatCompletionsHandler` wire format implementation.

### ModelInfo

Returned by `listModels()` for model discovery:

```swift
public struct ModelInfo: Sendable, Codable, Equatable, Hashable {
    /// API identifier -- pass this when creating a Model instance.
    public let id: String

    /// Human-readable display name (e.g., "Claude 3.5 Sonnet").
    public let displayName: String

    /// When the model was created/released. May be nil.
    public let createdAt: Date?

    /// Provider-specific metadata.
    /// For Bedrock: scope, base model, input/output modalities.
    /// For OpenRouter: pricing, context length, etc.
    public let metadata: JSONValue?
}
```

---

## Model Protocol

```swift
public protocol Model: Sendable {
    /// Provider identifier (e.g., "anthropic", "openai", "bedrock", "local").
    /// Used to determine how to handle thinking blocks when switching providers.
    static var providerId: String { get }

    /// Model identifier (e.g., "claude-sonnet-4-5-20250514", "gpt-4o").
    var name: String { get }

    /// Capabilities this model supports.
    var capabilities: ModelCapabilities { get }

    /// How to handle thinking blocks from other providers.
    /// Defaults to `.drop`.
    var foreignThinkingBehavior: ForeignThinkingBehavior { get }

    /// Execute a completion request and return the full response.
    func complete(_ request: CompletionRequest) async throws -> CompletionResponse

    /// Execute a completion request and stream events.
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error>
}
```

All Model types are `Sendable` and can be shared across tasks.

---

## Built-in Providers

### AnthropicProvider

Connects to the Anthropic Messages API (`https://api.anthropic.com/v1`).

```swift
let provider = AnthropicProvider(apiKey: "sk-ant-...")
let model = AnthropicModel(name: "claude-sonnet-4-5-20250514", provider: provider)

let response = try await model.complete("What is Swift?")
print(response.content ?? "")
```

**Authentication**: `x-api-key` header + `anthropic-version: 2023-06-01`.

**Supported models**: All Claude families (3, 3.5, 4, 4.5). Capabilities are auto-detected from the model name:

| Model Family | Capability Preset | Context Window |
|---|---|---|
| Claude 4.5 Opus | `.claude45Opus` | 200K |
| Claude 4.5 Sonnet | `.claude45Sonnet` | 200K |
| Claude 4.5 Haiku | `.claude45Haiku` | 200K |
| Claude 4 Sonnet | `.claude4Sonnet` | 200K |
| Claude 3.5 Sonnet/Opus | `.claude35` | 200K |
| Claude 3.5 Haiku | `.claude35Haiku` | 200K |
| Claude 3 Haiku | `.claude3Haiku` | 200K |

**AnthropicModel parameters**:

```swift
AnthropicModel(
    name: "claude-sonnet-4-5-20250514",
    provider: provider,
    defaultMaxTokens: 4096,              // Default if not specified in request
    foreignThinkingBehavior: .drop       // How to handle thinking from other providers
)
```

### OpenAIProvider

Connects to the OpenAI API (`https://api.openai.com/v1`).

```swift
let provider = OpenAIProvider(apiKey: "sk-...")
let model = OpenAIModel(name: "gpt-4o", provider: provider)

let response = try await model.complete("What is Swift?")
```

**Authentication**: `Authorization: Bearer <key>`.

**API routing**: `OpenAIModel` intelligently routes between two APIs:
- **Chat Completions API** -- used for multi-turn conversations with tool results, complex history, and stop sequences.
- **Responses API** -- used for first-turn tool calling and simple requests. Better tool calling with GPT-5 family reasoning.

**Supported models**: GPT-4, GPT-4o, GPT-4.1, GPT-5, o1, o3, o4 families. Capabilities are auto-detected:

| Model Family | Capability Preset | Context Window | Notes |
|---|---|---|---|
| GPT-5 (gpt-5, gpt-5.1, gpt-5.2, gpt-5-mini, gpt-5-nano) | `.gpt5` | 400K | Full capabilities |
| GPT-4.1 (gpt-4.1, gpt-4.1-mini, gpt-4.1-nano) | `.gpt41` | ~1M | Full capabilities |
| GPT-4o, GPT-4o-mini | `.gpt4o` | 128K | Full capabilities |
| GPT-4 Turbo | `.gpt4Turbo` | 128K | Full capabilities |
| o1, o1-mini, o1-pro | `.o1` | 200K | No temperature, tools, vision, system, or structured output |
| o3, o3-mini | `.o3` | 200K | No temperature or system messages. Tools, vision, structured output OK |
| o4-mini | `.o4` | 200K | No temperature or system messages. Tools, vision, structured output OK |

**OpenAIModel parameters**:

```swift
OpenAIModel(
    name: "gpt-4o",
    provider: provider,
    defaultMaxTokens: 4096,
    retryConfig: .default,               // 2 retries with exponential backoff
    foreignThinkingBehavior: .drop
)
```

### BedrockProvider

Connects to AWS Bedrock via the Converse API. Uses the AWS SDK for request signing (SigV4) -- the `authenticate(_:)` method is a no-op since the SDK handles signing internally.

Three ways to create:

```swift
// Option 1: Explicit credentials
let provider = try BedrockProvider(
    region: "us-east-1",
    accessKeyId: "AKIA...",
    secretAccessKey: "...",
    sessionToken: nil                    // Optional, for temporary credentials
)

// Option 2: Named profile from ~/.aws/credentials
let provider = try BedrockProvider(
    region: "us-east-1",
    profile: "default"                   // Does NOT hit EC2 metadata service
)

// Option 3: Environment variables
// Reads AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN,
// AWS_REGION (or AWS_DEFAULT_REGION), AWS_PROFILE
let provider = try BedrockProvider.fromEnvironment()
```

**Usage**:

```swift
let model = BedrockModel(
    name: "anthropic.claude-haiku-4-5-20251001-v1:0",
    provider: provider
)
let response = try await model.complete("Hello!")
```

**Capability detection**: BedrockModel auto-detects capabilities by parsing the model ID. It strips inference profile prefixes (e.g., `us.`, `eu.`, `global.`) before matching:

| Model Family | Context Window | Notes |
|---|---|---|
| Claude (all families via Bedrock) | Same as direct Anthropic | Full capabilities |
| Amazon Nova | 300K | Full capabilities |
| Llama | 128K | Limited tool calling, no vision |
| Mistral | 32K | No vision |

**Inference profiles**: Bedrock supports cross-region routing via inference profile IDs (e.g., `us.anthropic.claude-sonnet-4-5-20250514-v1:0`). Pass the full profile ID as the model name.

### LocalProvider

Connects to any OpenAI-compatible server running locally. No authentication required.

```swift
// Presets with default ports
let provider = LocalProvider.ollama()     // http://localhost:11434/v1
let provider = LocalProvider.lmStudio()   // http://localhost:1234/v1
let provider = LocalProvider.vllm()       // http://localhost:8000/v1

// Custom port
let provider = LocalProvider.ollama(port: 12345)

// Fully custom URL
let provider = LocalProvider(
    baseURL: URL(string: "http://my-server:9090/v1")!,
    requestTimeout: 600                  // 10 minutes (default: 300s = 5 min)
)
```

**Usage**:

```swift
let model = LocalModel(name: "llama3.2", provider: provider)
let response = try await model.complete("Hello!")
```

**LocalModel defaults** -- conservative choices for local servers:
- `max_tokens` parameter uses legacy format (not `max_completion_tokens`)
- `tool_choice: "auto"` instead of `"required"` (safer for local models)
- No retries by default (local servers don't rate-limit)
- Default max tokens is nil (let the server decide)

```swift
LocalModel(
    name: "llama3.2",
    provider: provider,
    capabilities: .local,                // Override if you know the model's capabilities
    defaultMaxTokens: nil,               // nil = let server decide
    retryConfig: .none,                  // No retries for local
    foreignThinkingBehavior: .drop
)
```

---

## ModelCapabilities

Declares what features a specific model supports. Used for request validation and capability-based feature selection.

```swift
public struct ModelCapabilities: Sendable, Codable, Equatable, Hashable {
    /// Whether the model supports the temperature parameter.
    /// o1/o3/o4 models do NOT support temperature.
    public let supportsTemperature: Bool

    /// Whether the model supports tool/function calling.
    public let supportsTools: Bool

    /// Whether the model supports image inputs (vision).
    public let supportsVision: Bool

    /// Whether the model supports structured JSON output.
    public let supportsStructuredOutput: Bool

    /// Whether the model supports system messages.
    /// o1 has no system message support; o3/o4 also lack it.
    public let supportsSystemMessage: Bool

    /// Maximum context window size in tokens.
    /// nil means unknown or unlimited.
    public let maxContextTokens: Int?
}
```

### Predefined Capability Sets

Yrden provides predefined capability sets as static properties on `ModelCapabilities`. These are used by auto-detection in each Model implementation but can also be used when constructing models manually.

**Anthropic Claude**:

| Preset | Temperature | Tools | Vision | Structured Output | System | Context |
|---|---|---|---|---|---|---|
| `.claude45Opus` | Yes | Yes | Yes | Yes | Yes | 200K |
| `.claude45Sonnet` | Yes | Yes | Yes | Yes | Yes | 200K |
| `.claude45Haiku` | Yes | Yes | Yes | Yes | Yes | 200K |
| `.claude4Sonnet` | Yes | Yes | Yes | Yes | Yes | 200K |
| `.claude35` | Yes | Yes | Yes | Yes | Yes | 200K |
| `.claude35Haiku` | Yes | Yes | Yes | Yes | Yes | 200K |
| `.claude3Haiku` | Yes | Yes | Yes | Yes | Yes | 200K |

**OpenAI GPT**:

| Preset | Temperature | Tools | Vision | Structured Output | System | Context |
|---|---|---|---|---|---|---|
| `.gpt5` | Yes | Yes | Yes | Yes | Yes | 400K |
| `.gpt41` | Yes | Yes | Yes | Yes | Yes | ~1M |
| `.gpt4o` | Yes | Yes | Yes | Yes | Yes | 128K |
| `.gpt4Turbo` | Yes | Yes | Yes | Yes | Yes | 128K |

**OpenAI Reasoning**:

| Preset | Temperature | Tools | Vision | Structured Output | System | Context |
|---|---|---|---|---|---|---|
| `.o1` | No | No | No | No | No | 200K |
| `.o3` | No | Yes | Yes | Yes | No | 200K |
| `.o4` | No | Yes | Yes | Yes | No | 200K |

**Local**:

| Preset | Temperature | Tools | Vision | Structured Output | System | Context |
|---|---|---|---|---|---|---|
| `.local` | Yes | Yes | No | Yes | Yes | nil (unknown) |

---

## Model Discovery

Every Provider implements `listModels()` returning an `AsyncThrowingStream<ModelInfo, Error>`. This enables lazy, paginated discovery.

```swift
// Collect all models
let allModels = try await Array(provider.listModels())
for model in allModels {
    print("\(model.displayName): \(model.id)")
}

// Find first matching model (stops early, saves API calls for paginated providers)
for try await model in provider.listModels() {
    if model.id.contains("claude-sonnet") {
        print("Found: \(model.id)")
        break
    }
}
```

**Provider-specific behavior**:
- **Anthropic**: Paginates with cursor-based `after_id`. Returns newest models first.
- **OpenAI**: Returns all models in a single response. Filters to chat-capable models (gpt-*, o1-*, o3-*, o4-*, chatgpt-*). Sorted newest first.
- **Bedrock**: Lists both foundation models and inference profiles. Includes metadata for type, scope, base model, and modalities.
- **Local**: Returns all models the server reports, no filtering. Sorted newest first.

---

## CachedModelList

An actor that caches model lists to avoid repeated API calls.

```swift
let cache = CachedModelList(ttl: 3600)  // 1-hour TTL

// First call fetches from API
let models = try await cache.models(from: provider)

// Subsequent calls return cached data (until TTL expires)
let models2 = try await cache.models(from: provider)

// Force refresh
let fresh = try await cache.models(from: provider, forceRefresh: true)

// Clear specific provider cache
cache.clear(for: provider)

// Clear all
cache.clearAll()
```

The cache key is derived from the provider type name and base URL, so different provider instances pointing to different servers maintain separate caches.

---

## Convenience Methods on Model

The `Model` protocol includes convenience extensions for common use cases, so you don't need to construct a `CompletionRequest` manually for simple operations.

```swift
// Simple text completion
let response = try await model.complete("What is Swift?")
print(response.content ?? "")

// With messages
let response = try await model.complete(messages: [
    .system("Be brief."),
    .user("Hello")
])

// With tools
let response = try await model.complete("What's the weather?", tools: [weatherTool])

// With structured output schema
let response = try await model.complete("Analyze this text", outputSchema: mySchema)

// Stream a simple prompt
for try await event in model.stream("Tell me a story") {
    if case .contentDelta(let text, _) = event {
        print(text, terminator: "")
    }
}

// Stream with messages
for try await event in model.stream(messages: [.system("Be brief"), .user("Hello")]) {
    // ...
}
```

For full control, construct a `CompletionRequest` directly:

```swift
let request = CompletionRequest(
    messages: [
        .system("You are a helpful assistant."),
        .user("What's the weather in Paris?")
    ],
    tools: [weatherTool],
    outputSchema: analysisSchema,
    config: CompletionConfig(temperature: 0.7, maxTokens: 1000)
)

let response = try await model.complete(request)
```

---

## Streaming

Streaming is supported by all providers via `model.stream(_:)`, which returns an `AsyncThrowingStream<StreamEvent, Error>`.

### StreamEvent

```swift
public enum StreamEvent: Sendable {
    /// Incremental text content. `kind` is `.text` (default) or `.thinking`.
    case contentDelta(String, kind: ContentKind = .text)

    /// Start of a tool call (id + tool name).
    case toolCallStart(id: String, name: String)

    /// Incremental tool call arguments JSON.
    case toolCallDelta(argumentsDelta: String)

    /// Tool call complete and ready to execute.
    case toolCallEnd(id: String)

    /// Stream complete. Contains the full CompletionResponse.
    /// Always the last event in a stream.
    case done(CompletionResponse)
}
```

### Event Flow Examples

**Text-only response**:
```
contentDelta("Hello")
contentDelta(" world!")
done(response)
```

**Tool call response**:
```
toolCallStart(id: "call_1", name: "search")
toolCallDelta(argumentsDelta: "{\"query\":")
toolCallDelta(argumentsDelta: "\"swift\"}")
toolCallEnd(id: "call_1")
done(response)
```

**Mixed response**:
```
contentDelta("Let me search for that...")
toolCallStart(id: "call_1", name: "search")
toolCallDelta(...)
toolCallEnd(id: "call_1")
done(response)
```

### ContentKind

Differentiates thinking/reasoning content from regular text in stream deltas:

```swift
public enum ContentKind: String, Sendable {
    case text      // Regular visible content
    case thinking  // Internal reasoning (extended thinking)
}
```

Usage:

```swift
for try await event in model.stream("Analyze this") {
    switch event {
    case .contentDelta(let text, let kind):
        if kind == .thinking {
            // Display in a collapsed/styled section
        } else {
            print(text, terminator: "")
        }
    case .toolCallStart(_, let name):
        print("\nCalling \(name)...")
    case .done(let response):
        print("\nDone. Tokens: \(response.usage.totalTokens)")
    default:
        break
    }
}
```

---

## Request Validation

Call `validateRequest(_:)` on any Model to check a request against model capabilities before sending. This catches mismatches early with clear error messages.

```swift
let request = CompletionRequest(
    messages: [.system("Be helpful"), .user("Hello")],
    config: CompletionConfig(temperature: 0.7)
)

do {
    try model.validateRequest(request)
} catch {
    print(error)  // e.g., "temperature not supported by o1-mini"
}
```

Validation checks:
- **Temperature**: Throws if set but `supportsTemperature` is false.
- **Tools**: Throws if tools provided but `supportsTools` is false.
- **Structured output**: Throws if `outputSchema` set but `supportsStructuredOutput` is false.
- **System messages**: Throws if a `.system` message is present but `supportsSystemMessage` is false.
- **Vision**: Throws if image content parts are present but `supportsVision` is false.

All Model implementations call `validateRequest` automatically in `complete(_:)` and `stream(_:)`.

---

## CompletionConfig

Configuration parameters for completion requests. Not all parameters are supported by all models -- `validateRequest` catches mismatches.

```swift
public struct CompletionConfig: Sendable {
    /// Sampling temperature (0.0 to 2.0). Not supported by o1/o3/o4.
    public let temperature: Double?

    /// Nucleus sampling (0.0 to 1.0). Recommend altering temperature OR topP, not both.
    public let topP: Double?

    /// Maximum tokens to generate.
    public let maxTokens: Int?

    /// Stop sequences that halt generation.
    public let stopSequences: [String]?

    /// Whether to store the response for later retrieval (OpenAI-specific).
    public let store: Bool?

    /// Cache key for prompt caching to optimize costs (OpenAI-specific).
    public let promptCacheKey: String?

    /// Retention policy for prompt cache.
    public let promptCacheRetention: PromptCacheRetention?

    /// Override foreign thinking behavior for this request.
    public let foreignThinkingBehavior: ForeignThinkingBehavior?
}
```

**Prompt cache retention**:

```swift
public enum PromptCacheRetention: String, Sendable {
    case inMemory = "in-memory"   // Default, shorter retention
    case extended = "24h"         // 24-hour extended caching
}
```

**Usage**:

```swift
// Default config (no overrides)
let config = CompletionConfig.default

// Custom config
let config = CompletionConfig(
    temperature: 0.7,
    topP: nil,
    maxTokens: 1000,
    stopSequences: ["END"],
    store: true,
    promptCacheKey: "my-cache",
    promptCacheRetention: .extended
)

let request = CompletionRequest(
    messages: [.user("Hello")],
    config: config
)
```

---

## ForeignThinkingBehavior

Controls how thinking blocks from other providers are handled when switching providers mid-conversation. For example, if an Anthropic model generated thinking blocks and you then send the conversation to an OpenAI model, this setting determines what happens to those blocks.

```swift
public enum ForeignThinkingBehavior: String, Sendable {
    /// Drop all foreign thinking blocks entirely (default).
    /// Safest option for production use.
    case drop

    /// Convert visible thinking content to text blocks.
    /// Useful for debugging or preserving reasoning context across providers.
    case convertToText
}
```

Set at model creation time or override per-request:

```swift
// Per-model default
let model = AnthropicModel(
    name: "claude-sonnet-4-5-20250514",
    provider: provider,
    foreignThinkingBehavior: .convertToText
)

// Per-request override
let config = CompletionConfig(foreignThinkingBehavior: .convertToText)
let request = CompletionRequest(messages: [...], config: config)
```

---

## Retry Configuration

Yrden implements exponential backoff with jitter for transient HTTP errors. Retry behavior varies by provider type.

```swift
public struct RetryConfig: Sendable {
    /// Maximum retry attempts (0 = no retries).
    public let maxRetries: Int

    /// Initial delay before first retry (seconds).
    public let initialDelay: TimeInterval

    /// Maximum delay between retries (seconds).
    public let maxDelay: TimeInterval

    /// Jitter factor (0.0-1.0) to prevent thundering herd.
    public let jitterFactor: Double
}
```

**Presets**:

| Preset | Max Retries | Initial Delay | Max Delay |
|---|---|---|---|
| `.default` | 2 | 0.5s | 30s |
| `.none` | 0 | -- | -- |
| `.aggressive` | 5 | 1.0s | 60s |

**Retriable status codes**: 408 (timeout), 409 (conflict), 429 (rate limited), 500+ (server errors).

**Provider defaults**:
- `OpenAIModel`: `RetryConfig.default` (2 retries)
- `LocalModel`: `RetryConfig.none` (no retries -- local servers don't rate-limit)
- `AnthropicModel`: No retry wrapper (handled at the caller level)
- `BedrockModel`: No retry wrapper (AWS SDK may handle its own retries)

Custom configuration:

```swift
let model = OpenAIModel(
    name: "gpt-4o",
    provider: provider,
    retryConfig: RetryConfig(maxRetries: 5, initialDelay: 1.0, maxDelay: 60)
)
```

---

## Error Handling

All providers map errors to `LLMError`, enabling consistent error handling across providers.

```swift
public enum LLMError: Error, Sendable {
    case rateLimited(retryAfter: TimeInterval?)
    case invalidAPIKey
    case contentFiltered(reason: String)
    case modelNotFound(String)
    case invalidRequest(String)
    case contextLengthExceeded(maxTokens: Int)
    case capabilityNotSupported(String)
    case networkError(String)
    case decodingError(String)
    case serverError(String)
}
```

**Error handling example**:

```swift
do {
    let response = try await model.complete(request)
} catch let error as LLMError {
    switch error {
    case .rateLimited(let retryAfter):
        if let delay = retryAfter {
            try await Task.sleep(for: .seconds(delay))
        }
        // retry...
    case .contextLengthExceeded(let maxTokens):
        print("Context too long, max: \(maxTokens)")
    case .invalidAPIKey:
        print("Check your API key")
    case .capabilityNotSupported(let detail):
        print("Not supported: \(detail)")
    case .modelNotFound(let model):
        print("Model not found: \(model)")
    default:
        print("Error: \(error.localizedDescription)")
    }
}
```

---

## CompletionResponse

The response from any Model's `complete(_:)` call:

```swift
let response = try await model.complete(request)

// Check for refusal
if let refusal = response.refusal {
    print("Model declined: \(refusal)")
    return
}

// Convenience properties
if let text = response.content {         // Combined text content
    print(text)
}
if let thinking = response.thinking {    // Combined thinking content
    print("[Thinking] \(thinking)")
}
for call in response.toolCalls {         // All tool calls
    print("Tool: \(call.name)")
}

// Fine-grained block iteration (preserves exact ordering for cache compatibility)
for block in response.contentBlocks {
    switch block {
    case .text(let text):
        print(text)
    case .thinking(let thinkingBlock):
        if let content = thinkingBlock.content {
            print("[Thinking] \(content)")
        }
    case .toolUse(let call):
        print("Call \(call.name) with \(call.arguments)")
    }
}

// Token usage
print("Input: \(response.usage.inputTokens)")
print("Output: \(response.usage.outputTokens)")
print("Total: \(response.usage.totalTokens)")

// Prompt caching stats (OpenAI)
if let cached = response.usage.cachedTokens, cached > 0 {
    print("Cached: \(cached) tokens")
}

// Reasoning tokens (o-series, GPT-5)
if let reasoning = response.usage.reasoningTokens, reasoning > 0 {
    print("Reasoning: \(reasoning) tokens")
}

// Stop reason
switch response.stopReason {
case .endTurn:          print("Natural finish")
case .toolUse:          print("Wants to call tools")
case .maxTokens:        print("Truncated -- hit token limit")
case .stopSequence:     print("Hit a stop sequence")
case .contentFiltered:  print("Blocked by content filter")
}
```
