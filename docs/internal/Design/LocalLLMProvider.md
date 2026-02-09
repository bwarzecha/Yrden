# Local LLM Support: LM Studio & Ollama

## TL;DR

Both LM Studio and Ollama expose **OpenAI-compatible APIs** (`/v1/chat/completions`). Yrden already has `OpenAICompatibleProvider` marker protocol and `OpenAIModel` that handles the wire format. A single `LocalProvider` struct (~30 lines) is all we need. One provider, configurable URL, works for both.

**One blocker**: `OpenAIModel.shouldUseResponsesAPI()` currently routes most requests to `/v1/responses`, which local servers don't support. This needs a bypass mechanism.

---

## Research Summary

### API Compatibility Matrix

| Feature | OpenAI (Real) | LM Studio | Ollama |
|---------|--------------|-----------|--------|
| **Endpoint** | `api.openai.com/v1` | `localhost:1234/v1` | `localhost:11434/v1` |
| **Auth** | Bearer token required | None | None (any string works) |
| **`/v1/chat/completions`** | Yes | Yes | Yes |
| **`/v1/responses`** | Yes | Yes | Partial (non-stateful) |
| **`/v1/models`** | Yes | Yes | Yes |
| **Tool calling** | Yes | Yes | Yes (model-dependent) |
| **`tool_choice` (string)** | `auto/none/required` | `auto/none/required`* | Partial (docs say no) |
| **`tool_choice` (object)** | Yes | **No** | **No** |
| **`response_format: json_object`** | Yes | **No** | Yes |
| **`response_format: json_schema`** | Yes | Yes | Yes |
| **Streaming (text)** | SSE | SSE | SSE |
| **Streaming (tool calls)** | Incremental with `index` | Incremental with `index` | Single chunk, **missing `index`** |
| **Image input** | URL or base64 | URL or base64 | **Base64 only** |

*LM Studio: `"required"` only works on llama.cpp engine, not MLX.

### Live Test Results

**LM Studio** (`http://localhost:1234/v1`, qwen3-4b loaded):
- Chat completions: works, identical OpenAI format
- Tool calling: works, returns `finish_reason: "tool_calls"`, tool IDs are numeric strings
- Structured output: `json_schema` works, `json_object` returns error
- Streaming: standard SSE, works correctly
- Quirks: `content` is `""` not `null` on tool calls, `tool_calls` is `[]` not `null` when absent, extra `reasoning_content` field

**Ollama** (`http://localhost:11434/v1`, qwen3:30b):
- Chat completions: works, OpenAI-compatible format
- Tool calling: works with capable models (30B+), small models (0.6B) emit tool calls as text
- Structured output: both `json_object` and `json_schema` work
- Streaming: SSE works, but tool calls arrive as single chunk (not incremental), missing `index` field in streamed tool calls
- Quirks: extra `reasoning` field (not `reasoning_content`), `max_tokens` counts reasoning tokens too

### Key Differences from Real OpenAI API

1. **No `/v1/responses` (reliably)** - Local servers don't fully support the Responses API
2. **`tool_choice` limitations** - Object form (`{"type":"function","function":{"name":"..."}}`) unsupported by both
3. **Streaming tool call `index`** - Missing in Ollama, causing issues with index-based accumulation
4. **Extra fields** - `reasoning_content` (LM Studio), `reasoning` (Ollama) in responses
5. **`json_object` not universal** - LM Studio only supports `json_schema`, not `json_object`
6. **Model capabilities vary** - No standard way to know if a local model supports tools/structured output

---

## Proposed Solution

### Option A: Minimal LocalProvider (Recommended)

A simple provider struct + a way to force Chat Completions API routing.

```swift
/// Provider for local OpenAI-compatible servers (LM Studio, Ollama, vLLM, etc.)
public struct LocalProvider: Provider, OpenAICompatibleProvider, Sendable {
    public let baseURL: URL
    private let apiKey: String?

    public init(baseURL: URL, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    public func authenticate(_ request: inout URLRequest) async throws {
        request.setValue(HTTPHeaderValue.applicationJSON, forHTTPHeaderField: HTTPHeaderField.contentType)
        if let apiKey {
            request.setValue(HTTPHeaderValue.bearerPrefix + apiKey, forHTTPHeaderField: HTTPHeaderField.authorization)
        }
    }

    public func listModels() -> AsyncThrowingStream<ModelInfo, Error> {
        // Fetch from /v1/models, return all (no filtering by prefix)
    }
}
```

Usage:

```swift
// LM Studio
let lmStudio = LocalProvider(baseURL: URL(string: "http://localhost:1234/v1")!)
let model = OpenAIModel(name: "qwen3-4b", provider: lmStudio)

// Ollama
let ollama = LocalProvider(baseURL: URL(string: "http://localhost:11434/v1")!)
let model = OpenAIModel(name: "qwen3:30b", provider: ollama)

// Remote self-hosted (vLLM with auth)
let vllm = LocalProvider(
    baseURL: URL(string: "https://my-vllm.example.com/v1")!,
    apiKey: "my-key"
)
```

