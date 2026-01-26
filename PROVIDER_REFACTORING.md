# Provider Refactoring Plan

> Tracking document for extracting duplicate code and hard-coded strings from provider implementations.

## Status: Complete

---

## Phase 1: Bedrock Internal Duplication (Quick Win)
**Status:** [x] Completed

### Problem
`BedrockModel.swift` has two nearly identical methods:
- `encodeRequest` (lines 95-136) → returns `ConverseInput`
- `encodeStreamRequest` (lines 138-179) → returns `ConverseStreamInput`

Both extract system messages, convert messages, build inference config, and build tool config.

### Solution
Extract common logic into a shared helper that returns a tuple, then have both methods use it.

### Files to Modify
- [x] `Sources/Yrden/Providers/Bedrock/BedrockModel.swift`

---

## Phase 2: HTTP Constants
**Status:** [x] Completed

### Problem
Hard-coded HTTP-related strings scattered across providers:

| String | Locations |
|--------|-----------|
| `"POST"` | AnthropicModel:272, OpenAIModel:384,451,687,770 |
| `"Content-Type"` | AnthropicProvider:51, OpenAIProvider:50 |
| `"application/json"` | AnthropicProvider:51, OpenAIProvider:50 |
| `"Authorization"` | OpenAIProvider:49 |
| `"Bearer "` | OpenAIProvider:49 |
| `"x-api-key"` | AnthropicProvider:49 |
| `"anthropic-version"` | AnthropicProvider:50 |
| `"2023-06-01"` | AnthropicProvider:50 |
| `"Retry-After"` / `"retry-after"` | OpenAIModel:424, AnthropicModel:311 (inconsistent casing!) |

### Solution
Create `Sources/Yrden/Providers/HTTPConstants.swift` with enums for headers, methods, and values.

### Files to Create
- [x] `Sources/Yrden/Providers/HTTPConstants.swift`

### Files to Modify
- [x] `Sources/Yrden/Providers/Anthropic/AnthropicProvider.swift`
- [x] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift`
- [x] `Sources/Yrden/Providers/OpenAI/OpenAIProvider.swift`
- [x] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift`

---

## Phase 3: SSE Constants
**Status:** [x] Completed

### Problem
SSE format strings repeated in streaming code:

| String | Locations |
|--------|-----------|
| `"data: "` | AnthropicModel:362, OpenAIModel:477,803 |
| `"event: "` | AnthropicModel:359 |
| `"[DONE]"` | OpenAIModel:481,807 |
| `dropFirst(6)` / `dropFirst(7)` | Multiple locations |

### Solution
Create `Sources/Yrden/SSE.swift` with SSE parsing constants.

### Files to Create
- [x] `Sources/Yrden/SSE.swift`

### Files to Modify
- [x] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift`
- [x] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift`

---

## Phase 4: Message Role Constants
**Status:** [x] Completed

### Problem
Role strings used in message conversion:

| String | Locations |
|--------|-----------|
| `"system"` | OpenAIModel:221 |
| `"user"` | OpenAIModel:229,236, AnthropicModel:127,149,170 |
| `"assistant"` | OpenAIModel:250, AnthropicModel:145 |
| `"tool"` | OpenAIModel:257,284 |
| `"function"` | OpenAIModel:245, OpenAIResponsesTypes:140 |

### Solution
Create `Sources/Yrden/MessageRoles.swift` with role constants.

### Files to Create
- [x] `Sources/Yrden/MessageRoles.swift`

### Files to Modify
- [x] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift`
- [x] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift`
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAITypes.swift` (not needed - comments only)
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAIResponsesTypes.swift` (not needed - comments only)

---

## Phase 5: API Endpoint Constants
**Status:** [x] Completed

### Problem
API endpoint paths hard-coded:

| String | Provider | Locations |
|--------|----------|-----------|
| `"messages"` | Anthropic | AnthropicModel:271,331 |
| `"models"` | Both | AnthropicProvider:103, OpenAIProvider:76 |
| `"chat/completions"` | OpenAI | OpenAIModel:383,450 |
| `"responses"` | OpenAI | OpenAIModel:686,769 |

### Solution
Add endpoint constants to each provider or create `Sources/Yrden/Providers/APIEndpoints.swift`.

### Files to Create
- [x] `Sources/Yrden/Providers/APIEndpoints.swift`

### Files to Modify
- [x] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift`
- [x] `Sources/Yrden/Providers/Anthropic/AnthropicProvider.swift`
- [x] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift`
- [x] `Sources/Yrden/Providers/OpenAI/OpenAIProvider.swift`

---

## Phase 6: Stop Reason Constants
**Status:** [x] Completed

### Problem
Provider-specific stop reason strings:

**Anthropic:**
- `"end_turn"`, `"tool_use"`, `"max_tokens"`, `"stop_sequence"`

**OpenAI:**
- `"stop"`, `"tool_calls"`, `"length"`, `"content_filter"`

**Anthropic Stream Events:**
- `"message_start"`, `"content_block_start"`, `"content_block_delta"`, `"content_block_stop"`, `"message_delta"`, `"message_stop"`, `"error"`, `"text_delta"`, `"input_json_delta"` (deferred to Phase 7)

### Solution
Create provider-specific constants in each provider's Types file or a shared constants file.

