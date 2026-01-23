# Development Progress

## Session: 2026-01-22 (Part 8)

### Completed

#### listModels() → AsyncThrowingStream + Caching

Refactored `listModels()` to return `AsyncThrowingStream<ModelInfo, Error>` instead of `[ModelInfo]`. This enables:
- **Lazy pagination** - Pages fetched on demand as stream is consumed
- **Early exit** - Stop iterating when you find what you need
- **Memory efficiency** - Don't hold 200+ models in memory for large catalogs (OpenRouter)

Also added `CachedModelList` actor for opt-in caching of model lists.

**Protocol Change:**

```swift
// Before
func listModels() async throws -> [ModelInfo]

// After
func listModels() -> AsyncThrowingStream<ModelInfo, Error>
```

**Usage:**

```swift
// Collect all models
var models: [ModelInfo] = []
for try await model in provider.listModels() {
    models.append(model)
}

// Find first matching model (stops early, no extra pages fetched)
for try await model in provider.listModels() {
    if model.id.contains("claude-3-5") {
        return model
    }
}

// With caching (recommended for repeated access)
let cache = CachedModelList(ttl: 3600)  // 1 hour TTL
let models = try await cache.models(from: provider)
let models2 = try await cache.models(from: provider)  // Cached
let fresh = try await cache.models(from: provider, forceRefresh: true)
```

**New Files/Types:**

| Type | Location | Description |
|------|----------|-------------|
| `CachedModelList` | Provider.swift | Actor for caching model lists with TTL |

**New Tests:**

| Test | Description |
|------|-------------|
| `listModels_earlyExit()` | Verifies lazy evaluation and early exit |
| `listModels_cached()` | Verifies CachedModelList caching behavior |

**Test Counts:** 226 tests (all passing)

---

## Session: 2026-01-22 (Part 7)

### Completed

#### Comprehensive Anthropic Test Coverage

In-depth review of test coverage revealed gaps in streaming, tool calling, and edge cases. Added 11 new integration tests and 2 unit tests to achieve robust coverage.

**Bug Fix: Streaming Mixed Content**

Fixed a bug in `AnthropicModel.processStreamEvent()` where `contentBlockStop` events for tool calls were not being handled correctly when text content preceded the tool call. The SSE `index` is the absolute content block index, not the tool call index.

- Changed `ToolCallAccumulator` to track `blockIndex`
- Updated `contentBlockStop` handler to find tool call by block index

**New Integration Tests:**

| Test | Category | Description |
|------|----------|-------------|
| `streamingWithStopSequence()` | Streaming | Stop sequence terminates stream correctly |
| `streamingWithMaxTokens()` | Streaming | Truncation mid-stream with `.maxTokens` |
| `streamingMixedContent()` | Streaming | Text + tool call in same stream |
| `streamingUsageTracking()` | Streaming | Token counts in streaming response |
| `multipleToolCalls()` | Tools | Multiple tools available, model selects |
| `toolCallWithNestedArguments()` | Tools | Complex nested object/array arguments |
| `toolResultWithError()` | Tools | Error response handled gracefully |
| `multiTurnWithTools()` | Multi-turn | Full loop: user → tool → result → follow-up |
| `unicodeHandling()` | Edge Cases | Unicode/emoji in messages |
| `unicodeInToolArguments()` | Edge Cases | Unicode in tool call arguments |
| `expensive_contextLengthExceeded()` | Error Handling | Context overflow (skipped by default) |

**New Unit Tests:**

| Test | Description |
|------|-------------|
| `decode_stopSequenceResponse()` | Response with `stop_sequence` field set |
| `decode_maxTokensResponse()` | Response with `max_tokens` stop reason |

**Test Counts:**
- Anthropic Integration: 31 tests (was 20)
- Anthropic Types Unit: 29 tests (was 27)
- **Total: 224 tests (all passing)**

**Expensive Test Pattern:**

Tests that are costly (high token usage) or slow are gated with:
```swift
@Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_EXPENSIVE_TESTS"] != nil))
```

Run with: `RUN_EXPENSIVE_TESTS=1 swift test --filter expensive`

---

## Session: 2026-01-22 (Part 6)

### Completed

#### Anthropic Integration Test Gaps

Closed testing gaps for stop sequences and vision/images. Identified that structured outputs (`outputSchema`) is not yet implemented for Anthropic.

**New Tests Added:**

