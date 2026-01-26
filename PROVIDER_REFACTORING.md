# Provider Refactoring Plan

> Tracking document for extracting duplicate code and hard-coded strings from provider implementations.

## Status: Phase 3 In Progress

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
**Status:** [ ] Not Started

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
- [ ] `Sources/Yrden/SSE.swift`

### Files to Modify
- [ ] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift`
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift`

---

## Phase 4: Message Role Constants
**Status:** [ ] Not Started

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
- [ ] `Sources/Yrden/MessageRoles.swift`

### Files to Modify
- [ ] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift`
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift`
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAITypes.swift`
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAIResponsesTypes.swift`

---

## Phase 5: API Endpoint Constants
**Status:** [ ] Not Started

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
- [ ] `Sources/Yrden/Providers/APIEndpoints.swift`

### Files to Modify
- [ ] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift`
- [ ] `Sources/Yrden/Providers/Anthropic/AnthropicProvider.swift`
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift`
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAIProvider.swift`

---

## Phase 6: Stop Reason Constants
**Status:** [ ] Not Started

### Problem
Provider-specific stop reason strings:

**Anthropic:**
- `"end_turn"`, `"tool_use"`, `"max_tokens"`, `"stop_sequence"`

**OpenAI:**
- `"stop"`, `"tool_calls"`, `"length"`, `"content_filter"`

**Anthropic Stream Events:**
- `"message_start"`, `"content_block_start"`, `"content_block_delta"`, `"content_block_stop"`, `"message_delta"`, `"message_stop"`, `"error"`, `"text_delta"`, `"input_json_delta"`

### Solution
Create provider-specific constants in each provider's Types file or a shared constants file.

### Files to Modify
- [ ] `Sources/Yrden/Providers/Anthropic/AnthropicTypes.swift`
- [ ] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift`
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAITypes.swift`
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift`

---

## Phase 7: Content Block Type Constants
**Status:** [ ] Not Started

### Problem
Content block type strings:

**Anthropic:**
- `"text"`, `"image"`, `"tool_use"`, `"tool_result"`, `"base64"`

**OpenAI:**
- `"text"`, `"image_url"`, `"input_text"`, `"output_text"`, `"input_image"`, `"message"`, `"function_call"`, `"reasoning"`, `"refusal"`

### Solution
Add constants to each provider's Types file.

### Files to Modify
- [ ] `Sources/Yrden/Providers/Anthropic/AnthropicTypes.swift`
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAITypes.swift`
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAIResponsesTypes.swift`

---

## Phase 8: HTTP Request Helper
**Status:** [ ] Not Started

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
Create `Sources/Yrden/Providers/HTTPClient.swift` with reusable request methods.

### Files to Create
- [ ] `Sources/Yrden/Providers/HTTPClient.swift`

### Files to Modify
- [ ] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift`
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift`

---

## Phase 9: HTTP Status Handler
**Status:** [ ] Not Started

### Problem
Nearly identical status code handling (~50 lines duplicated):
- AnthropicModel:281-307
- OpenAIModel:393-433

### Solution
Extract into shared `handleHTTPStatus` function in HTTPClient.swift.

### Files to Modify
- [ ] `Sources/Yrden/Providers/HTTPClient.swift` (extend from Phase 8)
- [ ] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift`
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift`

---

## Phase 10: Streaming Setup Helper
**Status:** [ ] Not Started

### Problem
Identical streaming setup pattern (~25 lines x 3):
- AnthropicModel:327-349
- OpenAIModel:445-468
- OpenAIModel:765-787

### Solution
Add streaming helper to HTTPClient.swift.

### Files to Modify
- [ ] `Sources/Yrden/Providers/HTTPClient.swift`
- [ ] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift`
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift`

---

## Phase 11: Error Message Parsing
**Status:** [ ] Not Started

### Problem
Identical error parsing logic:
- AnthropicModel:318-323
- OpenAIModel:436-441

### Solution
Create generic error parser or add to HTTPClient.swift.

### Files to Modify
- [ ] `Sources/Yrden/Providers/HTTPClient.swift`
- [ ] `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift`
- [ ] `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift`

---

## Phase 12: ToolCallAccumulator
**Status:** [ ] Not Started

### Problem
Similar structs in two files:
- AnthropicModel:483-488
- OpenAIModel:977-983

### Solution
Create shared `Sources/Yrden/Providers/ToolCallAccumulator.swift` or keep provider-specific (they have slightly different fields).

### Decision Needed
- [ ] Decide: Merge into shared struct with optional fields, or keep separate?

---

## Completed Phases

*(Move phases here as they are completed)*

---

## Commit History

| Phase | Commit Hash | Date | Notes |
|-------|-------------|------|-------|
| - | - | - | - |

