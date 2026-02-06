## Research Appendix: Cloudflare Agents API Surface

### Overview

Cloudflare Agents is a framework for building stateful, autonomous AI agents that run on Cloudflare's edge infrastructure. The SDK is built on top of Durable Objects (stateful micro-servers) and provides primitives for real-time communication, persistent state, tool execution, and LLM integration.

**Key architectural insight**: The Agent class hierarchy is `DurableObject > Server (PartyKit) > Agent`, with each layer adding developer-friendly abstractions on top of the foundational Durable Objects infrastructure.

---

### 1. Core Concepts & Types

#### Agent Class Definition

Agents are implemented by extending the base `Agent` class with generic type parameters for environment and state:

```typescript
import { Agent } from "agents";

class MyAgent extends Agent<Env, State> {
  // State type parameter defines the shape of persisted state
  initialState = { count: 0, messages: [] };
  
  // Custom methods become callable via RPC
  async processRequest(input: string): Promise<string> {
    // Access environment: this.env
    // Access state: this.state
    // Update state: this.setState({ ... })
    return "processed";
  }
}
```

#### AIChatAgent Extension

For chat-focused agents, the SDK provides `AIChatAgent` with built-in message handling:

```typescript
import { AIChatAgent, StreamTextOnFinishCallback } from "agents";

class ChatAgent extends AIChatAgent<Env> {
  // Built-in: this.messages contains conversation history
  
  async onChatMessage(onFinish: StreamTextOnFinishCallback<any>) {
    return createDataStreamResponse({
      execute: async (dataStream) => {
        const stream = streamText({
          model: openai("gpt-4o-mini"),
          system: "You are helpful.",
          messages: this.messages,
          onFinish,
          tools: myTools,
          maxSteps: 5,
        });
        stream.mergeIntoDataStream(dataStream);
      },
    });
  }
}
```

#### Configuration (wrangler.toml/wrangler.jsonc)

```toml
name = "my-agent"
main = "src/server.ts"
compatibility_date = "2026-02-04"
compatibility_flags = ["nodejs_compat"]

[durable_objects]
bindings = [
  { name = "MY_AGENT", class_name = "MyAgent" }
]

[[migrations]]
tag = "v1"
new_sqlite_classes = ["MyAgent"]

[observability]
enabled = true
```

---

### 2. Execution Model

#### Event-Driven, Single-Threaded

Each Agent instance runs as a single-threaded, globally-unique compute unit:

- **Serialized execution**: Synchronous code is atomic; async operations can interleave
- **No distributed locks needed**: The runtime enforces ordering automatically
- **Throughput limits**: ~500-1,000 requests/second per instance (varies by complexity)

#### Lifecycle Hooks

```typescript
class MyAgent extends Agent<Env, State> {
  // Called when instance starts or resumes from hibernation
  async onStart() {
    console.log("Agent starting");
  }
  
  // HTTP request handling
  async onRequest(request: Request): Promise<Response> {
    return new Response("OK");
  }
  
  // WebSocket lifecycle
  onConnect(connection: Connection, ctx: ConnectionContext) { }
  onMessage(connection: Connection, message: WSMessage) { }
  onClose(connection: Connection, code: number, reason: string, wasClean: boolean) { }
  onError(connection: Connection, error: Error) { }
  
  // State change reactions
  onStateUpdate(state: State, source: "server" | Connection) { }
}
```

#### CPU Time vs Wall Clock

- **Compute limit**: 30 seconds CPU time per request (refreshes on each new HTTP/WebSocket message)
- **Wall clock**: Unlimited - agents can wait on external I/O (LLM calls, database queries) without consuming CPU budget
- Long-running LLM calls (reasoning models) don't exhaust the time limit

#### Streaming Behavior

The SDK supports multiple streaming patterns:

```typescript
// Server-Sent Events (SSE) for HTTP
async onRequest(request: Request) {
  const stream = await this.streamFromLLM(prompt);
  return new Response(stream, {
    headers: { "Content-Type": "text/event-stream" }
  });
}

// WebSocket streaming
onMessage(connection: Connection, message: string) {
  const stream = this.callLLM(message);
  for await (const chunk of stream) {
    connection.send(JSON.stringify({ type: "delta", content: chunk }));
  }
  connection.send(JSON.stringify({ type: "done" }));
}
```

`AIChatAgent` provides **automatic resumable streaming**: if a client disconnects and reconnects mid-stream, the response resumes from where it left off.

---

### 3. State Management

#### Persistence Architecture

State is stored in an embedded SQLite database within each Agent instance:

```typescript
class MyAgent extends Agent<Env, { count: number; items: string[] }> {
  initialState = { count: 0, items: [] };
  
  increment() {
    // setState persists to SQLite and broadcasts to connected clients
    this.setState({ 
      ...this.state, 
      count: this.state.count + 1 
    });
  }
  
  // Direct SQL access for complex queries
  getRecentItems() {
    return this.sql<{ id: string; name: string }>`
      SELECT * FROM items 
      WHERE created_at > datetime('now', '-1 hour')
      ORDER BY created_at DESC
    `;
  }
}
```

