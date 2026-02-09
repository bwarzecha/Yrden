# Context Engineering & Message Modification: Cross-SDK Analysis

**Date:** February 4, 2026
**Analysis of:** OpenAI Agents SDK, Claude Agent SDK, Cloudflare Agents, Vercel AI SDK, LangGraph, PydanticAI, Microsoft AutoGen, CrewAI

---

## Executive Summary

This document provides a comprehensive comparison of **context engineering capabilities** across 8 major agent frameworks. Context engineering refers to the ability to inspect, modify, and manage conversation history (message arrays) before, during, and after LLM interactions.

### Key Findings

1. **Most frameworks provide observation-only hooks** - only 4 frameworks (LangGraph, Cloudflare, PydanticAI, Vercel AI) support meaningful message modification
2. **Only 2 frameworks provide automatic context management** - CrewAI and AutoGen handle token limits automatically
3. **LangGraph and PydanticAI are the most flexible** - state mutation and history processors respectively
4. **OpenAI Agents and Claude SDK prioritize safety over flexibility** - read-only hooks, no direct history access
5. **Token management is mostly manual** - most frameworks require custom implementations

### Critical Distinctions

| Capability | Supported By | Not Supported By |
|------------|--------------|------------------|
| **Direct message array modification** | LangGraph, Cloudflare, Vercel AI (via prepareStep) | OpenAI Agents, Claude SDK, CrewAI, AutoGen |
| **Declarative history transformation** | PydanticAI (history_processors) | All others |
| **Automatic context window management** | CrewAI, AutoGen | OpenAI, Claude, LangGraph, PydanticAI, Vercel, Cloudflare |
| **Mid-execution pause/resume** | LangGraph (interrupt), PydanticAI (iter) | OpenAI, Claude, CrewAI, AutoGen |
| **Selective message deletion** | LangGraph (RemoveMessage), Cloudflare | OpenAI, Claude, CrewAI, AutoGen |

---

## 1. Modification Capabilities Matrix

This matrix shows **what can be modified at each stage** of agent execution:

| SDK | Before LLM Call | After LLM Response | Mid-Turn (Tool Execution) | Between Turns | Tool Arguments |
|-----|-----------------|-------------------|--------------------------|---------------|----------------|
| **OpenAI Agents** | ❌ Read-only hooks | ❌ Read-only hooks | ❌ No access | ⚠️ Via `result.to_input_list()` | ❌ No modification |
| **Claude Agent SDK** | ❌ Observe only | ❌ Observe only | ⚠️ Can modify tool input | ❌ No direct access | ✅ PreToolUse hook |
| **Cloudflare Agents** | ✅ Mutate `this.messages` | ✅ Mutate `this.messages` | ✅ Mutate `this.messages` | ✅ Mutate `this.messages` | ✅ Direct access |
| **Vercel AI SDK** | ✅ `prepareStep` callback | ❌ No hooks | ⚠️ Via `prepareStep` | ⚠️ Manual implementation | ⚠️ Via `prepareStep` |
| **LangGraph** | ✅ Node functions | ✅ Node functions | ✅ Node functions | ✅ State management | ✅ Full control |
| **PydanticAI** | ✅ `history_processors` | ❌ No direct access | ⚠️ Via `ModelRetry` | ✅ `history_processors` | ⚠️ Via retries |
| **AutoGen** | ⚠️ `TransformMessages` | ⚠️ `TransformMessages` | ❌ No direct access | ✅ State save/load | ❌ No direct access |
| **CrewAI** | ⚠️ Can append via `@before_llm_call` | ⚠️ Transform via `@after_llm_call` | ❌ No access | ⚠️ Hooks only | ❌ No direct access |

**Legend:**
- ✅ Full support with clean API
- ⚠️ Partial support or requires workarounds
- ❌ Not supported

---

## 2. Hook System Deep Dive

### 2.1 OpenAI Agents SDK - Observation Only

**Architecture:** Event-driven, read-only hooks

**Available Hooks:**
```python
@AgentHooks.on_agent_start
async def on_agent_start(context: AgentStartContext) -> None:
    # Read-only: cannot modify context
    logger.info(f"Starting agent with {len(context.messages)} messages")

@AgentHooks.on_tool_end
async def on_tool_end(context: ToolEndContext) -> None:
    # Read-only: cannot modify tool result
    logger.info(f"Tool {context.tool_name} returned: {context.result}")

@AgentHooks.on_agent_end
async def on_agent_end(context: AgentEndContext) -> None:
    # Read-only: cannot modify final response
    logger.info(f"Agent completed with {context.usage.total_tokens} tokens")
```

**Modification Pattern (Workaround):**
```python
# Must use call_model_input_filter for any modification
def my_filter(input_list: list[dict]) -> list[dict]:
    # Only place to modify messages
    modified = []
    for msg in input_list:
        if msg["role"] == "user":
            modified.append({"role": "system", "content": "Context: ..."})
        modified.append(msg)
    return modified

# Apply during run call
result = await session.run(
    call_model_input_filter=my_filter
)
```

**Limitations:**
- Hooks cannot return modified data
- Filter runs only once at start, not per-turn
- No access to intermediate state during tool execution
- Manual history management via `result.to_input_list()`

**Use Cases Enabled:**
- Logging and observability
- Token counting
- Error handling
- Request/response validation

**Use Cases NOT Enabled:**
- Selective message deletion
- Mid-execution context injection
- Dynamic context pruning
- Progressive summarization

---

### 2.2 Claude Agent SDK - Block/Allow Pattern

**Architecture:** Lifecycle hooks with approval capability

**Available Hooks:**
```typescript
const agent = new Agent({
  // Before tool execution
  preToolUse: async (args) => {
    const { agentId, toolInput, toolName } = args;

    // Can return modified tool input
    if (toolName === "search" && toolInput.query.length > 100) {
      return {
        ...toolInput,
        query: toolInput.query.slice(0, 100)
      };
    }

    // Or block execution
    throw new Error("Tool not allowed");
  },

  // After tool execution
  postToolUse: async (args) => {
    // Read-only: cannot modify result
    console.log(`Tool ${args.toolName} completed`);
  }
});
```

**Modification Pattern:**
```typescript
// Cannot modify message history directly
// Workaround: Add system message for feedback
const response = await agent.run({
  input: userInput,
  // This adds to messages but doesn't modify existing
  systemMessage: "Additional context based on previous turn"
});
```