| Test | Description |
|------|-------------|
| `stopSequences()` | Verifies generation stops at stop sequence with `.stopSequence` reason |
| `stopSequences_multipleSequences()` | Tests multiple stop sequences (first match wins) |
| `imageInput()` | Single image (red PNG) with color recognition |
| `imageInputWithText()` | Image with system message |
| `multipleImages()` | Two images (red + green) in single request |

**Test Infrastructure:**
- Added helper functions for creating minimal valid PNG images programmatically
- `createTestPNG(color:)` generates 2x2 pixel solid color PNGs
- Includes CRC32 and Adler32 implementations for PNG chunk checksums

**Finding: Structured Outputs Not Yet Implemented**

The `outputSchema` field exists in `CompletionRequest` but is not used in `AnthropicModel.encodeRequest()`. Anthropic supports structured outputs via:
1. Tool use (forcing tool call with schema)
2. Beta structured outputs API

Implementation deferred to OpenAI provider work (where structured outputs are more mature).

---

## Session: 2026-01-22 (Part 5)

### Completed

#### Anthropic Provider Implementation

Implemented `AnthropicProvider` and `AnthropicModel` as the first real provider, validating the Model/Provider architecture with actual API support.

**New Files:**

| File | Lines | Description |
|------|-------|-------------|
| [AnthropicProvider.swift](../Sources/Yrden/Providers/Anthropic/AnthropicProvider.swift) | ~50 | API key auth, headers, base URL |
| [AnthropicTypes.swift](../Sources/Yrden/Providers/Anthropic/AnthropicTypes.swift) | ~280 | Internal wire format types for encoding/decoding |
| [AnthropicModel.swift](../Sources/Yrden/Providers/Anthropic/AnthropicModel.swift) | ~350 | `Model` protocol implementation with streaming |

**Key Implementation Details:**

1. **Request Encoding:**
   - System messages extracted to request `system` field (not in messages array)
   - Tool arguments converted from string to parsed JSON object
   - Images base64 encoded with `media_type`

2. **Response Decoding:**
   - Text content extracted from `content` blocks
   - Tool calls converted back to `ToolCall` with stringified arguments
   - Stop reason mapped to our `StopReason` enum

3. **Streaming:**
   - SSE event parsing for Anthropic's event types
   - Event types: `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`
   - Tool call arguments accumulated during streaming

4. **Error Handling:**
   - HTTP status codes mapped to `LLMError` cases
   - Anthropic error responses parsed for detailed messages
   - Rate limit retry-after header support

**Tests:**

| File | Tests | Coverage |
|------|-------|----------|
| [AnthropicTypesTests.swift](../Tests/YrdenTests/AnthropicTypesTests.swift) | 29 | Content blocks, messages, requests, responses, SSE events |
| [AnthropicIntegrationTests.swift](../Tests/YrdenTests/Integration/AnthropicIntegrationTests.swift) | 31 | Real API calls: completion, streaming, tools, vision, stop sequences, multi-turn, unicode, errors |

**Integration Test Coverage:**
- Simple completion with system messages
- Temperature and max_tokens config
- Streaming (basic, stop sequences, max tokens, mixed content, usage tracking)
- Tool calling (single, multi-turn, multiple tools, nested args, error results)
- Multi-turn conversation context
- Vision/images (single, multiple, with text)
- Stop sequences (single, multiple)
- Unicode/emoji handling
- Error handling (invalid API key, invalid model, context overflow)
- Model listing (`listModels()`)

**Model Discovery:**
- Added `ModelInfo` type with id, displayName, createdAt, metadata
- Added `listModels()` to `Provider` protocol
- Implemented for `AnthropicProvider` via `GET /v1/models`

---

## Session: 2026-01-22 (Part 4)

### Completed

#### Core LLM Types Implementation

Implemented all core types from [llm-provider-design.md](llm-provider-design.md) with comprehensive test coverage (164 tests total, 0 failures).

**Phase 1: Foundation Types**

| File | Types | Description |
|------|-------|-------------|
| [Tool.swift](../Sources/Yrden/Tool.swift) | `ToolDefinition`, `ToolCall`, `ToolOutput` | Tool calling primitives |
| [Message.swift](../Sources/Yrden/Message.swift) | `Message`, `ContentPart` | Conversation messages with multimodal support |
| [LLMError.swift](../Sources/Yrden/LLMError.swift) | `LLMError` | Typed error enum with all common failure modes |

**Phase 2: Composite Types**

| File | Types | Description |
|------|-------|-------------|
| [Completion.swift](../Sources/Yrden/Completion.swift) | `CompletionConfig`, `CompletionRequest`, `CompletionResponse`, `StopReason`, `Usage` | Request/response types |
| [Streaming.swift](../Sources/Yrden/Streaming.swift) | `StreamEvent` | Fine-grained streaming events |

