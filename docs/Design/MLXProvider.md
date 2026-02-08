# MLX Provider Design

Local model inference on Apple Silicon via mlx-swift-lm.

## Problem

Yrden's existing providers (Anthropic, OpenAI, Bedrock) are HTTP-based cloud APIs. For local development, testing without API costs, and offline use, we need a provider that runs models directly on-device. Apple's MLX framework is the best option for Apple Silicon.

**Key differences from HTTP providers:**

| Aspect | HTTP Providers | MLX Provider |
|---|---|---|
| Transport | URLRequest → JSON response | In-process inference |
| Model loading | Instant (API handles it) | Download + load into GPU memory (seconds to minutes) |
| Authentication | API keys | None (local) |
| Model selection | String ID → remote model | HuggingFace ID → local weights |
| Tool call format | Provider-defined JSON wire format | Model-dependent text patterns |
| Streaming | SSE chunks | Token-by-token generation |
| Vision | Provider handles encoding | Separate VLM factory + CIImage |
| Thinking | Provider-specific blocks | Template-dependent (`<think>`, Harmony channels) |

The fundamental challenge: **HTTP providers normalize tool calls server-side. With MLX, we get raw text and must parse tool calls ourselves, with every model family using a different format.**

## POC Findings

We ran 8 phases of exploration testing mlx-swift-lm directly. Key learnings:

### What Works Reliably

- **Basic completion** — all tested models produce coherent text via `ModelContainer.generate()`
- **Streaming** — token-by-token via `AsyncStream<Generation>` with `.chunk`, `.info`, `.toolCall` cases
- **Template introspection** — Jinja AST walking discovers model-specific parameters (e.g., `enable_thinking`, `reasoning_effort`) and infers their types/valid values
- **Model type detection** — `config.json` contains `model_type` field identifying the architecture

### Tool Calling — The Hard Part

mlx-swift-lm has a built-in `ToolCallProcessor` that only handles one format: `<tool_call>{JSON}</tool_call>`. Different model families use different formats:

| Model Family | Tool Call Format | mlx-swift-lm Support |
|---|---|---|
| Qwen3 | `<tool_call>{"name":"...","arguments":{...}}</tool_call>` | Native (built-in processor) |
| GPT-OSS | Harmony protocol: `<\|start\|>assistant<\|channel\|>commentary to=functions.NAME <\|constrain\|>json<\|message\|>ARGS<\|call\|>` | None — requires custom parsing |
| Llama/Hermes | `<tool_call>` variant (with prompt adjustments) | Partial |
| Others | Various or none | None |

**Our solution:** Build a text-based tool call parser in Yrden that handles multiple formats. Tested and working for both Qwen (`<tool_call>`) and GPT-OSS (Harmony).

**LM Studio comparison:** Uses the same approach — their open-source `mlx-engine` does raw inference, and their closed-source TypeScript layer parses tool calls per model family. They have the same bugs we found (GPT-OSS parsing failures, Qwen3 thinking tags hiding tool calls).

### Vision

- **Qwen3-VL** — broken in mlx-swift-lm (PatchMerger weight key mismatch)
- **Gemma 3 4B** — works correctly via `VLMModelFactory`
- **SmolVLM** — loads but too small for reliable answers
- VLMs require `VLMModelFactory.shared.loadContainer()` instead of `LLMModelFactory`

### Thinking/Reasoning

- **Qwen3** — `<think>...</think>` tags in raw text, controlled via `enable_thinking` template parameter
- **GPT-OSS** — analysis channel (`<|channel|>analysis<|message|>...<|end|>`) for chain-of-thought, `reasoning_effort` template parameter
- Both map cleanly to Yrden's `ContentKind.thinking` / `ThinkingBlock`

### Template Parameter Discovery

Our Jinja AST walker discovers model-specific template parameters automatically:

```
Qwen3-8B:    enable_thinking (bool, default=true)
GPT-OSS-20B: reasoning_effort (string, values=["low","medium","high"], default="medium")
             model_identity (string)
             builtin_tools (array, values=["browser","python"])
```

This enables the provider to auto-configure `additionalContext` without hardcoding per-model knowledge.

### Performance

| Model | Size | Speed |
|---|---|---|
| Qwen3-8B-4bit | ~5 GB | ~85 tok/s |
| GPT-OSS-20B-MXFP4-Q8 | ~12 GB | ~47 tok/s |
| Gemma 3 4B (VLM) | ~3 GB | ~60 tok/s |
| Gemma 3 1B | ~1 GB | ~120 tok/s |