#### State Characteristics

| Property | Behavior |
|----------|----------|
| **Consistency** | Immediate within agent (read-your-own-writes) |
| **Persistence** | Survives restarts, evictions, deployments |
| **Serialization** | Any JSON-serializable data |
| **Limit** | Up to 1 GB per agent instance |
| **Latency** | Zero-latency (colocated with agent execution) |

#### Client Synchronization

State automatically syncs to connected clients via WebSocket messages of type `"cf_agent_state"`:

```typescript
// Client-side (React)
import { useAgent } from "agents/react";

function App() {
  const { state, setState } = useAgent({
    agent: "my-agent",
    name: userId,  // Routes to specific agent instance
  });
  
  // state is automatically synchronized
  // setState updates server and other clients
}
```

#### In-Memory vs Persistent State

**Critical distinction**: Class properties (in-memory) are lost on eviction/crash; only `this.setState()` data persists.

```typescript
class MyAgent extends Agent<Env, State> {
  // VOLATILE - lost on eviction
  private cache = new Map<string, string>();
  
  // PERSISTENT - survives restarts
  initialState = { data: {} };
}
```

---

### 4. Tool/Action Definition

#### Tool Definition Pattern (with AI SDK)

Tools use Zod schemas for parameter validation:

```typescript
import { tool } from "ai";
import { z } from "zod";

// Auto-executing tool
const getCurrentTime = tool({
  description: "Get the current server time",
  parameters: z.object({
    timezone: z.string().optional().describe("IANA timezone name"),
  }),
  execute: async ({ timezone }) => {
    return new Date().toLocaleString("en-US", { timeZone: timezone });
  },
});

// Tool requiring confirmation (no execute function)
const sendEmail = tool({
  description: "Send an email to a recipient",
  parameters: z.object({
    to: z.string().email(),
    subject: z.string(),
    body: z.string(),
  }),
  // No execute = requires human confirmation
});

// Execution handler for confirmation-required tools
const executions = {
  sendEmail: async ({ to, subject, body }) => {
    await emailService.send({ to, subject, body });
    return `Email sent to ${to}`;
  },
};
```

#### Human-in-the-Loop Pattern

Tools can be wrapped to require approval before execution:

```typescript
const { issueCard } = toolkit.requireHumanInput(
  { issueCard: issueCardTool },
  {
    workflow: "approve-issued-card",
    actor: agent.name,
    recipients: ["admin_user_1"],
    metadata: {
      approve_url: `${BASE_URL}/approve`,
      reject_url: `${BASE_URL}/reject`,
    }
  }
);

// When approval webhook arrives:
if (result.interaction.status === "approved") {
  const toolCallResult = await toolkit.resumeToolExecution(result.toolCall);
}
```

State tracking prevents duplicate approvals:

```typescript
interface AgentState {
  toolCalls: Record<string, "requested" | "approved" | "rejected">;
}
```

#### MCP Integration

Agents can connect to Model Context Protocol servers for dynamic tool discovery:

```typescript
class MyAgent extends Agent<Env, State> {
  async onStart() {
    // Register MCP server
    await this.addMcpServer(
      "filesystem",
      "https://my-mcp-server.workers.dev",
      "https://my-agent.workers.dev/mcp-callback",
      "/agents"
    );
  }
  
  async getAvailableTools() {
    // Dynamically discover tools from MCP servers
    return await this.getMcpServers();
  }
}
```

---

### 5. Context Engineering Capabilities

#### Message History Access

`AIChatAgent` exposes `this.messages` containing the full conversation history:

```typescript
class ChatAgent extends AIChatAgent<Env> {
  async onChatMessage(onFinish) {
    // Full conversation history available
    console.log(this.messages);  // Array of {role, content, ...}
    
    // Persist to custom storage
    await this.saveMessages(this.messages);
  }
}
```

#### Modifying Messages Between Turns

You can modify messages before sending to the LLM:

```typescript
async onChatMessage(onFinish) {
  // Transient modification - doesn't persist
  const processedMessages = await processToolCalls({
    messages: this.messages,
    dataStream,
    tools,
    executions,
  });
  
  // Add context from database
  const relevantHistory = this.sql`
    SELECT content FROM history 
    WHERE embedding <-> ${currentEmbedding} < 0.5
    LIMIT 10
  `;
  
  const enrichedMessages = [
    { role: "system", content: `Context: ${relevantHistory.join("\n")}` },
    ...processedMessages,
  ];
  
  return streamText({
    messages: enrichedMessages,
    // ...
  });
}
```

#### Context Window Management

The SDK doesn't provide built-in context management, but enables custom implementations:

```typescript
class ChatAgent extends AIChatAgent<Env> {
  private maxContextTokens = 100000;
  
  async onChatMessage(onFinish) {
    let messages = this.messages;
    
    // Trim if context too large
    if (this.estimateTokens(messages) > this.maxContextTokens) {
      // Option 1: Truncate oldest
      messages = messages.slice(-50);
      
      // Option 2: Summarize
      const summary = await this.summarize(messages.slice(0, -10));
      messages = [
        { role: "system", content: `Previous context: ${summary}` },
        ...messages.slice(-10),
      ];
    }
    
    return streamText({ messages });
  }
}
```

#### SQL-Based Memory

Agents can use their embedded database for long-term memory:

```typescript
class MemoryAgent extends Agent<Env, State> {
  async storeMemory(content: string, embedding: number[]) {
    this.sql`
      INSERT INTO memories (content, embedding, created_at)
      VALUES (${content}, ${JSON.stringify(embedding)}, datetime('now'))
    `;
  }
  
  async retrieveRelevant(queryEmbedding: number[], limit = 5) {
    // Requires vector extension or manual similarity calculation
    return this.sql<{ content: string }>`
      SELECT content FROM memories
      ORDER BY created_at DESC
      LIMIT ${limit}
    `;
  }
}
```

---

### 6. Continuation/Resume Patterns

#### Global Addressability

Each agent instance is globally unique by ID. The same ID always routes to the same instance:

```typescript
// Routing patterns
export default {
  async fetch(request: Request, env: Env) {
    // Pattern 1: URL-based routing (/agents/:class/:name)
    return routeAgentRequest(request, env);
    
    // Pattern 2: Named lookup
    const agent = getAgentByName(env.MY_AGENT, userId);
    return agent.fetch(request);
  }
};
```

#### Resumable Streaming

`AIChatAgent` handles reconnection automatically:

```typescript
// Client disconnects mid-stream...
// Client reconnects to same agent ID...
// Stream resumes from last position automatically
```

#### Multi-Session State

State persists indefinitely (weeks/months), enabling long-running workflows:

```typescript
class WorkflowAgent extends Agent<Env, WorkflowState> {
  initialState = {
    stage: "pending",
    approvals: [],
    startedAt: null,
  };
  
  async startWorkflow(data: WorkflowData) {
    this.setState({
      ...this.state,
      stage: "awaiting_approval",
      startedAt: new Date().toISOString(),
    });
  }
  
  async receiveApproval(userId: string) {
    // Days/weeks later...
    this.setState({
      ...this.state,
      approvals: [...this.state.approvals, userId],
      stage: this.state.approvals.length >= 2 ? "approved" : "awaiting_approval",
    });
  }
}
```

#### Scheduled Continuation

Agents support scheduled method execution:

```typescript
// One-time delayed execution
await this.schedule(60, "checkStatus", { id: taskId });  // 60 seconds

// Specific time
await this.schedule(new Date("2026-12-25T00:00:00Z"), "sendGreeting", {});

// Cron-based recurring
await this.schedule("0 0 * * *", "dailyCleanup", {});  // Daily at midnight
```

---

### 7. Limitations & Tradeoffs

#### Platform Constraints (Cloudflare-Specific)

| Constraint | Limit | Impact |
|------------|-------|--------|
| **CPU time per request** | 30 seconds | Long synchronous computations impossible |
| **State size** | 1 GB per agent | Large datasets need external storage |
| **Throughput per instance** | 500-1000 req/sec | Must shard high-traffic workloads |
| **Concurrent agents** | Tens of millions | Not a practical limit |
| **Single alarm per DO** | 1 | SDK works around with SQL-based scheduling |

#### Architectural Constraints

1. **Single-threaded execution**: No parallel processing within one agent instance. CPU-bound work must be sharded across multiple agents or offloaded to Workers.

2. **No guaranteed shutdown hooks**: Agents may terminate without cleanup during deployments or inactivity. Design for recovery, not graceful shutdown.

3. **Alarm idempotency required**: Scheduled alarms may fire multiple times in edge cases. Handlers must be safe to repeat.

4. **Input gate behavior**: Non-storage I/O (fetch, LLM calls) opens the input gate, allowing concurrent requests to interleave:

```typescript
// RACE CONDITION RISK
async updateWithExternal() {
  const current = this.state.count;          // Read state
  const result = await fetch("...");          // Gate opens here!
  // Another request could modify count
  this.setState({ count: current + 1 });     // Stale data
}

// SAFE: Atomic read-modify-write
async updateSafe() {
  await this.ctx.storage.transaction(async (txn) => {
    const current = await txn.get("count");
    await txn.put("count", current + 1);
  });
}
```

5. **No cross-agent transactions**: Each agent is isolated. Coordinating state across agents requires explicit messaging and eventual consistency patterns.