**Pros:**
- Minimal code (~50 lines)
- Reuses 100% of existing `OpenAIModel` logic
- Works for any OpenAI-compatible server (vLLM, LocalAI, LM Deploy, etc.)
- No new protocols or abstractions

**Cons:**
- Requires solving the Responses API routing problem
- `capabilities(for:)` in `OpenAIModel` won't recognize local model names
- No auto-detection of what the server supports

### Option B: LocalProvider + LocalModel (More Control)

Separate `LocalModel` that wraps `OpenAIModel` behavior but never uses Responses API and allows user-specified capabilities.

**Pros:**
- Full control over routing and capabilities
- Clean separation from cloud OpenAI behavior

**Cons:**
- Duplicates significant `OpenAIModel` code or requires extracting shared internals
- More maintenance surface

### Recommendation: Option A with Two Fixes

Option A is the right approach. The two issues it has are solvable:

#### Fix 1: Responses API Routing

`OpenAIModel.shouldUseResponsesAPI()` needs to respect a flag. Three sub-options:

**1a. Provider-level flag (cleanest)**
Add a property to `OpenAICompatibleProvider`:
```swift
public protocol OpenAICompatibleProvider: Provider {
    /// Whether this provider supports the Responses API (/v1/responses).
    /// Default: true (OpenAI). Override to false for local servers.
    var supportsResponsesAPI: Bool { get }
}

extension OpenAICompatibleProvider {
    public var supportsResponsesAPI: Bool { true }
}
```

Then in `shouldUseResponsesAPI()`:
```swift
private func shouldUseResponsesAPI(_ request: CompletionRequest) -> Bool {
    guard provider.supportsResponsesAPI else { return false }
    // ... existing logic
}
```

**1b. OpenAIModel init parameter**
```swift
public init(
    name: String,
    provider: any Provider & OpenAICompatibleProvider,
    useResponsesAPI: Bool = true,  // false for local
    ...
)
```

**1c. Auto-detect from model name**
If the model name doesn't match any known OpenAI model (gpt-*, o1-*, o3-*, o4-*), skip Responses API.

**Recommendation: 1a** - it's semantically correct (the *provider* doesn't support it, not the model), and `LocalProvider` simply returns `false`.

#### Fix 2: Capabilities for Unknown Models

