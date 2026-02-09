## Appendix: Vercel AI SDK Research - Agentic Patterns

### Overview

The Vercel AI SDK (now hosted at `ai-sdk.dev`) is a TypeScript toolkit for building AI-powered applications and agents. It consists of two main libraries:

- **AI SDK Core**: Unified API for text generation, structured objects, tool calls, and agent building
- **AI SDK UI**: Framework-agnostic hooks for chat interfaces and generative UIs

This research focuses on the core agentic patterns for comparison with Yrden's design.

---

### 1. Core Functions & Types

#### Primary Generation Functions

| Function | Purpose | Return Type |
|----------|---------|-------------|
| `generateText()` | Non-streaming text + tool execution | `Promise<GenerateTextResult>` |
| `streamText()` | Streaming text + tool execution | `StreamTextResult` (with async iterables) |
| `generateObject()` | **Deprecated** - Use `generateText` with `output` | `Promise<{ object: T }>` |
| `streamObject()` | **Deprecated** - Use `streamText` with `output` | `{ partialObjectStream }` |

#### GenerateTextResult Properties

```typescript
interface GenerateTextResult<TOOLS, OUTPUT> {
  // Final step content
  text: string;
  content: ContentPart[];
  reasoning: ReasoningPart[];
  reasoningText?: string;
  files: GeneratedFile[];
  sources: Source[];
  
  // Tool interactions (final step)
  toolCalls: ToolCall[];
  toolResults: ToolResult[];
  
  // Execution metadata
  finishReason: 'stop' | 'tool-calls' | 'length' | 'content-filter' | 'error';
  usage: TokenUsage;
  totalUsage: TokenUsage;  // Cumulative across all steps
  
  // Multi-step details
  steps: StepResult[];
  
  // Response metadata
  response: ResponseMetadata;
  output?: OUTPUT;  // Structured output if specified
}
```

#### StepResult Type

```typescript
interface StepResult<TOOLS> {
  content: ContentPart[];
  text: string;
  reasoning: ReasoningPart[];
  files: GeneratedFile[];
  sources: Source[];
  
  toolCalls: ToolCall[];
  toolResults: ToolResult[];
  
  finishReason: string;
  rawFinishReason: string;
  usage: TokenUsage;
  
  request: RequestMetadata;
  response: ResponseMetadata;
}
```

---

### 2. Execution Model

#### Single vs Multi-Turn Execution

The SDK supports both single-shot and multi-turn (agentic) execution through the same functions:

```typescript
// Single turn - stops after first response
const result = await generateText({
  model: openai('gpt-4'),
  prompt: 'Hello',
});

// Multi-turn with tools - continues until stop condition
const result = await generateText({
  model: openai('gpt-4'),
  prompt: 'Analyze sales data',
  tools: { fetchSales, calculateTrend },
  stopWhen: stepCountIs(10),  // Max 10 iterations
});
```

#### Tool Loop Mechanism

The internal loop in `generateText`/`streamText` works as follows:

1. **Initial Processing**: Collect tool approvals from input, execute pre-approved tools
2. **Generation Loop** continues while:
   - Client tool calls exist AND all have been executed, OR
   - Deferred results are pending (provider-executed tools), AND
   - Stop condition is not met
3. **Per-Step Process**:
   - Invoke `prepareStep` callback for dynamic configuration
   - Convert prompt to language model format
   - Call model via `doGenerate`/`doStream`
   - Parse tool calls, check approval requirements
   - Execute client-side tools in parallel
   - Track provider-executed deferred results
   - Append response messages for next iteration

#### Loop Termination Conditions

The loop stops when ANY of these occur:
- Finish reason is NOT `'tool-calls'` (e.g., `'stop'`, `'length'`)
- A tool without an `execute` function is called
- Tool approval is required (`needsApproval: true`)
- A `stopWhen` condition returns `true`

#### Streaming Architecture

`streamText` uses composable TransformStreams:

```
Base Stream → Tool Transformation → Event Processor → Output Transform
     ↓
   Tee'd to: textStream, fullStream, partialOutputStream
```

Each step enqueues a dedicated stream segment, enabling continuous streaming without blocking.

**Key Differences:**

| Aspect | `streamText` | `generateText` |
|--------|-------------|----------------|
| Return | `StreamTextResult` with async iterables | Direct result object |
| Delivery | Immediate chunk delivery | Waits for completion |
| Memory | Progressive streaming | Buffers entire response |

---

### 3. Tool Definition

#### The `tool()` Helper

```typescript
import { tool } from 'ai';
import { z } from 'zod';

const weatherTool = tool({
  description: 'Get weather for a location',
  inputSchema: z.object({
    location: z.string().describe('City name'),
    units: z.enum(['celsius', 'fahrenheit']).optional(),
  }),
  
  execute: async ({ location, units }, options) => {
    // options contains: toolCallId, messages, abortSignal
    const data = await fetchWeather(location, units);
    return JSON.stringify(data);
  },
  
  // Optional properties
  outputSchema: z.object({ temp: z.number(), condition: z.string() }),
  strict: true,  // Enable strict schema validation
  needsApproval: false,  // Or async function for dynamic approval
});
```

