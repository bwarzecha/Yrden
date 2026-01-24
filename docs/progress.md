# Development Progress

## Running Tests

### Quick Reference

```bash
# Run all tests (unit tests only - no API keys needed)
swift test

# Run tests with API keys from .env file
export $(cat .env | grep -v '^#' | xargs) && swift test

# Run specific test filter
export $(cat .env | grep -v '^#' | xargs) && swift test --filter "OpenAI"

# Run expensive tests (o1, etc.)
export $(cat .env | grep -v '^#' | xargs) RUN_EXPENSIVE_TESTS=1 && swift test --filter "o1_"

# List available OpenAI models
export $(cat .env | grep -v '^#' | xargs) && swift test --filter "listAllModels"
```

### Environment Variables

Create a `.env` file in the project root (see `.env.template`):

```bash
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
# Optional
RUN_EXPENSIVE_TESTS=1
```

The `export $(cat .env | grep -v '^#' | xargs)` pattern:
1. Reads .env file
2. Filters out comment lines (starting with #)
3. Exports all key=value pairs to the environment
4. Runs the following command with those variables

---

## Session: 2026-01-23 (Part 3)

### Completed

#### Agent Core Implementation

Implemented the core Agent system inspired by PydanticAI with typed output, tool execution loop, and dependency injection.

**New Files:**

| File | Description |
|------|-------------|
| `Sources/Yrden/Agent/Agent.swift` | Main `Agent<Deps, Output>` actor with `run()` method |
| `Sources/Yrden/Agent/AgentContext.swift` | Rich context passed to tools during execution |
| `Sources/Yrden/Agent/AgentTool.swift` | `AgentTool` protocol, `ToolResult` enum, `AnyAgentTool` wrapper |
| `Sources/Yrden/Agent/AgentError.swift` | Agent-specific errors (maxIterationsReached, usageLimitExceeded, etc.) |
| `Sources/Yrden/Agent/AgentTypes.swift` | Supporting types: UsageLimits, EndStrategy, AgentResult, OutputValidator |
| `Tests/YrdenTests/Agent/AgentTests.swift` | Unit and integration tests |

**Core Types:**

| Type | Description |
|------|-------------|
| `Agent<Deps, Output>` | Actor that orchestrates tool use and produces typed output |
| `AgentContext<Deps>` | Context passed to tools with deps, model, usage, messages |
| `AgentTool` | Protocol for tools with typed `Args: SchemaType` and `Output: Sendable` |
| `ToolResult<T>` | `.success(T)`, `.retry(message:)`, `.failure(Error)`, `.deferred(DeferredToolCall)` |
| `AnyAgentTool<Deps>` | Type-erased wrapper for heterogeneous tool collections |
| `UsageLimits` | Token, request, and tool call limits |
| `EndStrategy` | `.early` (stop at first output) vs `.exhaustive` (run all tools) |
| `OutputValidator` | Post-validation with retry capability |

**Key Design Decisions:**

| Decision | Rationale |
|----------|-----------|
| Output tool for structured types | Anthropic/OpenAI require object schemas for tool input; using a tool ensures schema compliance |
| Text response for String output | When `Output == String`, no output tool is created; model responds with text directly |
| `AnyAgentTool` type erasure | Enables heterogeneous `[AnyAgentTool<Deps>]` collections while preserving type safety |
| `ToolResult` with retry | Tools can signal "try again" to the LLM with feedback message |
| `DeferredToolCall` foundation | Prepares for human-in-the-loop approval patterns |

**Message.swift Changes:**

- Added `ToolResultEntry` struct for multi-tool responses
- Added `.toolResults([ToolResultEntry])` case to Message enum
- Updated all providers (Anthropic, OpenAI, Bedrock) to handle new case

**Usage:**

```swift
// Define a tool
struct CalculatorTool: AgentTool {
    @Schema struct Args { let expression: String }

    var name: String { "calculator" }
    var description: String { "Evaluate a mathematical expression" }

    func call(context: AgentContext<Void>, arguments: Args) async throws -> ToolResult<String> {
        // ... evaluate expression ...
        return .success(result)
    }
}

// Create agent with typed output
@Schema struct MathResult { let expression: String; let result: Int }

let agent = Agent<Void, MathResult>(
    model: model,
    systemPrompt: "You are a math assistant.",
    tools: [AnyAgentTool(CalculatorTool())],
    maxIterations: 5
)

// Run and get typed result
let result = try await agent.run("What is 5 + 3?", deps: ())
print(result.output.result)  // 8
```

**Tests:** 6 new tests (unit + integration)

**Test Count:** 455 tests (all passing)

---

## Session: 2026-01-23 (Part 2)

### Completed

#### AWS Bedrock Provider Planning

Created comprehensive implementation plan for AWS Bedrock support: [bedrock-implementation-plan.md](bedrock-implementation-plan.md)

**Key Decisions:**

| Decision | Rationale |
|----------|-----------|
| Use AWS SDK for Swift | SigV4 signing is complex; SDK handles credentials, refresh, retries |
| Tool forcing for structured output | Bedrock has NO native JSON mode |
| Test with Claude + Amazon Nova | Validates cross-model family compatibility |
| `BedrockProvider` + `BedrockModel` | Follows existing architecture pattern |

**Bedrock Converse API Differences:**

| Aspect | Anthropic Direct | Bedrock Converse |
|--------|------------------|------------------|
| Auth | API key | AWS Signature V4 |
| System message | String | Array of content blocks |
| Tool schema | `input_schema` | `toolSpec.inputSchema.json` |
| Streaming | Same endpoint | Different endpoint (`/converseStream`) |
| Structured output | Native (beta) | Not supported |

**Implementation Phases:**
1. Provider setup + credentials
2. Basic completion (Claude + Nova)
3. Streaming
4. Tools & structured output
5. Advanced features (inference profiles, vision)
6. Testing & documentation

---

## Session: 2026-01-23 (Part 1)

### Completed

#### @Schema and @Guide Macros

Implemented compile-time JSON Schema generation from Swift types using Swift macros.

**New Files:**

| File | Description |
|------|-------------|
| `Sources/YrdenMacros/SchemaMacro.swift` | Main macro implementation for structs and enums |
| `Sources/YrdenMacros/GuideMacro.swift` | Property-level description/constraint marker |
| `Sources/YrdenMacros/SchemaGeneration/TypeParser.swift` | Parses Swift types to schema representation |
| `Sources/YrdenMacros/SchemaGeneration/SchemaBuilder.swift` | Generates Swift code for JSON Schema literals |

**Supported Types:**

| Swift Type | JSON Schema |
|------------|-------------|
| `String` | `{"type": "string"}` |
| `Int` | `{"type": "integer"}` |
| `Double` | `{"type": "number"}` |
| `Bool` | `{"type": "boolean"}` |
| `[T]` | `{"type": "array", "items": ...}` |
| `T?` | Same type, omitted from `required` |
| `@Schema struct` | Nested object reference |
| `enum: String` | `{"type": "string", "enum": [...]}` |
| `enum: Int` | `{"type": "integer", "enum": [...]}` |

**@Guide Constraints:**

```swift
@Guide(description: "Max results", .range(1...100))      // "Must be between 1 and 100"
@Guide(description: "Score", .rangeDouble(0.0...1.0))    // "Must be between 0.0 and 1.0"
@Guide(description: "Page", .minimum(1))                  // "Must be at least 1"
@Guide(description: "Count", .maximum(50))                // "Must be at most 50"
@Guide(description: "Tags", .count(1...10))               // "Must have between 1 and 10 items"
@Guide(description: "Items", .exactCount(5))              // "Must have exactly 5 items"
@Guide(description: "Sort", .options(["a", "b"]))         // Generates "enum": ["a", "b"]
@Guide(description: "Pattern", .pattern("^[a-z]+$"))      // "Must match pattern: ^[a-z]+$"
```

Note: `.options()` generates JSON Schema `enum`, all other constraints generate description text since most providers don't support JSON Schema validation keywords.

**Tests:** 63 tests covering all schema generation scenarios

---

#### Typed Structured Output API

Implemented PydanticAI-style typed API that returns decoded Swift types directly.

**New Types:**

| Type | Description |
|------|-------------|
| `TypedResponse<T>` | Wraps decoded data with usage, stopReason, rawJSON |
| `StructuredOutputError` | Comprehensive error enum for all failure modes |
| `RetryingHTTPClient` | Configurable retry logic with exponential backoff |

**Model Extension Methods:**

```swift
// OpenAI - native structured output
let result = try await model.generate(prompt, as: PersonInfo.self)
print(result.data.name)  // Already typed!

// Anthropic - tool-based extraction
let result = try await model.generateWithTool(
    prompt,
    as: PersonInfo.self,
    toolName: "extract_person"
)

// Streaming variants
for try await event in model.generateStream(prompt, as: PersonInfo.self) { ... }
for try await event in model.generateStreamWithTool(prompt, as: PersonInfo.self, toolName: "extract") { ... }

// Lower-level extraction
let typed = try model.extractAndDecode(from: response, as: PersonInfo.self, expectToolCall: false)
```

**StructuredOutputError Cases:**

| Error | Description |
|-------|-------------|
| `.modelRefused(reason)` | Model declined (safety, policy) |
| `.emptyResponse` | No content or tool calls |
| `.unexpectedTextResponse(content)` | Expected tool call, got text |
| `.unexpectedToolCall(toolName)` | Expected text, got tool call |
| `.decodingFailed(json, error)` | JSON didn't match schema |
| `.incompleteResponse(partialJSON)` | Response truncated (max tokens) |

**Tests:** 33 unit tests + 32 integration tests

---

#### Examples

Added runnable example targets:

```bash
swift run BasicSchema        # Schema generation demo (no API keys)
swift run StructuredOutput   # Typed API demo (requires API keys)
```

**Test Count:** 402 tests (all passing)

---

## Session: 2026-01-22 (Part 10)

### Completed

#### GPT-5.2 and Newer Models Support

Tested and added support for the newest OpenAI models discovered through model listing:
- **GPT-5 family**: gpt-5, gpt-5-mini, gpt-5-nano, gpt-5-pro, gpt-5.1, gpt-5.2
- **o3 family**: o3, o3-mini, o3-pro, o3-deep-research
- **GPT-4.1 family**: gpt-4.1, gpt-4.1-mini, gpt-4.1-nano

**Key API Changes for Newer Models:**

| Parameter | Old Models (GPT-4, GPT-3.5) | New Models (GPT-5.x, o3, o1, GPT-4.1) |
|-----------|----------------------------|----------------------------------------|
| Max tokens | `max_tokens` | `max_completion_tokens` |
| Temperature | Supported | o3/o1: NOT supported, GPT-5: supported |
| System messages | Supported | o3/o1: NOT supported, GPT-5: supported |

**Updated Files:**
- [OpenAITypes.swift](../Sources/Yrden/Providers/OpenAI/OpenAITypes.swift) - Added `max_completion_tokens` parameter
- [OpenAIModel.swift](../Sources/Yrden/Providers/OpenAI/OpenAIModel.swift) - Auto-detect which parameter to use based on model name
- [Model.swift](../Sources/Yrden/Model.swift) - Added `.gpt5` capability preset (400K context)

**Test Results:**
- GPT-5.2 completion: ✅ Working
- GPT-5.2 streaming: ✅ Working
- o3-mini reasoning: ✅ Working (uses more tokens for reasoning)

#### Structured Output Implementation (OpenAI)

Wired up `outputSchema` to OpenAI's `response_format` with `json_schema`. This enables type-safe JSON responses that conform to a specified schema.

**How it works:**
```swift
let schema: JSONValue = [
    "type": "object",
    "properties": [
        "sentiment": ["type": "string", "enum": ["positive", "negative", "neutral"]],
        "confidence": ["type": "number"]
    ],
    "required": ["sentiment", "confidence"],
    "additionalProperties": false
]

let request = CompletionRequest(
    messages: [.user("Analyze: 'I love this!'")],
    outputSchema: schema
)

let response = try await model.complete(request)
// response.content is guaranteed to be valid JSON matching the schema
```

**Updated Files:**
- [OpenAIModel.swift](../Sources/Yrden/Providers/OpenAI/OpenAIModel.swift) - Converts `outputSchema` to `response_format: json_schema`

**Tests Added:**
- `structuredOutput_sentimentAnalysis()` - Complex schema with enum, number, array
- `structuredOutput_dataExtraction()` - Extract structured data from text
- `structuredOutput_streaming()` - Structured output works with streaming
- `encode_structuredOutputRequest()` - Unit test for wire format

**Note:** Anthropic's structured output is in beta and not yet implemented.

**Learnings for Future Schema Development:**

1. **`additionalProperties: false` is required** for OpenAI's strict mode. Without it, the model may add extra fields.

2. **JSONValue has separate `.int` and `.double` cases**, not a unified `.number`. When parsing responses, handle both:
   ```swift
   switch value {
   case .int(let i): // handle integer
   case .double(let d): // handle decimal
   }
   ```

3. **Dictionary subscript returns optional** - `obj["key"]` returns `JSONValue?`, must unwrap before pattern matching:
   ```swift
   // Wrong: case .string(let s) = obj["key"]
   // Right:
   guard let value = obj["key"], case .string(let s) = value else { ... }
   ```

4. **"integer" in schema may return as double** - JSON doesn't distinguish int/double, so `"type": "integer"` might come back as `.double(32.0)` not `.int(32)`. Handle both.

5. **Streaming works with structured output** - Accumulate deltas, parse complete JSON at end. The model streams valid JSON fragments.

6. **Schema name is arbitrary** - We use `"response"` but any valid identifier works. OpenAI uses it for logging/debugging.

7. **`strict: true` enforces exact compliance** - Model will only output valid JSON matching the schema. No need for fallback parsing.

**Test Count:** 294 tests (all passing)

---

## Session: 2026-01-22 (Part 9)

### Completed

#### OpenAI Provider Implementation

Implemented `OpenAIProvider` and `OpenAIModel` as the second provider, validating the Model/Provider architecture works across different API formats.

**New Files:**

| File | Lines | Description |
|------|-------|-------------|
| [OpenAIProvider.swift](../Sources/Yrden/Providers/OpenAI/OpenAIProvider.swift) | ~110 | Bearer token auth, model listing |
| [OpenAITypes.swift](../Sources/Yrden/Providers/OpenAI/OpenAITypes.swift) | ~350 | Wire format types (internal) |
| [OpenAIModel.swift](../Sources/Yrden/Providers/OpenAI/OpenAIModel.swift) | ~430 | Model protocol implementation |

**Key Differences from Anthropic:**

| Aspect | Anthropic | OpenAI |
|--------|-----------|--------|
| Auth header | `x-api-key` | `Authorization: Bearer` |
| System message | Extracted to `system` field | In messages array (`role: system`) |
| Tool results | Content block in user message | Separate message (`role: tool`) |
| Images | `source.data` with base64 | Data URL format |
| Stream end | `message_stop` event | `data: [DONE]` |
| Stop reasons | `end_turn`, `tool_use` | `stop`, `tool_calls` |

**Capability Detection:**

Models are auto-detected by name prefix:
- `gpt-4o*`, `gpt-4-turbo*` → Full capabilities
- `o1*` → No temperature, no tools, no vision, no system messages
- `o3*` → No temperature, has tools/vision, no system messages

**Tests:**

| File | Tests | Coverage |
|------|-------|----------|
| [OpenAITypesTests.swift](../Tests/YrdenTests/OpenAITypesTests.swift) | 39 | Content parts, messages, requests, responses, streaming |
| [OpenAIIntegrationTests.swift](../Tests/YrdenTests/Integration/OpenAIIntegrationTests.swift) | 21 | Real API: completion, streaming, tools, vision, unicode, errors |

**Integration Test Coverage:**
- Simple completion with system messages
- Temperature and max_tokens config
- Streaming (basic, long response)
- Tool calling (single, multi-turn, multiple tools, streaming)
- Multi-turn conversation context
- Vision/images
- Unicode/emoji handling
- Error handling (invalid API key, invalid model)
- Model listing
- o1 capability validation (temperature, tools, system message restrictions)

**Test Counts:** 286 tests total (284 passing, 2 skipped)

**Expensive Test Pattern:**

Tests requiring special API access (o1 models) are gated:
```swift
@Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_EXPENSIVE_TESTS"] != nil))
func o1_simpleCompletion() async throws { ... }
```

Run with: `RUN_EXPENSIVE_TESTS=1 swift test --filter o1_`

---

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

### Immediate

1. **Agent Loop (continued)**
   - `Agent.runStream()` - Streaming events during execution
   - `Agent.iter()` - Iterable execution with `AgentNode` yielding
   - Deferred tool resolution (human-in-the-loop)
   - Output validators with retry

2. **AWS Bedrock Provider** (PLANNED - see [bedrock-implementation-plan.md](bedrock-implementation-plan.md))
   - `BedrockProvider` with AWS Signature V4 (via AWS SDK for Swift)
   - `BedrockModel` implementing Converse API format
   - Testing with Claude + Amazon Nova models
   - Tool forcing for structured output (no native JSON mode)

### Medium-term

4. **Provider Variants**
   - `AzureOpenAIProvider` - Different auth, URL structure
   - `LocalProvider` (Ollama) - OpenAI-compatible, no auth
   - `OpenRouterProvider` - Multi-model aggregator

5. **Runtime Constraint Validation**
   - Validate decoded data against @Guide constraints
   - Auto-retry with feedback on constraint violations

6. **MCP Integration**
   - Model Context Protocol client
   - Dynamic tool discovery from external servers

### Completed ✅

- ~~@Schema Macro~~ - JSON Schema generation from Swift types
- ~~@Guide constraints~~ - Descriptions and validation hints
- ~~Structured Outputs~~ - OpenAI native + Anthropic tool-based
- ~~Typed API~~ - generate(), generateWithTool(), TypedResponse<T>
- ~~Agent Core~~ - Agent<Deps, Output> with run(), tools, typed output

---

## File Structure (Current)

```
Yrden/
├── CLAUDE.md                           # Project instructions
├── README.md                           # ✅ Updated documentation
├── Package.swift
├── docs/
│   ├── llm-provider-design.md          # Design document
│   ├── bedrock-implementation-plan.md  # 📋 AWS Bedrock plan
│   ├── research-jsonvalue.md           # JSONValue research
│   ├── test-strategy-jsonvalue.md      # JSONValue test plan
│   └── progress.md                     # This file
├── Examples/
│   ├── BasicSchema/main.swift          # ✅ Schema generation demo
│   └── StructuredOutput/main.swift     # ✅ Typed API demo
├── Sources/
│   ├── Yrden/
│   │   ├── Yrden.swift                 # SchemaType protocol, macro declarations
│   │   ├── JSONValue.swift             # JSONValue enum (Sendable, Codable)
│   │   ├── Message.swift               # Message, ContentPart
│   │   ├── Tool.swift                  # ToolDefinition, ToolCall, ToolOutput
│   │   ├── Completion.swift            # Request/Response/Config types
│   │   ├── Streaming.swift             # StreamEvent
│   │   ├── Model.swift                 # Model protocol, ModelCapabilities
│   │   ├── Provider.swift              # Provider protocol
│   │   ├── LLMError.swift              # Typed error enum
│   │   ├── Model+StructuredOutput.swift # ✅ generate(), generateWithTool()
│   │   ├── StructuredOutput.swift      # ✅ TypedResponse<T>
│   │   ├── StructuredOutputError.swift # ✅ Error enum
│   │   ├── Retry.swift                 # ✅ RetryingHTTPClient
│   │   ├── Agent/                      # ✅ Agent system
│   │   │   ├── Agent.swift             # Main Agent<Deps, Output> actor
│   │   │   ├── AgentContext.swift      # Context passed to tools
│   │   │   ├── AgentTool.swift         # Tool protocol + AnyAgentTool
│   │   │   ├── AgentError.swift        # Agent-specific errors
│   │   │   └── AgentTypes.swift        # UsageLimits, EndStrategy, etc.
│   │   └── Providers/
│   │       ├── Anthropic/
│   │       │   ├── AnthropicProvider.swift
│   │       │   ├── AnthropicTypes.swift
│   │       │   └── AnthropicModel.swift
│   │       └── OpenAI/
│   │           ├── OpenAIProvider.swift
│   │           ├── OpenAITypes.swift
│   │           ├── OpenAIModel.swift
│   │           └── OpenAIResponsesTypes.swift  # ✅ Responses API types
│   └── YrdenMacros/
│       ├── YrdenMacros.swift           # Plugin entry point
│       ├── SchemaMacro.swift           # ✅ @Schema macro implementation
│       ├── GuideMacro.swift            # ✅ @Guide macro implementation
│       └── SchemaGeneration/
│           ├── TypeParser.swift        # ✅ Type parsing
│           └── SchemaBuilder.swift     # ✅ Schema code generation
├── Tests/
│   ├── YrdenTests/
│   │   ├── TestConfig.swift            # API key loading
│   │   ├── ToolTests.swift
│   │   ├── MessageTests.swift
│   │   ├── LLMErrorTests.swift
│   │   ├── CompletionTests.swift
│   │   ├── StreamingTests.swift
│   │   ├── ModelTests.swift
│   │   ├── AnthropicTypesTests.swift
│   │   ├── OpenAITypesTests.swift
│   │   ├── StructuredOutputTests.swift # ✅ Typed API unit tests
│   │   ├── Integration/
│   │   │   ├── AnthropicIntegrationTests.swift
│   │   │   ├── OpenAIIntegrationTests.swift
│   │   │   ├── SchemaIntegrationTests.swift      # ✅ @Schema with real APIs
│   │   │   └── TypedOutputIntegrationTests.swift # ✅ Typed API with real APIs
│   │   ├── Agent/
│   │   │   └── AgentTests.swift                  # ✅ Agent unit + integration tests
│   │   └── JSONValue/
│   │       └── ... (JSONValue tests)
│   └── YrdenMacrosTests/
│       └── YrdenMacrosTests.swift      # ✅ 35+ macro expansion tests
├── .env.template
└── .gitignore
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
| 2026-01-22 | OpenAI same patterns as Anthropic | Validates Model/Provider split; same public types, different wire format |
| 2026-01-22 | Capability detection by model name | Simple prefix matching (gpt-4o, o1, o3); avoids API call to check capabilities |
| 2026-01-22 | o1 tests gated behind RUN_EXPENSIVE_TESTS | o1 models may require special access; validation tests run without API call |
| 2026-01-23 | Bedrock uses AWS SDK for Swift | SigV4 manual implementation error-prone; SDK handles credentials/refresh |
| 2026-01-23 | Bedrock structured output via tool forcing | Converse API has no native JSON mode; same pattern as Anthropic tool-based |
| 2026-01-23 | Test Bedrock with Claude + Nova | Cross-model family testing ensures API compatibility |
| 2026-01-23 | Agent uses output tool for structured types | Providers require object schemas for tools; String output uses text response |
| 2026-01-23 | AnyAgentTool type erasure | Enables heterogeneous tool collections while preserving type safety internally |
| 2026-01-23 | String: SchemaType extension | Allows Agent<Deps, String> to work without output tool (text response) |
| 2026-01-23 | ToolResult enum with retry case | Tools can signal LLM to retry with feedback; cleaner than throwing |
| 2026-01-23 | Agent as actor | Thread-safe state management for tool execution loop |