`OpenAIModel.capabilities(for:)` falls back to `.gpt5` for unknown model names. For local models, this is wrong (they probably don't have 400K context). Two sub-options:

**2a. Accept capabilities in OpenAIModel init**
```swift
public init(
    name: String,
    provider: any Provider & OpenAICompatibleProvider,
    capabilities: ModelCapabilities? = nil,  // nil = auto-detect from name
    ...
)
```

If `capabilities` is provided, use it. Otherwise, fall back to `capabilities(for:)`.

**2b. Add a `.local` preset**
```swift
extension ModelCapabilities {
    /// Conservative defaults for local models.
    public static let local = ModelCapabilities(
        supportsTemperature: true,
        supportsTools: true,
        supportsVision: false,
        supportsStructuredOutput: true,
        supportsSystemMessage: true,
        maxContextTokens: nil  // Unknown
    )
}
```

**Recommendation: 2a + 2b** - Allow explicit override AND provide a sensible default.

---

## Streaming Robustness

### Missing `index` in Ollama Tool Calls

Ollama streams tool calls without the `index` field. Current code in `processToolCallDelta`:
```swift
let index = delta.index  // Will crash or be 0 if missing
```

**Fix**: Default to 0 when `index` is nil, and use tool call ID to disambiguate if multiple calls arrive:
```swift
let index = delta.index ?? accumulatedToolCalls.count  // Or 0 for single tool calls
```

This is already partially handled since `OpenAIStreamToolCall.index` could be made optional in the Codable type.

### Extra Fields (reasoning, reasoning_content)

Both servers add non-standard fields. Swift's `Codable` with `JSONDecoder` already ignores unknown keys by default, so these are safe. No code changes needed.

### Content `""` vs `null`

LM Studio returns empty string `""` for content when there are tool calls (OpenAI returns `null`). Current decoding handles this correctly since we check `!content.isEmpty` before using it.

---

## Structured Output Strategy

Use `response_format: { type: "json_schema" }` exclusively:
- Supported by both LM Studio and Ollama
- Matches what Yrden already generates in `encodeRequest()`
- More reliable than `json_object` (which LM Studio doesn't support)
- Provides schema-constrained output via grammar sampling (GBNF/Outlines)

**Caveat**: Small models (<7B params) produce unreliable structured output even with grammar constraints. The values may be syntactically valid JSON but semantically wrong. Document this limitation.

---

## Implementation Plan

### Step 1: Add `supportsResponsesAPI` to OpenAICompatibleProvider
- Add protocol property with default `true`
- Update `shouldUseResponsesAPI()` to check it
- `OpenAIProvider` inherits default (true)
- ~5 lines changed

### Step 2: Allow capabilities override in OpenAIModel init
- Add optional `capabilities` parameter
- Add `.local` preset to `ModelCapabilities`
- ~10 lines changed

### Step 3: Create LocalProvider
- New file: `Sources/Yrden/Providers/Local/LocalProvider.swift`
- `LocalProvider` struct conforming to `OpenAICompatibleProvider`
- `supportsResponsesAPI` returns `false`
- `listModels()` returns all models (no gpt-*/o1-* filtering)
- ~60 lines

### Step 4: Make streaming tool call index optional
- Change `OpenAIStreamToolCall.index` from `Int` to `Int?`
- Default to `accumulatedToolCalls.count` when nil
- ~3 lines changed

### Step 5: Integration test
- Test against LM Studio (if running)
- Test against Ollama (if running)
- Guard with environment variable or availability check
- Test: simple completion, tool calling, structured output, streaming

**Total estimated changes: ~80 lines of new code, ~20 lines modified.**

---

## Usage Examples

```swift
import Yrden

// --- LM Studio ---
let lmStudio = LocalProvider(baseURL: URL(string: "http://localhost:1234/v1")!)
let qwen = OpenAIModel(
    name: "qwen3-4b",
    provider: lmStudio,
    capabilities: .local
)

let response = try await qwen.complete("What is Swift?")
print(response.content ?? "")

// --- Ollama ---
let ollama = LocalProvider(baseURL: URL(string: "http://localhost:11434/v1")!)
let llama = OpenAIModel(
    name: "qwen3:30b",
    provider: ollama,
    capabilities: ModelCapabilities(
        supportsTemperature: true,
        supportsTools: true,
        supportsVision: false,
        supportsStructuredOutput: true,
        supportsSystemMessage: true,
        maxContextTokens: 32_768
    )
)

// Streaming
for try await event in llama.stream("Tell me about Swift") {
    if case .contentDelta(let text) = event {
        print(text, terminator: "")
    }
}

// Tool calling
let response = try await llama.complete("What's the weather?", tools: [weatherTool])

// Structured output
let analysis = try await llama.generate("Analyze this text", as: Analysis.self)

// --- Agent integration ---
let agent = Agent<Void, String>(
    model: llama,
    tools: [searchTool, calculatorTool],
    systemPrompt: "You are a helpful assistant."
)
let result = try await agent.run("Research quantum computing")
```

---

## Limitations & Gotchas

### Model-Dependent Behavior
- **Tool calling**: Only works with models trained for it (Qwen 2.5+, Llama 3.1+, Mistral). Small models (<7B) may emit tool calls as plain text.
- **Structured output**: Grammar sampling guarantees valid JSON structure but not semantic correctness. Smaller models produce worse results.
- **`max_tokens`**: On Ollama with thinking models (Qwen3), reasoning tokens count against `max_tokens`. A request with `max_tokens: 50` may produce 0 content tokens if the model used all 50 for internal reasoning.

### Server-Specific
- **LM Studio must be running** as a desktop app. Cannot be daemonized.
- **Ollama streaming + tools** is buggy on the `/v1` endpoint (missing `index`, chunks may arrive all at once).
- **Ollama's OpenAI compatibility is explicitly "experimental"** and subject to breaking changes.
- **LM Studio defaults to loaded model** if you pass an unrecognized model name (no error).

### Not Supported on Local Servers
- `tool_choice` as object (`{"type":"function","function":{"name":"..."}}`)
- `logprobs`, `n` (multiple completions), `logit_bias`
- Image URLs (Ollama only accepts base64)
- Prompt caching (`prompt_cache_key`, `prompt_cache_retention`)
- `store` parameter

---

## References

- [LM Studio OpenAI Compatibility](https://lmstudio.ai/docs/developer/openai-compat)
- [LM Studio Tool Use](https://lmstudio.ai/docs/developer/openai-compat/tools)
- [LM Studio Structured Output](https://lmstudio.ai/docs/developer/openai-compat/structured-output)
- [Ollama OpenAI Compatibility](https://docs.ollama.com/api/openai-compatibility)
- [Ollama Structured Outputs](https://docs.ollama.com/capabilities/structured-outputs)
- [Ollama Tool Support](https://ollama.com/blog/tool-support)
- [Ollama streaming tool calls issue #9084](https://github.com/ollama/ollama/issues/9084)
- [Ollama missing tool_calls index #7881](https://github.com/ollama/ollama/issues/7881)
- [LM Studio tool_choice object issue #670](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/670)
