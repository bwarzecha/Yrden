# Design: Provider Caching Behavior

> **Core principle:** Cache compatibility requires preserving exact message structure through the round-trip. Any modification, reordering, or loss of content blocks breaks cache hits.

---

## Table of Contents

1. [Problem Statement](#problem-statement)
2. [The Critical Round-Trip Problem](#the-critical-round-trip-problem)
3. [Provider Research](#provider-research)
   - [Anthropic Prompt Caching](#anthropic-prompt-caching)
   - [OpenAI Prompt Caching](#openai-prompt-caching)
   - [AWS Bedrock Prompt Caching](#aws-bedrock-prompt-caching)
4. [Provider Comparison](#provider-comparison)
5. [Architectural Implications for Yrden](#architectural-implications-for-yrden)
6. [Recommendations](#recommendations)
7. [Future Work](#future-work)
8. [Sources](#sources)

---

## Problem Statement

Yrden is a multi-provider Swift library for building AI agents. To optimize costs and latency, we need to understand and preserve cache compatibility when messages flow through the system:

1. **Cost reduction**: Cached tokens are significantly cheaper (up to 90% discount on Anthropic)
2. **Latency improvement**: Cache hits skip prompt processing
3. **Multi-turn conversations**: Agent loops benefit most from caching as context grows

However, if Yrden modifies message structure during the round-trip, cache compatibility is broken.

---

## The Critical Round-Trip Problem

Messages flow through Yrden in a cycle:

```
LLM Response --> CompletionResponse --> Message --> Request back to LLM
                                                         |
                                        Must match original for cache hit
```

### What Can Break Cache Compatibility

| Modification | Impact | Example |
|-------------|--------|---------|
| **Reordering content blocks** | Cache miss | Moving tool_use before text |
| **Concatenating text blocks** | Cache miss | Merging multiple text blocks into one |
| **Losing interleaving** | Cache miss | Separating tool calls from text content |
| **Losing thinking blocks** | Cache miss | Not preserving extended thinking output |
| **Changing tool order** | Cache miss | Tools defined in different order |
| **Modifying JSON structure** | Cache miss | Different key ordering in arguments |

### Current Yrden Message Type

```swift
public enum Message: Sendable, Equatable, Hashable {
    case system(String)
    case user([ContentPart])
    case assistant(String, toolCalls: [ToolCall])  // <-- Problem: separates content
    case toolResult(toolCallId: String, content: String)
    case toolResults([ToolResultEntry])
}
```

The `assistant` case stores text separately from tool calls, but providers like Anthropic interleave them in a single content array.

---

## Provider Research

### Anthropic Prompt Caching

**Sources:**
- https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching

#### Cache Hierarchy

Anthropic caches in a fixed order:

```
tools --> system --> messages
```

Each segment is cached independently. Modifying tools invalidates the tools cache but preserves system and messages caches (up to the modification point).

#### Content Block Order Matters

Assistant messages contain an array of content blocks. The **exact order must be preserved**:

```json
{
  "role": "assistant",
  "content": [
    {"type": "thinking", "thinking": "...", "signature": "..."},
    {"type": "text", "text": "I'll check the weather..."},
    {"type": "tool_use", "id": "toolu_01", "name": "get_weather", "input": {...}},
    {"type": "tool_use", "id": "toolu_02", "name": "get_time", "input": {...}}
  ]
}
```

Key observations:
- **Thinking blocks MUST start assistant messages** when extended thinking is enabled
- **Tool use blocks are content blocks** - they appear interleaved in the `content` array, not separate
- **Text and tool_use can be interleaved** - the model may output text, then a tool call, then more text

#### Cache Control

- **Up to 4 cache breakpoints** allowed per prompt via `cache_control` field
- **5-minute default TTL**
- **1-hour extended TTL** available for Claude 4.5 models
- **Automatic prefix checking** looks back ~20 content blocks from each breakpoint

#### Tool Choice Impact

Modifying `tool_choice` invalidates the message cache but tools and system remain cached.

#### Minimum Cacheable Length

- 1,024 tokens for Claude 4.5 Sonnet and Claude 4 Opus
- 2,048 tokens for other models

---

### OpenAI Prompt Caching

**Sources:**
- https://platform.openai.com/docs/guides/prompt-caching
- https://cookbook.openai.com/examples/prompt_caching101

#### Byte-for-Byte Matching Required

OpenAI prompt caching is extremely strict:

> "Tools must be identical even in their ordering between requests"

This means:
- **JSON key order matters** - even semantically equivalent JSON may not match
- **Tool definition order is critical** - reordering tools breaks cache
- **Whitespace matters** - different formatting breaks cache

#### Cache Key Computation

- **First ~256 tokens hashed** for cache key (exact algorithm not disclosed)
- **Both messages and tools contribute** to cache key
- **`prompt_cache_key` parameter** can influence routing for better cache hits across similar requests

#### Cache Retention

- **5-10 minute default retention** after last access
- **24-hour extended retention** available via `prompt_cache_retention: "24h"`
- **Cache cleared on inactivity** - no guaranteed minimum retention

#### Rate Limiting Interaction

> "At more than 15 requests per minute, additional machines may be used, reducing cache hit rates"

High-traffic applications may see reduced cache effectiveness due to load balancing across multiple cache instances.

#### Supported Models

Prompt caching is available for:
- GPT-4o and GPT-4o-mini (and dated versions)
- o1, o1-mini, o1-pro
- GPT-4.5-preview

---

### AWS Bedrock Prompt Caching

**Sources:**
- https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html
- https://aws.amazon.com/blogs/machine-learning/effectively-use-prompt-caching-on-amazon-bedrock/

#### Similar to Anthropic

Since Bedrock hosts Claude models, caching behavior is largely similar:

- **Alterations to prompt prefix cause cache misses**
- **1-hour TTL available** for Claude models (Sonnet 4.5, Haiku 4.5, Opus 4.5)
- **Automatic cache management** with single breakpoint at end of static content

#### Converse API Specifics

When using the Converse API:
- Tool definitions are part of `toolConfig`
- System prompts have a dedicated field
- Message format follows Bedrock's schema (translated from Anthropic internally)

#### Cache Breakpoint Placement

Bedrock recommends placing cache breakpoints:
1. After static system prompts
2. After few-shot examples
3. After large context documents

---

## Provider Comparison

| Feature | Anthropic | OpenAI | Bedrock |
|---------|-----------|--------|---------|
| **Default TTL** | 5 min | 5-10 min | 5 min |
| **Extended TTL** | 1 hour (Claude 4.5) | 24 hours | 1 hour |
| **Content block order matters** | Yes | Yes (byte-for-byte) | Yes |
| **Tool definition order matters** | Yes | Yes (critical) | Yes |
| **Content interleaving** | Yes (text + tool_use) | N/A (different format) | Yes |
| **Manual cache control** | `cache_control` field | `prompt_cache_key` | `cachePoint` |
| **Max cache breakpoints** | 4 | N/A | Similar to Anthropic |
| **Minimum cacheable tokens** | 1,024-2,048 | Not disclosed | Model-dependent |
| **Thinking block support** | Yes (must be first) | N/A | Yes |

### Cost Savings

| Provider | Cache Write | Cache Read | Savings |
|----------|-------------|------------|---------|
| **Anthropic** | 1.25x base | 0.1x base | Up to 90% on reads |
| **OpenAI** | 1x base | 0.5x base | 50% on reads |
| **Bedrock** | Similar to Anthropic | Similar to Anthropic | Up to 90% on reads |

---

## Architectural Implications for Yrden

### Problem 1: Tool Call Interleaving

**Current Yrden code separates tool calls:**

```swift
case assistant(String, toolCalls: [ToolCall])
```

**But Anthropic interleaves them in the content array:**

```json
{
  "content": [
    {"type": "text", "text": "Let me check..."},
    {"type": "tool_use", "id": "toolu_01", "name": "search", "input": {...}},
    {"type": "text", "text": "And also..."},
    {"type": "tool_use", "id": "toolu_02", "name": "calculate", "input": {...}}
  ]
}
```

When we reconstruct the message for the next request, we lose the interleaving:

```
Original:  [text, tool_use, text, tool_use]
Yrden:     text="Let me check... And also...", toolCalls=[search, calculate]
Round-trip: [text, tool_use, tool_use]  <-- Cache miss!
```

#### Options Analyzed

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| **1. Add `toolUse` to AssistantContentBlock** | Full interleaving preservation | Perfect cache compatibility, matches API structure | Breaking change to Message type |
| **2. Store interleaving metadata** | Track original positions separately | Non-breaking to Message type | Complex, error-prone, extra state |
| **3. Accept imperfect cache** | Document limitation | Simple, no changes needed | Cache misses in multi-tool scenarios |

**Recommendation:** Option 1 is the correct long-term solution.

### Problem 2: Thinking Block Loss

When extended thinking is enabled, Claude returns thinking blocks that **must start** assistant messages:

```json
{
  "content": [
    {"type": "thinking", "thinking": "Let me analyze...", "signature": "abc123"},
    {"type": "text", "text": "Based on my analysis..."}
  ]
}
```

Yrden's current `Message.assistant(String, toolCalls:)` loses thinking entirely:
- Only the text content is preserved
- The thinking block and its signature are discarded
- Round-trip breaks cache because thinking block is missing

**Solution:** This is addressed in the ThinkingBlockSupport design - use `[AssistantContentBlock]` array instead of `String`.

### Problem 3: Tool Definition Ordering

OpenAI explicitly states tool order must be identical. Yrden should:

1. **Document this requirement** in user-facing docs
2. **Use ordered collections** for tools (Array, not Set)
3. **Warn if tool order changes** between requests in the same conversation

### Problem 4: JSON Key Ordering

When serializing tool call arguments back to JSON, key order may differ from the original:

```swift
// Original from LLM
{"query": "weather", "limit": 5}

// After round-trip through JSONValue and back
{"limit": 5, "query": "weather"}  // Different order = cache miss on OpenAI
```

**Mitigation options:**
1. Store original JSON string in `ToolCall.arguments` (current approach - good)
2. Use ordered JSON encoding
3. Accept this limitation for OpenAI

---

## Recommendations

### Immediate (No Breaking Changes)

1. **Preserve tool argument strings exactly** - Do not parse and re-serialize
2. **Document tool ordering requirement** - Users must maintain consistent tool order
3. **Add `cachedTokens` to Usage** - Already implemented, expose in metrics

### Short-term (Minor Changes)

1. **Add thinking block support** - Per ThinkingBlockSupport design
2. **Store original content block order** - Metadata for reconstruction
3. **Add cache hit/miss to CompletionResponse** - For observability

### Long-term (Breaking Changes)

1. **Redesign AssistantContentBlock** to support interleaving:

```swift
public enum AssistantContentBlock: Sendable, Equatable, Hashable {
    case text(String)
    case thinking(content: String, signature: String)
    case toolUse(ToolCall)
}

public enum Message: Sendable, Equatable, Hashable {
    case system(String)
    case user([ContentPart])
    case assistant([AssistantContentBlock])  // Full interleaving support
    case toolResult(toolCallId: String, content: String)
    case toolResults([ToolResultEntry])
}
```

2. **Add cache control options** to CompletionConfig:

```swift
public struct CompletionConfig {
    // ... existing fields ...

    /// Cache breakpoint hints for providers that support manual cache control.
    /// Anthropic: Up to 4 breakpoints via cache_control field
    /// OpenAI: Influences routing via prompt_cache_key
    public let cacheBreakpoints: [CacheBreakpoint]?
}

public struct CacheBreakpoint: Sendable {
    /// Index in messages array where cache should break
    let messageIndex: Int
    /// TTL preference (provider may ignore)
    let ttl: CacheTTL?
}

public enum CacheTTL: Sendable {
    case standard      // 5 minutes
    case extended      // 1 hour (Anthropic Claude 4.5, Bedrock)
    case longTerm      // 24 hours (OpenAI)
}
```

---

## Future Work

1. **Cache effectiveness metrics** - Track cache hit rates across providers
2. **Automatic cache breakpoint insertion** - Heuristics for optimal placement
3. **Tool order warning/enforcement** - Detect and warn about order changes
4. **Provider-specific caching strategies** - Optimize per-provider
5. **Cache-aware conversation management** - Help users maximize cache hits

---

## Sources

### Anthropic
- [Prompt Caching Documentation](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching)
- [Extended Thinking](https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking)

### OpenAI
- [Prompt Caching Guide](https://platform.openai.com/docs/guides/prompt-caching)
- [Prompt Caching Cookbook](https://cookbook.openai.com/examples/prompt_caching101)

### AWS Bedrock
- [Prompt Caching User Guide](https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html)
- [Effective Prompt Caching Blog](https://aws.amazon.com/blogs/machine-learning/effectively-use-prompt-caching-on-amazon-bedrock/)

---

## Document History

| Date | Change |
|------|--------|
| 2026-02-05 | Initial comprehensive design documenting provider caching behavior and Yrden implications |