## Architecture

### How It Fits

```
┌──────────────────────────────────────────┐
│  Agent / User Code                       │
│                                          │
│  let model = MLXModel(                   │
│      modelId: "mlx-community/Qwen3-...", │
│      provider: mlxProvider               │
│  )                                       │
│  let response = try await model.complete(│
│      request                             │
│  )                                       │
└──────────┬───────────────────────────────┘
           │ Model protocol
           ▼
┌──────────────────────────────────────────┐
│  MLXModel: Model                         │
│                                          │
│  1. Convert CompletionRequest → UserInput│
│  2. Call container.generate()            │
│  3. Collect raw text + .toolCall events  │
│  4. Parse tool calls (format-aware)      │
│  5. Parse thinking blocks                │
│  6. Build CompletionResponse / stream    │
│     StreamEvents                         │
└──────────┬───────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────┐
│  mlx-swift-lm                            │
│                                          │
│  ModelContainer (Sendable, thread-safe)  │
│  - prepare(input:) → LMInput            │
│  - generate(input:parameters:)           │
│    → AsyncStream<Generation>             │
└──────────────────────────────────────────┘
```

### Provider vs Model

Following the existing pattern where `Provider` = transport and `Model` = API format:

- **`MLXProvider`** — handles model discovery (local cache + HuggingFace Hub), no auth needed
- **`MLXModel`** — handles message conversion, generation, tool call parsing, thinking extraction

Unlike HTTP providers where the model is remote, MLX models must be loaded into memory. `MLXModel` owns a `ModelContainer` that it loads lazily on first use.

## Model Container Caching

### The Problem

With HTTP providers, `OpenAIModel` is a lightweight struct — construction is instant, each API call is stateless. But MLX models are fundamentally different:

- **Loading takes seconds to minutes** (download weights + load into GPU memory)
- **Each model consumes 1-16 GB of unified memory**
- **The same model may be used across multiple Agent runs, tool retries, and conversations**

Without caching, every `MLXModel` instance triggers a fresh multi-GB load. In an agent loop that runs 5 tool-calling iterations, that's 5 redundant loads of the same model.

### Design: `MLXModelCache`

An actor that manages loaded `ModelContainer` instances, keyed by HuggingFace model ID. Follows the same actor-based caching pattern as the existing `CachedModelList`.

```swift
public actor MLXModelCache {
    /// Singleton for shared use. Callers can also create private instances.
    public static let shared = MLXModelCache()

    private var loaded: [String: CacheEntry] = [:]
    private let maxModels: Int

    public init(maxModels: Int = 2) {
        self.maxModels = maxModels
    }

    /// Get or load a model container. Returns immediately if already loaded.
    /// Reports download/load progress via the optional callback.
    public func container(
        for modelId: String,
        factory: ModelProfile.ModelFactory = .llm,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> ModelContainer {
        if let entry = loaded[modelId] {
            entry.lastAccessed = ContinuousClock.now
            return entry.container
        }

        // Evict least-recently-used if at capacity
        if loaded.count >= maxModels {
            evictLRU()
        }

        // Load the model
        let container = try await loadContainer(
            modelId: modelId,
            factory: factory,
            onProgress: onProgress
        )

        loaded[modelId] = CacheEntry(
            container: container,
            lastAccessed: ContinuousClock.now
        )

        return container
    }

    /// Explicitly unload a model to free GPU memory.
    public func unload(_ modelId: String) {
        loaded.removeValue(forKey: modelId)
    }

    /// Unload all models.
    public func unloadAll() {
        loaded.removeAll()
    }

    /// Currently loaded model IDs.
    public var loadedModels: [String] {
        Array(loaded.keys)
    }

    private func evictLRU() {
        guard let oldest = loaded.min(by: { $0.value.lastAccessed < $1.value.lastAccessed }) else {
            return
        }
        loaded.removeValue(forKey: oldest.key)
    }

    private struct CacheEntry {
        let container: ModelContainer
        var lastAccessed: ContinuousClock.Instant
    }
}
```

### How MLXModel Uses the Cache

`MLXModel` does not own a `ModelContainer`. It holds a reference to the cache and its model ID, requesting the container on each `complete()`/`stream()` call. Since the container is already loaded after the first call, subsequent calls are instant.