#### Design Decisions That Constrain Flexibility

1. **Durable Objects foundation**: Lock-in to Cloudflare's infrastructure. No self-hosting option for the Agent SDK itself (though MCP servers can be external).

2. **WebSocket-centric**: RPC uses WebSocket messages, not HTTP. HTTP handlers are separate from the method-call pattern.

3. **State serialization**: Only JSON-serializable data. No functions, circular references, or custom class instances in state.

4. **Tool definitions server-side**: In `AIChatAgent`, tools must be defined in `onChatMessage`. Dynamic client-provided tools require custom implementation.

5. **No built-in context management**: Unlike some frameworks, there's no automatic context truncation or summarization. You implement your own strategy.

#### What You CAN'T Do Easily

- Run long synchronous computations (>30s CPU)
- Share state atomically across multiple agent instances
- Use non-JSON-serializable state (functions, Maps, Sets persist as JSON)
- Self-host the Agents SDK outside Cloudflare
- Process more than ~1000 requests/second per logical entity without sharding
- Guarantee exactly-once execution of alarms (must be idempotent)

---

### Sources

- [Cloudflare Agents Documentation](https://developers.cloudflare.com/agents/)
- [Agents API Reference](https://developers.cloudflare.com/agents/api-reference/agents-api/)
- [Agent Class Internals](https://developers.cloudflare.com/agents/concepts/agent-class/)
- [Calling Agents](https://developers.cloudflare.com/agents/api-reference/calling-agents/)
- [Configuration](https://developers.cloudflare.com/agents/api-reference/configuration/)
- [Store and Sync State](https://developers.cloudflare.com/agents/api-reference/store-and-sync-state/)
- [Platform Limits](https://developers.cloudflare.com/agents/platform/limits/)
- [Using AI Models](https://developers.cloudflare.com/agents/api-reference/using-ai-models/)
- [Model Context Protocol](https://developers.cloudflare.com/agents/model-context-protocol/)
- [Workflows](https://developers.cloudflare.com/agents/concepts/workflows/)
- [Human in the Loop](https://developers.cloudflare.com/agents/concepts/human-in-the-loop/)
- [Tools Concept](https://developers.cloudflare.com/agents/concepts/tools/)
- [Rules of Durable Objects](https://developers.cloudflare.com/durable-objects/best-practices/rules-of-durable-objects/)
- [GitHub: cloudflare/agents](https://github.com/cloudflare/agents)
- [GitHub: cloudflare/agents-starter](https://github.com/cloudflare/agents-starter)
- [Blog: Making Cloudflare the best platform for building AI Agents](https://blog.cloudflare.com/build-ai-agents-on-cloudflare/)
- [Blog: Building AI agents with Knock and Cloudflare's Agents SDK](https://blog.cloudflare.com/building-agents-at-knock-agents-sdk/)
Now I'll compile the additional research into a continuation document.

---

## Research Appendix: Cloudflare Agents API Surface (Continued)

### 8. RPC & Method Invocation

#### @callable Decorator

The Agents SDK enables remote procedure calls (RPC) through WebSockets using the `@callable` decorator. This allows clients to invoke agent methods directly:

```typescript
class MyAgent extends Agent<Env, State> {
  @callable({ description: "Add two numbers" })
  async add(a: number, b: number): Promise<number> {
    return a + b;
  }
  
  @callable({ 
    description: "Generate a report",
    stream: true  // Enable streaming responses
  })
  async *generateReport(topic: string): AsyncGenerator<string> {
    for (const section of reportSections) {
      yield await this.processSectionStream(section, topic);
    }
  }
}
```

#### Client-Side RPC

From JavaScript clients, call methods using agent stubs:

```typescript
// Server-side invocation
const agent = getAgentByName(env.MyAgent, "unique-id");
const result = await agent.add(2, 3);  // Returns 5

// Client-side via WebSocket
import { useAgent } from "agents/react";

function Calculator() {
  const agent = useAgent({ agent: "my-agent", name: userId });
  
  async function calculate() {
    // Send RPC message
    agent.send(JSON.stringify({
      type: "rpc",
      method: "add",
      args: [2, 3]
    }));
  }
}
```

#### Streaming RPC Responses

Methods marked with `stream: true` return AsyncGenerators, enabling progressive responses:

```typescript
@callable({ stream: true })
async *streamData(): AsyncGenerator<DataChunk> {
  for await (const chunk of this.processLargeDataset()) {
    yield chunk;
  }
}
```

---

### 9. HTTP & Server-Sent Events (SSE)

#### HTTP Request Handling

Agents handle HTTP requests via the `onRequest` lifecycle hook:

```typescript
class APIAgent extends Agent<Env, State> {
  async onRequest(request: Request): Promise<Response> {
    const url = new URL(request.url);
    
    if (url.pathname === "/api/status") {
      return Response.json({ 
        status: "active",
        state: this.state 
      });
    }
    
    if (url.pathname === "/api/stream" && request.method === "POST") {
      return this.handleStreamRequest(request);
    }
    
    return new Response("Not Found", { status: 404 });
  }
}
```

#### agentFetch for Client Communication

The SDK provides `agentFetch()` for making HTTP requests to agents from browsers:

```typescript
import { agentFetch } from "agents/client";

async function fetchAgentData(userId: string) {
  const response = await agentFetch(
    {
      agent: "task-manager",      // Agent class name
      name: `user-${userId}`,     // Specific instance
    },
    {
      method: "GET",
      headers: {
        "Authorization": `Bearer ${token}`,
      },
    }
  );
  
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }
  
  return await response.json();
}
```

#### Server-Sent Events (SSE)

SSE enables unidirectional streaming from agent to client over HTTP:

```typescript
class StreamingAgent extends Agent<Env, State> {
  async onRequest(request: Request): Promise<Response> {
    // Stream AI response via SSE
    const stream = await this.callAIModel(prompt);
    
    return stream.toTextStreamResponse({
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
      },
    });
  }
}
```

**Key SSE characteristics**:
- **No time limit**: Unlike typical HTTP requests, SSE streams can run for hours
- **HTTP-based**: Works through firewalls and proxies
- **Server-to-client only**: For bidirectional communication, use WebSockets
- **Automatic reconnection**: Browsers reconnect on connection loss

---

### 10. Workflows Integration

#### Durable Execution for Long-Running Tasks

Workflows complement Agents by providing guaranteed execution for multi-step background processes:

```typescript
import { WorkflowEntrypoint } from "cloudflare:workers";

export class DataPipelineWorkflow extends WorkflowEntrypoint {
  async run(event, step) {
    // Each step persists state automatically
    const rawData = await step.do("fetch", async () => {
      return await fetchFromExternalAPI();
    });
    
    // Failures retry this step only, not previous steps
    const processed = await step.do("process", async () => {
      return transformData(rawData);
    });
    
    // Sleep for hours/days without consuming resources
    await step.sleep("6 hours");
    
    // Continue execution
    await step.do("notify", async () => {
      await sendNotification(processed);
    });
  }
}
```

#### Agent-Workflow Communication

**AgentWorkflow** enables bidirectional communication:

```typescript
import { AgentWorkflow } from "agents/workflows";

export class ReportGenerationWorkflow extends AgentWorkflow {
  async run(event, step) {
    const items = event.payload.items;
    
    for (let i = 0; i < items.length; i++) {
      // Process each item durably
      await step.do(`process-${i}`, async () => {
        return processItem(items[i]);
      });
      
      // Report progress to Agent (broadcasts to clients)
      await this.reportProgress({
        percent: ((i + 1) / items.length) * 100,
        message: `Processed ${i + 1}/${items.length}`,
      });
    }
    
    // Update Agent state (persistent, broadcast to clients)
    await step.mergeAgentState({ 
      lastReportCompleted: new Date().toISOString() 
    });
  }
}
```

#### Durable vs Non-Durable Operations

| Operation | Durability | Semantics |
|-----------|-----------|-----------|
| `step.do()` | Durable | Exactly-once execution |
| `step.updateAgentState()` | Durable | Persistent state changes |
| `step.mergeAgentState()` | Durable | Partial state updates |
| `this.reportProgress()` | Non-durable | May repeat on retry |
| `this.broadcastToClients()` | Non-durable | May repeat on retry |

**Critical**: Non-durable operations may execute multiple times if the workflow retries.

#### Triggering Workflows from Agents

```typescript
class MyAgent extends Agent<Env, State> {
  async startReport(data: ReportData) {
    // Launch durable workflow
    const workflowId = await this.env.WORKFLOWS.create({
      workflow: "report-generation",
      params: { items: data.items },
    });
    
    this.setState({ 
      currentWorkflowId: workflowId,
      workflowStatus: "running" 
    });
  }
}
```

---

### 11. Task Queue System

#### Built-In Queue for Background Work

Agents include a task queue for deferred, sequential execution:

```typescript
class EmailAgent extends Agent<Env, State> {
  async handleNewMessage(message: Message) {
    // Enqueue without blocking
    await this.queue("processMessage", { 
      messageId: message.id,
      userId: message.from 
    });
    
    // Returns immediately
    return { status: "queued" };
  }
  
  // Callback executed in background
  async processMessage(
    payload: { messageId: string; userId: string },
    queueItem: QueueItem
  ) {
    const message = await this.fetchMessage(payload.messageId);
    const response = await this.generateAIResponse(message);
    await this.sendEmail(payload.userId, response);
  }
}
```

#### Queue Characteristics

- **Sequential execution**: Next task waits until previous completes
- **Non-blocking enqueue**: `queue()` returns immediately
- **Persistent**: Tasks survive agent restarts
- **Automatic dequeue**: Successful completion removes task
- **Failed tasks**: Remain in queue for manual handling

#### Queue Inspection & Management

```typescript
class TaskManager extends Agent<Env, State> {
  async getQueueStatus() {
    // Get specific queue
    const emailQueue = await this.getQueue("processEmail");
    
    // Get all queues
    const allQueues = await this.getQueues();
    
    return { emailQueue, allQueues };
  }
  
  async clearFailedTasks() {
    // Dequeue specific callback
    await this.dequeueAllByCallback("processEmail");
    
    // Clear all queues
    await this.dequeueAll();
  }
}
```

---

### 12. React Hooks API

#### useAgent Hook

Establishes WebSocket connection with state synchronization:

```typescript
import { useAgent } from "agents/react";

function AgentInterface() {
  const { state, setState, send, connection } = useAgent({
    agent: "task-manager",           // Agent class name
    name: userId,                     // Instance identifier
    onMessage: (message) => {
      console.log("Received:", message.data);
    },
    onOpen: () => console.log("Connected"),
    onClose: () => console.log("Disconnected"),
    onError: (error) => console.error(error),
  });
  
  // state auto-syncs with server
  // setState updates server + other clients
  
  return (
    <div>
      <p>Server state: {JSON.stringify(state)}</p>
      <button onClick={() => setState({ count: state.count + 1 })}>
        Increment
      </button>
    </div>
  );
}
```

#### useAgentChat Hook

Specialized hook for chat applications:

```typescript
import { useAgent } from "agents/react";
import { useAgentChat } from "agents/ai-react";

function ChatApp() {
  const agent = useAgent({ agent: "chat-agent", name: userId });
  
  const {
    messages,          // Array of chat messages
    input,             // Current input value
    handleInputChange, // Input onChange handler
    handleSubmit,      // Form onSubmit handler
    clearHistory,      // Clear message history
    isLoading,         // Streaming in progress
  } = useAgentChat({
    agent,
    maxSteps: 5,       // Max tool calls per turn
  });
  
  return (
    <div className="chat-container">
      <div className="messages">
        {messages.map((msg) => (
          <div key={msg.id} className={`message ${msg.role}`}>
            {msg.content}
          </div>
        ))}
      </div>
      
      <form onSubmit={handleSubmit}>
        <input 
          value={input}
          onChange={handleInputChange}
          disabled={isLoading}
        />
        <button type="submit" disabled={isLoading}>
          Send
        </button>
      </form>
    </div>
  );
}
```

---

### 13. Email Integration

#### Receiving Emails

Agents can receive emails through Cloudflare Email Routing:

```typescript
import { PostalMime } from "postal-mime";

class EmailAgent extends Agent<Env, State> {
  async onEmail(email: AgentEmail) {
    // Parse email
    const raw = await email.getRaw();
    const parsed = await PostalMime.parse(raw);
    
    // Extract details
    const from = email.headers.get("from");
    const subject = email.headers.get("subject");
    const body = parsed.text || parsed.html;
    
    // Process with AI
    const response = await this.generateResponse(body);
    
    // Send reply
    await this.replyToEmail(email, {
      fromName: "Support Bot",
      subject: `Re: ${subject}`,
      body: response,
    });
  }
}
```

#### Email Routing Configuration

```typescript
// Worker email handler
export default {
  async email(email: ForwardableEmailMessage, env: Env) {
    // Route to agent based on email address
    await routeAgentEmail(email, env, {
      resolver: createAddressBasedEmailResolver("EmailAgent"),
    });
  },
};
```

#### Sending Emails

```typescript
class NotificationAgent extends Agent<Env, State> {
  async sendAlert(userId: string, message: string) {
    const userEmail = await this.getUserEmail(userId);
    
    await this.replyToEmail(null, {
      to: userEmail,
      fromName: "Alert System",
      subject: "Important Alert",
      body: message,
      // Optional: CC, BCC, attachments
    });
  }
}
```

---

### 14. Context Tracking (AsyncLocalStorage)

#### getCurrentAgent() Helper

The SDK wraps methods with `AsyncLocalStorage` for context access anywhere:

```typescript
import { getCurrentAgent } from "agents";

// Utility function deep in call stack
async function logCurrentState() {
  const { agent, connection, request, email } = getCurrentAgent();
  
  if (agent) {
    console.log("Agent state:", agent.state);
  }
  
  if (connection) {
    console.log("WebSocket connection:", connection.id);
  }
  
  if (request) {
    console.log("HTTP request:", request.url);
  }
  
  if (email) {
    console.log("Email from:", email.headers.get("from"));
  }
}

// Called from agent method - no explicit context passing needed
class MyAgent extends Agent<Env, State> {
  async processData() {
    await someUtility();  // Can call getCurrentAgent() internally
  }
}
```

#### Context Structure

```typescript
interface AgentContext {
  agent: Agent<any, any>;         // Current agent instance
  connection?: Connection;         // WebSocket connection (if applicable)
  request?: Request;               // HTTP request (if applicable)
  email?: AgentEmail;              // Email message (if applicable)
}
```

This eliminates "context passing" boilerplate, enabling cleaner utility functions and middleware.

---

### 15. Cleanup & Destruction

#### destroy() Method

Completely wipes an agent instance:

```typescript
class TemporaryAgent extends Agent<Env, State> {
  async completeTask(taskId: string) {
    // Perform final work
    await this.finishTask(taskId);
    
    // Destroy agent instance
    await this.destroy();
    
    // After this:
    // - All tables dropped (cf_agents_state, cf_agents_schedules, etc.)
    // - All alarms deleted
    // - All storage cleared
    // - Context aborted (agent evicted)
  }
}
```

#### Safe Destruction from Scheduled Tasks

```typescript
class CleanupAgent extends Agent<Env, State> {
  async onStart() {
    // Schedule self-destruction
    await this.schedule(
      new Date(Date.now() + 86400000),  // 24 hours
      "selfDestruct",
      {}
    );
  }
  
  async selfDestruct() {
    console.log("Cleaning up...");
    
    // Safe to call from schedule callback
    await this.destroy();
    // Agent sets flag to skip DB updates
    // Yields to event loop before abort
  }
}
```

#### Known Limitation

There's a documented bug with immediate re-initialization after destruction. If you destroy an agent and immediately access the same ID, SQLite tables may not be fully stable. **Workaround**: Use different agent IDs or add delay before re-access.

---

### 16. Observability & Monitoring

#### Built-In Workers Observability

Agents inherit Cloudflare Workers' observability features:

**Configuration (wrangler.toml)**:
```toml
[observability]
enabled = true

[observability.traces]
enabled = true
```

#### Logging

Standard console methods write to Workers Logs:

```typescript
class MonitoredAgent extends Agent<Env, State> {
  async processRequest(data: RequestData) {
    console.log("Processing request", { 
      agentId: this.name,
      dataSize: data.items.length 
    });
    
    try {
      const result = await this.process(data);
      console.info("Success", { resultId: result.id });
      return result;
    } catch (error) {
      console.error("Processing failed", { 
        error: error.message,
        stack: error.stack 
      });
      throw error;
    }
  }
}
```

#### Tracing (OpenTelemetry)

Cloudflare Workers support OpenTelemetry traces:

- Automatically tracks request lifecycle
- Compatible with Honeycomb, Grafana Cloud, Axiom
- Custom spans for detailed instrumentation
- Currently free during beta (paid after March 1, 2026)

#### Analytics Engine

For custom metrics and business analytics:

```typescript
class AnalyticsAgent extends Agent<Env, State> {
  async trackToolUsage(toolName: string, duration: number) {
    // Write to Analytics Engine
    this.env.ANALYTICS.writeDataPoint({
      blobs: [toolName, this.name],
      doubles: [duration],
      indexes: [toolName],  // For querying
    });
  }
}
```

#### Third-Party Integrations

Cloudflare has partnerships with:
- Datadog
- Honeycomb
- New Relic
- Sentry
- Splunk
- Sumo Logic

---

### 17. Workers AI Integration

#### Direct Model Access

Agents can call Cloudflare's Workers AI models:

```typescript
import { createWorkersAI } from "workers-ai-provider";

class AIAgent extends AIChatAgent<Env> {
  async onChatMessage(onFinish) {
    const workersAI = createWorkersAI({
      binding: this.env.AI,
    });
    
    return createDataStreamResponse({
      execute: async (dataStream) => {
        const stream = streamText({
          model: workersAI("@cf/meta/llama-3.3-70b-instruct-fp8-fast"),
          system: "You are helpful.",
          messages: this.messages,
          onFinish,
          maxSteps: 5,
        });
        
        stream.mergeIntoDataStream(dataStream);
      },
    });
  }
}
```

#### Structured Output Support

Workers AI models support JSON mode:

```typescript
const response = await this.env.AI.run(
  "@cf/meta/llama-3.1-8b-instruct",
  {
    messages: [{ role: "user", content: prompt }],
    response_format: {
      type: "json_schema",
      json_schema: {
        name: "user_info",
        schema: {
          type: "object",
          properties: {
            name: { type: "string" },
            age: { type: "number" },
          },
          required: ["name", "age"],
        },
      },
    },
  }
);
```

#### Streaming Support

All LLMs on Workers AI support streaming via Server-Sent Events:

```typescript
const stream = await this.env.AI.run(
  "@cf/meta/llama-3.1-8b-instruct",
  {
    messages: [{ role: "user", content: prompt }],
    stream: true,  // Enable SSE streaming
  }
);

for await (const chunk of stream) {
  console.log(chunk);
}
```

#### AI Gateway Integration

Route AI calls through AI Gateway for caching, rate limiting, and observability:

```typescript
import { createAIGateway } from "ai-gateway-provider";

const gateway = createAIGateway({
  accountId: env.CLOUDFLARE_ACCOUNT_ID,
  gatewayId: "my-gateway",
  apiKey: env.CLOUDFLARE_API_KEY,
});

const stream = streamText({
  model: gateway("openai:gpt-4"),  // Routes through gateway
  messages: this.messages,
});
```

---

### 18. Configuration & Deployment

#### SQLite Migration Requirement

**Critical**: Agents require a migration configuration with `new_sqlite_classes`:

```toml
# wrangler.toml
[[migrations]]
tag = "v1"
new_sqlite_classes = ["MyAgent"]
```

**Important constraints**:
- Cannot enable SQLite on existing Durable Objects (must be set from first deployment)
- Cannot change this setting in later migrations
- Automatic migration from KV to SQLite planned but not yet available

#### Environment Variables

```toml
[env.production.vars]
OPENAI_API_KEY = ""  # Placeholder - use secrets

[env.production]
# Secrets set via CLI
# wrangler secret put OPENAI_API_KEY
```

#### Full Configuration Example

```toml
name = "my-ai-agent"
main = "src/server.ts"
compatibility_date = "2026-02-04"
compatibility_flags = ["nodejs_compat"]

[durable_objects]
bindings = [
  { name = "CHAT_AGENT", class_name = "ChatAgent" },
  { name = "TASK_AGENT", class_name = "TaskAgent" },
]

[[migrations]]
tag = "v1"
new_sqlite_classes = ["ChatAgent", "TaskAgent"]

[observability]
enabled = true

[[ai]]
binding = "AI"

[[workflows]]
binding = "WORKFLOWS"
class_name = "ReportWorkflow"
```

---

### 19. Performance Characteristics

#### Cold Start Performance

Cloudflare Workers (which Agents run on) achieve:
- **<5ms cold starts** using isolate technology
- **99.99% warm request rate** via "Shard and Conquer" consistent hashing
- **Effective zero cold starts** for HTTPS requests (warmed during TLS handshake)

#### Latency

- **Agent state access**: Zero-latency (colocated SQLite)
- **Cross-agent communication**: Network round-trip (regional latency)
- **AI inference**: Depends on model (Workers AI: 190+ global locations)

#### Throughput Limits (Per Agent Instance)

| Metric | Limit | Notes |
|--------|-------|-------|
| Requests/second | 500-1,000 | Varies by operation complexity |
| CPU time/request | 30 seconds | Refreshes per message |
| State size | 1 GB | Per agent instance |
| Concurrent connections | Unlimited | WebSockets scale horizontally |

**Scaling strategy**: Shard workloads across multiple agent instances (different IDs), not vertically within one instance.

---

### Additional Sources

- [Agents API Reference](https://developers.cloudflare.com/agents/api-reference/agents-api/)
- [HTTP and Server-Sent Events](https://developers.cloudflare.com/agents/api-reference/http-sse/)
- [Cloudflare Workflows Overview](https://developers.cloudflare.com/workflows/)
- [Workflows Guide](https://developers.cloudflare.com/workflows/get-started/guide/)
- [Workers Observability](https://developers.cloudflare.com/workers/observability/)
- [Workers AI](https://developers.cloudflare.com/workers-ai/)
- [AsyncLocalStorage](https://developers.cloudflare.com/workers/runtime-apis/nodejs/asynclocalstorage/)
- [Durable Objects Migrations](https://developers.cloudflare.com/durable-objects/reference/durable-objects-migrations/)
- [Rules of Workflows](https://developers.cloudflare.com/workflows/build/rules-of-workflows/)
- [Agents SDK Changelog - MCP & Task Queues](https://developers.cloudflare.com/changelog/2025-08-05-agents-mcp-update/)
- [Agents SDK Changelog - npm package](https://developers.cloudflare.com/changelog/2025-03-18-npm-i-agents/)
- [Agents SDK Changelog - Resumable Streaming](https://developers.cloudflare.com/changelog/2025-11-26-agents-resumable-streaming/)
- [Building Agents at Knock (Human-in-the-Loop)](https://blog.cloudflare.com/building-agents-at-knock-agents-sdk/)
- [Making Cloudflare the Best Platform for AI Agents](https://blog.cloudflare.com/build-ai-agents-on-cloudflare/)
- [Workflows GA: Production-Ready Durable Execution](https://blog.cloudflare.com/workflows-ga-production-ready-durable-execution/)
- [Workers Observability Launch](https://blog.cloudflare.com/introducing-workers-observability-logs-metrics-and-queries-all-in-one-place/)
- [Eliminating Cold Starts](https://blog.cloudflare.com/eliminating-cold-starts-2-shard-and-conquer/)