#### Tool Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `description` | `string` | Guides model's tool selection |
| `inputSchema` | Zod/JSON Schema | Defines and validates parameters |
| `execute` | `async (args, opts) => T` | Optional - executes the tool |
| `outputSchema` | Zod/JSON Schema | Optional - validates return type |
| `strict` | `boolean` | Provider-specific strict mode |
| `needsApproval` | `boolean \| async fn` | Require user approval |

#### ToolExecutionOptions

```typescript
interface ToolExecutionOptions {
  toolCallId: string;           // Unique identifier
  messages: ModelMessage[];     // Conversation history
  abortSignal?: AbortSignal;    // Cancellation support
}
```

#### Tool Choice Modes

```typescript
generateText({
  tools: { search, calculate },
  toolChoice: 'auto',      // Model decides (default)
  // toolChoice: 'none',   // Disable tools
  // toolChoice: 'required', // Force tool use
  // toolChoice: { type: 'tool', toolName: 'search' }, // Specific tool
});
```

#### Approval-Required Execution

```typescript
const riskyTool = tool({
  description: 'Execute database query',
  inputSchema: z.object({ query: z.string() }),
  needsApproval: true,  // Always require approval
  // OR dynamic:
  needsApproval: async ({ query }) => query.includes('DELETE'),
  execute: async ({ query }) => db.execute(query),
});
```

When `needsApproval` triggers, the model returns `tool-approval-request` parts instead of executing. A second API call processes the user's decision.

---

### 4. State & Continuation

#### Message History Patterns

The SDK does NOT maintain conversation state internally. You manage messages externally:

```typescript
let messages: CoreMessage[] = [
  { role: 'system', content: 'You are helpful.' },
];

async function chat(userMessage: string) {
  messages.push({ role: 'user', content: userMessage });
  
  const result = await generateText({
    model: openai('gpt-4'),
    messages,
    tools: { ... },
  });
  
  // Append ALL response messages (including tool calls/results)
  messages.push(...result.response.messages);
  
  return result.text;
}
```

#### Message Types

```typescript
type CoreMessage = 
  | { role: 'system'; content: string }
  | { role: 'user'; content: string | ContentPart[] }
  | { role: 'assistant'; content: string | ContentPart[] }
  | { role: 'tool'; content: ToolResultPart[] };
```

User messages support multi-modal content:
- Text parts
- Image parts (base64, URL, Buffer)
- File parts (with MIME type)

#### Resume Capabilities

**Limitation**: The SDK has no built-in resume mechanism for interrupted runs. The `steps` array in results contains all intermediate state, but resumption requires manual reconstruction:

```typescript
// After interruption, you must:
// 1. Reconstruct messages from saved steps
// 2. Re-call generateText with the reconstructed state
```

---

### 5. Context Engineering

#### Modifying Context Between Steps

The `prepareStep` callback runs before each generation step:

```typescript
generateText({
  model: openai('gpt-4'),
  prompt: 'Complex task',
  tools: { search, analyze, summarize },
  
  prepareStep: async ({ stepNumber, steps, messages, model }) => {
    // Dynamic model switching
    if (stepNumber > 3) {
      return { model: anthropic('claude-3-opus') };
    }
    
    // Context management - prune old messages
    if (messages.length > 20) {
      return {
        messages: [
          messages[0],  // Keep system prompt
          ...messages.slice(-10),  // Keep recent context
        ],
      };
    }
    
    // Tool phasing
    const phase = stepNumber < 3 ? 'search' : 'analyze';
    return {
      activeTools: [phase],
    };
    
    // Pass context to tools
    return {
      experimental_context: {
        userId: 'user-123',
        stepNumber,
      },
    };
  },
});
```

#### PrepareStep Return Options

```typescript
interface PrepareStepResult {
  model?: LanguageModel;          // Switch models mid-run
  messages?: CoreMessage[];       // Modify message history
  tools?: ToolSet;                // Change available tools
  activeTools?: string[];         // Limit tool subset
  toolChoice?: ToolChoice;        // Change tool selection mode
  experimental_context?: unknown; // Pass data to tool execute()
}
```

#### Token Management

The SDK provides usage tracking but no automatic context management:

```typescript
const result = await generateText({ ... });

console.log(result.usage);       // Final step tokens
console.log(result.totalUsage);  // Cumulative across all steps

// Manual truncation in prepareStep is required for long conversations
```

---

### 6. Multi-Step / Agentic Patterns

#### ToolLoopAgent Class

The SDK provides a dedicated agent abstraction:

```typescript
import { ToolLoopAgent, stepCountIs } from 'ai';

const agent = new ToolLoopAgent({
  model: openai('gpt-4'),
  instructions: 'You are a helpful research assistant.',
  tools: {
    search: tool({ ... }),
    calculate: tool({ ... }),
  },
  stopWhen: stepCountIs(20),  // Default max steps
  
  onStepFinish: async ({ usage, toolCalls, finishReason }) => {
    console.log(`Step completed: ${toolCalls.length} tool calls`);
  },
});

// Non-streaming execution
const result = await agent.generate({
  prompt: 'Analyze Q4 sales trends',
});

// Streaming execution
const stream = await agent.stream({
  prompt: 'Analyze Q4 sales trends',
});
```