```swift
let cache = MLXModelCache.shared

// First call: downloads + loads (~5 seconds for Qwen3-8B)
let model1 = try await MLXModel.load("mlx-community/Qwen3-8B-4bit", cache: cache)
let response1 = try await model1.complete(request1)

// Second call: instant (container already in cache)
let model2 = try await MLXModel.load("mlx-community/Qwen3-8B-4bit", cache: cache)
let response2 = try await model2.complete(request2)

// model1 and model2 share the same underlying ModelContainer
```

### Agent Loop Scenario

```swift
// The agent loop creates requests in a loop — container is loaded once
let model = try await MLXModel.load("mlx-community/Qwen3-8B-4bit", cache: cache)

for await node in agent.iter(prompt, deps: deps) {
    // Each iteration calls model.complete() — hits cache, no reload
    switch node {
    case .toolCall(let call):
        let result = try await executeTool(call)
        // ... feed result back, model.complete() again — still cached
    }
}
```

### Memory Management

- **`maxModels`** (default: 2) — limits how many models stay loaded simultaneously. When loading a third model, the least-recently-used one is evicted.
- **Explicit unload** — `cache.unload(modelId)` releases GPU memory for a specific model. Useful when switching between large models.
- **ARC fallback** — if the cache itself is deallocated, all containers are released.
- **No automatic memory pressure handling** (v1) — the caller is responsible for managing model lifetime. A future version could observe system memory pressure notifications and evict proactively.

### Why Actor, Not Just a Dictionary

- `ModelContainer` is `Sendable` and thread-safe for inference, but the loading process is not — two concurrent callers requesting the same model ID should not trigger two parallel downloads.
- The actor serializes `container(for:)` calls, ensuring exactly one load per model ID.
- Matches the existing `CachedModelList` pattern in the codebase.

## KV-Cache Reuse Between Turns

### The Problem

In an agent loop, the model is called multiple times with a growing message history:

```
Turn 1: [system, user]                              → 500 tokens processed
Turn 2: [system, user, assistant, tool_result]       → 900 tokens processed (500 repeated)
Turn 3: [system, user, assistant, tool_result, asst2, tool2] → 1400 tokens (900 repeated)
```

With HTTP providers, the server handles prompt caching (Anthropic's cache_control, OpenAI's automatic prefix caching). With MLX, every `complete()` call re-tokenizes and re-processes the entire conversation from scratch. For a 10-turn agent loop, that's O(n²) token processing instead of O(n).

### What mlx-swift-lm Provides

mlx-swift-lm has full KV-cache support through its `KVCache` types:

- **`KVCacheSimple`** — stores all key/value pairs, grows incrementally. Tracks `offset` (tokens processed so far).
- **`RotatingKVCache`** — sliding window variant for very long sequences.
- **`QuantizedKVCache`** — memory-efficient quantized variant.

The library's `ChatSession` demonstrates multi-turn reuse:

```swift
// ChatSession internally:
var kvCache: [KVCache]

// Turn 1: Create new cache, generate
kvCache = model.newCache(parameters: params)
generate(input: fullConversation, cache: kvCache)  // processes all tokens

// Turn 2: REUSE same cache array
generate(input: fullConversation, cache: kvCache)  // only processes NEW tokens
```

The key mechanism: you pass the **full tokenized conversation** each time, but the attention layers see the cache already has KVs for tokens 0..N and only compute embeddings for the new tokens N+1..M. The `offset` property tracks the boundary.

This works correctly for agent loops because **we only append messages** (never modify earlier ones), so the token prefix is always stable.

### Design Challenge

Yrden's `Model` protocol is stateless — each `complete()` call is independent:

```swift
public protocol Model: Sendable {
    func complete(_ request: CompletionRequest) async throws -> CompletionResponse
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error>
}
```

The agent loop in `AgentIterator.callModel()` rebuilds a fresh `CompletionRequest` with all accumulated messages every turn. There's no session handle, no cache state passed between calls.

### Design: Transparent Cache Inside MLXModel

`MLXModel` holds an internal KV-cache and **detects prefix reuse automatically**. The Model protocol stays unchanged — callers don't know caching is happening.

```swift
public final class MLXModel: Model, Sendable {
    // ... existing fields ...

    /// Internal KV-cache state for prefix reuse between turns.
    /// Protected by ModelContainer's internal actor isolation.
    private let kvCacheState: KVCacheState

    final class KVCacheState: Sendable {
        // Stores the cache + a fingerprint of what's in it
        // Thread-safety: all access goes through ModelContainer (which is actor-isolated)
        private var cache: [KVCache]?
        private var cachedTokenCount: Int = 0
        private var cachedMessageHash: Int = 0  // Hash of messages that produced the cache
    }
}
```

