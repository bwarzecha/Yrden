# GGML Provider Design

Local model inference on Apple Silicon via llama.cpp (GGUF format).

## Problem

Yrden's MLX provider covers local inference via Apple's MLX framework, but GGUF is the dominant model distribution format in the open-source ecosystem. Most community-quantized models ship as GGUF first. A GGML provider enables:

- **Broader model selection** — thousands of GGUF models on HuggingFace vs hundreds of MLX conversions
- **Format flexibility** — users can download any GGUF from TheBloke, bartowski, ggml-org, unsloth, etc.
- **Complementary to MLX** — some models are only available as GGUF (e.g., GPT-OSS)
- **Cross-platform potential** — llama.cpp runs on Linux/Windows too (MLX is Apple-only)

**Key differences from MLX provider:**

| Aspect | MLX Provider | GGML Provider |
|---|---|---|
| Framework | mlx-swift-lm (high-level Swift) | llama.cpp C API (low-level) |
| Model format | MLX safetensors (HuggingFace) | GGUF (single file) |
| Template rendering | Built into mlx-swift-lm | Must handle ourselves (3 paths) |
| Tool call detection | Built-in `ToolCallProcessor` | Must parse raw text ourselves |
| Streaming | `AsyncStream<Generation>` with typed events | Token-by-token via sampler loop |
| Vision | VLMModelFactory (separate) | Not available (XCFramework excludes multimodal) |
| API surface | ~5 Swift types | ~30 C functions with manual memory management |

**The fundamental challenge: llama.cpp gives us raw C API access. Everything above tokenization — template rendering, tool call parsing, thinking extraction — must be built by us.**

## POC Findings

We ran 7 phases of exploration testing llama.cpp via `mattt/llama.swift`. Key learnings:

### What Works Reliably

- **Basic completion** — all tested models (Qwen3-4B, Llama-3.2-1B, Gemma-3-1B, GPT-OSS-20B) produce coherent text
- **Token-by-token streaming** — via `llama_decode` + `llama_sampler_sample` loop, with `fflush(stdout)` for real-time output
- **GGUF metadata introspection** — `llama_model_meta_val_str` reads architecture, model name, tokenizer config, and chat templates directly from the file
- **Template parameter discovery** — same Jinja AST walker from MLX POC works on GGUF-embedded templates
- **Multi-model loading** — sequential loading of different models works correctly (backend init/free cycle)

### Template Rendering — Three Paths

Unlike MLX where `mlx-swift-lm` handles template rendering internally, GGML requires us to render chat templates ourselves. We discovered three paths with different tradeoffs:

| Path | Speed | Tool Support | Coverage | Used When |
|---|---|---|---|---|
| **C API** (`llama_chat_apply_template`) | Fast (~0.1ms) | No | ~50 hardcoded formats | Simple messages, no tools |
| **swift-jinja** (`Template.render()`) | Medium (~1ms) | Yes | Most templates | Tools, thinking params |
| **Manual prompt building** | Fast | Yes | Format-specific | Templates too complex for swift-jinja |

**C API path:** `llama_chat_apply_template` is a pure C function that pattern-matches against ~50 known template formats (ChatML, Llama, Gemma, Qwen, etc.). It's fast and reliable but only handles basic `system/user/assistant` messages — no tools, no `enable_thinking`, no custom context.

**swift-jinja path:** Full Jinja2 template rendering via `huggingface/swift-jinja`. Handles tools, thinking parameters, and model-specific context. Works for Qwen3, Llama-3.2, Gemma-3, and most other models.

**Manual path:** Some models have templates too complex for swift-jinja. GPT-OSS has a 16K-char template with recursive macros, `namespace()` objects, and `raise_exception()` — all of which break the parser. For these, we build prompts manually following the model's format spec.

**Our `formatMessages()` function chains these:** try C API first (fastest, works for simple cases), fall back to Jinja, fall back to manual.