**Limitations:**
- Cannot access or modify message array directly
- Hooks are tool-focused, not message-focused
- No inter-turn state management exposed
- Automatic persistence (can't opt out)

**Use Cases Enabled:**
- Tool input validation and sanitization
- Tool execution approval (human-in-the-loop)
- Tool result logging

**Use Cases NOT Enabled:**
- Message history manipulation
- Context window management
- Selective message removal
- Token budget enforcement

---

### 2.3 Cloudflare Agents - Full Mutation

**Architecture:** Imperative with direct state access

**Available Hooks:**
```typescript
class MyAgent extends Agent {
  async onChatMessage(message: Message): Promise<void> {
    // Full access to mutable message array

    // 1. Inspect history
    const messageCount = this.messages.length;

    // 2. Prune old messages
    if (messageCount > 20) {
      // Keep system message + last 19 messages
      const systemMsg = this.messages[0];
      const recentMsgs = this.messages.slice(-19);
      this.messages = [systemMsg, ...recentMsgs];
    }

    // 3. Inject context
    if (this.messages.some(m => m.content.includes("urgent"))) {
      this.messages.splice(1, 0, {
        role: "system",
        content: "Priority: High urgency request detected"
      });
    }

    // 4. Update state
    this.setState({ lastMessageAt: Date.now() });
  }

  async onToolResult(name: string, result: any): Promise<void> {
    // Can modify messages after tool execution
    const lastMessage = this.messages[this.messages.length - 1];
    if (lastMessage.role === "tool") {
      // Append metadata
      lastMessage.content += `\n[Processed at ${new Date().toISOString()}]`;
    }
  }
}
```

**State Management:**
```typescript
// Persisted across requests
this.setState({
  conversationSummary: "...",
  tokenCount: 1500,
  lastPruneAt: Date.now()
});

// Retrieve state
const state = this.getState();
if (state.tokenCount > 10000) {
  // Trigger summarization
}
```

**Limitations:**
- Very imperative, requires discipline
- No built-in token counting
- Manual persistence management
- Risk of state inconsistency

**Use Cases Enabled:**
- Complete message history control
- Custom pruning strategies
- Dynamic context injection
- Stateful conversations with persistence
- Real-time modifications during execution

**Use Cases NOT Enabled:**
- Declarative transformations (all imperative)
- Automatic token management

---

### 2.4 Vercel AI SDK - Step Preparation

**Architecture:** Callback before each step

**Hook:**
```typescript
const result = await agent.run({
  prompt: "Analyze sales data",

  // Called before EACH step (including tool calls)
  prepareStep: async ({ step, messages, tools }) => {
    // Can return modified messages
    const modifiedMessages = [...messages];

    // Example: Inject recent context
    if (step.stepType === "tool-call") {
      modifiedMessages.push({
        role: "system",
        content: `Current step: ${step.stepNumber}. Be concise.`
      });
    }

    // Example: Prune old messages
    if (modifiedMessages.length > 50) {
      const systemMsgs = modifiedMessages.filter(m => m.role === "system");
      const recentMsgs = modifiedMessages.slice(-40);
      return {
        messages: [...systemMsgs, ...recentMsgs],
        tools // Can also modify tools per-step
      };
    }

    return { messages: modifiedMessages, tools };
  }
});
```

**Known Issues (from research):**
- `prepareStep` doesn't always trigger as expected
- Tool messages sometimes bypass the callback
- No post-step hooks for observation

**Limitations:**
- Only one callback (no separation of concerns)
- Runs before every step (can't skip)
- No access to previous step results in callback
- Must return full messages array each time

**Use Cases Enabled:**
- Per-step context injection
- Progressive message pruning
- Dynamic tool selection
- Step-specific prompting

**Use Cases NOT Enabled:**
- Post-step modifications
- Selective step skipping
- Read-only observation hooks

---

### 2.5 LangGraph - Full Control via State

**Architecture:** Graph nodes with state mutation

**Pattern:**
```python
from langchain_core.messages import RemoveMessage, trim_messages

def manage_context(state: MessagesState) -> dict:
    """Node that modifies conversation history"""

    # 1. Access full message list
    messages = state["messages"]

    # 2. Selective deletion by ID
    to_remove = [
        RemoveMessage(id=msg.id)
        for msg in messages
        if msg.role == "system" and msg.created_at < cutoff
    ]

    # 3. Token-based trimming
    trimmed = trim_messages(
        messages,
        strategy="last",
        token_counter=len,  # or tiktoken
        max_tokens=4000,
        start_on="human",
        end_on=["human", "tool"],
        include_system=True
    )

    # 4. Summarization
    if len(messages) > 100:
        old_messages = messages[:80]
        summary = llm.invoke([
            {"role": "system", "content": "Summarize this conversation"},
            *old_messages
        ])
        trimmed = [
            {"role": "system", "content": f"Summary: {summary.content}"},
            *messages[80:]
        ]

    return {"messages": to_remove + trimmed}

# Wire into graph
graph = StateGraph(MessagesState)
graph.add_node("manage_context", manage_context)
graph.add_node("agent", agent_node)
graph.add_edge("manage_context", "agent")
```

**Interrupt/Resume Pattern:**
```python
def approval_node(state: MessagesState):
    """Pause for human approval"""
    last_message = state["messages"][-1]
    if last_message.role == "tool":
        # Pause execution
        raise NodeInterrupt(f"Approve tool result: {last_message.content}")

# On resume
config = {"configurable": {"thread_id": "abc123"}}
for event in app.stream(Command(resume="approved"), config):
    print(event)
```

**Limitations:**
- High complexity (graph construction, supersteps, etc.)
- No built-in token counting
- Manual checkpoint management for persistence
- Requires understanding of state reducers

**Use Cases Enabled:**
- Complete message history control
- Selective message deletion by ID
- Token-based trimming with multiple strategies
- Summarization workflows
- Human-in-the-loop with pause/resume
- Multi-agent context sharing

**Use Cases NOT Enabled:**
- Simple, declarative API (very imperative)
- Automatic context management

---

### 2.6 PydanticAI - Declarative History Processors

**Architecture:** Pure functions that transform message arrays

**Pattern:**
```python
from pydantic_ai import Agent, AgentContext
from pydantic_ai.messages import Message, ModelRequestPart

def keep_recent(n: int):
    """Keep only the last N messages"""
    def processor(messages: list[Message]) -> list[Message]:
        if len(messages) <= n:
            return messages
        # Keep system messages + last N user/assistant
        system_msgs = [m for m in messages if m.role == "system"]
        recent = [m for m in messages if m.role != "system"][-n:]
        return system_msgs + recent
    return processor

def summarize_old(threshold: int = 50):
    """Summarize messages beyond threshold"""
    async def processor(messages: list[Message], ctx: AgentContext) -> list[Message]:
        if len(messages) <= threshold:
            return messages

        # Summarize old messages
        old = messages[:threshold-10]
        recent = messages[threshold-10:]

        summary_prompt = "Summarize this conversation concisely:\n"
        summary_prompt += "\n".join(str(m) for m in old)

        summary = await ctx.agent.llm.invoke([
            {"role": "system", "content": summary_prompt}
        ])

        return [
            Message(role="system", content=f"Summary: {summary}"),
            *recent
        ]
    return processor

def enforce_token_limit(max_tokens: int):
    """Enforce token budget"""
    def processor(messages: list[Message]) -> list[Message]:
        total_tokens = sum(count_tokens(m.content) for m in messages)

        if total_tokens <= max_tokens:
            return messages

        # Truncate from oldest
        kept = []
        current_tokens = 0
        for msg in reversed(messages):
            msg_tokens = count_tokens(msg.content)
            if current_tokens + msg_tokens > max_tokens:
                break
            kept.insert(0, msg)
            current_tokens += msg_tokens

        return kept
    return processor

# Compose processors
agent = Agent(
    model="anthropic:claude-sonnet",
    history_processors=[
        keep_recent(30),
        summarize_old(threshold=50),
        enforce_token_limit(max_tokens=100_000)
    ]
)

# Processors run BEFORE EVERY LLM request
result = await agent.run("Analyze Q4 sales")
```

**Advanced Pattern - PII Redaction:**
```python
import re

def redact_pii():
    """Remove personally identifiable information"""
    patterns = {
        "email": r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b',
        "phone": r'\b\d{3}[-.]?\d{3}[-.]?\d{4}\b',
        "ssn": r'\b\d{3}-\d{2}-\d{4}\b'
    }

    def processor(messages: list[Message]) -> list[Message]:
        redacted = []
        for msg in messages:
            content = msg.content
            for pii_type, pattern in patterns.items():
                content = re.sub(pattern, f"[REDACTED_{pii_type.upper()}]", content)

            redacted.append(Message(
                role=msg.role,
                content=content,
                metadata={"pii_redacted": True}
            ))
        return redacted

    return processor

# Add to agent
agent = Agent(
    model="openai:gpt-4",
    history_processors=[redact_pii(), keep_recent(20)]
)
```

**Limitations:**
- Processors run on EVERY LLM request (can't skip)
- No access to agent state within processors (except via context)
- Cannot directly modify messages in place (must return new list)
- Async processors have limited capabilities

**Use Cases Enabled:**
- Declarative, composable transformations
- Token budget enforcement
- PII redaction
- Progressive summarization
- Message filtering and pruning
- Format transformations

**Use Cases NOT Enabled:**
- Conditional processing (runs every time)
- Stateful transformations (processors are pure functions)
- Mid-execution modifications

---

### 2.7 Microsoft AutoGen - Transform Messages

**Architecture:** Message transformers with state management

**Pattern:**
```python
from autogen import ConversableAgent, GroupChat
from autogen.agentchat.contrib.capabilities import transform_messages, transforms

# Built-in transformer for compression
llm_lingua = transforms.TextMessageCompressor(
    min_length=10000,  # Only compress if > 10k chars
    compression_params={
        "target_token": 4000,
        "use_context_level_filter": True
    }
)

agent = ConversableAgent(
    name="assistant",
    llm_config={"model": "gpt-4"},
    # Add transformer capability
    capabilities=[transform_messages.TransformMessages(
        transforms=[llm_lingua]
    )]
)

# Custom transformer
class CustomTransform(MessageTransform):
    def apply_transform(self, messages: list[dict]) -> list[dict]:
        # Keep only last 20 messages
        if len(messages) > 20:
            return [messages[0]] + messages[-19:]  # System + recent
        return messages

    def get_logs(self, pre_transform_messages, post_transform_messages):
        return f"Reduced from {len(pre_transform_messages)} to {len(post_transform_messages)}"

# State management for persistence
agent.save_state("checkpoint.json")
# Later...
agent.load_state("checkpoint.json")
```

**GroupChat with Memory:**
```python
from autogen.agentchat.contrib.memory import (
    ChromaVectorDB,
    VectorMemory
)

# Long-term memory with vector DB
vector_db = ChromaVectorDB(
    client=chromadb.Client(),
    collection_name="agent_memory"
)

memory = VectorMemory(
    vector_db=vector_db,
    window=10  # Remember last 10 turns
)

group_chat = GroupChat(
    agents=[agent1, agent2],
    memory=memory,
    max_round=50
)
```

**Limitations:**
- Message transforms are global (affect all messages)
- No per-turn or per-agent customization
- State management is separate from message management
- Requires external vector DB for long-term memory

**Use Cases Enabled:**
- Automatic compression with LLMLingua
- State persistence and restoration
- Long-term memory with vector retrieval
- Multi-agent conversation management

**Use Cases NOT Enabled:**
- Fine-grained message filtering
- Selective deletion by criteria
- Dynamic per-turn transformations

---

### 2.8 CrewAI - Hook-Based Append

**Architecture:** Decorator-based hooks with append-only modification

**Pattern:**
```python
from crewai import Agent, Task, Crew

class ContextAwareAgent(Agent):
    @before_llm_call
    def inject_context(self, messages: list[dict]) -> list[dict]:
        # Can only APPEND, not remove or reorder
        messages.append({
            "role": "system",
            "content": f"Current time: {datetime.now().isoformat()}"
        })

        # Add task context
        if self.current_task:
            messages.append({
                "role": "system",
                "content": f"Task: {self.current_task.description}"
            })

        return messages

    @after_llm_call
    def transform_response(self, response: str) -> str:
        # Can transform final response
        if len(response) > 5000:
            return response[:5000] + "... [truncated]"
        return response

# Automatic context management
agent = Agent(
    role="researcher",
    goal="Find information",
    backstory="...",
    llm_config={
        "model": "gpt-4",
        "temperature": 0.7
    },
    # Automatic context window management
    respect_context_window=True,  # Uses summarization
    max_iter=10  # Prevents infinite loops
)
```

**Automatic Summarization:**
```python
# When respect_context_window=True
# CrewAI automatically:
# 1. Counts tokens before each LLM call
# 2. If approaching limit, summarizes oldest messages
# 3. Replaces old messages with summary
# 4. Continues execution

crew = Crew(
    agents=[agent],
    tasks=[task],
    # Configurable memory
    memory=True,  # Enables short-term and long-term memory
    verbose=True
)
```

**Limitations:**
- Hooks can only append, not remove or reorder messages
- Automatic summarization is opaque (can't customize strategy)
- No access to message IDs for selective deletion
- Cannot pause/resume execution

**Use Cases Enabled:**
- Context injection per LLM call
- Response post-processing
- Automatic token management
- Multi-agent memory sharing

**Use Cases NOT Enabled:**
- Message deletion or pruning
- Selective filtering
- Mid-execution pause
- Custom summarization strategies

---

## 3. Message Transformation Patterns

This section catalogs common patterns with implementations across frameworks.

### 3.1 Pattern: Sliding Window (Keep Last N)

**Use Case:** Maintain fixed conversation size to control token usage.

**LangGraph:**
```python
def sliding_window(state: MessagesState, n: int = 20) -> dict:
    messages = state["messages"]
    if len(messages) <= n:
        return {}

    # Keep system message + last n-1
    system = [m for m in messages if m.role == "system"]
    recent = [m for m in messages if m.role != "system"][-(n-len(system)):]
    return {"messages": system + recent}
```

**PydanticAI:**
```python
def keep_recent(n: int):
    def processor(messages: list[Message]) -> list[Message]:
        if len(messages) <= n:
            return messages
        system_msgs = [m for m in messages if m.role == "system"]
        recent = [m for m in messages if m.role != "system"][-n:]
        return system_msgs + recent
    return processor
```

**Cloudflare:**
```typescript
async onChatMessage(message: Message) {
    const MAX_MESSAGES = 20;
    if (this.messages.length > MAX_MESSAGES) {
        const system = this.messages.filter(m => m.role === "system");
        const recent = this.messages.filter(m => m.role !== "system").slice(-19);
        this.messages = [...system, ...recent];
    }
}
```

**OpenAI Agents (Workaround):**
```python
def sliding_window_filter(messages: list[dict]) -> list[dict]:
    MAX = 20
    if len(messages) <= MAX:
        return messages
    return [messages[0]] + messages[-(MAX-1):]

result = await session.run(
    call_model_input_filter=sliding_window_filter
)
```

---

### 3.2 Pattern: Progressive Summarization

**Use Case:** Summarize old messages when history exceeds threshold.

**LangGraph:**
```python
def progressive_summarization(state: MessagesState) -> dict:
    messages = state["messages"]
    THRESHOLD = 50

    if len(messages) < THRESHOLD:
        return {}

    # Summarize oldest 30 messages
    to_summarize = messages[:30]
    to_keep = messages[30:]

    summary_prompt = "Summarize the following conversation:\n"
    summary_prompt += "\n".join(f"{m.role}: {m.content}" for m in to_summarize)

    summary = llm.invoke([{"role": "user", "content": summary_prompt}])

    return {
        "messages": [
            {"role": "system", "content": f"[Previous conversation]: {summary.content}"},
            *to_keep
        ]
    }
```

**PydanticAI:**
```python
def summarize_old(threshold: int = 50):
    async def processor(messages: list[Message], ctx: AgentContext) -> list[Message]:
        if len(messages) <= threshold:
            return messages

        old = messages[:threshold-10]
        recent = messages[threshold-10:]

        # Use agent's LLM to summarize
        summary_messages = [
            Message(role="user", content="Summarize concisely:\n" +
                   "\n".join(str(m) for m in old))
        ]

        result = await ctx.agent.model.request(summary_messages)
        summary_text = result.content

        return [
            Message(role="system", content=f"Summary: {summary_text}"),
            *recent
        ]

    return processor
```

**AutoGen:**
```python
# Built-in with TextMessageCompressor
from autogen.agentchat.contrib.capabilities import transforms

compressor = transforms.TextMessageCompressor(
    min_length=10000,  # Compress if > 10k chars
    compression_params={
        "target_token": 4000,
        "use_context_level_filter": True,
        "use_sentence_level_filter": False
    }
)
```

---

### 3.3 Pattern: Token Budget Enforcement

**Use Case:** Ensure total context stays under token limit.

**PydanticAI:**
```python
import tiktoken

def enforce_token_limit(max_tokens: int, model: str = "gpt-4"):
    encoding = tiktoken.encoding_for_model(model)

    def count_tokens(text: str) -> int:
        return len(encoding.encode(text))

    def processor(messages: list[Message]) -> list[Message]:
        total = sum(count_tokens(m.content) for m in messages)

        if total <= max_tokens:
            return messages

        # Keep system + trim oldest
        system = [m for m in messages if m.role == "system"]
        others = [m for m in messages if m.role != "system"]

        kept = system.copy()
        current_tokens = sum(count_tokens(m.content) for m in system)

        for msg in reversed(others):
            msg_tokens = count_tokens(msg.content)
            if current_tokens + msg_tokens > max_tokens:
                break
            kept.insert(len(system), msg)
            current_tokens += msg_tokens

        return kept

    return processor

agent = Agent(
    model="openai:gpt-4",
    history_processors=[enforce_token_limit(8000)]
)
```

**LangGraph:**
```python
from langchain_core.messages import trim_messages
import tiktoken

def token_trimmer(state: MessagesState) -> dict:
    encoding = tiktoken.encoding_for_model("gpt-4")

    trimmed = trim_messages(
        state["messages"],
        token_counter=lambda msgs: sum(len(encoding.encode(m.content)) for m in msgs),
        max_tokens=8000,
        strategy="last",  # Keep most recent
        start_on="human",
        include_system=True
    )

    return {"messages": trimmed}
```

---

### 3.4 Pattern: Selective Message Removal

**Use Case:** Remove specific messages by criteria (e.g., errors, old system messages).

**LangGraph:**
```python
from langchain_core.messages import RemoveMessage

def remove_old_system_messages(state: MessagesState, max_age: timedelta) -> dict:
    cutoff = datetime.now() - max_age

    to_remove = [
        RemoveMessage(id=m.id)
        for m in state["messages"]
        if m.role == "system" and m.created_at < cutoff
    ]

    return {"messages": to_remove}

def remove_error_messages(state: MessagesState) -> dict:
    to_remove = [
        RemoveMessage(id=m.id)
        for m in state["messages"]
        if "error" in m.content.lower() or m.metadata.get("failed")
    ]

    return {"messages": to_remove}
```

**Cloudflare:**
```typescript
async removeOldSystemMessages(maxAgeMs: number) {
    const cutoff = Date.now() - maxAgeMs;

    this.messages = this.messages.filter(msg => {
        if (msg.role !== "system") return true;
        return msg.timestamp > cutoff;
    });
}

async removeErrorMessages() {
    this.messages = this.messages.filter(msg =>
        !msg.content.includes("[ERROR]") && !msg.metadata?.failed
    );
}
```

**Other Frameworks:**
Not directly supported - requires workarounds like rebuilding entire message array.

---

### 3.5 Pattern: Context Injection

**Use Case:** Add dynamic context (time, user info, task details) before LLM call.

**CrewAI:**
```python
class ContextAwareAgent(Agent):
    @before_llm_call
    def inject_dynamic_context(self, messages: list[dict]) -> list[dict]:
        # Current time
        messages.append({
            "role": "system",
            "content": f"Current UTC time: {datetime.utcnow().isoformat()}"
        })

        # User context
        if self.user_context:
            messages.append({
                "role": "system",
                "content": f"User: {self.user_context['name']}, Tier: {self.user_context['tier']}"
            })

        # Task progress
        if self.current_task:
            progress = self.current_task.progress_percentage
            messages.append({
                "role": "system",
                "content": f"Task progress: {progress}%"
            })

        return messages
```

**Vercel AI SDK:**
```typescript
await agent.run({
    prompt: "Analyze data",
    prepareStep: async ({ messages }) => {
        return {
            messages: [
                ...messages,
                {
                    role: "system",
                    content: `Context: ${JSON.stringify(await getDynamicContext())}`
                }
            ]
        };
    }
});
```

**PydanticAI:**
```python
def inject_context(context_fn: Callable[[], dict]):
    def processor(messages: list[Message]) -> list[Message]:
        context = context_fn()
        context_msg = Message(
            role="system",
            content=f"Context: {json.dumps(context)}"
        )
        # Insert after system prompt
        system_msgs = [m for m in messages if m.role == "system"]
        other_msgs = [m for m in messages if m.role != "system"]
        return system_msgs + [context_msg] + other_msgs

    return processor

agent = Agent(
    model="openai:gpt-4",
    history_processors=[
        inject_context(lambda: {
            "time": datetime.utcnow().isoformat(),
            "user": current_user.dict()
        })
    ]
)
```

---

### 3.6 Pattern: Format Transformation

**Use Case:** Convert between different message formats or add metadata.

**PydanticAI:**
```python
def add_message_metadata():
    def processor(messages: list[Message]) -> list[Message]:
        annotated = []
        for i, msg in enumerate(messages):
            annotated.append(Message(
                role=msg.role,
                content=msg.content,
                metadata={
                    **msg.metadata,
                    "index": i,
                    "word_count": len(msg.content.split()),
                    "processed_at": datetime.utcnow().isoformat()
                }
            ))
        return annotated

    return processor
```

**LangGraph:**
```python
def transform_format(state: MessagesState) -> dict:
    """Convert from one format to another"""
    transformed = []

    for msg in state["messages"]:
        # Add structured metadata
        transformed.append({
            **msg,
            "metadata": {
                "provider": "anthropic",
                "model": "claude-3",
                "processed": True
            }
        })

    return {"messages": transformed}
```

---

## 4. Token Management Strategies

### 4.1 Token Counting Approaches

| SDK | Built-in Counter | Recommended Approach |
|-----|------------------|---------------------|
| **OpenAI Agents** | ❌ | Use `tiktoken` manually |
| **Claude SDK** | ❌ | Use Anthropic's tokenizer |
| **Cloudflare** | ❌ | Manual with `tiktoken` |
| **Vercel AI** | ❌ | Manual with provider tokenizer |
| **LangGraph** | ⚠️ `trim_messages` accepts `token_counter` | Provide custom function |
| **PydanticAI** | ❌ | Implement in history processor |
| **AutoGen** | ✅ Built into `TextMessageCompressor` | Uses LLMLingua |
| **CrewAI** | ✅ Automatic if `respect_context_window=True` | Built-in |

### 4.2 Budget Enforcement Patterns

**Hard Limit (Reject if exceeded):**
```python
# PydanticAI
def enforce_hard_limit(max_tokens: int):
    def processor(messages: list[Message]) -> list[Message]:
        total = sum(count_tokens(m.content) for m in messages)
        if total > max_tokens:
            raise ValueError(f"Token limit exceeded: {total} > {max_tokens}")
        return messages
    return processor
```

**Soft Limit (Truncate to fit):**
```python
# PydanticAI
def enforce_soft_limit(max_tokens: int):
    def processor(messages: list[Message]) -> list[Message]:
        total = sum(count_tokens(m.content) for m in messages)
        if total <= max_tokens:
            return messages

        # Truncate oldest messages
        kept = []
        current = 0
        for msg in reversed(messages):
            tokens = count_tokens(msg.content)
            if current + tokens > max_tokens:
                break
            kept.insert(0, msg)
            current += tokens

        return kept
    return processor
```

**Dynamic Limit (Adjust per model):**
```python
# LangGraph
MODEL_LIMITS = {
    "gpt-4": 8192,
    "gpt-4-32k": 32768,
    "claude-3-sonnet": 200000
}

def dynamic_token_limit(state: MessagesState, model: str) -> dict:
    max_tokens = MODEL_LIMITS.get(model, 4096)

    trimmed = trim_messages(
        state["messages"],
        token_counter=count_tokens,
        max_tokens=max_tokens,
        strategy="last"
    )

    return {"messages": trimmed}
```

### 4.3 Provider-Specific Token Counting

**OpenAI:**
```python
import tiktoken

def count_openai_tokens(messages: list[dict], model: str = "gpt-4") -> int:
    encoding = tiktoken.encoding_for_model(model)

    tokens = 0
    for msg in messages:
        tokens += 4  # Message overhead
        tokens += len(encoding.encode(msg["content"]))
        tokens += len(encoding.encode(msg["role"]))

    tokens += 2  # Reply priming
    return tokens
```

**Anthropic:**
```python
from anthropic import Anthropic

client = Anthropic()

def count_anthropic_tokens(messages: list[dict]) -> int:
    # Anthropic provides token counting API
    response = client.messages.count_tokens(
        model="claude-3-sonnet-20240229",
        messages=messages
    )
    return response.input_tokens
```

---

## 5. Context Window Engineering

### 5.1 Hierarchical Memory Pattern

**Concept:** Maintain multiple tiers of memory with different retention policies.

**Implementation (LangGraph):**
```python
from dataclasses import dataclass
from typing import List

@dataclass
class HierarchicalMemory:
    short_term: list  # Last 10 messages (verbatim)
    medium_term: list  # Summaries of last 50 messages
    long_term: dict  # Key facts extracted from entire history

def manage_hierarchical_memory(state: MessagesState) -> dict:
    messages = state["messages"]

    # Short-term: Keep last 10 verbatim
    short_term = messages[-10:]

    # Medium-term: Summarize messages 10-50
    if len(messages) > 10:
        medium_messages = messages[-50:-10] if len(messages) > 50 else messages[:-10]
        medium_summary = llm.invoke([
            {"role": "user", "content": f"Summarize: {medium_messages}"}
        ])
        medium_term = [{"role": "system", "content": medium_summary.content}]
    else:
        medium_term = []

    # Long-term: Extract facts from all messages
    if len(messages) > 100:
        facts = extract_facts(messages)  # Custom extraction logic
        long_term_msg = {
            "role": "system",
            "content": f"Key facts: {json.dumps(facts)}"
        }
    else:
        long_term_msg = None

    # Reconstruct context
    new_messages = []
    if long_term_msg:
        new_messages.append(long_term_msg)
    new_messages.extend(medium_term)
    new_messages.extend(short_term)

    return {"messages": new_messages}
```

### 5.2 Vector-Based Retrieval

**Concept:** Store all messages in vector DB, retrieve relevant subset per turn.

**Implementation (AutoGen with ChromaDB):**
```python
from autogen.agentchat.contrib.memory import ChromaVectorDB, VectorMemory
import chromadb

# Setup vector DB
client = chromadb.Client()
vector_db = ChromaVectorDB(
    client=client,
    collection_name="conversation_history"
)

# Create memory with retrieval
memory = VectorMemory(
    vector_db=vector_db,
    window=10  # Last 10 turns always included
)

# Agent uses memory
agent = ConversableAgent(
    name="assistant",
    llm_config={"model": "gpt-4"},
    memory=memory
)

# On each turn:
# 1. Embed current query
# 2. Retrieve top-K similar past messages
# 3. Include retrieved + last 10 in context
```

### 5.3 Semantic Compression

**Concept:** Compress semantically similar messages into single representation.

**Implementation (Custom with PydanticAI):**
```python
from sklearn.metrics.pairwise import cosine_similarity
import numpy as np

def semantic_compression(similarity_threshold: float = 0.9):
    async def processor(messages: list[Message], ctx: AgentContext) -> list[Message]:
        if len(messages) < 5:
            return messages

        # Get embeddings for all messages
        embeddings = []
        for msg in messages:
            emb = await ctx.agent.get_embedding(msg.content)
            embeddings.append(emb)

        embeddings = np.array(embeddings)

        # Find similar message clusters
        similarity_matrix = cosine_similarity(embeddings)

        compressed = []
        seen = set()

        for i, msg in enumerate(messages):
            if i in seen:
                continue

            # Find similar messages
            similar_indices = np.where(similarity_matrix[i] > similarity_threshold)[0]

            if len(similar_indices) > 1:
                # Merge similar messages
                similar_msgs = [messages[j] for j in similar_indices]
                merged_content = f"[Merged {len(similar_msgs)} similar messages]: "
                merged_content += " | ".join(m.content[:100] for m in similar_msgs)

                compressed.append(Message(
                    role=msg.role,
                    content=merged_content
                ))
                seen.update(similar_indices)
            else:
                compressed.append(msg)
                seen.add(i)

        return compressed

    return processor
```

---

## 6. Use Case Walkthroughs

### 6.1 Use Case: PII Redaction Workflow

**Requirements:**
- Redact emails, phone numbers, SSNs from messages
- Log what was redacted for audit
- Apply before every LLM call

**Implementation - PydanticAI:**
```python
import re
from typing import Dict, List
import logging

logger = logging.getLogger(__name__)

class PIIRedactor:
    PATTERNS = {
        "email": r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b',
        "phone": r'\b\d{3}[-.]?\d{3}[-.]?\d{4}\b',
        "ssn": r'\b\d{3}-\d{2}-\d{4}\b',
        "credit_card": r'\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b'
    }

    def __init__(self):
        self.redaction_log: List[Dict] = []

    def redact(self, text: str, message_id: str) -> str:
        redacted = text
        redacted_items = []

        for pii_type, pattern in self.PATTERNS.items():
            matches = re.findall(pattern, text)
            if matches:
                redacted_items.extend([
                    {"type": pii_type, "value": match}
                    for match in matches
                ])
                redacted = re.sub(pattern, f"[REDACTED_{pii_type.upper()}]", redacted)

        if redacted_items:
            self.redaction_log.append({
                "message_id": message_id,
                "timestamp": datetime.utcnow().isoformat(),
                "redacted": redacted_items
            })
            logger.warning(f"Redacted {len(redacted_items)} PII items from message {message_id}")

        return redacted

def create_pii_redaction_processor():
    redactor = PIIRedactor()

    def processor(messages: list[Message]) -> list[Message]:
        redacted_messages = []

        for msg in messages:
            redacted_content = redactor.redact(
                msg.content,
                message_id=msg.id or str(hash(msg.content))
            )

            redacted_messages.append(Message(
                role=msg.role,
                content=redacted_content,
                metadata={
                    **msg.metadata,
                    "pii_redacted": redacted_content != msg.content
                }
            ))

        return redacted_messages

    return processor, redactor

# Usage
redaction_processor, redactor = create_pii_redaction_processor()

agent = Agent(
    model="openai:gpt-4",
    history_processors=[redaction_processor]
)

result = await agent.run("Process user data: john@email.com, 555-123-4567")

# Audit log
print(redactor.redaction_log)
# [{"message_id": "...", "redacted": [{"type": "email", "value": "john@email.com"}, ...]}]
```

---

### 6.2 Use Case: Long-Running Research with Progressive Summarization

**Requirements:**
- Agent conducts multi-day research
- History grows to thousands of messages
- Keep recent detail, summarize old content
- Maintain hierarchical memory

**Implementation - LangGraph:**
```python
from langchain_core.messages import BaseMessage, SystemMessage, HumanMessage, AIMessage
from langgraph.graph import StateGraph, MessagesState
from typing import Literal

class ResearchState(MessagesState):
    summary: str
    research_facts: dict[str, str]
    iteration: int

def manage_research_context(state: ResearchState) -> dict:
    """Context management node"""
    messages = state["messages"]
    iteration = state.get("iteration", 0)

    RECENT_THRESHOLD = 20
    SUMMARY_THRESHOLD = 100

    # Every 100 iterations, create new summary
    if iteration % 100 == 0 and len(messages) > SUMMARY_THRESHOLD:
        old_messages = messages[:-RECENT_THRESHOLD]

        summary_prompt = f"""Summarize the following research conversation.
        Focus on: key findings, important URLs, methodologies discussed.

        Conversation:
        {format_messages(old_messages)}
        """

        summary_response = llm.invoke([HumanMessage(content=summary_prompt)])
        new_summary = summary_response.content

        # Update state
        return {
            "messages": [
                SystemMessage(content=f"Research Summary:\n{new_summary}"),
                *messages[-RECENT_THRESHOLD:]
            ],
            "summary": new_summary,
            "iteration": iteration + 1
        }

    return {"iteration": iteration + 1}

def extract_facts(state: ResearchState) -> dict:
    """Extract key facts from recent messages"""
    messages = state["messages"]

    extraction_prompt = """Extract key facts from this conversation.
    Format: {"fact_name": "fact_value", ...}
    Only include verifiable facts.
    """

    response = llm.invoke([
        SystemMessage(content=extraction_prompt),
        *messages[-10:]
    ])

    facts = json.loads(response.content)
    existing_facts = state.get("research_facts", {})

    return {
        "research_facts": {**existing_facts, **facts}
    }

def research_agent(state: ResearchState) -> dict:
    """Main research agent node"""
    messages = state["messages"]
    facts = state.get("research_facts", {})

    # Inject facts into context
    context_msg = SystemMessage(
        content=f"Known facts:\n{json.dumps(facts, indent=2)}"
    )

    response = llm.invoke([context_msg, *messages])

    return {"messages": [response]}

# Build graph
builder = StateGraph(ResearchState)
builder.add_node("manage_context", manage_research_context)
builder.add_node("extract_facts", extract_facts)
builder.add_node("research", research_agent)

builder.set_entry_point("manage_context")
builder.add_edge("manage_context", "extract_facts")
builder.add_edge("extract_facts", "research")
builder.add_edge("research", "manage_context")

graph = builder.compile()

# Run for extended period
config = {"configurable": {"thread_id": "research_001"}}

for i in range(1000):  # Long-running research
    result = graph.invoke(
        {"messages": [HumanMessage(content=f"Research iteration {i}")]},
        config
    )

    # Checkpointing happens automatically
    # Context management runs every iteration
    # Summary created every 100 iterations
```

---

### 6.3 Use Case: Multi-Agent Coordination with Shared Context

**Requirements:**
- Multiple specialized agents (researcher, writer, critic)
- Shared conversation history
- Each agent sees relevant context for their role
- Prevent context explosion

**Implementation - LangGraph:**
```python
from langgraph.graph import StateGraph, END
from typing import Annotated

class SharedState(MessagesState):
    researcher_context: list[BaseMessage]
    writer_context: list[BaseMessage]
    critic_context: list[BaseMessage]
    current_agent: str

def route_to_agent(state: SharedState) -> Literal["researcher", "writer", "critic", END]:
    """Decide which agent goes next"""
    last_msg = state["messages"][-1]

    if "need more research" in last_msg.content.lower():
        return "researcher"
    elif "draft" in last_msg.content.lower():
        return "writer"
    elif "review" in last_msg.content.lower():
        return "critic"
    else:
        return END

def prepare_researcher_context(state: SharedState) -> dict:
    """Give researcher relevant context"""
    all_messages = state["messages"]

    # Researcher needs: question, previous findings, critic feedback
    relevant = [
        m for m in all_messages
        if m.role == "user" or
           "finding" in m.content.lower() or
           "critic" in m.metadata.get("source", "")
    ]

    # Keep last 15 relevant messages
    context = relevant[-15:]

    return {"researcher_context": context, "current_agent": "researcher"}

def researcher_agent(state: SharedState) -> dict:
    context = state["researcher_context"]

    response = researcher_llm.invoke([
        SystemMessage(content="You are a researcher. Find factual information."),
        *context
    ])

    return {
        "messages": [AIMessage(
            content=response.content,
            metadata={"source": "researcher"}
        )]
    }

def prepare_writer_context(state: SharedState) -> dict:
    all_messages = state["messages"]

    # Writer needs: research findings, previous drafts, style guidelines
    relevant = [
        m for m in all_messages
        if "researcher" in m.metadata.get("source", "") or
           "draft" in m.content.lower() or
           m.role == "user"
    ]

    context = relevant[-20:]

    return {"writer_context": context, "current_agent": "writer"}

def writer_agent(state: SharedState) -> dict:
    context = state["writer_context"]

    response = writer_llm.invoke([
        SystemMessage(content="You are a writer. Create clear, engaging content."),
        *context
    ])

    return {
        "messages": [AIMessage(
            content=response.content,
            metadata={"source": "writer"}
        )]
    }

def prepare_critic_context(state: SharedState) -> dict:
    all_messages = state["messages"]

    # Critic needs: latest draft, original requirements
    draft = next((m for m in reversed(all_messages)
                 if "writer" in m.metadata.get("source", "")), None)
    requirements = next((m for m in all_messages if m.role == "user"), None)

    context = [requirements, draft] if draft and requirements else all_messages[-5:]

    return {"critic_context": context, "current_agent": "critic"}

def critic_agent(state: SharedState) -> dict:
    context = state["critic_context"]

    response = critic_llm.invoke([
        SystemMessage(content="You are a critic. Provide constructive feedback."),
        *context
    ])

    return {
        "messages": [AIMessage(
            content=response.content,
            metadata={"source": "critic"}
        )]
    }

# Build graph
builder = StateGraph(SharedState)

builder.add_node("prepare_researcher", prepare_researcher_context)
builder.add_node("researcher", researcher_agent)

builder.add_node("prepare_writer", prepare_writer_context)
builder.add_node("writer", writer_agent)

builder.add_node("prepare_critic", prepare_critic_context)
builder.add_node("critic", critic_agent)

builder.set_entry_point("prepare_researcher")

builder.add_conditional_edges("researcher", route_to_agent)
builder.add_conditional_edges("writer", route_to_agent)
builder.add_conditional_edges("critic", route_to_agent)

builder.add_edge("prepare_researcher", "researcher")
builder.add_edge("prepare_writer", "writer")
builder.add_edge("prepare_critic", "critic")

graph = builder.compile()

# Run
result = graph.invoke({
    "messages": [HumanMessage(content="Write an article about AI agents")]
})
```

**Key Pattern:**
- Each agent gets filtered context via `prepare_X_context` nodes
- Prevents full history from growing for each agent
- Metadata tags enable filtering by source
- Routing logic decides next agent

---

### 6.4 Use Case: Token Budget Optimization for Cost Control

**Requirements:**
- Enforce hard token budget across conversation
- Prioritize recent + important messages
- Track token usage per turn
- Fail gracefully if budget exceeded

**Implementation - PydanticAI:**
```python
import tiktoken
from dataclasses import dataclass
from typing import Optional

@dataclass
class TokenBudget:
    max_tokens: int
    used_tokens: int = 0
    important_message_ids: set[str] = None

    def __post_init__(self):
        if self.important_message_ids is None:
            self.important_message_ids = set()

def count_tokens(text: str, model: str = "gpt-4") -> int:
    encoding = tiktoken.encoding_for_model(model)
    return len(encoding.encode(text))

def create_budget_enforcer(budget: TokenBudget):
    """Create history processor that enforces token budget"""

    def processor(messages: list[Message]) -> list[Message]:
        # Count tokens in all messages
        message_tokens = [
            (msg, count_tokens(msg.content))
            for msg in messages
        ]

        total_tokens = sum(t for _, t in message_tokens)

        # If within budget, return as-is
        if total_tokens <= budget.max_tokens:
            budget.used_tokens = total_tokens
            return messages

        # Exceeded budget - intelligently prune

        # 1. Always keep system messages
        system_msgs = [(m, t) for m, t in message_tokens if m.role == "system"]
        system_tokens = sum(t for _, t in system_msgs)

        # 2. Keep important messages (marked by user)
        important_msgs = [
            (m, t) for m, t in message_tokens
            if m.id in budget.important_message_ids
        ]
        important_tokens = sum(t for _, t in important_msgs)

        # 3. Allocate remaining budget to recent messages
        remaining_budget = budget.max_tokens - system_tokens - important_tokens

        if remaining_budget <= 0:
            raise ValueError(
                f"System + important messages exceed budget: "
                f"{system_tokens + important_tokens} > {budget.max_tokens}"
            )

        # Keep most recent messages that fit
        other_msgs = [
            (m, t) for m, t in message_tokens
            if m.role != "system" and m.id not in budget.important_message_ids
        ]

        kept_others = []
        current = 0

        for msg, tokens in reversed(other_msgs):
            if current + tokens > remaining_budget:
                break
            kept_others.insert(0, (msg, tokens))
            current += tokens

        # Reconstruct message list
        result = [m for m, _ in system_msgs]
        result.extend(m for m, _ in kept_others)
        result.extend(m for m, _ in important_msgs)

        # Sort by original order
        original_order = {id(m): i for i, m in enumerate(messages)}
        result.sort(key=lambda m: original_order.get(id(m), 0))

        budget.used_tokens = sum(t for _, t in system_msgs + kept_others + important_msgs)

        return result

    return processor

def track_token_usage():
    """History processor that logs token usage"""

    def processor(messages: list[Message]) -> list[Message]:
        total = sum(count_tokens(m.content) for m in messages)

        print(f"[Token Usage] {total} tokens across {len(messages)} messages")

        # Breakdown by role
        by_role = {}
        for msg in messages:
            tokens = count_tokens(msg.content)
            by_role[msg.role] = by_role.get(msg.role, 0) + tokens

        for role, tokens in by_role.items():
            print(f"  - {role}: {tokens} tokens")

        return messages

    return processor

# Usage
budget = TokenBudget(max_tokens=8000)

agent = Agent(
    model="openai:gpt-4",
    history_processors=[
        track_token_usage(),
        create_budget_enforcer(budget)
    ]
)

# Mark important messages
async with agent.iter("Analyze quarterly sales") as run:
    async for node in run:
        if isinstance(node, ModelResponse):
            # Mark key insights as important
            if "critical" in node.content.lower():
                budget.important_message_ids.add(node.message_id)

# Check final usage
print(f"Total used: {budget.used_tokens} / {budget.max_tokens}")
```

---

## 7. Limitations & Workarounds

### 7.1 OpenAI Agents - Cannot Modify Mid-Execution

**Limitation:** Hooks are read-only, `call_model_input_filter` only runs once.

**Workaround:**
```python
# Store state externally, rebuild context on each turn
class ContextManager:
    def __init__(self):
        self.full_history = []
        self.summary = None

    def add_turn(self, messages):
        self.full_history.extend(messages)
        if len(self.full_history) > 50:
            self.summary = self._summarize(self.full_history[:40])
            self.full_history = self.full_history[40:]

    def get_context_filter(self):
        def filter_fn(messages):
            if self.summary:
                return [
                    {"role": "system", "content": f"Summary: {self.summary}"},
                    *messages
                ]
            return messages
        return filter_fn

ctx_mgr = ContextManager()

result = await session.run(
    call_model_input_filter=ctx_mgr.get_context_filter()
)

ctx_mgr.add_turn(result.to_input_list())
```

---

### 7.2 Claude SDK - No Direct History Access

**Limitation:** Cannot read or modify message history directly.

**Workaround:**
```typescript
// Maintain parallel history externally
class ConversationManager {
    private history: Message[] = [];

    async run(agent: Agent, input: string) {
        // Manage history externally
        this.pruneHistory();

        const response = await agent.run({
            input,
            // Can't inject history, but can add system message
            systemMessage: this.getSummary()
        });

        // Track response
        this.history.push({ role: "user", content: input });
        this.history.push({ role: "assistant", content: response.output });

        return response;
    }

    private pruneHistory() {
        if (this.history.length > 20) {
            this.history = this.history.slice(-20);
        }
    }

    private getSummary(): string {
        return `Previous context: ${this.history.length} messages`;
    }
}
```

---

### 7.3 Vercel AI - prepareStep Doesn't Always Fire

**Limitation:** `prepareStep` callback has reliability issues.

**Workaround:**
```typescript
// Maintain history externally, inject via maxMessages
const conversationHistory: Message[] = [];

function manageHistory(newMessages: Message[]) {
    conversationHistory.push(...newMessages);

    // Custom pruning
    if (conversationHistory.length > 50) {
        const system = conversationHistory.filter(m => m.role === "system");
        const recent = conversationHistory.filter(m => m.role !== "system").slice(-40);
        conversationHistory.length = 0;
        conversationHistory.push(...system, ...recent);
    }

    return conversationHistory;
}

const result = await agent.run({
    prompt: "Analyze data",
    // Provide full managed history
    messages: conversationHistory
});

// Update after response
manageHistory([
    { role: "user", content: "Analyze data" },
    { role: "assistant", content: result.text }
]);
```

---

### 7.4 CrewAI - Cannot Remove Messages

**Limitation:** Hooks can only append, not remove or reorder.

**Workaround:**
```python
# Use respect_context_window for automatic management
agent = Agent(
    role="analyst",
    goal="Analyze data",
    respect_context_window=True,  # Auto-summarizes when needed
    llm_config={"model": "gpt-4"}
)

# For custom control, manage externally
class CrewAIContextManager:
    def __init__(self, max_messages=30):
        self.max_messages = max_messages
        self.history = []

    def add_messages(self, messages):
        self.history.extend(messages)
        if len(self.history) > self.max_messages:
            # Summarize and reset
            summary = self._summarize(self.history[:-10])
            self.history = [
                {"role": "system", "content": f"Summary: {summary}"},
                *self.history[-10:]
            ]

    @before_llm_call
    def inject_context(self, messages):
        # Can only append
        messages.extend(self.history)
        return messages
```

---

## 8. Performance Implications

### 8.1 Overhead by Approach

| Approach | CPU | Memory | Latency | Scalability |
|----------|-----|--------|---------|-------------|
| **No management** | Low | ❌ High | Low | Poor |
| **Sliding window** | Low | Medium | Low | Good |
| **Token counting** | Medium | Medium | Low | Good |
| **Summarization** | High (LLM call) | Low | ❌ High | Excellent |
| **Vector retrieval** | Medium (embedding) | Medium (DB) | Medium | Excellent |
| **Semantic compression** | ❌ Very High | High | High | Medium |

### 8.2 Caching Strategies

**Token Count Caching:**
```python
from functools import lru_cache

@lru_cache(maxsize=1000)
def count_tokens_cached(content: str, model: str) -> int:
    encoding = tiktoken.encoding_for_model(model)
    return len(encoding.encode(content))

def processor(messages: list[Message]) -> list[Message]:
    # Cached token counting
    total = sum(count_tokens_cached(m.content, "gpt-4") for m in messages)
    # ...
```

**Summary Caching:**
```python
class SummarizationCache:
    def __init__(self):
        self.cache: dict[str, str] = {}

    def get_summary(self, messages: list[Message]) -> Optional[str]:
        # Hash message content
        key = hashlib.sha256(
            json.dumps([m.content for m in messages]).encode()
        ).hexdigest()

        return self.cache.get(key)

    def store_summary(self, messages: list[Message], summary: str):
        key = hashlib.sha256(
            json.dumps([m.content for m in messages]).encode()
        ).hexdigest()

        self.cache[key] = summary

cache = SummarizationCache()

def summarize_with_cache(messages: list[Message]) -> str:
    # Check cache first
    cached = cache.get_summary(messages)
    if cached:
        return cached

    # Generate summary
    summary = llm.invoke([{"role": "user", "content": format_for_summary(messages)}])

    # Store in cache
    cache.store_summary(messages, summary.content)

    return summary.content
```

### 8.3 Optimization Recommendations

**For High-Frequency Agents (chatbots):**
- Use sliding window (cheap, fast)
- Cache token counts
- Avoid summarization in hot path

**For Long-Running Agents (research, analysis):**
- Use progressive summarization
- Store summaries in persistent cache
- Consider vector retrieval for very long histories

**For Multi-Agent Systems:**
- Per-agent context filtering (don't share full history)
- Shared vector store for common knowledge
- Lazy summarization (only when needed)

---

## 9. Code Examples

### 9.1 Complete PII Redaction System

See section 6.1 for full implementation.

### 9.2 Complete Token Budget System

See section 6.4 for full implementation.

### 9.3 Hierarchical Memory with LangGraph

```python
from langgraph.graph import StateGraph, MessagesState
from langchain_core.messages import SystemMessage, HumanMessage, AIMessage
from typing import TypedDict, List

class MemoryTier(TypedDict):
    short_term: List[BaseMessage]  # Last 10 messages
    medium_term: str  # Summary of last 50
    long_term: dict  # Key facts

class HierarchicalState(MessagesState):
    memory: MemoryTier

def update_memory(state: HierarchicalState) -> dict:
    messages = state["messages"]
    current_memory = state.get("memory", {
        "short_term": [],
        "medium_term": "",
        "long_term": {}
    })

    # Short-term: Always last 10
    current_memory["short_term"] = messages[-10:]

    # Medium-term: Summarize if > 50 messages
    if len(messages) > 50:
        to_summarize = messages[-50:-10]
        summary = llm.invoke([
            SystemMessage(content="Summarize these messages concisely"),
            *to_summarize
        ])
        current_memory["medium_term"] = summary.content

    # Long-term: Extract facts if > 100 messages
    if len(messages) > 100:
        facts_prompt = "Extract key facts as JSON: {\"fact\": \"value\", ...}"
        facts_response = llm.invoke([
            SystemMessage(content=facts_prompt),
            *messages[:100]
        ])
        current_memory["long_term"] = json.loads(facts_response.content)

    return {"memory": current_memory}

def prepare_context(state: HierarchicalState) -> dict:
    memory = state["memory"]

    context_messages = []

    # Add long-term facts
    if memory["long_term"]:
        context_messages.append(SystemMessage(
            content=f"Known facts: {json.dumps(memory['long_term'])}"
        ))

    # Add medium-term summary
    if memory["medium_term"]:
        context_messages.append(SystemMessage(
            content=f"Previous context: {memory['medium_term']}"
        ))

    # Add short-term verbatim
    context_messages.extend(memory["short_term"])

    return {"messages": context_messages}

# Build graph
builder = StateGraph(HierarchicalState)
builder.add_node("update_memory", update_memory)
builder.add_node("prepare_context", prepare_context)
builder.add_node("agent", agent_node)

builder.set_entry_point("update_memory")
builder.add_edge("update_memory", "prepare_context")
builder.add_edge("prepare_context", "agent")

graph = builder.compile()
```

---

## 10. Anti-Patterns

### 10.1 Anti-Pattern: Ignoring Token Limits

**Bad:**
```python
# No token management - will eventually exceed context
agent = Agent(model="openai:gpt-4")

for i in range(1000):
    result = await agent.run(f"Step {i}")
    # History grows unbounded
```

**Good:**
```python
agent = Agent(
    model="openai:gpt-4",
    history_processors=[
        enforce_token_limit(max_tokens=8000),
        keep_recent(30)
    ]
)

for i in range(1000):
    result = await agent.run(f"Step {i}")
    # History automatically managed
```

---

### 10.2 Anti-Pattern: Losing Important Context

**Bad:**
```python
# Blindly truncate - may lose critical context
def processor(messages):
    return messages[-10:]  # Keep last 10
```

**Good:**
```python
def intelligent_truncate(messages):
    # Always keep system messages
    system = [m for m in messages if m.role == "system"]

    # Keep important user messages (marked)
    important = [m for m in messages if m.metadata.get("important")]

    # Fill remaining with recent
    others = [m for m in messages if m not in system and m not in important]
    recent = others[-10:]

    return system + important + recent
```

---

### 10.3 Anti-Pattern: Expensive Operations in Hot Path

**Bad:**
```python
def processor(messages):
    # Summarize EVERY time (expensive!)
    summary = llm.invoke([{"role": "user", "content": format(messages)}])
    return [{"role": "system", "content": summary.content}]
```

**Good:**
```python
def processor(messages):
    # Only summarize if threshold reached
    if len(messages) < 50:
        return messages

    # Check cache first
    cached = get_cached_summary(messages[:40])
    if cached:
        return [{"role": "system", "content": cached}, *messages[40:]]

    # Generate and cache
    summary = llm.invoke([...])
    cache_summary(messages[:40], summary.content)
    return [{"role": "system", "content": summary.content}, *messages[40:]]
```

---

### 10.4 Anti-Pattern: Not Handling Async Properly

**Bad:**
```python
def processor(messages):
    # Blocking call in processor!
    summary = requests.post("https://api/summarize", json=messages).json()
    return [{"role": "system", "content": summary}]
```

**Good:**
```python
async def processor(messages, ctx):
    # Proper async
    summary = await ctx.agent.summarize(messages)
    return [Message(role="system", content=summary)]
```

---

### 10.5 Anti-Pattern: Modifying Messages In Place

**Bad:**
```python
def processor(messages):
    # Mutating original list!
    messages.pop(0)
    messages[0].content = "Modified"
    return messages
```

**Good:**
```python
def processor(messages):
    # Create new list and objects
    return [
        Message(role=m.role, content=m.content)
        for m in messages[1:]
    ]
```

---

### 10.6 Anti-Pattern: Not Validating After Transformation

**Bad:**
```python
def processor(messages):
    return messages[-10:]  # What if < 10 messages? What if all system?
```

**Good:**
```python
def processor(messages):
    if len(messages) <= 10:
        return messages

    kept = messages[-10:]

    # Validate: must have at least one non-system message
    if all(m.role == "system" for m in kept):
        # Find last user or assistant message
        for m in reversed(messages):
            if m.role in ["user", "assistant"]:
                kept.append(m)
                break

    return kept
```

---

### 10.7 Anti-Pattern: Over-Aggressive Pruning

**Bad:**
```python
# Delete everything older than 2 messages
def processor(messages):
    return messages[-2:]
```

**Good:**
```python
# Intelligent context retention
def processor(messages):
    MIN_CONTEXT = 5
    TARGET_TOKENS = 4000

    if len(messages) <= MIN_CONTEXT:
        return messages

    total_tokens = sum(count_tokens(m.content) for m in messages)

    if total_tokens <= TARGET_TOKENS:
        return messages

    # Gradually prune, keeping at least MIN_CONTEXT
    kept = messages[-MIN_CONTEXT:]
    current_tokens = sum(count_tokens(m.content) for m in kept)

    for msg in reversed(messages[:-MIN_CONTEXT]):
        msg_tokens = count_tokens(msg.content)
        if current_tokens + msg_tokens > TARGET_TOKENS:
            break
        kept.insert(0, msg)
        current_tokens += msg_tokens

    return kept
```

---

### 10.8 Anti-Pattern: Ignoring Message Roles

**Bad:**
```python
def processor(messages):
    # Treats all messages equally
    return sorted(messages, key=lambda m: len(m.content))[-10:]
```

**Good:**
```python
def processor(messages):
    # Respect role semantics
    system = [m for m in messages if m.role == "system"]
    conversation = [m for m in messages if m.role in ["user", "assistant"]]

    # Keep all system, last 10 conversation
    return system + conversation[-10:]
```

---

## 11. Recommendations for Yrden

Based on this comprehensive analysis, here are specific recommendations for Yrden's context engineering design:

### 11.1 Adopt PydanticAI's History Processor Pattern

**Rationale:** Declarative, composable, type-safe.

```swift
protocol HistoryProcessor {
    func process(_ messages: [Message]) async throws -> [Message]
}

struct Agent<Deps, Output> {
    let historyProcessors: [HistoryProcessor]

    func run(_ prompt: String, deps: Deps) async throws -> Output {
        var messages = buildMessages(prompt)

        // Apply processors sequentially
        for processor in historyProcessors {
            messages = try await processor.process(messages)
        }

        // Send to LLM
        return try await provider.complete(messages)
    }
}

// Built-in processors
struct KeepRecent: HistoryProcessor {
    let count: Int

    func process(_ messages: [Message]) async throws -> [Message] {
        guard messages.count > count else { return messages }
        let system = messages.filter { $0.role == .system }
        let recent = messages.filter { $0.role != .system }.suffix(count - system.count)
        return system + Array(recent)
    }
}

struct EnforceTokenLimit: HistoryProcessor {
    let maxTokens: Int
    let model: String

    func process(_ messages: [Message]) async throws -> [Message] {
        // Implementation...
    }
}

// Usage
let agent = Agent<MyDeps, Report>(
    provider: anthropic,
    historyProcessors: [
        KeepRecent(count: 30),
        EnforceTokenLimit(maxTokens: 100_000, model: "claude-3")
    ]
)
```

---

### 11.2 Support LangGraph-Style Iteration Control

**Rationale:** Enables fine-grained control for advanced use cases.

```swift
// Iterator pattern
struct AgentIterator<Deps, Output>: AsyncSequence {
    typealias Element = AgentNode

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(agent: agent, prompt: prompt, deps: deps)
    }
}

enum AgentNode {
    case modelRequest([Message])
    case modelResponse(String)
    case toolCall(ToolCall)
    case toolResult(String)
    case finalResult(Output)
}

// Usage
for await node in agent.iter("Complex task", deps: deps) {
    switch node {
    case .modelRequest(var messages):
        // Modify before LLM call
        messages.insert(contextMessage, at: 0)

    case .toolCall(let call):
        // Approve/reject
        guard await approve(call) else { continue }

    case .finalResult(let result):
        return result
    }
}
```

---

### 11.3 Provide Built-In Token Management

**Rationale:** Token limits are universal concern, should be first-class.

```swift
struct UsageLimits {
    let maxTokensPerRequest: Int?
    let maxTokensTotal: Int?
    let maxIterations: Int?

    var current: UsageStats
}

struct UsageStats {
    var tokensUsed: Int
    var requestsMade: Int
    var iterationsRun: Int
}

let agent = Agent<MyDeps, Output>(
    provider: anthropic,
    usageLimits: UsageLimits(
        maxTokensPerRequest: 8_000,
        maxTokensTotal: 200_000,
        maxIterations: 50
    )
)

// Agent automatically:
// 1. Counts tokens before each request
// 2. Throws if limits exceeded
// 3. Exposes usage stats
print(agent.usageStats)
```

---

### 11.4 Make Hooks Observational by Default

**Rationale:** Safety first, power when needed.

```swift
protocol AgentHook {
    func onModelRequest(_ request: ModelRequest) async
    func onModelResponse(_ response: ModelResponse) async
    func onToolCall(_ call: ToolCall) async
    func onToolResult(_ result: ToolResult) async
    func onError(_ error: Error) async
}

// Hooks are read-only
struct LoggingHook: AgentHook {
    func onModelRequest(_ request: ModelRequest) async {
        logger.info("Sending \(request.messages.count) messages")
    }

    // Cannot modify, only observe
}

// For modification, use history processors
let agent = Agent(
    provider: anthropic,
    hooks: [LoggingHook(), MetricsHook()],  // Observation
    historyProcessors: [KeepRecent(30)]      // Modification
)
```

---

### 11.5 Support Hierarchical Memory Pattern

**Rationale:** Enables long-running agents with bounded context.

```swift
struct HierarchicalMemory {
    var shortTerm: [Message]  // Last N verbatim
    var mediumTerm: String?   // Summary of older messages
    var longTerm: [String: String]  // Extracted facts
}

struct MemoryProcessor: HistoryProcessor {
    let shortTermSize: Int
    let mediumTermThreshold: Int

    var memory = HierarchicalMemory(shortTerm: [])

    func process(_ messages: [Message]) async throws -> [Message] {
        // Update memory tiers
        memory.shortTerm = Array(messages.suffix(shortTermSize))

        if messages.count > mediumTermThreshold {
            memory.mediumTerm = await summarize(messages)
        }

        // Reconstruct context
        var context: [Message] = []

        if let summary = memory.mediumTerm {
            context.append(Message(role: .system, content: "Context: \(summary)"))
        }

        context.append(contentsOf: memory.shortTerm)

        return context
    }
}
```

---

### 11.6 Provide Type-Safe Message Filtering

**Rationale:** Leverage Swift's type system for correctness.

```swift
// Fluent API for message filtering
extension Array where Element == Message {
    func keepRecent(_ count: Int) -> [Message] {
        guard self.count > count else { return self }
        let system = filter { $0.role == .system }
        let recent = filter { $0.role != .system }.suffix(count - system.count)
        return system + Array(recent)
    }

    func removeRole(_ role: Message.Role) -> [Message] {
        filter { $0.role != role }
    }

    func keepOnly(_ roles: Set<Message.Role>) -> [Message] {
        filter { roles.contains($0.role) }
    }

    func withTokenLimit(_ limit: Int, model: String) throws -> [Message] {
        // Implementation with token counting
    }
}

// Usage in processor
struct CustomProcessor: HistoryProcessor {
    func process(_ messages: [Message]) async throws -> [Message] {
        return try messages
            .removeRole(.system)
            .keepRecent(20)
            .withTokenLimit(8000, model: "gpt-4")
    }
}
```

---

### 11.7 Support Pause/Resume Like LangGraph

**Rationale:** Human-in-the-loop is critical for agents.

```swift
enum AgentControl {
    case `continue`
    case pause(reason: String)
    case resume(with: String)
}

// In iterator
for await node in agent.iter("Task", deps: deps) {
    switch node {
    case .toolCall(let call) where call.requiresApproval:
        // Pause execution
        throw AgentPaused(call: call)
    default:
        break
    }
}

// Resume later
let result = try await agent.resume(
    conversationId: "abc",
    with: "approved"
)
```

---

### 11.8 Avoid OpenAI's Read-Only Hook Mistake

**Rationale:** Flexibility is important for production use.

**Don't do this (OpenAI pattern):**
```swift
// ❌ Read-only hooks are too limiting
protocol AgentHook {
    func onModelRequest(_ request: ModelRequest)  // No return, can't modify
}
```

**Do this instead:**
```swift
// ✅ Separate observation (hooks) from modification (processors)
protocol AgentHook {
    func onModelRequest(_ request: ModelRequest) async  // Observe only
}

protocol HistoryProcessor {
    func process(_ messages: [Message]) async throws -> [Message]  // Modify
}
```

---

### 11.9 Make Persistence Opt-In

**Rationale:** Not all agents need persistence, and it adds complexity.

```swift
// Default: No persistence
let agent = Agent<MyDeps, Output>(
    provider: anthropic
)

// Opt-in to persistence
let persistentAgent = Agent<MyDeps, Output>(
    provider: anthropic,
    checkpointer: SQLiteCheckpointer(path: "./agent.db")
)

// Full control
let conversation = try await persistentAgent.startConversation()
let result1 = try await conversation.run("Step 1")
let result2 = try await conversation.run("Step 2")

// Restore later
let restored = try await persistentAgent.restoreConversation(id: conversation.id)
```

---

### 11.10 Provide Example Processors Out of the Box

**Rationale:** Common patterns should be built-in.

```swift
// Yrden.Processors namespace
extension HistoryProcessor {
    static func keepRecent(_ count: Int) -> HistoryProcessor {
        KeepRecent(count: count)
    }

    static func enforceTokenLimit(_ limit: Int, model: String) -> HistoryProcessor {
        EnforceTokenLimit(maxTokens: limit, model: model)
    }

    static func redactPII() -> HistoryProcessor {
        PIIRedactor()
    }

    static func summarizeOld(threshold: Int) -> HistoryProcessor {
        Summarizer(threshold: threshold)
    }
}

// Usage
let agent = Agent(
    provider: anthropic,
    historyProcessors: [
        .keepRecent(30),
        .enforceTokenLimit(8000, model: "claude-3"),
        .redactPII()
    ]
)
```

---

## 12. Conclusion

### Key Takeaways

1. **Only 4 out of 8 frameworks support meaningful message modification** - most are observation-only
2. **PydanticAI and LangGraph offer the best flexibility** - declarative processors vs. full state control
3. **Automatic context management is rare** - only CrewAI and AutoGen provide it
4. **Token management is mostly manual** - requires custom implementation in most frameworks
5. **There are clear tradeoffs** - safety vs. flexibility, automatic vs. manual, declarative vs. imperative

### For Yrden

- **Adopt PydanticAI's history processor pattern** - declarative, composable, type-safe
- **Support LangGraph's iteration control** - for advanced use cases requiring fine-grained control
- **Provide built-in token management** - make limits first-class
- **Separate observation from modification** - hooks for observation, processors for modification
- **Include common processors out of the box** - keep recent, token limits, PII redaction, summarization
- **Make persistence opt-in** - don't force persistence on all agents
- **Support pause/resume** - human-in-the-loop is critical
- **Leverage Swift's type system** - compile-time safety, fluent APIs, protocol-oriented design

### Resources

- LangGraph: https://docs.langchain.com/oss/python/langgraph/
- PydanticAI: https://ai.pydantic.dev/
- OpenAI Agents: https://platform.openai.com/docs/agents
- Claude Agent SDK: https://github.com/anthropics/anthropic-sdk-typescript
- CrewAI: https://docs.crewai.com/
- AutoGen: https://microsoft.github.io/autogen/

---

**Document Version:** 1.0
**Last Updated:** February 4, 2026
**Author:** Comprehensive cross-SDK analysis based on 8 framework research documents