**How it works on each `complete()` call:**

```swift
func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
    let container = try await cache.container(for: modelId)

    // 1. Convert messages and tokenize
    let chatMessages = request.messages.map { convertMessage($0) }
    let input = UserInput(chat: chatMessages, tools: toolSpecs, ...)
    let lmInput = try await container.prepare(input: input)

    // 2. Check if we can reuse the KV-cache
    let messageHash = hashMessages(request.messages)
    let kvCache: [KVCache]

    if let existing = kvCacheState.cache,
       kvCacheState.cachedMessageHash == hashPrefix(request.messages) {
        // Prefix matches — reuse cache, only new tokens need processing
        kvCache = existing
    } else {
        // Different conversation or first call — fresh cache
        kvCache = model.newCache(parameters: generateParameters)
        kvCacheState.cachedTokenCount = 0
    }

    // 3. Generate with cache
    let stream = try await container.generate(
        input: lmInput,
        parameters: params,
        cache: kvCache  // Reused or fresh
    )

    // 4. Collect output...

    // 5. Update cache state for next call
    kvCacheState.cache = kvCache
    kvCacheState.cachedMessageHash = messageHash
    kvCacheState.cachedTokenCount = kvCache[0].offset
}
```

### Prefix Detection Strategy

The tricky part: how to determine that the current request shares a prefix with the cached state.

**Option A: Message hash comparison**

Hash the messages array excluding the last N messages (which are new this turn). If the hash matches, the prefix is the same.

```swift
// Agent loop always appends: [existing..., newAssistant, newToolResults]
// Hash all messages except the last 1-2 → if matches previous, prefix is reusable
func hashPrefix(_ messages: [Message], dropLast n: Int = 2) -> Int {
    var hasher = Hasher()
    for msg in messages.dropLast(n) {
        hasher.combine(msg)
    }
    return hasher.finalize()
}
```

**Limitation:** This is a heuristic. If the system prompt changes mid-loop (dynamic system prompts), the prefix is invalidated. That's correct — the cache should be discarded.

**Option B: Token-level prefix matching**

Tokenize the full conversation, compare token-by-token with what's in the cache. More precise but requires storing the cached token array.

```swift
// Compare first N tokens of new input with cached tokens
let newTokens = tokenize(fullConversation)
let prefixLength = commonPrefixLength(newTokens, cachedTokens)
if prefixLength == cachedTokens.count {
    // Perfect prefix match — trim cache to prefixLength, generate from there
}
```

**Option C: Turn counter (simplest)**

Since the agent loop always appends, track the turn number. If the current turn is previous + 1 and the model ID is the same, assume the prefix is valid.

**Recommendation:** Start with **Option A** (message hash). It's correct for the common case (agent loop) and handles edge cases (system prompt changes, different conversations) by invalidating. Token-level matching (Option B) is a future optimization.

### Cache Invalidation

The cache must be discarded when:

1. **Different conversation** — message prefix doesn't match (hash mismatch)
2. **Model switch** — different `MLXModel` instance (cache is per-instance)
3. **Explicit reset** — caller requests fresh generation
4. **Memory pressure** — `MLXModelCache` evicts the model container (cache becomes invalid)

### Performance Impact

For a typical 5-turn agent loop with Qwen3-8B (~85 tok/s):

| Scenario | Without Cache | With Cache |
|---|---|---|
| Turn 1 (500 input tokens) | 5.9s prefill | 5.9s (cold start) |
| Turn 2 (900 input tokens) | 10.6s prefill | 4.7s (400 new tokens) |
| Turn 3 (1400 input tokens) | 16.5s prefill | 5.9s (500 new tokens) |
| Turn 4 (2000 input tokens) | 23.5s prefill | 7.1s (600 new tokens) |
| Turn 5 (2700 input tokens) | 31.8s prefill | 8.2s (700 new tokens) |
| **Total** | **88.3s** | **31.8s** |

~2.8x speedup for a 5-turn loop. The savings grow with conversation length.

### Limitations