### Files to Modify
- [x] `Sources/Yrden/Providers/Anthropic/AnthropicTypes.swift`
- [x] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift`
- [x] `Sources/Yrden/Providers/OpenAI/OpenAITypes.swift`
- [x] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift`

---

## Phase 7: Content Block Type Constants
**Status:** [x] Completed

### Problem
Content block type strings:

**Anthropic:**
- `"text"`, `"image"`, `"tool_use"`, `"tool_result"`, `"base64"`
- Stream event types: `"message_start"`, `"content_block_start"`, etc.
- Delta types: `"text_delta"`, `"input_json_delta"`

**OpenAI:**
- `"text"`, `"image_url"`, `"input_text"`, `"output_text"`, `"input_image"`, `"message"`, `"function_call"`, `"reasoning"`, `"refusal"`

### Solution
Added constants to each provider's Types file:
- `AnthropicEventType` - SSE event type identifiers
- `AnthropicDeltaType` - Delta type identifiers
- `ResponsesOutputType` - Output item type identifiers
- `ResponsesContentType` - Content type identifiers
- `ResponsesInputType` - Input item type identifiers

### Files Modified
- [x] `Sources/Yrden/Providers/Anthropic/AnthropicTypes.swift` - Added AnthropicEventType, AnthropicDeltaType
- [x] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift` - Fixed remaining "text" usage
- [x] `Sources/Yrden/Providers/OpenAI/OpenAIResponsesTypes.swift` - Added ResponsesOutputType, ResponsesContentType, ResponsesInputType
- [x] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift` - Updated function_call usage

---

## Phase 8: HTTP Request Helper
**Status:** [x] Completed

### Problem
Identical HTTP request pattern in AnthropicModel and OpenAIModel (~40 lines duplicated):
```swift
var urlRequest = URLRequest(url: provider.baseURL.appendingPathComponent("..."))
urlRequest.httpMethod = "POST"
try await provider.authenticate(&urlRequest)
urlRequest.httpBody = try JSONEncoder().encode(request)
let (data, response) = try await URLSession.shared.data(for: urlRequest)
try handleHTTPResponse(response, data: data)
```

### Solution
Created `HTTPClient` enum with reusable request methods:
- `sendJSONPOST` - Sends POST with JSON body, returns (Data, HTTPURLResponse)
- `streamJSONPOST` - Sends POST for streaming, returns (AsyncBytes, HTTPURLResponse)
- `collectErrorData` - Collects error data from streaming response
- `parseRetryAfter` - Parses Retry-After header

### Files Created
- [x] `Sources/Yrden/Providers/HTTPClient.swift`

### Files Modified
- [x] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift` - Simplified sendRequest, streamRequest
- [x] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift` - Simplified sendRequest, streamRequest, sendResponsesRequest, streamResponsesRequest

---

## Phase 9: HTTP Status Handler
**Status:** [~] Kept Provider-Specific

### Problem
Nearly identical status code handling (~50 lines duplicated):
- AnthropicModel:281-307
- OpenAIModel:393-433

### Decision
After analysis, the status handling differs enough between providers to warrant keeping separate:
- OpenAI has retry logic for 408, 409, 429, 500+
- OpenAI checks for context length in 400 errors
- Anthropic has simpler handling

Added helper for common cases (`handleCommonStatus`, `parseRetryAfter`) to HTTPClient.swift, but kept main status handling in providers since the logic diverges significantly.

---

## Phase 10: Streaming Setup Helper
**Status:** [x] Completed (merged with Phase 8)

### Problem
Identical streaming setup pattern (~25 lines x 3):
- AnthropicModel:327-349
- OpenAIModel:445-468
- OpenAIModel:765-787

### Solution
Combined with Phase 8 - `HTTPClient.streamJSONPOST` and `collectErrorData` handle all streaming setup.

### Files Modified
- [x] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift`
- [x] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift`

---

## Phase 11: Error Message Parsing
**Status:** [~] Kept Provider-Specific

### Problem
Similar error parsing logic:
- AnthropicModel parseErrorMessage (~5 lines)
- OpenAIModel parseErrorMessage (~5 lines)

### Decision
After analysis, the functions are too simple to benefit from extraction:
- Each is only 5 lines of code
- They use different error types (AnthropicError, OpenAIError)
- Extracting would add complexity (protocol or closure) for minimal benefit
- The fallback logic (`String(data:encoding:) ?? "Unknown error"`) is already consistent

The current approach is clean and maintainable.

---

## Phase 12: ToolCallAccumulator
**Status:** [~] Kept Provider-Specific

### Problem
Similar structs in two files:
- AnthropicModel: ToolCallAccumulator (id, name, blockIndex, arguments)
- OpenAIModel: ToolCallAccumulator (id, name, arguments, started, ended)

### Decision
After analysis, these structs serve different purposes:
- **Anthropic**: Uses `blockIndex` for SSE content block positioning
- **OpenAI**: Uses `started`/`ended` flags for explicit state tracking

The streaming protocols differ significantly:
- Anthropic sends content_block_start/delta/stop events with indices
- OpenAI sends incremental deltas with implicit start/end detection

Merging would require awkward optional fields or protocol abstraction.
The current approach keeps each provider's streaming logic self-contained and clear.

---

## Completed Phases

*(Move phases here as they are completed)*

---

## Commit History

| Phase | Commit Hash | Date | Notes |
|-------|-------------|------|-------|
| - | - | - | - |