**Phase 3: Protocols**

| File | Types | Description |
|------|-------|-------------|
| [Model.swift](../Sources/Yrden/Model.swift) | `Model` protocol, `ModelCapabilities` | Model abstraction with capability validation |
| [Provider.swift](../Sources/Yrden/Provider.swift) | `Provider` protocol, `OpenAICompatibleProvider` | Connection and authentication |

**Key Features:**
- All types are `Sendable`, `Codable`, `Equatable`, `Hashable`
- `ModelCapabilities` with predefined constants for common models (Claude 3.5, GPT-4o, o1/o3)
- Request validation against model capabilities (throws `LLMError.capabilityNotSupported`)
- Convenience extensions on `Model` for common patterns

**Tests:**

| File | Tests | Coverage |
|------|-------|----------|
| [ToolTests.swift](../Tests/YrdenTests/ToolTests.swift) | 21 | ToolDefinition, ToolCall, ToolOutput roundtrip + edge cases |
| [MessageTests.swift](../Tests/YrdenTests/MessageTests.swift) | 29 | Message, ContentPart roundtrip + convenience constructors |
| [LLMErrorTests.swift](../Tests/YrdenTests/LLMErrorTests.swift) | 26 | Error enum + LocalizedError descriptions |
| [CompletionTests.swift](../Tests/YrdenTests/CompletionTests.swift) | 28 | Request/Response/Config/StopReason/Usage |
| [StreamingTests.swift](../Tests/YrdenTests/StreamingTests.swift) | 26 | StreamEvent roundtrip + event sequences |
| [ModelTests.swift](../Tests/YrdenTests/ModelTests.swift) | 26 | ModelCapabilities + request validation |

---

## Session: 2026-01-22 (Part 3)

### Completed

#### JSONValue Implementation - All 5 Phases Complete

Fully implemented `JSONValue` type with comprehensive test coverage (165 tests, 0 failures).

**Implementation** ([Sources/Yrden/JSONValue.swift](../Sources/Yrden/JSONValue.swift)):
- Recursive enum: `null`, `bool`, `int`, `double`, `string`, `array`, `object`
- Custom Codable (not synthesized - proper JSON format, not wrapped enum)
- Type-safe accessors: `boolValue`, `intValue`, `doubleValue`, `stringValue`, `arrayValue`, `objectValue`
- Subscript access: `value["key"]` for objects, `value[0]` for arrays
- Literal expressibility: `nil`, `true`, `42`, `3.14`, `"hello"`, `[1, 2]`, `["a": 1]`
- Sendable, Equatable, Hashable

**Tests** ([Tests/YrdenTests/JSONValue/](../Tests/YrdenTests/JSONValue/)):

| File | Tests | Coverage |
|------|-------|----------|
| [JSONValuePrimitiveTests.swift](../Tests/YrdenTests/JSONValue/JSONValuePrimitiveTests.swift) | 55 | null, bool, int, double, string - roundtrip, encoding, decoding, accessors, literals |
| [JSONValueObjectTests.swift](../Tests/YrdenTests/JSONValue/JSONValueObjectTests.swift) | 29 | objects - roundtrip, accessor, subscript, nested, literals, edge cases |
| [JSONValueArrayTests.swift](../Tests/YrdenTests/JSONValue/JSONValueArrayTests.swift) | 29 | arrays - roundtrip, accessor, subscript, heterogeneous, nested, literals |
| [JSONValueEqualityTests.swift](../Tests/YrdenTests/JSONValue/JSONValueEqualityTests.swift) | 32 | Equatable/Hashable - same/different values, nested, Set/Dictionary usage |
| [JSONValueE2ETests.swift](../Tests/YrdenTests/JSONValue/JSONValueE2ETests.swift) | 20 | real-world: JSON Schema, tool args, structured outputs, provider formats |

**Phases completed:**
1. ✅ Primitives - null, bool, int, double, string + accessors + literals
2. ✅ Object - object case + objectValue + subscript + nested
3. ✅ Array - array case + arrayValue + subscript + mixed
4. ✅ Equatable/Hashable - synthesized works, edge cases verified
5. ✅ E2E - JSON Schema, tool arguments, structured output scenarios

---

## Session: 2026-01-22 (Part 2)

### Completed

#### 1. Research: JSONValue Patterns
Investigated how to represent arbitrary JSON in Swift. Key findings:

- **`[String: Any]` won't work** - not Sendable, not Codable (Swift 6 requirement)
- **JSEN pattern** is industry standard - recursive enum for JSON representation
- **Swift's gap** - no built-in arbitrary JSON type, everyone rolls their own
- **Our scope** - we wrap Apple's JSONDecoder, we don't parse JSON ourselves

Created research document: [docs/research-jsonvalue.md](research-jsonvalue.md)

#### 2. Test Strategy: JSONValue
Defined focused test strategy. Key decisions:

- **Don't test Apple's code** - JSONDecoder handles parsing
- **Test our code** - Codable impl, accessors, subscripts, literals
- **8 test categories** - roundtrip, encoding format, decoding, accessors, subscripts, literals, equatable, **end-to-end**
- **E2E tests critical** - verify full flow (schema → encode → decode → access) works for real scenarios
- **~45 tests total** - small, focused, maintainable

Created test strategy: [docs/test-strategy-jsonvalue.md](test-strategy-jsonvalue.md)

---

## Session: 2026-01-22 (Part 1)

### Completed

#### 1. LLM Provider Design Document
Created comprehensive design document at [docs/llm-provider-design.md](llm-provider-design.md) covering:

- **Design Tenets** (7 core principles):
  - Sendable everywhere
  - Codable by default (opt-in usage)
  - Deps never Codable
  - Lazy initialization
  - State/behavior separation
  - Pausable execution
  - Model-agnostic core

- **Architecture Decision: Model/Provider Split** (PydanticAI-style)
  - `Model` = API format + capabilities + complete()/stream()
  - `Provider` = connection + authentication
  - Avoids N×M type explosion
  - Enables: Azure OpenAI, Ollama, Bedrock with multiple model families

- **10 Design Decisions** with rationale and alternatives considered:
  1. Model/Provider split
  2. Swift API surface (TBD - options documented)
  3. Request type with convenience overloads
  4. Models implement both streaming and non-streaming
  5. Fine-grained streaming events
  6. Closed Message enum
  7. JSONValue for schema representation
  8. Typed error enum
  9. Unified tool system
  10. Codable opt-in for serialization

- **Apple Ecosystem Opportunities** identified (future, not blocking):
  - Handoff, CloudKit sync, SwiftUI binding, Siri/Shortcuts, Background tasks, On-device models

- **Risks and Open Questions** documented

#### 2. Test Configuration Setup
Created environment variable support for integration tests:

- [.env.template](.env.template) - Template for API keys
- [Tests/YrdenTests/TestConfig.swift](../Tests/YrdenTests/TestConfig.swift) - Loads keys from env vars or .env file
- Updated [.gitignore](../.gitignore) to exclude `.env` files

**Key design decision:** Tests fail loudly if required API keys are missing (no silent skipping).

---

## Next Steps

### Immediate (Next Session)

1. **OpenAI Model**
   - Validates abstraction works across providers
   - Different capabilities (test o1 handling)
   - `OpenAIProvider` and `OpenAIChatModel`
   - Integration tests with real API

2. **Anthropic Remaining Gaps**
   - ❌ **Structured outputs** - Not yet implemented (type exists but not wired to API)
   - All other features comprehensively tested ✅

3. **Edge Cases** (lower priority)
   - Rate limiting (actual 429 with retry-after) - hard to test reliably
   - Content filtering - hard to trigger intentionally

### Medium-term

4. **Provider Variants**
   - `AzureOpenAIProvider`
   - `LocalProvider` (Ollama)

5. **@Schema Macro**
   - JSON Schema generation from Swift types
   - `@Guide` for constraints

6. **Tool Protocol**
   - `Tool` protocol with typed arguments
   - `TypedTool` with `SchemaType` arguments
   - Tool execution in agent loop

---

## File Structure (Current)