1. **No cross-instance sharing** — each `MLXModel` instance has its own KV-cache. Two agents using the same model don't share cache.
2. **Memory cost** — KV-cache grows with context length. For Qwen3-8B with 4K context: ~200 MB. This is on top of the model weights.
3. **No partial invalidation** — if the prefix changes (e.g., edited earlier message), the entire cache is discarded. Can't surgically update middle tokens.
4. **Streaming complication** — during streaming, we accumulate the response into the cache. If the stream is cancelled mid-way, the cache may be in an inconsistent state. Must handle by discarding on cancellation.

## Components

### 1. MLXProvider

```swift
public struct MLXProvider: Provider, Sendable {
    public var baseURL: URL { /* not applicable, return placeholder */ }

    public func authenticate(_ request: inout URLRequest) async throws {
        // No-op — local inference needs no auth
    }

    public func listModels() -> AsyncThrowingStream<ModelInfo, Error> {
        // List models in local HuggingFace cache
        // + query HuggingFace Hub for MLX-tagged models
    }
}
```

### 2. MLXModel

The core component. Conforms to `Model` protocol. Does **not** own a `ModelContainer` — requests one from `MLXModelCache` on each call. Holds internal KV-cache state for prefix reuse between turns (see "KV-Cache Reuse Between Turns" section).

```swift
public final class MLXModel: Model, Sendable {
    public static let providerId = "mlx"

    public let name: String               // HuggingFace model ID
    public let capabilities: ModelCapabilities
    public let foreignThinkingBehavior: ForeignThinkingBehavior

    private let modelId: String           // e.g., "mlx-community/Qwen3-8B-4bit"
    private let profile: ModelProfile     // Tested model metadata
    private let containerCache: MLXModelCache  // Shared model container cache
    private let kvCacheState: KVCacheState     // Per-instance KV-cache for prefix reuse

    public func complete(_ request: CompletionRequest) async throws -> CompletionResponse
    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error>

    /// Discard the KV-cache. Next complete() call will process all tokens from scratch.
    /// Useful when switching conversations or after long-running loops to free memory.
    public func resetKVCache()
}
```

**Initialization** goes through the cache:

```swift
public static func load(
    _ modelId: String,
    cache: MLXModelCache = .shared,
    profile: ModelProfile? = nil,        // nil = auto-detect from config
    onProgress: (@Sendable (Progress) -> Void)? = nil
) async throws -> MLXModel {
    // 1. Read config.json → model_type → LLM vs VLM factory
    // 2. Read tokenizer_config.json → discover template parameters
    // 3. Load container via cache (downloads + loads if not cached)
    // 4. Build capabilities from profile + discovered params
    // 5. Return configured MLXModel (holds reference to cache, not container)
}
```

The `load()` factory eagerly loads the model into the cache so the first `complete()` call doesn't have a surprise multi-second delay. Subsequent `MLXModel` instances for the same model ID skip loading entirely.

### 3. ModelProfile

Static metadata for tested models. Untested models get a default profile based on auto-detection.

```swift
public struct ModelProfile: Sendable {
    public let modelId: String
    public let displayName: String
    public let modelType: String          // From config.json: "qwen3", "gpt_oss", "gemma3", etc.
    public let factory: ModelFactory      // .llm or .vlm
    public let toolCallFormat: ToolCallFormat
    public let capabilities: ModelCapabilities
    public let defaultAdditionalContext: [String: AnySendable]?  // e.g., ["enable_thinking": false]

    public enum ModelFactory: String, Sendable {
        case llm    // LLMModelFactory
        case vlm    // VLMModelFactory
    }
}
```

### 4. ModelRegistry

Curated list of tested models. Falls back to auto-detection for unknown models.

```swift
public struct ModelRegistry: Sendable {
    /// Look up a tested model profile. Returns nil for untested models.
    public func profile(for modelId: String) -> ModelProfile?

    /// All tested model profiles.
    public var testedModels: [ModelProfile] { get }
}
```

**Tested models (from POC):**

| Model | model_type | Factory | Tools | Vision | Thinking |
|---|---|---|---|---|---|
| `mlx-community/Qwen3-8B-4bit` | qwen3 | llm | native | no | `enable_thinking` |
| `mlx-community/gpt-oss-20b-MXFP4-Q8` | gpt_oss | llm | harmony | no | analysis channel |
| `mlx-community/gemma-3-4b-it-qat-4bit` | gemma3 | vlm | untested | yes | no |
| `mlx-community/gemma-3-1b-it-qat-4bit` | gemma3_text | llm | no (too small) | no | no |

