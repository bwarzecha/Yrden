# Messages and Chat History

Yrden represents conversations as arrays of `Message` values. Messages are the fundamental unit of state in both model calls and agent runs -- every prompt, response, tool call, and tool result is a message.

## Message

A single message in a conversation. Five cases cover every role in an LLM conversation:

```swift
public enum Message: Sendable {
    case system(String)
    case user([ContentPart])
    case assistant([AssistantContentBlock])
    case toolResult(toolCallId: String, content: String)
    case toolResults([ToolResultEntry])
}
```

- **`.system`** -- Instructions for the LLM. Usually the first message. Set via `Agent.systemPrompt` rather than manually.
- **`.user`** -- Human input. Contains one or more content parts (text, images).
- **`.assistant`** -- LLM response. Contains ordered content blocks (text, thinking, tool calls).
- **`.toolResult`** -- Result of a single tool execution, keyed by the tool call ID.
- **`.toolResults`** -- Results of multiple tool executions from a single assistant response.

### Convenience Constructors

For common cases, convenience methods avoid boilerplate:

```swift
// Single text user message
Message.user("Hello")
// equivalent to: Message.user([.text("Hello")])

// Multimodal user message (text + image)
Message.user([.text("What's this?"), .image(data, mimeType: "image/png")])

// Text-only assistant response
Message.assistant("Response text")
// equivalent to: Message.assistant([.text("Response text")])

// Assistant with text and tool calls
Message.assistant("I'll search for that", toolCalls: [searchCall])

// Assistant with only tool calls (no text)
Message.assistantToolCalls([call1, call2])
```

### Computed Properties

Extract specific content from messages without pattern matching:

```swift
let message: Message = ...

// All tool calls from an assistant message (empty for other roles)
message.toolCalls          // -> [ToolCall]

// Combined text content (excludes thinking)
message.assistantContent   // -> String?

// Combined thinking content
message.assistantThinking  // -> String?

// Raw content blocks
message.assistantBlocks    // -> [AssistantContentBlock]?
```

These return `nil` or empty arrays when called on non-assistant messages, so they are safe to use without checking the message role first.

## ContentPart

Individual pieces of content within a user message. Supports text and images for multimodal conversations.

```swift
public enum ContentPart: Sendable {
    case text(String)
    case image(Data, mimeType: String)
}
```

Common MIME types for images: `image/png`, `image/jpeg`, `image/gif`, `image/webp`.

```swift
// Text-only
let parts: [ContentPart] = [.text("Describe this image")]

// Text + image
let imageData = try Data(contentsOf: imageURL)
let parts: [ContentPart] = [
    .text("What's in this image?"),
    .image(imageData, mimeType: "image/png")
]

let message = Message.user(parts)
```

## AssistantContentBlock

Content blocks within an assistant message. Preserves exact ordering for prompt caching compatibility across providers.

```swift
public enum AssistantContentBlock: Sendable {
    case text(String)
    case thinking(ThinkingBlock)
    case toolUse(ToolCall)
}
```

Blocks can appear in any order. A typical response with thinking might look like:

```swift
let blocks: [AssistantContentBlock] = [
    .thinking(ThinkingBlock(content: "Let me analyze...", providerData: "sig", provider: "anthropic")),
    .text("Based on my analysis..."),
    .toolUse(searchToolCall)
]
```

Each block type has a convenience accessor:

```swift
let block: AssistantContentBlock = ...

block.textContent     // -> String? (for .text blocks)
block.thinkingBlock   // -> ThinkingBlock? (for .thinking blocks)
block.thinkingContent // -> String? (thinking text, nil if filtered)
block.toolCall        // -> ToolCall? (for .toolUse blocks)
block.isThinking      // -> Bool
```

## ThinkingBlock

Represents internal reasoning from extended thinking features (Anthropic Claude, OpenAI o-series).

```swift
public struct ThinkingBlock: Sendable, Codable {
    let content: String?      // nil if filtered by provider
    let providerData: String? // opaque data, pass through unchanged
    let provider: String      // "anthropic", "openai", etc.
}
```

Key behaviors:

- **`content`** -- The visible thinking text. Nil when the provider filters or redacts the reasoning.
- **`providerData`** -- Opaque data (signatures, encrypted content) that must be passed back unchanged for cache compatibility. Do not modify or inspect this.
- **`provider`** -- Identifies which provider generated the block, used for correct handling when switching providers.
- **`isFiltered`** -- `true` when content is nil but providerData is present (filtered thinking).

```swift
// Visible thinking from Anthropic
let visible = ThinkingBlock(
    content: "Let me analyze this step by step...",
    providerData: "signature_abc123",
    provider: "anthropic"
)

// Filtered thinking (must pass through unchanged)
let filtered = ThinkingBlock(
    content: nil,
    providerData: "encrypted_data",
    provider: "anthropic"
)
filtered.isFiltered  // true
```

## ToolResultEntry

A single tool result entry for multi-tool responses. Pairs a tool call ID with its output.

```swift
public struct ToolResultEntry: Sendable, Codable {
    let id: String
    let output: ToolOutput
}
```

Convenience constructors:

```swift
ToolResultEntry.text(id: "call_123", "Search found 5 results")
ToolResultEntry.error(id: "call_456", "File not found: data.csv")
```

## ToolOutput

The output of a tool execution. Three cases cover success, structured data, and errors:

```swift
public enum ToolOutput: Sendable, Codable {
    case text(String)
    case json(JSONValue)
    case error(String)
}
```

- **`.text`** -- Plain text result. Most common for simple tools.
- **`.json`** -- Structured JSON result for tools that return complex data.
- **`.error`** -- Error message. The LLM receives this and can use it to retry or explain the failure to the user.

## Chat History

### Continuing Conversations

Every `AgentRun` contains the complete message history. Pass it to a subsequent run to continue the conversation:

```swift
// First run
let run1 = try await agent.run("Hello, what can you help me with?")
let messages = run1.messages

// Continue with history
let run2 = try await agent.run("Tell me more about the first option", messageHistory: messages)
```

Or use the `continuingFrom:` shorthand:

```swift
let run1 = try await agent.run("Hello")
let run2 = try await agent.run("Follow up question", continuingFrom: run1)
```

The `continuingFrom:` variant handles edge cases automatically. If the previous run paused for tool approval, it cancels all pending tool calls before continuing (LLM APIs require a tool result for every tool use in the assistant message).

### Message History Structure

A typical conversation history looks like:

```swift
[
    .system("You are a helpful assistant."),           // from agent.systemPrompt
    .user("What's the weather in Paris?"),             // first prompt
    .assistant([.toolUse(weatherToolCall)]),            // LLM requests tool
    .toolResult(toolCallId: "call_1", content: "18C"), // tool result
    .assistant("The weather in Paris is 18C."),        // final response
    .user("And in London?"),                           // follow-up prompt
    .assistant([.toolUse(londonWeatherCall)]),          // LLM requests tool again
    .toolResult(toolCallId: "call_2", content: "12C"),
    .assistant("London is 12C."),
]
```

### Serialization

All message types are fully `Codable`. This means you can serialize conversation history to disk, send it over a network, or store it in a database:

```swift
let encoder = JSONEncoder()
let data = try encoder.encode(run.messages)

// Later...
let decoder = JSONDecoder()
let messages = try decoder.decode([Message].self, from: data)
let continued = try await agent.run("New question", messageHistory: messages)
```

`AgentRun` and `IterationState` are also `Codable` when `Output` is `Codable`, so you can persist the entire run state including output, usage, and iteration count.