#### Stop Conditions

```typescript
import { stepCountIs, hasToolCall } from 'ai';

// Built-in conditions
stopWhen: stepCountIs(20)           // Max 20 steps
stopWhen: hasToolCall('done')       // Stop when 'done' tool is called

// Multiple conditions (stops when ANY is true)
stopWhen: [stepCountIs(20), hasToolCall('finalAnswer')]

// Custom condition
const costLimit: StopCondition = ({ steps }) => {
  const totalTokens = steps.reduce((sum, s) => sum + s.usage.totalTokens, 0);
  return totalTokens > 100000;  // Stop if over 100k tokens
};
```

#### StopCondition Type

```typescript
type StopCondition<TOOLS> = (options: {
  steps: StepResult<TOOLS>[];
}) => boolean | PromiseLike<boolean>;
```

#### Forced Tool Usage Pattern

Combine `toolChoice: 'required'` with a "done" tool for structured workflows:

```typescript
const agent = new ToolLoopAgent({
  tools: {
    search: tool({ execute: async (args) => { ... } }),
    analyze: tool({ execute: async (args) => { ... } }),
    done: tool({  // No execute - triggers stop
      description: 'Call when task is complete',
      inputSchema: z.object({ answer: z.string() }),
    }),
  },
  toolChoice: 'required',  // Force tool use every step
});
// Agent stops when it calls the 'done' tool
```

#### Callbacks

```typescript
generateText({
  onStepFinish: async ({ 
    text, 
    toolCalls, 
    toolResults,
    finishReason,
    usage,
    response,
  }) => {
    // Called after each generation step
    await logStep(usage);
  },
  
  onFinish: async ({
    text,
    totalUsage,
    steps,
    finishReason,
  }) => {
    // Called once when all generation completes
    await recordUsage(totalUsage);
  },
});

// For streaming
streamText({
  onChunk: ({ chunk }) => {
    // Called for each stream chunk
    if (chunk.type === 'text-delta') {
      process.stdout.write(chunk.text);
    }
  },
  onError: ({ error }) => {
    // Handle streaming errors without crashing
    console.error('Stream error:', error);
  },
});
```

---

### 7. Structured Output

#### Output Module (Recommended)

```typescript
import { generateText, Output } from 'ai';

// Object output
const { output } = await generateText({
  model: openai('gpt-4'),
  prompt: 'Extract user info from: John Doe, 30 years old',
  output: Output.object({
    schema: z.object({
      name: z.string(),
      age: z.number(),
    }),
  }),
});
// output: { name: 'John Doe', age: 30 }

// Array output with element streaming
const { elementStream } = await streamText({
  model: openai('gpt-4'),
  prompt: 'List 5 programming languages',
  output: Output.array({
    schema: z.object({
      name: z.string(),
      paradigm: z.string(),
    }),
  }),
});

for await (const element of elementStream) {
  console.log(element);  // Each element is fully validated
}

// Choice output (classification)
const { output } = await generateText({
  prompt: 'Classify sentiment: "I love this!"',
  output: Output.choice({
    options: ['positive', 'negative', 'neutral'],
  }),
});
// output: 'positive'
```

#### Output Types

| Method | Use Case | Streaming Support |
|--------|----------|-------------------|
| `Output.text()` | Plain text (default) | Yes |
| `Output.object()` | Typed objects | Partial objects |
| `Output.array()` | Lists of items | Element-by-element |
| `Output.choice()` | Classification | No |
| `Output.json()` | Unvalidated JSON | Yes |

---

### 8. Middleware

Language model middleware intercepts and modifies LLM calls:

```typescript
import { wrapLanguageModel } from 'ai';

const loggingMiddleware = {
  transformParams: async ({ params }) => {
    console.log('Request:', params);
    return params;
  },
  
  wrapGenerate: async ({ doGenerate, params }) => {
    const result = await doGenerate();
    console.log('Response:', result.text);
    return result;
  },
  
  wrapStream: async ({ doStream, params }) => {
    const stream = await doStream();
    // Can transform stream chunks
    return stream;
  },
};

const wrappedModel = wrapLanguageModel(openai('gpt-4'), loggingMiddleware);
```

Use cases: guardrails, RAG injection, caching, logging, rate limiting.

---

### 9. Limitations & Tradeoffs

#### What You CAN'T Do

| Limitation | Description | Workaround |
|------------|-------------|------------|
| **No built-in state persistence** | Conversation history not saved | Manage messages externally |
| **No resume from interruption** | Steps array is read-only | Reconstruct from saved state |
| **No parallel tool execution control** | Tools run in parallel by default | Use single tools or orchestrate externally |
| **No cross-step message injection** | Can only modify in `prepareStep` | Use `prepareStep` callback |
| **No iterative/pausable loop** | Loop runs to completion | Use `stopWhen` with approval tools |
| **Limited inter-agent communication** | No built-in handoff protocol | Implement externally |

#### Streaming vs Non-Streaming Differences