For **untested models**, auto-detect:
1. Read `config.json` → `model_type` → select factory (VLM types use vlm factory)
2. Read `tokenizer_config.json` → template params → set `additionalContext`
3. Attempt tool calling with mlx-swift-lm's built-in processor (works for `<tool_call>` models)
4. Capabilities default to conservative (tools: false unless model_type is known to support them)

### 5. ToolCallParser

Extracts tool calls from raw model text output. Used when mlx-swift-lm's built-in processor doesn't detect them.

```swift
public struct ToolCallParser: Sendable {
    public enum Format: String, Sendable {
        case qwen       // <tool_call>{JSON}</tool_call>
        case harmony    // Harmony protocol (GPT-OSS)
    }

    /// Parse tool calls from raw text, trying all known formats.
    public static func parse(text: String) -> [ToolCall]

    /// Parse with a specific format hint (faster, no guessing).
    public static func parse(text: String, format: Format) -> [ToolCall]

    /// Extract thinking/analysis content from Harmony output.
    public static func parseHarmonyAnalysis(text: String) -> String?

    /// Extract final response from Harmony output (strips channel markup).
    public static func parseHarmonyFinalResponse(text: String) -> String?
}
```

### 6. TemplateIntrospector

Discovers model-specific template parameters from Jinja chat templates. Used during model loading to auto-configure `additionalContext`.

```swift
public struct TemplateIntrospector: Sendable {
    /// Discovered parameter with inferred type information.
    public struct Parameter: Sendable {
        public let name: String
        public let inferredType: ParameterType
        public let defaultValue: String?
        public let validValues: [String]?
    }

    public enum ParameterType: String, Sendable {
        case bool, string, number, array, unknown
    }

    /// Discover template parameters from a Jinja chat template string.
    public static func discover(template: String) -> [Parameter]
}
```

## Request/Response Flow

### CompletionRequest → MLX Generation

```swift
func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
    // 1. Convert messages
    let chatMessages = request.messages.map { convertMessage($0) }

    // 2. Convert tools (if supported)
    let toolSpecs: [ToolSpec]? = request.tools?.map { convertTool($0) }

    // 3. Build additionalContext from config + profile
    var context = profile.defaultAdditionalContext ?? [:]
    // If thinking not requested, disable it
    // Map CompletionConfig.temperature → GenerateParameters

    // 4. Prepare input
    let input = UserInput(chat: chatMessages, tools: toolSpecs, additionalContext: context)
    let lmInput = try await container.prepare(input: input)

    // 5. Generate
    let params = GenerateParameters(
        maxTokens: request.config.maxTokens ?? 4096,
        temperature: request.config.temperature.map { Float($0) } ?? 0.6
    )
    let stream = try await container.generate(input: lmInput, parameters: params)

    // 6. Collect output
    var rawText = ""
    var nativeToolCalls: [MLXLMCommon.ToolCall] = []
    var usage = Usage(inputTokens: 0, outputTokens: 0)

    for await generation in stream {
        switch generation {
        case .chunk(let text):       rawText += text
        case .toolCall(let call):    nativeToolCalls.append(call)
        case .info(let info):        usage = makeUsage(info)
        }
    }

    // 7. Build response (format-aware)
    return buildResponse(
        rawText: rawText,
        nativeToolCalls: nativeToolCalls,
        usage: usage
    )
}
```

### Building the Response (Format-Aware)

```swift
func buildResponse(rawText: String, nativeToolCalls: [...], usage: Usage) -> CompletionResponse {
    var contentBlocks: [AssistantContentBlock] = []

    // --- Tool calls ---
    // Strategy: prefer native (mlx-swift-lm detected), fall back to our parser
    var toolCalls: [ToolCall] = []

    if !nativeToolCalls.isEmpty {
        // mlx-swift-lm caught them (Qwen/Hermes format)
        toolCalls = nativeToolCalls.map { convertToolCall($0) }
    } else if profile.toolCallFormat != .none {
        // Try our parser on raw text
        toolCalls = ToolCallParser.parse(text: rawText, format: profile.toolCallFormat)
    }

    // --- Thinking/analysis ---
    switch profile.modelType {
    case "gpt_oss":
        // Extract analysis channel as thinking
        if let analysis = ToolCallParser.parseHarmonyAnalysis(text: rawText) {
            contentBlocks.append(.thinking(ThinkingBlock(content: analysis, provider: "mlx")))
        }
        // Extract final response text (strip Harmony markup)
        if let finalText = ToolCallParser.parseHarmonyFinalResponse(text: rawText) {
            contentBlocks.append(.text(finalText))
        } else if toolCalls.isEmpty {
            // No Harmony structure detected — use raw text
            contentBlocks.append(.text(rawText))
        }

    default:
        // Qwen-style: extract <think> tags, rest is text
        let (thinking, responseText) = extractThinkingBlocks(rawText)
        if let thinking {
            contentBlocks.append(.thinking(ThinkingBlock(content: thinking, provider: "mlx")))
        }
        if !responseText.isEmpty {
            contentBlocks.append(.text(responseText))
        }
    }

    // --- Append tool calls ---
    for call in toolCalls {
        contentBlocks.append(.toolUse(call))
    }

    let stopReason: StopReason = toolCalls.isEmpty ? .endTurn : .toolUse

    return CompletionResponse(
        contentBlocks: contentBlocks,
        refusal: nil,
        stopReason: stopReason,
        usage: usage
    )
}
```