```
Yrden/
├── CLAUDE.md                           # Project instructions
├── Package.swift
├── docs/
│   ├── llm-provider-design.md          # ✅ Design document
│   ├── research-jsonvalue.md           # ✅ JSONValue research
│   ├── test-strategy-jsonvalue.md      # ✅ JSONValue test plan
│   └── progress.md                     # ✅ This file
├── Sources/
│   ├── Yrden/
│   │   ├── Yrden.swift                 # SchemaType protocol, @Schema macro decl
│   │   ├── JSONValue.swift             # ✅ JSONValue enum (Sendable, Codable)
│   │   ├── Message.swift               # ✅ Message, ContentPart
│   │   ├── Tool.swift                  # ✅ ToolDefinition, ToolCall, ToolOutput
│   │   ├── Completion.swift            # ✅ Request/Response/Config types
│   │   ├── Streaming.swift             # ✅ StreamEvent
│   │   ├── Model.swift                 # ✅ Model protocol, ModelCapabilities
│   │   ├── Provider.swift              # ✅ Provider protocol
│   │   ├── LLMError.swift              # ✅ Typed error enum
│   │   └── Providers/
│   │       └── Anthropic/              # ✅ Anthropic provider
│   │           ├── AnthropicProvider.swift   # API key auth
│   │           ├── AnthropicTypes.swift      # Wire format types
│   │           └── AnthropicModel.swift      # Model implementation
│   └── YrdenMacros/
│       ├── YrdenMacros.swift           # Plugin entry point
│       └── SchemaMacro.swift           # Macro implementation (stub)
├── Tests/
│   ├── YrdenTests/
│   │   ├── YrdenTests.swift            # Basic tests
│   │   ├── TestConfig.swift            # ✅ API key loading
│   │   ├── ToolTests.swift             # ✅ Tool type tests
│   │   ├── MessageTests.swift          # ✅ Message type tests
│   │   ├── LLMErrorTests.swift         # ✅ Error tests
│   │   ├── CompletionTests.swift       # ✅ Completion type tests
│   │   ├── StreamingTests.swift        # ✅ StreamEvent tests
│   │   ├── ModelTests.swift            # ✅ Model/Capabilities tests
│   │   ├── AnthropicTypesTests.swift   # ✅ Anthropic wire format tests
│   │   ├── Integration/                # ✅ Integration tests (real API)
│   │   │   └── AnthropicIntegrationTests.swift
│   │   └── JSONValue/                  # ✅ JSONValue tests
│   │       ├── JSONValuePrimitiveTests.swift
│   │       ├── JSONValueObjectTests.swift
│   │       ├── JSONValueArrayTests.swift
│   │       ├── JSONValueEqualityTests.swift
│   │       └── JSONValueE2ETests.swift
│   └── YrdenMacrosTests/
│       └── YrdenMacrosTests.swift      # Macro tests
├── .env.template                       # ✅ API key template
└── .gitignore                          # ✅ Updated for .env
```

---

## Design Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-01-22 | Model/Provider split | Follow PydanticAI, avoid N×M explosion |
| 2026-01-22 | JSONValue over [String: Any] | Sendable + Codable required |
| 2026-01-22 | Codable opt-in | Enable Apple features without requiring them |
| 2026-01-22 | Deps never Codable | Keep deps flexible (DB, HTTP clients) |
| 2026-01-22 | Tests fail on missing keys | No silent skipping |
| 2026-01-22 | Custom Codable for JSONValue | Synthesized Codable wraps values incorrectly |
| 2026-01-22 | Separate int/double cases | JSON Schema distinguishes integer vs number |
| 2026-01-22 | Test our code, not Apple's | JSONDecoder handles parsing, we test our wrapper |
| 2026-01-22 | Incremental implementation | Each feature tested before adding next; primitives → object → array → e2e |
| 2026-01-22 | All types Equatable+Hashable | Enables use in Sets/Dictionaries for caching, deduplication |
| 2026-01-22 | String in LLMError.networkError | Error protocol not Equatable; use String for description |
| 2026-01-22 | Custom Codable for enums | Avoid synthesized wrapped format; use role/type discriminators |
| 2026-01-22 | Request validation in Model extension | Catch capability mismatches before API call |
| 2026-01-22 | Model = API format, not LLM | Same LLM via different APIs needs different Model classes (e.g., Claude via Anthropic vs Bedrock) |
| 2026-01-22 | OpenRouter extends OpenAIChatModel | OpenRouter uses OpenAI-compatible format with extra metadata |
| 2026-01-22 | Internal wire format types | Keep AnthropicTypes internal, only expose public Model/Provider |
| 2026-01-22 | ToolCall.arguments as String | Provider-agnostic; Anthropic parses to JSONValue internally, serializes back to string |
| 2026-01-22 | SSE parsing in model | Each provider handles its own streaming format; no common SSE abstraction needed |
| 2026-01-22 | Model.name = API identifier | String that goes to API (base model ID or inference profile ID for Bedrock) |
| 2026-01-22 | listModels() returns ModelInfo | Rich metadata for discovery; provider-specific details in `metadata: JSONValue?` |
| 2026-01-22 | listModels() → AsyncThrowingStream | Lazy pagination for large catalogs; early exit support; caller decides caching |
| 2026-01-22 | CachedModelList actor | Opt-in caching with TTL; keeps Provider stateless and Sendable |