- `streamText` defaults to `stepCountIs(1)` (single step) vs `stepCountIs(20)` for agents
- Streaming requires handling partial objects and errors as stream parts
- Some callbacks (`onChunk`) only available in streaming mode
- Structured output parsing is progressive in streaming, final-only in non-streaming

#### State Access Limitations

- Tool `execute` only receives: `toolCallId`, `messages`, `abortSignal`, and `experimental_context`
- Cannot access intermediate step results from within tools
- Cannot modify the message array from within tool execution
- `prepareStep` cannot access the current step's tool calls (only prior steps)

---

### 10. Comparison with Yrden Design Goals

| Feature | Vercel AI SDK | Yrden Goal |
|---------|---------------|------------|
| **Multi-provider** | Yes (OpenAI, Anthropic, etc.) | Yes |
| **Structured output** | Yes (Zod schemas) | Yes (`@Schema` macro) |
| **Tool definition** | `tool()` helper with Zod | Protocol conformance |
| **Agent loop** | `ToolLoopAgent` class | `Agent.iter()` / AsyncSequence |
| **Loop control** | `stopWhen`, `prepareStep` | Full iteration control |
| **Human approval** | `needsApproval` on tools | Planned |
| **State persistence** | None (external) | None (external) |
| **Resume capability** | None | Planned (iteration continuation) |
| **MCP support** | Yes | Planned |
| **Streaming** | Yes (TransformStreams) | Yes (AsyncSequence) |
| **Middleware** | Yes | TBD |
| **Type safety** | Runtime (Zod) | Compile-time (macros) |

#### Key Architectural Differences

1. **Loop Control Granularity**: Vercel uses callbacks (`onStepFinish`) and conditions (`stopWhen`). Yrden aims for full iteration control via `AsyncSequence`, allowing inspection/modification of each node before execution.

2. **Schema Generation**: Vercel relies on Zod (runtime). Yrden uses Swift macros (compile-time).

3. **Error Handling**: Vercel uses thrown errors + stream error parts. Yrden will use typed `Result<T, ToolError>`.

