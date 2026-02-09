# Design: Thinking/Reasoning Block Support

> Add support for thinking/reasoning content blocks across Anthropic, OpenAI, and AWS Bedrock providers, enabling extended thinking capabilities while maintaining backward compatibility.

## Table of Contents

1. [Problem Statement](#problem-statement)
2. [Research Summary](#research-summary)
3. [Design Goals](#design-goals)
4. [Proposed Solution](#proposed-solution)
5. [Type Definitions](#type-definitions)
6. [Provider-Specific Implementation](#provider-specific-implementation)
7. [Files to Modify](#files-to-modify)
8. [Migration Guide](#migration-guide)
9. [Verification Plan](#verification-plan)
10. [Tradeoffs and Limitations](#tradeoffs-and-limitations)
11. [Open Questions](#open-questions)

---

## Problem Statement

### Current State

Yrden currently loses thinking/reasoning content from LLM responses:

1. **Message.assistant** only stores text content and tool calls:
   ```swift
   case assistant(String, toolCalls: [ToolCall])
   ```
   This loses:
   - Thinking block content entirely
   - Block order (thinking must come first)
   - Signature field (required by Anthropic for verification)
   - Structure needed for prompt cache compatibility

2. **Agent.swift:314-315** discards thinking content:
   ```swift
   static func fromResponse(_ response: CompletionResponse) -> Message {
       .assistant(response.content ?? "", toolCalls: response.toolCalls)
   }
   ```

3. **StreamEvent.contentDelta** has no way to indicate content type:
   ```swift
   case contentDelta(String)  // Is this thinking or regular content?
   ```

4. **Provider implementations ignore reasoning**:
   - OpenAIModel.swift:683-685 ignores `ResponsesOutputItem.reasoning`
   - BedrockModel.swift:427 handles `.reasoningcontent` with `default: break`

### Why This Matters

Extended thinking is critical for complex reasoning tasks. Without proper support:
- **Cache invalidation**: Anthropic requires exact thinking block preservation for cache hits
- **Lost reasoning**: Users cannot access or display thinking content
- **Tool use breaks**: Anthropic requires thinking blocks passed back unchanged during tool use
- **Debugging difficulty**: No visibility into model's reasoning process

---

## Research Summary

### Anthropic Extended Thinking

**Source**: https://platform.claude.com/docs/en/docs/build-with-claude/extended-thinking

**Key Requirements**:

1. **Block Ordering**: Thinking blocks MUST start assistant messages when extended thinking is enabled
2. **Immutability**: The ENTIRE sequence of consecutive thinking blocks must match outputs from original request - cannot rearrange or modify
3. **Tool Use Protocol**: During tool use, thinking blocks MUST be passed back to the API unmodified
4. **Signature Verification**: Signature field is REQUIRED for Anthropic to verify thinking blocks

**JSON Format**:
```json
{
  "type": "thinking",
  "thinking": "Let me analyze...",
  "signature": "WaUjzkypQ2mUEVM36O2TxuC..."
}
```

**Redacted Thinking** (safety-flagged content that must be passed back unchanged):
```json
{
  "type": "redacted_thinking",
  "data": "encrypted_base64_data..."
}
```

**Stream Delta Types**:
- `thinking_delta` - thinking text chunks
- `signature_delta` - signature chunks (must accumulate)

### OpenAI Reasoning

**Current API** (Responses API):

The API returns reasoning in `output` array with type:
```swift
case reasoning(id: String, content: [String]?, summary: [String]?)
```

- `content`: Array of reasoning text chunks (optional)
- `summary`: Array of summary text chunks (optional)

**CRITICAL**: Do NOT join content chunks with separators - concatenate directly to preserve exact content for cache compatibility.

**Currently**: Ignored in OpenAIModel.swift lines 683-685:
```swift
case .reasoning, .unknown:
    // Reasoning items are internal; we don't expose them
    break
```

### AWS Bedrock Reasoning

Uses `.reasoningcontent` delta type in streaming.

**Currently**: Handled with `default: break` at line 427 in BedrockModel.swift.

---

## Design Goals

1. **Preserve thinking content** for display and debugging
2. **Maintain exact block structure** for cache compatibility
3. **Support signature verification** (Anthropic requirement)
4. **Enable round-trip** of thinking blocks during tool use
5. **Backward compatible** - existing code compiles unchanged
6. **Provider-agnostic** - unified types work across providers

### Non-Goals

- Extended thinking configuration (budget_tokens, etc.) - separate feature
- Thinking block modification - violates immutability requirement
- Complex thinking block manipulation APIs

---

## Proposed Solution

### Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Stream Layer                              │
│  StreamEvent.contentDelta(String, kind: ContentKind = .text)    │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Response Layer                              │
│  CompletionResponse.contentBlocks: [AssistantContentBlock]      │
│  - Preserves block order                                        │
│  - Preserves signatures                                         │
│  - Computed: .content, .thinking for convenience                │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Message Layer                               │
│  Message.assistant([AssistantContentBlock], toolCalls:)         │
│  - Enables cache-compatible round-trip                          │
│  - Convenience: .assistant(String) still works                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Type Definitions

### 1. ContentKind Enum

Indicates the type of content being streamed. Designed for graceful degradation.

```swift
/// Kind of content in a stream delta or content block.
///
/// Used to differentiate thinking/reasoning content from regular text.
/// Defaults to `.text` for backward compatibility.
public enum ContentKind: String, Sendable, Codable, Equatable, Hashable {
    /// Regular text content visible to users.
    case text

    /// Internal reasoning/thinking content from extended thinking.
    /// May be displayed differently in UIs (e.g., collapsed, styled).
    case thinking
}
```

### 2. AssistantContentBlock Enum

Preserves the full structure of assistant message content for cache compatibility.

```swift
/// A content block within an assistant message.
///
/// Preserves block structure for:
/// - Cache compatibility (exact round-trip required)
/// - Thinking block verification (signature field)
/// - Proper ordering (thinking blocks must come first)
///
/// ## Anthropic Requirements
///
/// When extended thinking is enabled:
/// 1. Thinking blocks MUST start assistant messages
/// 2. The ENTIRE sequence must match original output exactly
/// 3. Signature field MUST be preserved for verification
/// 4. During tool use, pass thinking blocks back unchanged
///
/// ## Example
/// ```swift
/// let blocks: [AssistantContentBlock] = [
///     .thinking(text: "Let me analyze...", signature: "abc123..."),
///     .text("Based on my analysis...")
/// ]
/// let message = Message.assistant(blocks, toolCalls: [])
/// ```
public enum AssistantContentBlock: Sendable, Equatable, Hashable, Codable {
    /// Regular text content.
    case text(String)

    /// Thinking/reasoning content with verification signature.
    ///
    /// - Parameters:
    ///   - text: The thinking content (may be displayed to users)
    ///   - signature: Cryptographic signature for verification (Anthropic requirement)
    case thinking(text: String, signature: String)

    /// Redacted thinking content (safety-filtered).
    ///
    /// This must be passed back to the API unchanged. The data is encrypted
    /// and cannot be read, but must be preserved for conversation continuity.
    ///
    /// - Parameter data: Encrypted base64 data
    case redactedThinking(data: String)
}
```

**Codable Implementation**:

```swift
extension AssistantContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case signature
        case data
    }

    private enum BlockType: String, Codable {
        case text
        case thinking
        case redactedThinking = "redacted_thinking"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(BlockType.self, forKey: .type)

        switch type {
        case .text:
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case .thinking:
            let text = try container.decode(String.self, forKey: .text)
            let signature = try container.decode(String.self, forKey: .signature)
            self = .thinking(text: text, signature: signature)
        case .redactedThinking:
            let data = try container.decode(String.self, forKey: .data)
            self = .redactedThinking(data: data)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode(BlockType.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let text, let signature):
            try container.encode(BlockType.thinking, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(signature, forKey: .signature)
        case .redactedThinking(let data):
            try container.encode(BlockType.redactedThinking, forKey: .type)
            try container.encode(data, forKey: .data)
        }
    }
}
```

**Convenience Properties**:

```swift
extension AssistantContentBlock {
    /// The text content if this is a text block.
    public var textContent: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    /// The thinking text if this is a thinking block.
    public var thinkingContent: String? {
        if case .thinking(let text, _) = self { return text }
        return nil
    }

    /// Whether this block contains thinking content.
    public var isThinking: Bool {
        switch self {
        case .thinking, .redactedThinking: return true
        case .text: return false
        }
    }
}
```

### 3. StreamEvent Update

Add `kind` parameter with default value for backward compatibility.

```swift
public enum StreamEvent: Sendable, Equatable, Hashable {
    /// Incremental content from the model.
    /// Concatenate all deltas of the same kind to build the full response.
    ///
    /// - Parameters:
    ///   - content: The text delta
    ///   - kind: Type of content (defaults to `.text` for backward compatibility)
    case contentDelta(String, kind: ContentKind = .text)

    // ... existing cases unchanged
}
```

**Codable Update**:

```swift
extension StreamEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case content
        case kind  // New field
        case id
        case name
        case argumentsDelta
        case response
    }

    private enum EventType: String, Codable {
        case contentDelta
        // ... existing cases
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EventType.self, forKey: .type)

        switch type {
        case .contentDelta:
            let content = try container.decode(String.self, forKey: .content)
            let kind = try container.decodeIfPresent(ContentKind.self, forKey: .kind) ?? .text
            self = .contentDelta(content, kind: kind)
        // ... existing cases
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .contentDelta(let content, let kind):
            try container.encode(EventType.contentDelta, forKey: .type)
            try container.encode(content, forKey: .content)
            if kind != .text {  // Only encode non-default
                try container.encode(kind, forKey: .kind)
            }
        // ... existing cases
        }
    }
}
```

### 4. CompletionResponse Update

Add `contentBlocks` while maintaining backward compatibility.

```swift
public struct CompletionResponse: Codable, Sendable, Equatable, Hashable {
    /// Structured content blocks preserving thinking/text order.
    /// Use this for cache-compatible round-trips.
    public let contentBlocks: [AssistantContentBlock]

    /// Refusal explanation from the model.
    public let refusal: String?

    /// Tool calls requested by the model.
    public let toolCalls: [ToolCall]

    /// Reason the model stopped generating.
    public let stopReason: StopReason

    /// Token usage for this request/response.
    public let usage: Usage

    // MARK: - Convenience Properties

    /// Combined text content (excludes thinking blocks).
    /// Use `contentBlocks` for full structure.
    public var content: String? {
        let texts = contentBlocks.compactMap { $0.textContent }
        return texts.isEmpty ? nil : texts.joined()
    }

    /// Combined thinking content.
    /// Returns nil if no thinking blocks present.
    public var thinking: String? {
        let thoughts = contentBlocks.compactMap { $0.thinkingContent }
        return thoughts.isEmpty ? nil : thoughts.joined()
    }

    // MARK: - Initializers

    /// Full initializer with content blocks.
    public init(
        contentBlocks: [AssistantContentBlock],
        refusal: String? = nil,
        toolCalls: [ToolCall],
        stopReason: StopReason,
        usage: Usage
    ) {
        self.contentBlocks = contentBlocks
        self.refusal = refusal
        self.toolCalls = toolCalls
        self.stopReason = stopReason
        self.usage = usage
    }

    /// Convenience initializer for text-only responses (backward compatible).
    public init(
        content: String?,
        refusal: String? = nil,
        toolCalls: [ToolCall],
        stopReason: StopReason,
        usage: Usage
    ) {
        self.contentBlocks = content.map { [.text($0)] } ?? []
        self.refusal = refusal
        self.toolCalls = toolCalls
        self.stopReason = stopReason
        self.usage = usage
    }
}
```

### 5. Message.assistant Update

Support block-based content while maintaining convenience.

```swift
public enum Message: Sendable, Equatable, Hashable {
    // ... existing cases

    /// Assistant (LLM) response with structured content blocks and tool calls.
    ///
    /// Use this form when you need to preserve thinking blocks for cache compatibility
    /// or round-trip during tool use.
    ///
    /// - Parameters:
    ///   - content: Structured content blocks (thinking + text)
    ///   - toolCalls: Tools the LLM wants to invoke
    case assistant([AssistantContentBlock], toolCalls: [ToolCall])

    // ... existing cases
}

// MARK: - Message Convenience

extension Message {
    /// Creates an assistant message with text content and no tool calls.
    public static func assistant(_ content: String) -> Message {
        .assistant([.text(content)], toolCalls: [])
    }

    /// Creates an assistant message with text content and tool calls.
    ///
    /// Use this convenience when you don't need to preserve thinking blocks.
    public static func assistant(_ content: String, toolCalls: [ToolCall]) -> Message {
        let blocks: [AssistantContentBlock] = content.isEmpty ? [] : [.text(content)]
        return .assistant(blocks, toolCalls: toolCalls)
    }

    /// Creates an assistant message with only tool calls (no text content).
    public static func assistantToolCalls(_ toolCalls: [ToolCall]) -> Message {
        .assistant([], toolCalls: toolCalls)
    }

    /// The text content of an assistant message (excludes thinking).
    public var assistantContent: String? {
        guard case .assistant(let blocks, _) = self else { return nil }
        let texts = blocks.compactMap { $0.textContent }
        return texts.isEmpty ? nil : texts.joined()
    }

    /// The thinking content of an assistant message.
    public var assistantThinking: String? {
        guard case .assistant(let blocks, _) = self else { return nil }
        let thoughts = blocks.compactMap { $0.thinkingContent }
        return thoughts.isEmpty ? nil : thoughts.joined()
    }
}
```

### 6. ModelStreamEvent Update (IterationContext.swift)

```swift
public enum ModelStreamEvent: Sendable {
    /// Content delta with kind indicator.
    case contentDelta(String, kind: ContentKind = .text)

    // ... existing cases unchanged
}
```

### 7. AgentStreamEvent Update (AgentTypes.swift)

```swift
public enum AgentStreamEvent<Output: SchemaType>: Sendable {
    /// Content delta from the model with kind indicator.
    case contentDelta(String, kind: ContentKind = .text)

    // ... existing cases unchanged
}
```

---

## Provider-Specific Implementation

### Anthropic (AnthropicModel.swift)

#### Types to Add (AnthropicTypes.swift)

```swift
// Add to AnthropicBlockType
enum AnthropicBlockType {
    static let text = "text"
    static let toolUse = "tool_use"
    static let thinking = "thinking"           // NEW
    static let redactedThinking = "redacted_thinking"  // NEW
}

// Add to AnthropicDeltaType
enum AnthropicDeltaType {
    static let textDelta = "text_delta"
    static let inputJsonDelta = "input_json_delta"
    static let thinkingDelta = "thinking_delta"      // NEW
    static let signatureDelta = "signature_delta"    // NEW
}

// Update AnthropicStreamContentBlock
struct AnthropicStreamContentBlock: Decodable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: JSONValue?
    let thinking: String?     // NEW
    let signature: String?    // NEW
    let data: String?         // NEW (for redacted_thinking)
}

// Update AnthropicStreamDelta
enum AnthropicStreamDelta: Decodable {
    case textDelta(String)
    case inputJsonDelta(String)
    case thinkingDelta(String)      // NEW
    case signatureDelta(String)     // NEW

    // ... update init(from decoder:)
}

// Update AnthropicContentBlock enum for encoding
enum AnthropicContentBlock: Codable {
    case text(String)
    case image(base64: String, mediaType: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: String, isError: Bool?)
    case thinking(text: String, signature: String)           // NEW
    case redactedThinking(data: String)                      // NEW

    // ... update Codable implementation
}
```

#### Streaming Changes (AnthropicModel.swift)

```swift
private func processStreamEvent(
    _ event: AnthropicStreamEvent,
    continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
    accumulatedContent: inout String,
    accumulatedThinking: inout String,         // NEW
    accumulatedSignature: inout String,        // NEW
    accumulatedContentBlocks: inout [AssistantContentBlock],  // NEW
    accumulatedToolCalls: inout [ToolCallAccumulator],
    inputTokens: inout Int,
    outputTokens: inout Int
) throws {
    switch event {
    // ... existing cases

    case .contentBlockStart(let index, let block):
        if block.type == AnthropicBlockType.thinking {
            // Start of thinking block
            accumulatedThinking = block.thinking ?? ""
            accumulatedSignature = block.signature ?? ""
        } else if block.type == AnthropicBlockType.redactedThinking {
            // Redacted thinking - store immediately
            if let data = block.data {
                accumulatedContentBlocks.append(.redactedThinking(data: data))
            }
        } else if block.type == AnthropicBlockType.toolUse {
            // ... existing tool handling
        }

    case .contentBlockDelta(_, let delta):
        switch delta {
        case .textDelta(let text):
            accumulatedContent += text
            continuation.yield(.contentDelta(text, kind: .text))

        case .thinkingDelta(let text):
            accumulatedThinking += text
            continuation.yield(.contentDelta(text, kind: .thinking))

        case .signatureDelta(let sig):
            accumulatedSignature += sig
            // Don't emit - signature is internal

        case .inputJsonDelta(let json):
            // ... existing tool argument handling
        }

    case .contentBlockStop(let index):
        // If we accumulated thinking content, store the block
        if !accumulatedThinking.isEmpty {
            accumulatedContentBlocks.append(
                .thinking(text: accumulatedThinking, signature: accumulatedSignature)
            )
            accumulatedThinking = ""
            accumulatedSignature = ""
        }
        // ... existing tool call handling

    case .messageDelta(let delta, let usage):
        // ... build final response with contentBlocks

        // Add text content block if any
        if !accumulatedContent.isEmpty {
            accumulatedContentBlocks.append(.text(accumulatedContent))
        }

        let response = CompletionResponse(
            contentBlocks: accumulatedContentBlocks,
            toolCalls: toolCalls,
            stopReason: stopReason,
            usage: Usage(inputTokens: inputTokens, outputTokens: outputTokens)
        )
        continuation.yield(.done(response))

    // ... existing cases
    }
}
```

#### Message Encoding (AnthropicModel.swift)

```swift
private func convertMessage(_ message: Message) throws -> AnthropicMessage {
    switch message {
    // ... existing cases

    case .assistant(let blocks, let toolCalls):
        var anthropicBlocks: [AnthropicContentBlock] = []

        for block in blocks {
            switch block {
            case .text(let text):
                if !text.isEmpty {
                    anthropicBlocks.append(.text(text))
                }
            case .thinking(let text, let signature):
                anthropicBlocks.append(.thinking(text: text, signature: signature))
            case .redactedThinking(let data):
                anthropicBlocks.append(.redactedThinking(data: data))
            }
        }

        for toolCall in toolCalls {
            let input = try parseToolArguments(toolCall.arguments)
            anthropicBlocks.append(.toolUse(id: toolCall.id, name: toolCall.name, input: input))
        }

        if anthropicBlocks.isEmpty {
            anthropicBlocks.append(.text(""))
        }

        return AnthropicMessage(role: MessageRole.assistant, content: anthropicBlocks)

    // ... existing cases
    }
}
```

### OpenAI (OpenAIModel.swift)

#### Response Decoding

```swift
private func decodeResponsesResponse(_ data: Data) throws -> CompletionResponse {
    let response = try JSONDecoder().decode(ResponsesAPIResponse.self, from: data)

    var contentBlocks: [AssistantContentBlock] = []
    var refusal: String?
    var toolCalls: [ToolCall] = []

    for item in response.output {
        switch item {
        case .message(_, _, let contentItems):
            for contentItem in contentItems {
                switch contentItem {
                case .outputText(let text, _):
                    contentBlocks.append(.text(text))
                case .refusal(let text):
                    refusal = (refusal ?? "") + text
                case .unknown:
                    break
                }
            }

        case .functionCall(_, let callId, let name, let arguments):
            toolCalls.append(ToolCall(id: callId, name: name, arguments: arguments))

        case .reasoning(_, let content, let summary):
            // NOW HANDLED: Extract reasoning content
            // CRITICAL: Concatenate directly without separators for cache compatibility
            if let contentChunks = content {
                let reasoningText = contentChunks.joined()  // NO separator
                if !reasoningText.isEmpty {
                    // OpenAI reasoning doesn't have signatures - use empty string
                    contentBlocks.insert(.thinking(text: reasoningText, signature: ""), at: 0)
                }
            }
            // Summary is a condensed version - could store separately if needed

        case .unknown:
            break
        }
    }

    // ... rest of method

    return CompletionResponse(
        contentBlocks: contentBlocks,
        refusal: refusal,
        toolCalls: toolCalls,
        stopReason: stopReason,
        usage: usage
    )
}
```

#### Streaming Update

```swift
private func streamResponsesRequest(
    _ request: ResponsesAPIRequest,
    continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
) async throws {
    // ... existing setup

    var accumulatedContent: [AssistantContentBlock] = []
    var accumulatedText = ""
    var accumulatedReasoning = ""  // NEW

    for try await line in bytes.lines {
        // ... existing parsing

        switch event.type {
        case "response.text.delta", "response.output_text.delta":
            if let delta = event.delta {
                accumulatedText += delta
                continuation.yield(.contentDelta(delta, kind: .text))
            }

        case "response.reasoning.delta":  // NEW
            if let delta = event.delta {
                accumulatedReasoning += delta
                continuation.yield(.contentDelta(delta, kind: .thinking))
            }

        // ... existing cases
        }
    }

    // Build final content blocks (reasoning first, then text)
    if !accumulatedReasoning.isEmpty {
        accumulatedContent.append(.thinking(text: accumulatedReasoning, signature: ""))
    }
    if !accumulatedText.isEmpty {
        accumulatedContent.append(.text(accumulatedText))
    }

    let completionResponse = CompletionResponse(
        contentBlocks: accumulatedContent,
        // ... rest
    )
}
```

### Bedrock (BedrockModel.swift)

#### Streaming Update

```swift
private func streamRequest(
    _ input: ConverseStreamInput,
    continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
) async throws {
    // ... existing setup

    var accumulatedContentBlocks: [AssistantContentBlock] = []
    var fullTextContent = ""
    var fullReasoningContent = ""  // NEW

    for try await event in stream {
        switch event {
        // ... existing cases

        case .contentblockdelta(let deltaEvent):
            if let delta = deltaEvent.delta {
                switch delta {
                case .text(let text):
                    fullTextContent += text
                    continuation.yield(.contentDelta(text, kind: .text))

                case .tooluse(let toolDelta):
                    // ... existing handling

                case .reasoningcontent(let reasoning):  // NEW - was previously ignored
                    if let text = reasoning.text {
                        fullReasoningContent += text
                        continuation.yield(.contentDelta(text, kind: .thinking))
                    }

                default:
                    break
                }
            }

        // ... existing cases
        }
    }

    // Build content blocks (reasoning first)
    if !fullReasoningContent.isEmpty {
        accumulatedContentBlocks.append(.thinking(text: fullReasoningContent, signature: ""))
    }
    if !fullTextContent.isEmpty {
        accumulatedContentBlocks.append(.text(fullTextContent))
    }

    let finalResponse = CompletionResponse(
        contentBlocks: accumulatedContentBlocks,
        toolCalls: allToolCalls,
        stopReason: finalStopReason,
        usage: Usage(inputTokens: totalInputTokens, outputTokens: totalOutputTokens)
    )
}
```

---

## Files to Modify

### Core Types

| File | Changes |
|------|---------|
| `Sources/Yrden/Streaming.swift` | Add `ContentKind` enum, update `StreamEvent.contentDelta` with `kind` parameter, update `Codable` |
| `Sources/Yrden/Message.swift` | Add `AssistantContentBlock` enum, update `Message.assistant` case, add convenience methods |
| `Sources/Yrden/Completion.swift` | Update `CompletionResponse` with `contentBlocks`, add computed `content`/`thinking`, update initializers |

### Agent Layer

| File | Changes |
|------|---------|
| `Sources/Yrden/Agent/Agent.swift` | Update `fromResponse()` to use `contentBlocks` |
| `Sources/Yrden/Agent/Iteration/IterationContext.swift` | Update `ModelStreamEvent.contentDelta` with `kind` |
| `Sources/Yrden/Agent/AgentTypes.swift` | Update `AgentStreamEvent.contentDelta` with `kind` |

### Providers

| File | Changes |
|------|---------|
| `Sources/Yrden/Providers/Anthropic/AnthropicTypes.swift` | Add thinking block types, update delta types, update content block enum |
| `Sources/Yrden/Providers/Anthropic/AnthropicModel.swift` | Handle thinking deltas in streaming, encode thinking blocks in messages, build `contentBlocks` in response |
| `Sources/Yrden/Providers/OpenAI/OpenAIModel.swift` | Extract reasoning from `ResponsesOutputItem.reasoning`, emit reasoning stream events |
| `Sources/Yrden/Providers/OpenAI/OpenAIResponsesTypes.swift` | No changes needed - types already support reasoning |
| `Sources/Yrden/Providers/Bedrock/BedrockModel.swift` | Handle `.reasoningcontent` delta, build `contentBlocks` |

### Tests

| File | Changes |
|------|---------|
| `Tests/YrdenTests/Unit/ContentKindTests.swift` | NEW: Test `ContentKind` enum |
| `Tests/YrdenTests/Unit/AssistantContentBlockTests.swift` | NEW: Test block types and Codable |
| `Tests/YrdenTests/Unit/MessageThinkingTests.swift` | NEW: Test Message convenience methods |
| `Tests/YrdenTests/Unit/StreamEventThinkingTests.swift` | NEW: Test streaming with kind |
| `Tests/YrdenTests/Integration/AnthropicThinkingTests.swift` | NEW: E2E with extended thinking |
| `Tests/YrdenTests/Integration/OpenAIReasoningTests.swift` | NEW: E2E with o-series reasoning |

---

## Migration Guide

### Backward Compatibility

The design prioritizes backward compatibility through default parameters and computed properties.

#### 1. StreamEvent Pattern Matching

**Before (still works)**:
```swift
case .contentDelta(let text):
    print(text)
```

**After (captures kind)**:
```swift
case .contentDelta(let text, let kind):
    switch kind {
    case .text: print(text)
    case .thinking: print("[Thinking] \(text)")
    }
```

**Ignore kind explicitly**:
```swift
case .contentDelta(let text, _):
    print(text)  // Handles all content types
```

#### 2. Message.assistant Creation

**Before (still works)**:
```swift
let msg = Message.assistant("Hello")
let msg2 = Message.assistant("Hello", toolCalls: [call])
```

**After (with thinking blocks)**:
```swift
let msg = Message.assistant([
    .thinking(text: "Let me think...", signature: "abc..."),
    .text("Hello")
], toolCalls: [])
```

#### 3. CompletionResponse Access

**Before (still works)**:
```swift
if let content = response.content {
    print(content)
}
```

**After (with thinking)**:
```swift
// Access thinking separately
if let thinking = response.thinking {
    print("[Thinking] \(thinking)")
}
if let content = response.content {
    print(content)
}

// Or iterate blocks
for block in response.contentBlocks {
    switch block {
    case .thinking(let text, _): print("[Thinking] \(text)")
    case .text(let text): print(text)
    case .redactedThinking: print("[Redacted]")
    }
}
```

#### 4. AgentStreamEvent Handling

**Before (still works)**:
```swift
case .contentDelta(let text):
    print(text)
```

**After (with kind)**:
```swift
case .contentDelta(let text, let kind):
    if kind == .thinking {
        thinkingView.append(text)
    } else {
        responseView.append(text)
    }
```

---

## Verification Plan

### Unit Tests

1. **ContentKind**
   - Codable round-trip
   - Equatable/Hashable
   - Default value in StreamEvent

2. **AssistantContentBlock**
   - All cases: `.text`, `.thinking`, `.redactedThinking`
   - Codable round-trip for each case
   - Convenience properties (`textContent`, `thinkingContent`, `isThinking`)
   - Equatable/Hashable

3. **CompletionResponse**
   - `content` computed property (excludes thinking)
   - `thinking` computed property
   - Both initializers work correctly
   - Codable preserves blocks

4. **Message.assistant**
   - Block-based initializer preserves order
   - Convenience methods create correct blocks
   - `assistantContent` excludes thinking
   - `assistantThinking` extracts thinking

5. **StreamEvent.contentDelta**
   - Default kind is `.text`
   - Codable preserves kind
   - Backward compatible pattern matching

### Integration Tests

1. **Anthropic Extended Thinking**
   - Enable extended thinking in request
   - Verify thinking blocks in response
   - Verify streaming emits `kind: .thinking`
   - Round-trip: thinking blocks pass back unchanged during tool use
   - Verify signature preservation

2. **OpenAI Reasoning**
   - Use o-series or gpt-5 model
   - Verify reasoning extracted from response
   - Verify streaming emits reasoning deltas
   - Verify no content mangling (direct concatenation)

3. **Bedrock Reasoning**
   - Use Claude model with reasoning enabled
   - Verify reasoning content captured
   - Verify streaming works

4. **Cache Compatibility**
   - Make request with extended thinking
   - Use response to create Message
   - Make follow-up request
   - Verify cache hit (if measurable) or no API errors

### Manual Testing

1. Enable extended thinking on Claude
2. Observe thinking content in stream events
3. Make tool call that triggers tool use
4. Verify conversation continues correctly
5. Check that thinking blocks are not duplicated or corrupted

---

## Tradeoffs and Limitations

### Tradeoffs

| Decision | Pros | Cons |
|----------|------|------|
| **Default parameter `kind: .text`** | Backward compatible, existing code compiles | Callers must opt-in to see thinking |
| **Block-based Message.assistant** | Full structure preserved, cache compatible | More complex type |
| **Empty signature for non-Anthropic** | Unified type across providers | Signature field unused for OpenAI/Bedrock |
| **Computed `content` property** | Familiar API, easy migration | Hides thinking by default |

### Limitations

1. **Signature verification**: Only Anthropic uses signatures. Other providers use empty string.

2. **Block order enforcement**: We preserve order but don't validate that thinking comes first. Invalid ordering will cause API errors at runtime.

3. **Redacted thinking**: Cannot be inspected or modified. Must be passed through opaquely.

4. **Extended thinking configuration**: This design only handles responses. Enabling extended thinking (budget_tokens, etc.) is a separate feature.

5. **No thinking modification**: Per Anthropic requirements, thinking blocks cannot be modified. The API enforces this through signature verification.

---

## Open Questions

### Resolved

1. **Q: Should `ContentKind` have more cases?**
   A: No. Keep it simple: `.text` and `.thinking`. Other content types (images, tool calls) are already separate enum cases.

2. **Q: How to handle provider differences in signature support?**
   A: Use empty string for providers without signatures. This keeps the type unified.

3. **Q: Should we validate block ordering?**
   A: No. Let the API validate. We just preserve what we receive.

### Unresolved

1. **Extended thinking configuration**: How should users enable extended thinking? Separate `CompletionConfig` field? Provider-specific config?

2. **Reasoning tokens in UI**: Should `Usage` expose `reasoningTokens` separately from `outputTokens`? (Currently it does via `Usage.reasoningTokens`)

3. **Thinking display in tools**: When displaying tool results in a UI, should we show the thinking that preceded the tool call?

---

## Appendix: Example API Usage

### Streaming with Thinking

```swift
for try await event in model.stream(request) {
    switch event {
    case .contentDelta(let text, let kind):
        switch kind {
        case .thinking:
            thinkingTextView.append(text)
        case .text:
            responseTextView.append(text)
        }
    case .done(let response):
        // Full thinking available
        if let thinking = response.thinking {
            print("Model thinking: \(thinking.prefix(100))...")
        }
    default:
        break
    }
}
```

### Tool Use with Thinking Preservation

```swift
// First request gets tool call with thinking
let response1 = try await model.complete(request1)

// Create message preserving thinking blocks
let assistantMessage = Message.assistant(
    response1.contentBlocks,
    toolCalls: response1.toolCalls
)

// Execute tools
let toolResults = try await executeTools(response1.toolCalls)

// Continue conversation - thinking blocks preserved for cache
let request2 = CompletionRequest(
    messages: request1.messages + [
        assistantMessage,
        .toolResults(toolResults)
    ],
    tools: tools
)
let response2 = try await model.complete(request2)
```

### Accessing Thinking Content

```swift
let response = try await agent.run("Solve this puzzle", deps: deps)

// Access via computed property
if let thinking = response.lastResponse?.thinking {
    print("The model thought: \(thinking)")
}

// Or iterate blocks
for block in response.lastResponse?.contentBlocks ?? [] {
    switch block {
    case .thinking(let text, let signature):
        print("[Thinking] \(text)")
        print("[Signature] \(signature.prefix(20))...")
    case .text(let text):
        print("[Response] \(text)")
    case .redactedThinking:
        print("[Redacted thinking block]")
    }
}
```