### Streaming

```swift
func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
        Task {
            // ... prepare input same as complete() ...

            var rawText = ""

            for await generation in stream {
                switch generation {
                case .chunk(let text):
                    rawText += text
                    // For Qwen: emit text deltas directly (thinking tags handled post-hoc)
                    // For GPT-OSS: buffer until we can parse channel structure
                    if profile.modelType != "gpt_oss" {
                        continuation.yield(.contentDelta(text))
                    }

                case .toolCall(let call):
                    // Native detection (Qwen)
                    let tc = convertToolCall(call)
                    continuation.yield(.toolCallStart(id: tc.id, name: tc.name))
                    continuation.yield(.toolCallDelta(argumentsDelta: tc.arguments))
                    continuation.yield(.toolCallEnd(id: tc.id))

                case .info(let info):
                    // Generation complete — finalize
                    let response = buildResponse(rawText: rawText, ...)

                    // For GPT-OSS: emit buffered content now
                    if profile.modelType == "gpt_oss" {
                        for block in response.contentBlocks {
                            switch block {
                            case .thinking(let tb):
                                if let content = tb.content {
                                    continuation.yield(.contentDelta(content, kind: .thinking))
                                }
                            case .text(let t):
                                continuation.yield(.contentDelta(t))
                            case .toolUse(let tc):
                                continuation.yield(.toolCallStart(id: tc.id, name: tc.name))
                                continuation.yield(.toolCallDelta(argumentsDelta: tc.arguments))
                                continuation.yield(.toolCallEnd(id: tc.id))
                            }
                        }
                    }

                    continuation.yield(.done(response))
                }
            }

            continuation.finish()
        }
    }
}
```

**Streaming tradeoff for GPT-OSS:** Harmony protocol mixes channels in the raw output (`analysis`, `commentary`, `final`). We can't emit meaningful deltas until we know which channel the text belongs to. So GPT-OSS streams are buffered and emitted at the end. This is acceptable because:
- The model generates at ~47 tok/s with ~33 tokens per tool call — sub-second
- Final responses stream normally once we detect the `final` channel

Qwen models stream text deltas in real-time since there's no channel multiplexing.

## Message Conversion

```swift
// Yrden Message → mlx-swift-lm Chat.Message
func convertMessage(_ message: Message) -> Chat.Message {
    switch message {
    case .system(let text):
        return .system(text)

    case .user(let parts):
        let text = parts.compactMap { part -> String? in
            if case .text(let t) = part { return t }
            return nil
        }.joined()

        let images: [UserInput.Image] = parts.compactMap { part in
            if case .image(let data, _) = part {
                return .data(data)
            }
            return nil
        }

        return images.isEmpty ? .user(text) : .user(text, images: images)

    case .assistant(let blocks):
        // Reconstruct raw text from blocks
        // For Qwen: wrap thinking in <think> tags, append tool calls as <tool_call>
        // For GPT-OSS: reconstruct Harmony channel format
        return .assistant(reconstructAssistantText(blocks))

    case .toolResult(let toolCallId, let content):
        return .tool(content)

    case .toolResults(let entries):
        // mlx-swift-lm only supports single tool result per message
        // Send each as separate .tool message
        // (handled in message list conversion)
    }
}
```

## Configuration Mapping