4. **Tool Retry**: Vercel has no built-in retry mechanism for failed tools. Yrden plans `ToolRejection` pattern (like PydanticAI's `ModelRetry`).

---

### References

- Documentation: https://ai-sdk.dev/docs
- GitHub: https://github.com/vercel/ai
- Core source: `packages/ai/src/generate-text/`
- Agent source: `packages/ai/src/agent/`
Let me try different URLs.
Let me try accessing documentation pages more directly.
Let me look at more source code directly from the repository.
Let me look at the actual documentation examples and GitHub issues more closely.
Now let me get more details on provider metadata and advanced features.
Let me search for additional architectural details.
Now let me compile all this research into a comprehensive continuation document.

---

## Appendix: Vercel AI SDK Research - Agentic Patterns (Continued)

### 11. PrepareStep Configuration

The `prepareStep` callback provides fine-grained control over each step in the agent loop, running before each generation step begins.

#### PrepareStep Parameters

```typescript
prepareStep: async ({
  model,           // Current model
  stepNumber,      // 0-indexed step counter
  steps,           // Array of completed StepResult objects
  messages,        // Messages that will be sent for this step
}) => {
  // Return object to override settings for this step
  return {
    model?: LanguageModel;
    messages?: CoreMessage[];
    tools?: ToolSet;
    activeTools?: string[];
    toolChoice?: ToolChoice;
    system?: string;
    experimental_context?: unknown;
    providerOptions?: Record<string, unknown>;
  };
}
```

#### Common Use Cases

**1. Dynamic Model Switching**

```typescript
prepareStep: async ({ stepNumber, messages }) => {
  // Use cheaper model for simple tasks
  if (stepNumber === 0) {
    return { model: openai('gpt-4o-mini') };
  }
  // Switch to more capable model after initial steps
  if (stepNumber > 2 && messages.length > 10) {
    return { model: anthropic('claude-opus-4') };
  }
}
```

**2. Context Management (Token Limiting)**

```typescript
prepareStep: async ({ messages }) => {
  if (messages.length > 20) {
    return {
      messages: [
        messages[0],          // Keep system prompt
        ...messages.slice(-10), // Keep recent 10 messages
      ],
    };
  }
}
```

**3. Tool Phasing**

```typescript
prepareStep: async ({ stepNumber }) => {
  // Phase 1: Search tools only
  if (stepNumber < 3) {
    return { activeTools: ['search', 'lookup'] };
  }
  // Phase 2: Analysis tools only
  if (stepNumber < 6) {
    return { activeTools: ['analyze', 'calculate'] };
  }
  // Phase 3: Summarization
  return {
    activeTools: ['summarize'],
    toolChoice: { type: 'tool', toolName: 'summarize' },
  };
}
```

**4. Provider-Specific Features**

```typescript
prepareStep: async ({ stepNumber }) => {
  return {
    providerOptions: {
      anthropic: {
        // Persist Anthropic code execution container across steps
        codeExecutionContainerId: containerId,
      },
    },
  };
}
```

**5. Passing Context to Tools**

```typescript
prepareStep: async ({ stepNumber, steps }) => {
  return {
    experimental_context: {
      userId: 'user-123',
      stepNumber,
      previousResults: steps.map(s => s.text),
    },
  };
}
```

#### Limitations (from GitHub Issues)

Based on community feedback, there are some known limitations:

- **Message modifications may not persist**: [Issue #9631](https://github.com/vercel/ai/issues/9631) reports that message overrides in `prepareStep` are not preserved between steps
- **Cannot modify tool definitions**: [Issue #9743](https://github.com/vercel/ai/issues/9743) requests the ability to update the tools list dynamically (useful for MCP servers)
- **Cannot access current step's tool calls**: `prepareStep` runs BEFORE the step, so you only have access to prior steps
- **No direct tool result injection**: You cannot inject tool results without a corresponding tool call

---

### 12. Stop Conditions

Stop conditions determine when the agent loop terminates. The SDK provides built-in conditions and supports custom implementations.

#### Built-in Stop Conditions

**stepCountIs(n)**

Stops after a maximum of `n` steps if tools were called.

```typescript
import { generateText, stepCountIs } from 'ai';

const { text, steps } = await generateText({
  model: openai('gpt-4'),
  tools: { search, analyze },
  stopWhen: stepCountIs(5),  // Max 5 steps
  prompt: 'Research quantum computing',
});

console.log(`Completed in ${steps.length} steps`);
```

**hasToolCall(toolName)**

Stops when a specific tool is called (typically a "done" or "finish" tool).

```typescript
const { text } = await generateText({
  model: anthropic('claude-sonnet-4'),
  tools: {
    search: tool({ /* ... */ }),
    done: tool({
      description: 'Call when task is complete',
      inputSchema: z.object({ answer: z.string() }),
      // No execute function - triggers stop
    }),
  },
  stopWhen: hasToolCall('done'),
});
```

#### Multiple Stop Conditions

```typescript
stopWhen: [
  stepCountIs(20),          // Safety limit
  hasToolCall('finalAnswer'), // Explicit completion
]
// Stops when ANY condition returns true
```

#### Custom Stop Conditions

```typescript
import { StopCondition } from 'ai';

const costLimit: StopCondition<typeof tools> = ({ steps }) => {
  const totalTokens = steps.reduce(
    (sum, step) => sum + step.usage.totalTokens,
    0
  );
  return totalTokens > 100000;  // Stop if over 100k tokens
};

const hasAnswer: StopCondition<typeof tools> = ({ steps }) => {
  return steps.some(step => 
    step.text?.includes("ANSWER:") ?? false
  );
};

const result = await generateText({
  stopWhen: [costLimit, hasAnswer],
  // ...
});
```

#### StopCondition Type

```typescript
type StopCondition<TOOLS extends ToolSet> = (options: {
  steps: Array<StepResult<TOOLS>>;
}) => PromiseLike<boolean> | boolean;
```

#### Known Issues

From community feedback and GitHub issues:

- **stopWhen doesn't force final answer**: [Discussion #7941](https://github.com/vercel/ai/discussions/7941) - When `stepCountIs(5)` is reached, execution stops entirely without generating a final response
- **Implicit stop conditions**: `clientToolCalls.length === 0` appears to be an implicit stop condition
- **Provider inconsistencies**: Using `prepareStep` with `toolChoice: 'none'` to force text generation after tool limit doesn't work consistently across providers (Claude stops generation entirely)
- **sendAutomaticallyWhen interaction**: [Issue #7683](https://github.com/vercel/ai/issues/7683) - When `sendAutomaticallyWhen` is true, the loop may continue even after `stopWhen` evaluates to true

---

### 13. Stream Types and Consumption

The SDK provides multiple stream types for different consumption patterns.

#### Stream Types

**textStream** - Text deltas only:

```typescript
const { textStream } = streamText({
  model: openai('gpt-4'),
  prompt: 'Write a story',
});

for await (const chunk of textStream) {
  process.stdout.write(chunk);  // chunk is string
}
```

**fullStream** - All events including tool calls:

```typescript
const { fullStream } = streamText({
  model: anthropic('claude-sonnet-4'),
  tools: { search },
  prompt: 'Research AI',
});

for await (const part of fullStream) {
  switch (part.type) {
    case 'text-delta':
      process.stdout.write(part.text);
      break;
    case 'tool-call':
      console.log(`Calling ${part.toolName} with`, part.input);
      break;
    case 'tool-result':
      console.log(`Result:`, part.output);
      break;
    case 'error':
      console.error('Error:', part.error);
      break;
  }
}
```

**elementStream** - For array outputs:

```typescript
const { elementStream } = streamText({
  model: openai('gpt-4'),
  prompt: 'List 10 programming languages',
  output: Output.array({
    schema: z.object({
      name: z.string(),
      year: z.number(),
    }),
  }),
});

for await (const element of elementStream) {
  console.log(element);  // Each element is fully validated
}
```

**partialOutputStream** - For object outputs:

```typescript
const { partialOutputStream } = streamText({
  model: openai('gpt-4'),
  output: Output.object({
    schema: z.object({
      name: z.string(),
      bio: z.string(),
    }),
  }),
});

for await (const partial of partialOutputStream) {
  console.log(partial);  // Partial objects as they stream
}
```

#### TextStreamPart Types

The `fullStream` emits a union of part types:

```typescript
type TextStreamPart<TOOLS, OUTPUT> =
  // Text events
  | { type: 'text-start'; id: string }
  | { type: 'text-delta'; text: string }
  | { type: 'text-end' }
  
  // Reasoning events (o1 models)
  | { type: 'reasoning-start' }
  | { type: 'reasoning-delta'; reasoning: string }
  | { type: 'reasoning-end' }
  
  // Tool events
  | { type: 'tool-call'; toolCallId: string; toolName: string }
  | { type: 'tool-input-start'; toolCallId: string }
  | { type: 'tool-input-delta'; toolCallId: string; delta: string }
  | { type: 'tool-input-end'; toolCallId: string }
  | { type: 'tool-result'; toolCallId: string; output: unknown }
  | { type: 'tool-error'; toolCallId: string; error: Error }
  | { type: 'tool-output-denied'; toolCallId: string }
  
  // Lifecycle events
  | { type: 'start-step'; stepNumber: number }
  | { type: 'finish-step'; finishReason: string; usage: TokenUsage }
  | { type: 'start' }
  | { type: 'finish'; finishReason: string; usage: TokenUsage }
  
  // Other
  | { type: 'source'; source: Source }
  | { type: 'file'; file: GeneratedFile }
  | { type: 'error'; error: Error }
  | { type: 'abort' }
  | { type: 'raw'; rawEvent: unknown };
```

#### Consuming Streams

**Auto-consumption via Promises:**

```typescript
const result = streamText({ /* ... */ });

// Accessing these properties consumes the entire stream
const text = await result.text;
const usage = await result.usage;
const toolCalls = await result.toolCalls;
```

**Manual consumption:**

```typescript
const result = streamText({ /* ... */ });

// Consume manually
for await (const chunk of result.textStream) {
  // Process chunks
}

// After manual consumption, promises resolve
const text = await result.text;  // Contains full accumulated text
```

**Force consumption without processing:**

```typescript
await result.consumeStream();  // Drains stream, populates promises
```

---

### 14. UI Integration (AI SDK UI)

The AI SDK UI package provides React hooks for building chat interfaces.

#### useChat Hook

```typescript
import { useChat } from 'ai/react';

function ChatComponent() {
  const {
    messages,          // UIMessage[]
    input,             // Current input value
    status,            // 'ready' | 'submitted' | 'streaming' | 'error'
    error,             // Error object if present
    
    sendMessage,       // (message?) => void
    stop,              // () => void
    regenerate,        // () => void
    setMessages,       // (messages) => void
    addToolOutput,     // (toolCallId, output) => void
    resumeStream,      // () => void
  } = useChat({
    id: 'chat-1',
    
    onFinish: (message) => {
      console.log('Response complete:', message);
    },
    
    onToolCall: ({ toolCall }) => {
      // Human-in-the-loop approval
      if (needsApproval(toolCall)) {
        const approved = confirm(`Allow ${toolCall.toolName}?`);
        if (approved) {
          addToolOutput(toolCall.id, executeLocally(toolCall));
        }
      }
    },
    
    experimental_throttle: 50,  // Batch UI updates (ms)
  });
  
  return (
    <div>
      {messages.map(m => (
        <div key={m.id}>{m.content}</div>
      ))}
      <input value={input} onChange={e => setInput(e.target.value)} />
      <button onClick={() => sendMessage()}>Send</button>
      {status === 'streaming' && <button onClick={stop}>Stop</button>}
    </div>
  );
}
```

#### UIMessage Structure

```typescript
type UIMessage = {
  id: string;
  role: 'user' | 'assistant' | 'system' | 'tool';
  parts: MessagePart[];
  metadata?: Record<string, unknown>;
};

type MessagePart =
  | { type: 'text'; text: string }
  | { type: 'image'; image: string | URL }
  | { type: 'file'; file: File }
  | { type: 'tool-call'; toolCallId: string; toolName: string; input: unknown }
  | { type: 'tool-result'; toolCallId: string; output: unknown };
```

#### Transport Options

**DefaultChatTransport** (HTTP):

```typescript
useChat({
  transport: DefaultChatTransport({
    url: '/api/chat',
    headers: { 'X-Custom': 'value' },
    credentials: 'include',
  }),
});
```

**DirectChatTransport** (Server-side):

```typescript
import { DirectChatTransport } from 'ai/react';

useChat({
  transport: DirectChatTransport({
    agent: myToolLoopAgent,
  }),
});
```

---

### 15. Middleware System

Language model middleware intercepts and transforms LLM calls.

#### Middleware Lifecycle

```typescript
import { wrapLanguageModel } from 'ai';

const middleware = {
  // Transform params before calling model
  transformParams: async ({ params }) => {
    console.log('Request:', params.prompt);
    return {
      ...params,
      temperature: params.temperature ?? 0.7,  // Set defaults
    };
  },
  
  // Wrap generate call
  wrapGenerate: async ({ doGenerate, params }) => {
    const start = Date.now();
    const result = await doGenerate();
    console.log(`Generated in ${Date.now() - start}ms`);
    return result;
  },
  
  // Wrap stream call
  wrapStream: async ({ doStream, params }) => {
    const stream = await doStream();
    // Can transform stream chunks here
    return stream;
  },
};

const wrappedModel = wrapLanguageModel(openai('gpt-4'), middleware);
```

#### Built-in Middleware

**extractReasoningMiddleware** - Extract reasoning from tagged content:

```typescript
import { extractReasoningMiddleware } from 'ai';

const model = wrapLanguageModel(
  openai('gpt-4'),
  extractReasoningMiddleware({ tag: 'think' })
);
// Extracts <think>...</think> content as reasoning
```

**extractJsonMiddleware** - Strip markdown fences:

```typescript
import { extractJsonMiddleware } from 'ai';

const model = wrapLanguageModel(
  someModel,
  extractJsonMiddleware()
);
// Strips ```json...``` fences for structured output
```

**defaultSettingsMiddleware** - Apply defaults:

```typescript
import { defaultSettingsMiddleware } from 'ai';

const model = wrapLanguageModel(
  openai('gpt-4'),
  defaultSettingsMiddleware({
    temperature: 0.7,
    maxOutputTokens: 2000,
  })
);
```

**simulateStreamingMiddleware** - Fake streaming:

```typescript
import { simulateStreamingMiddleware } from 'ai';

const model = wrapLanguageModel(
  nonStreamingModel,
  simulateStreamingMiddleware({ delayMs: 10 })
);
```

#### Common Middleware Use Cases

**RAG Integration:**

```typescript
const ragMiddleware = {
  transformParams: async ({ params }) => {
    const context = await retrieveContext(params.prompt);
    return {
      ...params,
      prompt: `Context:\n${context}\n\nQuery: ${params.prompt}`,
    };
  },
};
```

**Caching:**

```typescript
const cacheMiddleware = {
  wrapGenerate: async ({ doGenerate, params }) => {
    const cacheKey = hash(params);
    const cached = cache.get(cacheKey);
    if (cached) return cached;
    
    const result = await doGenerate();
    cache.set(cacheKey, result);
    return result;
  },
};
```

**Guardrails:**

```typescript
const guardrailsMiddleware = {
  wrapGenerate: async ({ doGenerate, params }) => {
    const result = await doGenerate();
    result.text = redactSensitiveInfo(result.text);
    return result;
  },
};
```

---

### 16. Embeddings

The SDK supports generating embeddings for similarity search and RAG.

#### Single Embedding

```typescript
import { embed } from 'ai';
import { openai } from '@ai-sdk/openai';

const { embedding } = await embed({
  model: openai.embedding('text-embedding-3-small'),
  value: 'sunny day at the beach',
});

console.log(embedding);  // number[] - vector representation
```

#### Batch Embeddings

```typescript
import { embedMany } from 'ai';

const { embeddings } = await embedMany({
  model: openai.embedding('text-embedding-3-small'),
  values: [
    'The cat sat on the mat',
    'A dog ran through the park',
    'Birds flew over the lake',
  ],
  maxParallelCalls: 5,  // Control concurrency
  maxRetries: 3,
});

console.log(embeddings.length);  // 3
```

#### Similarity Calculation

```typescript
import { cosineSimilarity } from 'ai';

const similarity = cosineSimilarity(embedding1, embedding2);
console.log(similarity);  // 0.0 to 1.0
```

#### Supported Providers

- OpenAI: `text-embedding-3-small`, `text-embedding-3-large`
- Google: `text-embedding-004`, `text-multilingual-embedding-002`
- Mistral: `mistral-embed`
- Cohere: `embed-english-v3.0`, `embed-multilingual-v3.0`

---

### 17. Error Handling

#### Error Types

The SDK defines 31 error types (all prefixed with `AI_`):

- `AI_APICallError` - Provider API call failed
- `AI_InvalidArgumentError` - Invalid function argument
- `AI_InvalidToolInputError` - Tool received invalid input
- `AI_NoContentGeneratedError` - Model returned no content
- `AI_NoObjectGeneratedError` - No structured object generated
- `AI_RetryError` - All retries exhausted
- `AI_TypeValidationError` - Output validation failed
- `AI_ToolCallNotFoundForApprovalError` - Approval request for unknown tool call
- (And 23 others - see [error reference](https://ai-sdk.dev/docs/reference/ai-sdk-errors))

#### Regular Error Handling

```typescript
try {
  const { text } = await generateText({ /* ... */ });
} catch (error) {
  if (error instanceof AI_NoContentGeneratedError) {
    console.error('Model returned no content');
  } else if (error instanceof AI_APICallError) {
    console.error('API call failed:', error.statusCode);
  }
}
```

#### Streaming Error Handling

**Simple streams** (textStream):

```typescript
try {
  for await (const chunk of result.textStream) {
    process.stdout.write(chunk);
  }
} catch (error) {
  console.error('Stream error:', error);
}
```

**Full streams** (fullStream):

```typescript
for await (const part of result.fullStream) {
  switch (part.type) {
    case 'error':
      console.error('Error part:', part.error);
      break;
    case 'tool-error':
      console.error(`Tool ${part.toolCallId} failed:`, part.error);
      break;
    // ... other parts
  }
}
```

#### Retry Configuration

```typescript
const result = await generateText({
  model: openai('gpt-4'),
  prompt: 'Hello',
  maxRetries: 3,  // Default: 2
});
```

#### Abort Handling

```typescript
const controller = new AbortController();

const result = streamText({
  model: openai('gpt-4'),
  prompt: 'Long task',
  abortSignal: controller.signal,
  
  onAbort: ({ steps }) => {
    console.log(`Aborted after ${steps.length} steps`);
    cleanup();
  },
});

// Later
controller.abort();
```

---

### 18. Architecture Comparison: Vercel AI SDK vs Yrden

| Aspect | Vercel AI SDK | Yrden Design Goal |
|--------|---------------|-------------------|
| **Language** | TypeScript | Swift |
| **Schema Definition** | Zod (runtime) | `@Schema` macro (compile-time) |
| **Type Safety** | Runtime validation | Compile-time + runtime |
| **Loop Control** | Callbacks + conditions | `AsyncSequence` iteration |
| **State Management** | External (manual) | External (manual) |
| **Resume Capability** | None | Planned (iteration continuation) |
| **Tool Execution** | Auto-parallel | Auto-parallel + approval |
| **Error Model** | Thrown errors + stream errors | Typed `Result<T, Error>` |
| **Retry Pattern** | Global retries (maxRetries) | Per-tool + `ModelRetry` signal |
| **Middleware** | `wrapLanguageModel` | TBD |
| **UI Integration** | React hooks (useChat) | N/A (server-side library) |
| **MCP Support** | Yes | Planned |
| **Streaming** | TransformStreams | AsyncSequence |

#### Key Architectural Insights

**1. Loop Control Philosophy**

- **Vercel**: Callback-based (`onStepFinish`, `prepareStep`) with declarative stop conditions
- **Yrden Goal**: Imperative iteration control via `for await` over `AsyncSequence`

Example contrast:

```typescript
// Vercel: Declarative callbacks
const result = await generateText({
  onStepFinish: ({ toolCalls }) => {
    if (needsApproval(toolCalls[0])) {
      // Can't actually pause here - callback only observes
    }
  },
  stopWhen: customCondition,
});

// Yrden: Imperative control
for await let node in agent.iter(prompt, deps: deps) {
  switch node {
  case .toolCall(let call):
    if needsApproval(call) {
      let approved = await requestApproval(call)
      if !approved { continue }  // Actually skip execution
    }
  case .response(let partial): ...
  }
}
```

**2. Schema Generation Strategy**

- **Vercel**: Runtime schema generation via Zod, validated at execution time
- **Yrden**: Compile-time schema generation via Swift macros, validated at compile time AND runtime

**3. Limitations Both Share**

- No built-in state persistence
- No automatic conversation compaction (manual in `prepareStep` / planned in Yrden)
- Tool execution is fire-and-forget (no built-in result validation/retry)
- Multi-agent coordination requires external orchestration

**4. Areas Where Vercel Excels**

- **Mature middleware system**: Composable transformations for RAG, caching, guardrails
- **UI integration**: First-class React hooks with stream resumption
- **Provider ecosystem**: 10+ official providers
- **Telemetry**: Built-in observability hooks

**5. Areas Where Yrden Could Differentiate**

- **Compile-time type safety**: Catch schema errors at build time
- **First-class iteration control**: Pause, inspect, modify mid-loop
- **Typed error handling**: `Result` types instead of exceptions
- **Per-tool retry**: Fine-grained retry configuration with reflection

---

### Sources

- [AI SDK Core Documentation](https://ai-sdk.dev/docs)
- [AI SDK GitHub Repository](https://github.com/vercel/ai)
- [Agents: Loop Control](https://ai-sdk.dev/docs/agents/loop-control)
- [AI SDK Core: generateText](https://ai-sdk.dev/docs/reference/ai-sdk-core/generate-text)
- [AI SDK Core: streamText](https://ai-sdk.dev/docs/reference/ai-sdk-core/stream-text)
- [AI SDK Core: Tool Calling](https://ai-sdk.dev/docs/ai-sdk-core/tools-and-tool-calling)
- [How to build AI Agents with Vercel and the AI SDK](https://vercel.com/kb/guide/how-to-build-ai-agents-with-vercel-and-the-ai-sdk)
- [AI SDK 6 Release](https://vercel.com/blog/ai-sdk-6)
- [GitHub Issue #7941: How to limit tool call steps](https://github.com/vercel/ai/discussions/7941)
- [GitHub Issue #9631: prepareStep messages not preserved](https://github.com/vercel/ai/issues/9631)
- [GitHub Issue #9743: prepareStep tool updates](https://github.com/vercel/ai/issues/9743)
- [GitHub Issue #7683: stopWhen and sendAutomaticallyWhen interaction](https://github.com/vercel/ai/issues/7683)