### Template Rendering — Swift Jinja Limitations

`huggingface/swift-jinja` is the only Swift Jinja2 implementation. It handles most LLM templates but has gaps:

**Supported:** `namespace()`, `raise_exception()`, macros, filters, tests, `is defined` checks
**Not supported:** Recursive `for` loops, some edge cases in complex nested macros

**GPT-OSS template failure:** The 16K-char GPT-OSS template uses `{% for ... recursive %}` and deeply nested macros that cause a parser error: `Expected '%}' after if condition.. Got eof instead`. This affects swift-jinja, not the model or llama.cpp.

**minja-swift evaluation:** We attempted to integrate `johnmai-dev/minja-swift` (Swift wrapper around Google's C++ minja engine). Findings:
- C++ interop (`.interoperabilityMode(.Cxx)`) contaminates the entire target's build settings
- When combined with LlamaSwift XCFramework, causes SIGTRAP crash at runtime — unhandled C++ exception in `minja_chat_template_apply` (no try-catch in the C++ wrapper)
- Package is unmaintained (v0.0.1, single day of commits, Jan 2025)
- **Verdict:** not production-ready. Manual prompt building is more reliable.

**LM Studio comparison:** Uses `@huggingface/jinja` (JavaScript npm package) in its Electron layer. Also has template rendering bugs — GPT-OSS multi-turn fails for them too. Their MLX backend uses Python's real Jinja2 (the reference implementation) which handles everything.

**google/minja (C++):** The most robust alternative. Header-only C++17, integrated into llama.cpp since Jan 2025. Supports all features GPT-OSS needs. Available via llama.cpp's official Swift Package, but not exposed through `mattt/llama.swift`'s XCFramework (the `common` library with minja is excluded from the public C API).

### Tool Calling — The Hard Part

llama.cpp has no built-in tool call detection. We get raw text and must parse it ourselves. Different model families use different formats:

| Model Family | Tool Call Format | Example |
|---|---|---|
| Qwen3 | `<tool_call>{JSON}</tool_call>` | `<tool_call>{"name":"get_weather","arguments":{"city":"Prague"}}</tool_call>` |
| GPT-OSS | Harmony protocol | `<\|start\|>assistant<\|channel\|>commentary to=functions.get_weather <\|constrain\|>json<\|message\|>{"city":"Prague"}<\|call\|>` |
| Llama/Hermes | `<tool_call>` variant | Similar to Qwen with prompt adjustments |
| Others | Various or none | Model-dependent |

**Harmony protocol quirks discovered:**
- The model sometimes generates a "buggy" variant: `<|start|>assistant to=functions.NAME<|channel|>commentary json<|message|>ARGS<|call|>` (fields reordered)
- The `<|call|>` token is sometimes consumed as a stop token by llama.cpp, so tool calls may end abruptly without it
- Our parser handles both the correct and buggy formats, with or without `<|call|>`

**Multi-call parsing:** GPT-OSS only supports one tool call per generation (the template only reads `tool_calls[0]`). Qwen supports multiple `<tool_call>` blocks.

### GGUF Metadata

GGUF files embed rich metadata accessible via `llama_model_meta_val_str`:

```
general.architecture    → "qwen3", "llama", "gemma3", "gpt_oss"
general.name            → "Qwen3 4B Instruct Awq"
general.file_type       → quantization type (15 = Q4_K_M)
tokenizer.ggml.model    → "gpt2" (tokenizer type)
tokenizer.ggml.pre      → "qwen2" (pre-tokenizer)
tokenizer.chat_template → Full Jinja template string
tokenizer.ggml.bos_token_id → 151643
tokenizer.ggml.eos_token_id → 151645
```

**Null byte gotcha:** GPT-OSS embeds a `\0` at position 12895 of its 16K-char template. Must strip with `.replacingOccurrences(of: "\0", with: "")` before parsing.

### Vision

**Not supported.** `mattt/llama.swift` distributes llama.cpp as an XCFramework that explicitly excludes `libmtmd.a` (the multimodal library containing llava/clip support). The build script filters it out.

- Zero issues/PRs about vision support in `mattt/llama.swift`
- `tattn/LocalLLMClient` is the only Swift package with GGUF + vision (hybrid approach: XCFramework + source-compiled mtmd/clip C++ files)
- The official `ggml-org/llama.cpp` Swift Package includes multimodal but is a much heavier dependency

### Thinking/Reasoning

- **Qwen3** — `<think>...</think>` tags in raw text, controlled via `enable_thinking` template parameter (bool, default=true)
- **GPT-OSS** — analysis channel (`<|channel|>analysis<|message|>...<|end|>`) for chain-of-thought, `reasoning_effort` parameter (string: "low"/"medium"/"high")
- **Reasoning effort actually works:** Clear difference in analysis depth — low=~50 tokens, medium=~102 tokens, high=~200 tokens for the same question

Both map cleanly to Yrden's `ContentKind.thinking` / `ThinkingBlock`.

### Template Parameter Discovery

Same Jinja AST walker from MLX POC discovers model-specific parameters:

```
Qwen3-4B:    enable_thinking (bool, default=true)
GPT-OSS-20B: Template parse fails (too complex for swift-jinja)
             But regex fallback discovers: reasoning_effort, model_identity, builtin_tools
Llama-3.2:   (none discovered — simple ChatML template)
Gemma-3:     (none discovered)
```

### Performance

| Model | Size (GGUF Q4_K_M) | Speed (M4 Max) |
|---|---|---|
| Qwen3-4B | ~2.3 GB | ~95 tok/s |
| GPT-OSS-20B | ~11.6 GB | ~73 tok/s |
| Llama-3.2-1B | ~0.9 GB | ~130 tok/s |
| Gemma-3-1B | ~0.8 GB | ~120 tok/s |

All models fully offloaded to GPU (`n_gpu_layers = 99`). Flash attention auto-enabled on M4 Max.

## Architecture

### How It Fits

```
┌──────────────────────────────────────────┐
│  Agent / User Code                       │
│                                          │
│  let model = GGMLModel(                  │
│      modelId: "Qwen/Qwen3-4B-GGUF",     │
│      filename: "Qwen3-4B-Q4_K_M.gguf",  │
│      provider: ggmlProvider              │
│  )                                       │
│  let response = try await model.complete(│
│      request                             │
│  )                                       │
└──────────┬───────────────────────────────┘
           │ Model protocol
           ▼
┌──────────────────────────────────────────┐
│  GGMLModel: Model                        │
│                                          │
│  1. Convert CompletionRequest messages   │
│  2. Render chat template (C/Jinja/manual)│
│  3. Tokenize prompt                      │
│  4. Run sampler loop (decode + sample)   │
│  5. Parse tool calls from raw text       │
│  6. Extract thinking blocks              │
│  7. Build CompletionResponse / stream    │
│     StreamEvents                         │
└──────────┬───────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────┐
│  llama.cpp (via mattt/llama.swift)       │
│                                          │
│  C API: llama_model_load_from_file,      │
│  llama_tokenize, llama_decode,           │
│  llama_sampler_sample,                   │
│  llama_chat_apply_template,              │
│  llama_model_meta_val_str                │
└──────────────────────────────────────────┘
```

### Provider vs Model

Following the existing pattern where `Provider` = transport and `Model` = API format:

- **`GGMLProvider`** — handles model discovery (local GGUF files + HuggingFace Hub download), no auth needed
- **`GGMLModel`** — handles template rendering, tokenization, generation, tool call parsing, thinking extraction

Unlike HTTP providers where construction is instant, GGML models require loading weights into GPU memory (seconds to tens of seconds for large models). `GGMLModel` manages a `LlamaModel` (our C API wrapper) lifecycle.

## Components

### 1. GGMLProvider

```swift
public struct GGMLProvider: Provider, Sendable {
    public var baseURL: URL { /* not applicable */ }

    public func authenticate(_ request: inout URLRequest) async throws {
        // No-op — local inference
    }

    public func listModels() -> AsyncThrowingStream<ModelInfo, Error> {
        // List GGUF files in local cache
        // ~/Documents/huggingface/models/
    }
}
```

### 2. LlamaModel (C API Wrapper)

Thin Swift wrapper managing llama.cpp model + context lifecycle. Already validated in POC.

```swift
final class LlamaModel {
    let model: OpaquePointer      // llama_model
    let context: OpaquePointer    // llama_context
    let vocab: OpaquePointer      // llama_vocab
    let eosToken: llama_token
    let bosToken: llama_token

    init(path: String, contextSize: UInt32 = 4096, gpuLayers: Int32 = 99) throws
    deinit  // calls llama_free, llama_model_free, llama_backend_free

    func metadataString(key: String) -> String?
    func chatTemplate() -> String?
    func clearCache()
}
```

**Key lifecycle notes:**
- `llama_backend_init()` in init, `llama_backend_free()` in deinit
- Context cleared between generations via `llama_memory_clear`
- Model params: `n_gpu_layers = 99` (full GPU offload), `n_ctx` configurable, `n_batch = 512`

### 3. GGMLModel

The core component. Conforms to `Model` protocol.

```swift
public final class GGMLModel: Model, Sendable {
    public static let providerId = "ggml"

    public let name: String
    public let capabilities: ModelCapabilities
    public let foreignThinkingBehavior: ForeignThinkingBehavior

    private let llamaModel: LlamaModel
    private let profile: ModelProfile
    private let templateRenderer: TemplateRenderer

    public func complete(_ request: CompletionRequest) async throws -> CompletionResponse
    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error>
}
```

### 4. TemplateRenderer

Encapsulates the three-path template rendering strategy.

```swift
public struct TemplateRenderer: Sendable {
    enum Strategy {
        case cAPI            // llama_chat_apply_template (fast, basic)
        case jinja           // swift-jinja (full features)
        case manual(Format)  // Format-specific prompt building
    }

    /// Render messages to a prompt string.
    /// Tries C API → Jinja → manual, in order.
    func render(
        template: String,
        messages: [(role: String, content: String)],
        tools: [[String: Any]]?,
        bosToken: String,
        eosToken: String,
        additionalContext: [String: Any]
    ) throws -> String
}
```

### 5. ToolCallParser

Same as MLX design — extracts tool calls from raw model text output.

```swift
public struct ToolCallParser: Sendable {
    public enum Format: String, Sendable {
        case qwen       // <tool_call>{JSON}</tool_call>
        case harmony    // Harmony protocol (GPT-OSS)
    }

    public static func parse(text: String) -> [ToolCall]
    public static func parse(text: String, format: Format) -> [ToolCall]
    public static func parseHarmonyAnalysis(text: String) -> String?
    public static func parseHarmonyFinalResponse(text: String) -> String?
}
```

**Harmony parser handles three variants:**
1. Correct format: `<|start|>assistant<|channel|>commentary to=functions.NAME <|constrain|>json<|message|>ARGS<|call|>`
2. Buggy format: `<|start|>assistant to=functions.NAME<|channel|>commentary json<|message|>ARGS<|call|>`
3. Truncated: Same as above but without `<|call|>` (consumed as stop token)

### 6. ModelProfile

Static metadata for tested models.

```swift
public struct ModelProfile: Sendable {
    public let modelId: String
    public let displayName: String
    public let architecture: String       // From GGUF: "qwen3", "llama", "gemma3", "gpt_oss"
    public let toolCallFormat: ToolCallFormat
    public let capabilities: ModelCapabilities
    public let defaultAdditionalContext: [String: AnySendable]?
    public let templateStrategy: TemplateRenderer.Strategy
}
```

### 7. TemplateIntrospector

Reused from MLX — discovers model-specific template parameters from Jinja chat templates.

```swift
public struct TemplateIntrospector: Sendable {
    public struct Parameter: Sendable {
        public let name: String
        public let inferredType: ParameterType  // bool, string, number, array, unknown
        public let defaultValue: String?
        public let validValues: [String]?
    }

    public static func discover(template: String) -> [Parameter]
}
```

## Model Container Caching

### The Problem

Same as MLX: loading a GGUF model takes seconds (download + GPU memory allocation). Without caching, an agent loop with 5 tool-calling iterations triggers 5 redundant loads.

### Design: `GGMLModelCache`

An actor managing loaded `LlamaModel` instances, keyed by file path.

```swift
public actor GGMLModelCache {
    public static let shared = GGMLModelCache()

    private var loaded: [String: CacheEntry] = [:]
    private let maxModels: Int

    public init(maxModels: Int = 2)

    public func model(
        for path: String,
        contextSize: UInt32 = 4096,
        gpuLayers: Int32 = 99
    ) async throws -> LlamaModel

    public func unload(_ path: String)
    public func unloadAll()
}
```

Unlike MLX where `ModelContainer` is Sendable/thread-safe, `LlamaModel` wraps raw C pointers. The actor ensures serial access — only one generation at a time per model.

## KV-Cache Reuse Between Turns

### What llama.cpp Provides

llama.cpp maintains an internal KV-cache in `llama_context`. The cache persists between `llama_decode` calls and grows incrementally. Calling `llama_memory_clear` resets it.

### Challenge

Our current POC calls `clearCache()` before every generation, discarding the KV-cache. For agent loops, this means re-processing the entire conversation from scratch each turn.

### Design: Prefix Detection

Same strategy as MLX — detect when the current request shares a message prefix with the previous one, and skip clearing the cache. The cache already contains KVs for the shared prefix tokens; only new tokens need processing.

```swift
// Pseudocode for cache reuse
func generate(request: CompletionRequest) throws -> CompletionResponse {
    let messageHash = hashMessages(request.messages.dropLast(2))

    if messageHash == previousMessageHash {
        // Don't clear cache — prefix is still valid
        // Only tokenize and decode the new messages
    } else {
        llamaModel.clearCache()
        // Tokenize and decode everything from scratch
    }

    // ... sampler loop ...

    previousMessageHash = hashMessages(request.messages)
}
```

### Performance Impact

Same as MLX — ~2.8x speedup for a 5-turn agent loop with growing conversation context.

## Request/Response Flow

### CompletionRequest → Generation

```swift
func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
    // 1. Render chat template (C API / Jinja / manual)
    let prompt = try templateRenderer.render(
        template: llamaModel.chatTemplate(),
        messages: request.messages,
        tools: request.tools,
        additionalContext: profile.defaultAdditionalContext
    )

    // 2. Tokenize
    let tokens = tokenize(llamaModel, text: prompt)

    // 3. Decode prompt as batch
    var batch = llama_batch_get_one(&tokens, Int32(tokens.count))
    llama_decode(llamaModel.context, batch)

    // 4. Sampler loop
    let sampler = buildSamplerChain(
        temperature: request.config.temperature,
        topP: request.config.topP
    )
    var rawText = ""
    for _ in 0..<maxTokens {
        let token = llama_sampler_sample(sampler, llamaModel.context, -1)
        if llama_vocab_is_eog(llamaModel.vocab, token) { break }
        rawText += tokenToString(llamaModel, token: token)
        // decode next token...
    }

    // 5. Build response (format-aware)
    return buildResponse(rawText: rawText)
}
```

### Building the Response (Format-Aware)

Same structure as MLX — prefer native tool call detection, fall back to our parser, extract thinking blocks based on model type.

```swift
func buildResponse(rawText: String) -> CompletionResponse {
    var contentBlocks: [AssistantContentBlock] = []

    // Tool calls
    let toolCalls = ToolCallParser.parse(
        text: rawText,
        format: profile.toolCallFormat
    )

    // Thinking/analysis
    switch profile.architecture {
    case "gpt_oss":
        if let analysis = ToolCallParser.parseHarmonyAnalysis(text: rawText) {
            contentBlocks.append(.thinking(...))
        }
        if let finalText = ToolCallParser.parseHarmonyFinalResponse(text: rawText) {
            contentBlocks.append(.text(finalText))
        }
    default:
        let (thinking, responseText) = extractThinkingBlocks(rawText)
        // ... same as MLX
    }

    for call in toolCalls {
        contentBlocks.append(.toolUse(call))
    }

    return CompletionResponse(contentBlocks: contentBlocks, ...)
}
```

### Streaming

Token-by-token generation naturally supports streaming:

```swift
func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
        Task {
            // ... tokenize and decode prompt ...

            var rawText = ""
            for _ in 0..<maxTokens {
                let token = llama_sampler_sample(sampler, context, -1)
                if llama_vocab_is_eog(vocab, token) { break }

                let piece = tokenToString(llamaModel, token: token)
                rawText += piece

                // For non-Harmony models: emit text deltas in real-time
                if profile.architecture != "gpt_oss" {
                    continuation.yield(.contentDelta(piece))
                }
            }

            // For Harmony: emit buffered content at end (same as MLX)
            let response = buildResponse(rawText: rawText)
            continuation.yield(.done(response))
            continuation.finish()
        }
    }
}
```

**Same streaming tradeoff as MLX for GPT-OSS:** Harmony channel multiplexing prevents real-time text streaming — content is buffered and emitted after generation completes.

## Configuration Mapping

```swift
CompletionConfig.temperature     → llama_sampler_init_temp(Float)
CompletionConfig.topP            → llama_sampler_init_top_p(Float, 1)
CompletionConfig.maxTokens       → sampler loop iteration limit
CompletionConfig.stopSequences   → post-generation text truncation (not native)

// Temperature = 0 → llama_sampler_init_greedy() (no temp/topP samplers)
// Temperature > 0 → temp → topP → dist sampler chain

// GGML-specific (via template params):
// enable_thinking    → additionalContext["enable_thinking"]
// reasoning_effort   → additionalContext["reasoning_effort"]
```

## Supported Models

### Tier 1: Tested and Verified

| Model ID | Architecture | Tools | Thinking | Size (Q4_K_M) | Speed |
|---|---|---|---|---|---|
| `Qwen/Qwen3-4B-GGUF` | qwen3 | yes (native) | yes (`enable_thinking`) | 2.3 GB | ~95 tok/s |
| `unsloth/gpt-oss-20b-GGUF` | gpt_oss | yes (harmony) | yes (analysis channel) | 11.6 GB | ~73 tok/s |
| `bartowski/Llama-3.2-1B-Instruct-GGUF` | llama | untested | no | 0.9 GB | ~130 tok/s |
| `ggml-org/gemma-3-1b-it-GGUF` | gemma3 | untested | no | 0.8 GB | ~120 tok/s |

### Tier 2: Auto-Detected

Any GGUF model compatible with llama.cpp. The provider auto-detects:
- `general.architecture` from GGUF metadata → tool call format, thinking style
- `tokenizer.chat_template` → template rendering strategy
- Template parameters via Jinja AST introspection → `additionalContext`
- Tool support defaults to `false` unless architecture is known to support it

## Limitations

1. **No vision support** — `mattt/llama.swift` XCFramework excludes `libmtmd.a`. The only workaround is `tattn/LocalLLMClient` (hybrid approach) or switching to the official `ggml-org/llama.cpp` Swift Package (heavier dependency).

2. **Template rendering gaps** — swift-jinja cannot parse complex templates (GPT-OSS). Manual prompt building is the fallback. Filing an issue or contributing recursive `for` loop support to swift-jinja would fix this for most models.

3. **No logits-level structured output** — same as MLX. Can't constrain generation at the token level. Structured output relies on the model following its chat template.

4. **Low-level C API** — `mattt/llama.swift` is a thin `@_exported import llama` wrapper. All memory management, error handling, and lifecycle management falls on us. No Swift-native convenience layer.

5. **Single-threaded generation** — `llama_context` is not thread-safe. Each model instance can only run one generation at a time. The `GGMLModelCache` actor enforces this.

6. **GPT-OSS streaming is buffered** — same as MLX. Harmony channel multiplexing prevents real-time text streaming.

7. **Tool call format fragmentation** — each model family invents its own format. New families need new parsers. The `ToolCallParser` is extensible but requires manual work per format.

8. **GPT-OSS single tool call per turn** — the template only reads `tool_calls[0]`. Multiple tool calls require multiple generation rounds.

## MLX vs GGML Provider Comparison

| Feature | MLX Provider | GGML Provider |
|---|---|---|
| Model format | MLX safetensors | GGUF |
| Model ecosystem | ~hundreds on HF | ~thousands on HF |
| Vision | Yes (Gemma 3 VLM) | No |
| Template rendering | Built into mlx-swift-lm | Three-path strategy (C/Jinja/manual) |
| Tool detection | Built-in `ToolCallProcessor` | Custom `ToolCallParser` |
| KV-cache | Explicit `[KVCache]` arrays | Internal to `llama_context` |
| Thread safety | `ModelContainer` is Sendable | Raw C pointers, needs actor isolation |
| Swift API | High-level (5 types) | Low-level C (~30 functions) |
| Build complexity | Normal SPM | Normal SPM (XCFramework) |
| Cross-platform | Apple-only | Potentially Linux/Windows |

**Recommendation:** Offer both. MLX for Apple-native quality (vision, simpler API). GGML for maximum model compatibility and cross-platform potential.

## Dependencies

```swift
// Package.swift additions
.package(url: "https://github.com/mattt/llama.swift", .upToNextMajor(from: "2.7964.0"))

// Products used:
// - LlamaSwift (llama.cpp XCFramework, auto-tracked releases)

// Already in Yrden's dependency tree:
// - Jinja (swift-jinja, for template rendering)
// - Hub (swift-transformers, for GGUF file download)
```

`mattt/llama.swift` auto-publishes SPM releases tracking upstream llama.cpp (593+ releases). Versioning uses llama.cpp's build number (e.g., `2.7964.0`).

## Open Questions

1. **Should we use `mattt/llama.swift` or `ggml-org/llama.cpp` official Swift Package?** The official package includes minja (C++ Jinja) and multimodal support, but is heavier and less SPM-polished. `mattt/llama.swift` is lightweight with proper semver, but excludes vision and minja.

2. **LlamaModel as class or actor?** The C API isn't thread-safe. Options: (a) `final class` wrapped in `GGMLModelCache` actor for serial access, (b) make `LlamaModel` itself an actor. Option (a) is simpler and matches the existing pattern.

3. **Sampler configuration** — llama.cpp offers many samplers (temp, top-p, top-k, min-p, mirostat, grammar). Which should we expose beyond temperature and top-p? Grammar-based sampling could enable structured output.

4. **GGUF file management** — should the provider manage a local GGUF cache directory, or rely on HuggingFace Hub's cache? The POC uses `~/Documents/huggingface/models/` with a manual curl fallback for large files where the Hub API fails.

5. **Context size management** — GGUF models have a `context_length` in metadata (e.g., Qwen3 = 40960). Should we auto-configure `n_ctx` from this, or use a conservative default (4096)? Larger context = more memory.