```swift
CompletionConfig.temperature     → GenerateParameters.temperature (Float)
CompletionConfig.topP            → GenerateParameters.topP (Float)
CompletionConfig.maxTokens       → GenerateParameters.maxTokens (Int)
CompletionConfig.stopSequences   → Not directly supported (use EOS tokens)

// MLX-specific (via template params):
// enable_thinking    → additionalContext["enable_thinking"]
// reasoning_effort   → additionalContext["reasoning_effort"]
```

`CompletionConfig` fields that don't apply to MLX (`store`, `promptCacheKey`, `promptCacheRetention`) are silently ignored — no error, they're just not relevant for local inference.

## Supported Models

### Tier 1: Tested and Verified

These models have been run through the full POC test suite. The provider ships with pre-built `ModelProfile` entries for each.

| Model ID | Display Name | Tools | Vision | Thinking | Min RAM |
|---|---|---|---|---|---|
| `mlx-community/Qwen3-8B-4bit` | Qwen3 8B | yes (native) | no | yes | 8 GB |
| `mlx-community/gpt-oss-20b-MXFP4-Q8` | GPT-OSS 20B | yes (harmony) | no | yes | 16 GB |
| `mlx-community/gemma-3-4b-it-qat-4bit` | Gemma 3 4B | no | yes | no | 4 GB |

### Tier 2: Auto-Detected

Any HuggingFace model compatible with mlx-swift-lm. The provider auto-detects:
- `model_type` from `config.json` → factory selection
- Template parameters from `tokenizer_config.json` → `additionalContext`
- Tool support defaults to `false` unless model uses `<tool_call>` format (detected from chat template)

### Adding New Models to Tier 1

1. Run the model through Phase 6 (`testModel()`) to verify basic completion
2. Test tool calling — check if mlx-swift-lm's native processor catches them, or if a custom parser is needed
3. Test vision if applicable (VLM factory)
4. Add `ModelProfile` entry to `ModelRegistry`

## Limitations

1. **No logits-level structured output** — unlike LM Studio (which uses Outlines), we don't constrain generation at the token level. Structured output relies on the model following its chat template. This is fine for tool calling but means `outputSchema` is not enforceable.

2. **GPT-OSS streaming is buffered** — Harmony channel multiplexing prevents real-time text streaming. Text arrives all at once after generation completes.

3. **Single model in memory** — MLX models consume significant GPU memory. Loading a second model may cause the first to be evicted. The provider doesn't manage memory lifecycle — the caller is responsible for model lifetime.

4. **Qwen3-VL broken upstream** — PatchMerger weight key mismatch in mlx-swift-lm. Can't use Qwen3 for vision until fixed upstream.

5. **Tool call format fragmentation** — each model family invents its own format. New families may need new parsers. The `ToolCallParser` is extensible but requires manual work per format.

6. **No parallel tool calls for GPT-OSS** — the chat template only reads `tool_calls[0]`. Multiple tool calls require multiple generation rounds.

## Dependencies

```swift
// Package.swift additions
.package(url: "https://github.com/ml-explore/mlx-swift-lm/", from: "2.29.0")

// Products used:
// - MLXLLM (text model loading/inference)
// - MLXVLM (vision model loading/inference)
// - MLXLMCommon (ModelContainer, Generation, ToolCall, etc.)
// - Hub (HuggingFace model download)
// - Tokenizers (ToolSpec typealias)

// Already in Yrden's dependency tree:
// - Jinja (swift-jinja, for template introspection)
```

## Open Questions

1. **Should MLXModel be a class or actor?** `ModelContainer` is already Sendable/thread-safe. An actor would add unnecessary serialization. A `final class` with `Sendable` conformance (all stored properties are Sendable) seems right — matches `OpenAIModel` pattern (struct there, but MLX needs reference semantics for the KV-cache state). However, the mutable `KVCacheState` introduces shared mutable state — may need to be an actor after all, or use a lock.

2. **Model loading UX** — should `MLXModel.load()` report download/load progress? If so, via a callback or an `AsyncStream<LoadProgress>`? The caller (Agent, UI) likely wants to show a progress bar.

3. **Default model** — should there be a recommended default for users who just want "a local model that works"? Qwen3-8B-4bit is the obvious choice (best all-rounder, ~5 GB, fast).

4. **KV-cache and concurrent access** — if two agent loops share the same `MLXModel` instance, they'd fight over the KV-cache. Should we scope the cache per agent run (via `runID`) or keep it simple and invalidate on prefix mismatch? Per-run scoping is more correct but adds complexity.
