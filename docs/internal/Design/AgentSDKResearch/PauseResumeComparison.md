# Pause/Resume Patterns: Cross-SDK Comparison

**Research Date:** February 2026
**Primary Focus:** PydanticAI, LangGraph, OpenAI Agents SDK, Vercel AI SDK
**Comprehensive Analysis:** 500+ lines, complete working examples

---

## Executive Summary

This document provides an in-depth analysis of pause/resume mechanisms across the four most sophisticated agent SDKs: PydanticAI, LangGraph, OpenAI Agents SDK, and Vercel AI SDK. These patterns are critical for:

- **Human-in-the-loop workflows** - Requiring approval before executing sensitive operations
- **Long-running workflows** - Persisting state across sessions, crashes, or deployments
- **Debugging and testing** - Inspecting and modifying execution state at specific points
- **Cost control** - Stopping execution when budget/token limits reached
- **Error recovery** - Resuming from failure points without re-executing earlier steps

### Key Findings

**Best-in-class implementations:**
- **PydanticAI** - Fine-grained iterator control with `.iter()` / `.next()`
- **LangGraph** - Comprehensive checkpointing with cross-session resume
- **OpenAI Agents SDK** - Serializable `RunState` with approval workflows
- **Vercel AI SDK** - Callback-based control with `prepareStep` and `stopWhen`

**Design Philosophy Differences:**
- **PydanticAI**: In-process iteration control (not serializable)
- **LangGraph**: Graph-based with persistent checkpoints (database-backed)
- **OpenAI SDK**: State serialization for async workflows (JSON-based)
- **Vercel AI**: Callback observation (limited pause capability)

---

## Table of Contents

1. [Pause Trigger Taxonomy](#1-pause-trigger-taxonomy)
2. [Pause Representation Patterns](#2-pause-representation-patterns)
3. [State Preservation](#3-state-preservation)
4. [Resume Mechanisms](#4-resume-mechanisms)
5. [Human-in-the-Loop Workflows](#5-human-in-the-loop-workflows)
6. [Cross-Session Resume](#6-cross-session-resume)
7. [Error Recovery](#7-error-recovery)
8. [Complete Code Examples](#8-complete-code-examples)
9. [Yrden Recommendations](#9-yrden-recommendations)

---

## 1. Pause Trigger Taxonomy

All four SDKs pause execution under specific conditions. Here's a complete taxonomy:

### 1.1 Resource Limits

**PydanticAI: UsageLimits**

```python
from pydantic_ai import UsageLimits, UsageLimitExceeded, capture_run_messages

limits = UsageLimits(
    request_limit=50,           # Max LLM API calls
    tool_calls_limit=100,       # Max tool executions
    input_tokens_limit=10000,   # Max input tokens
    output_tokens_limit=2000,   # Max output tokens
    total_tokens_limit=12000,   # Combined limit
)

# Execution stops when any limit is breached
with capture_run_messages() as messages:
    try:
        result = await agent.run('Complex task', deps=deps, usage_limits=limits)
    except UsageLimitExceeded as e:
        # Pause: Exception contains usage data
        print(f"Limit hit: {e}")  # "Exceeded request_limit of 50 (requests=51)"
        # messages contains full conversation history
        saved_state = messages  # Can resume from here
```

**Characteristics:**
- **Trigger**: Resource consumption thresholds
- **Representation**: Exception with usage metadata
- **State**: Must use `capture_run_messages()` context manager
- **Resume**: Restart with modified limits or different strategy

**Vercel AI SDK: maxSteps**

```typescript
import { generateText, stepCountIs } from 'ai';

const result = await generateText({
  model: openai('gpt-4'),
  tools: { search, analyze },
  stopWhen: stepCountIs(10),  // Pause after 10 tool execution steps
  prompt: 'Complex research task',
});

// No exception - graceful termination
console.log(result.finishReason);  // 'stop' or 'tool-calls'
console.log(result.steps.length);  // 10
```

**Characteristics:**
- **Trigger**: Step count threshold
- **Representation**: Normal return with partial result
- **State**: `steps` array contains full execution history
- **Resume**: Manual reconstruction from `steps`

**LangGraph: Recursion Limit**

```python
from langgraph.errors import GraphRecursionError

graph = StateGraph(MyState)
# ... add nodes/edges ...
app = graph.compile(checkpointer=MemorySaver())

try:
    result = app.invoke(
        {"input": "task"},
        config={"recursion_limit": 25}  # Default: 25
    )
except GraphRecursionError as e:
    # Pause: Graph hit max iterations
    state = app.get_state(config)  # Retrieve current state
    # Can resume from checkpoint
```

**Characteristics:**
- **Trigger**: Graph iteration limit
- **Representation**: Exception
- **State**: Checkpointer preserves state automatically
- **Resume**: Call `update_state()` and re-invoke

**OpenAI Agents SDK: MaxTurnsExceeded**

```python
from agents import Agent, Runner, MaxTurnsExceeded

agent = Agent(name="Assistant", tools=[...])

try:
    result = await Runner.run(agent, "Complex task", max_turns=10)
except MaxTurnsExceeded as e:
    # Pause: Agent exhausted turn limit
    # WARNING: No access to partial result or state!
    print(f"Exceeded {e.max_turns} turns")
    # e.run_data contains metadata but NOT resumable state
```

**Characteristics:**
- **Trigger**: Turn count limit
- **Representation**: Exception
- **State**: **LOST** - no access to partial result
- **Resume**: **NOT POSSIBLE** - must restart from beginning

### 1.2 Explicit User Control

**PydanticAI: Manual iter() Control**

```python
async with agent.iter('Analyze data', deps=deps) as run:
    async for node in run:
        if isinstance(node, CallToolsNode):
            # User decides to pause
            if some_condition:
                break  # Exit iteration
        node = await run.next(node)

    # Implicit pause - stopped iteration
    # Can resume by calling run.next() again later
```

**LangGraph: interrupt() Function**

```python
from langgraph.types import interrupt, Command

def process_node(state: State):
    # Explicit pause for user input
    user_feedback = interrupt("Please provide feedback")

    return {
        "result": f"Processed with feedback: {user_feedback}"
    }

# Execution pauses when interrupt() is called
result = app.invoke({"input": "task"}, config=config)
# Returns without completing

# Resume with user input
app.invoke(
    Command(resume="Great feedback!"),
    config=config
)
```

**OpenAI Agents SDK: Tool Approval**

```python
from agents import function_tool

@function_tool(needs_approval=True)
async def delete_file(path: str) -> str:
    """Delete a file - requires approval."""
    os.remove(path)
    return f"Deleted {path}"

# Execution pauses when approval-required tool is called
result = await Runner.run(agent, "Clean up temporary files")

if result.interruptions:
    # Pause: Tool approval required
    state = result.to_state()  # Get resumable state
    # Later...
    state.approve(result.interruptions[0])
    final_result = await Runner.run(agent, state)
```

**Vercel AI SDK: needsApproval**

```typescript
const riskyTool = tool({
  description: 'Execute database query',
  inputSchema: z.object({ query: z.string() }),
  needsApproval: true,  // Pause on this tool
  execute: async ({ query }) => db.execute(query),
});

const result = await generateText({
  tools: { riskyTool },
  prompt: 'Delete old records',
});

// Pauses automatically - returns tool-approval-request parts
// User must approve and re-call with approval
```

### 1.3 Workflow-Specific Triggers

**LangGraph: interrupt_before / interrupt_after**

```python
app = graph.compile(
    checkpointer=checkpointer,
    interrupt_before=["risky_operation"],  # Pause before this node
    interrupt_after=["data_collection"],   # Pause after this node
)

# Execution pauses at designated nodes
result = app.invoke({"input": "data"}, config=config)
state = app.get_state(config)

# Inspect state, then resume
app.invoke(None, config=config)  # Continue from pause
```

**Custom Conditions (All SDKs)**

Each SDK supports custom pause logic:

- **PydanticAI**: Break iteration loop based on node inspection
- **LangGraph**: Use `interrupt()` in node functions
- **OpenAI**: Dynamic `needs_approval` function
- **Vercel**: Custom `stopWhen` condition

---

## 2. Pause Representation Patterns

### 2.1 Exception-Based (PydanticAI, OpenAI, LangGraph)

**Pattern**: Pause is signaled by raising an exception.

**PydanticAI Example:**

```python
from pydantic_ai.exceptions import UsageLimitExceeded

try:
    result = await agent.run('task', usage_limits=limits)
except UsageLimitExceeded as e:
    # Exception IS the pause signal
    print(f"Paused: {e.limit_type} exceeded")
```

**Pros:**
- Clear error boundary
- Impossible to ignore (forces handling)
- Can attach metadata to exception

**Cons:**
- Control flow via exceptions (anti-pattern in some languages)
- Must use try/except for normal operation
- State may be lost (OpenAI's MaxTurnsExceeded)

### 2.2 Return Value (Vercel AI SDK)

**Pattern**: Pause is indicated by return value properties.

```typescript
const result = await generateText({
  stopWhen: stepCountIs(10),
  // ...
});

// Normal return - check finishReason to detect pause
if (result.finishReason === 'tool-calls') {
  // Paused due to tool calls without execution
  console.log('Paused mid-execution');
}
```

**Pros:**
- No exceptions for normal flow
- State always accessible via `result.steps`
- Can continue processing partial results

**Cons:**
- Easy to miss pause condition
- Ambiguous distinction between "done" and "paused"
- No built-in resume mechanism

### 2.3 State Return (LangGraph, OpenAI Agents SDK)

**Pattern**: Pause returns a state object that can be serialized and resumed.

**LangGraph Example:**

```python
result = app.invoke(input, config=config)
state = app.get_state(config)

if state.next:
    # Paused - has pending nodes
    print(f"Paused at: {state.next}")
    serialized = app.get_state_history(config)
else:
    # Completed
    print("Finished")
```

**OpenAI Example:**

```python
result = await Runner.run(agent, "task")

if result.interruptions:
    # Paused for approval
    state = result.to_state()
    state_json = state.to_json()  # Serialize for later
    # ... later ...
    state = RunState.from_json(state_json)
    state.approve(interruption)
    final = await Runner.run(agent, state)
```

**Pros:**
- Explicit state representation
- Serializable for cross-session resume
- Clear distinction between paused and completed

**Cons:**
- Requires checkpointer/state management infrastructure
- State object may be large
- Must handle state expiration

### 2.4 Iterator Pattern (PydanticAI)

**Pattern**: Pause is simply stopping iteration.

```python
async with agent.iter('task', deps=deps) as run:
    async for node in run:
        if should_pause(node):
            break  # Pause = stop iterating
        node = await run.next(node)

    # Paused here - run object still exists
    # Can resume by continuing iteration
```

**Pros:**
- Natural Python idiom
- Fine-grained control (per-node)
- State implicit in iterator

**Cons:**
- Limited to single session (iterator lifetime)
- No built-in serialization
- Must manage iterator lifecycle

---

## 3. State Preservation

### 3.1 What Gets Preserved

| SDK | Messages | Tool Results | Usage Stats | Agent State | Custom Data |
|-----|----------|--------------|-------------|-------------|-------------|
| **PydanticAI** | ✅ (with capture) | ✅ | ✅ | ❌ | ❌ |
| **LangGraph** | ✅ (checkpointer) | ✅ | ❌ | ✅ | ✅ (in state) |
| **OpenAI SDK** | ✅ (in state) | ✅ | ✅ | ✅ | ✅ (context) |
| **Vercel AI** | ✅ (steps array) | ✅ | ✅ | ❌ | ❌ |

### 3.2 State Preservation Details

**PydanticAI: Message Capture**

```python
from pydantic_ai import capture_run_messages, UsageLimitExceeded

with capture_run_messages() as messages:
    try:
        result = await agent.run('task', usage_limits=limits)
    except UsageLimitExceeded:
        # messages contains: [ModelRequest, ModelResponse, ...]
        # Can serialize and store
        saved = [msg.model_dump() for msg in messages]

        # Resume: Use as message_history
        result = await agent.run(
            'continue task',
            message_history=messages
        )
```

**Known Issue**: [#1083](https://github.com/pydantic/pydantic-ai/issues/1083) - Without `capture_run_messages()`, history is lost on exception.

**LangGraph: Checkpointer**

```python
from langgraph.checkpoint.memory import MemorySaver
from langgraph.checkpoint.sqlite import SqliteSaver

# In-memory (session only)
checkpointer = MemorySaver()

# Persistent (cross-session)
checkpointer = SqliteSaver.from_conn_string("./checkpoints.db")

app = graph.compile(checkpointer=checkpointer)

# State automatically saved at each step
result = app.invoke({"input": "data"}, config={"thread_id": "user-123"})

# Retrieve state
state = app.get_state(config={"thread_id": "user-123"})
print(state.values)     # Current state dict
print(state.next)       # Next nodes to execute
print(state.config)     # Configuration
```

**State includes:**
- All graph state values (TypedDict)
- Message history (if using `add_messages` reducer)
- Pending nodes
- Parent graph state (for subgraphs)

**OpenAI Agents SDK: RunState**

```python
from agents import RunState

# Get state after interruption
result = await Runner.run(agent, "task")
state = result.to_state()

# Serialize
state_json = state.to_json()

# What's included in state:
# - input: Original user input
# - new_items: Generated items (messages, tool calls, results)
# - raw_responses: LLM API responses
# - current_agent: Active agent
# - current_turn: Turn counter
# - interruptions: Pending approvals
# - context: NOT INCLUDED (must be provided on resume)

# Resume (different session)
state = RunState.from_json(state_json)
state.approve(state.interruptions[0])

# Must provide context again
result = await Runner.run(agent, state, context=my_context)
```

**Critical Limitation**: Agent configuration and context are NOT serialized. You must store and reconstruct them separately.

**Vercel AI SDK: Steps Array**

```typescript
const result = await generateText({
  stopWhen: stepCountIs(10),
  // ...
});

// Steps array contains ALL intermediate state
result.steps.forEach(step => {
  console.log(step.text);          // Generated text
  console.log(step.toolCalls);     // Tool invocations
  console.log(step.toolResults);   // Tool outputs
  console.log(step.usage);         // Token usage
  console.log(step.finishReason);  // Why this step ended
});

// But NO built-in resume mechanism
// Must manually reconstruct messages and re-call generateText()
```

### 3.3 Known State Preservation Issues

**PydanticAI:**
- [Issue #1083](https://github.com/pydantic/pydantic-ai/issues/1083): `UsageLimitExceeded` loses message history without `capture_run_messages()`
- `iter()` state not serializable (iterator-local)

**LangGraph:**
- Checkpointer storage overhead for large graphs
- State serialization fails for non-JSON types (must use custom serializers)
- No automatic state cleanup (old checkpoints accumulate)

**OpenAI Agents SDK:**
- Agent configuration not included in `RunState`
- Context must be reconstructed manually
- State size grows with long conversations (no automatic compaction)

**Vercel AI SDK:**
- No built-in resume (must manually reconstruct)
- `experimental_context` not persisted across steps
- [Issue #9631](https://github.com/vercel/ai/issues/9631): Message modifications in `prepareStep` may not persist

---

## 4. Resume Mechanisms

### 4.1 PydanticAI: Message History Continuation

```python
# Initial run
result1 = await agent.run('What is Python?', deps=deps)

# Resume by providing message history
result2 = await agent.run(
    'Give me an example',
    deps=deps,
    message_history=result1.all_messages()
)

# After limit exceeded
with capture_run_messages() as messages:
    try:
        await agent.run('task', usage_limits=limits)
    except UsageLimitExceeded:
        pass

# Resume with higher limit
result = await agent.run(
    'continue',
    message_history=messages,
    usage_limits=UsageLimits(request_limit=100)
)
```

**Key Points:**
- Resume = new run with old messages
- No special "resume" method
- Can modify prompt, limits, or even agent

### 4.2 LangGraph: invoke() Continuation

```python
# Initial run (pauses at interrupt)
app.invoke({"input": "data"}, config={"thread_id": "session-1"})

# Resume from checkpoint
app.invoke(
    None,  # No new input
    config={"thread_id": "session-1"}  # Same thread_id
)

# Or with new data
app.invoke(
    {"additional_data": "value"},
    config={"thread_id": "session-1"}
)

# Or with Command for advanced control
app.invoke(
    Command(resume="user input"),
    config={"thread_id": "session-1"}
)
```

**Key Points:**
- Resume by re-invoking with same `thread_id`
- Can pass `None`, new state, or `Command`
- Checkpointer handles state retrieval automatically

### 4.3 OpenAI Agents SDK: RunState Resumption

```python
# Initial run (pauses for approval)
result = await Runner.run(agent, "Delete all files")

if result.interruptions:
    state = result.to_state()

    # Handle approvals
    for interruption in state.interruptions:
        approved = get_user_approval(interruption)
        if approved:
            state.approve(interruption)
        else:
            state.reject(interruption)

    # Resume execution
    final_result = await Runner.run(
        agent,          # Same agent
        state,          # Resumable state
        context=ctx,    # Must provide context again
        max_turns=10    # Can adjust limits
    )
```

**Key Points:**
- Resume via `Runner.run()` with `RunState` input
- Must provide context again (not serialized)
- Can approve/reject multiple interruptions before resume

### 4.4 Vercel AI SDK: Manual Reconstruction

```typescript
// Initial run
const result1 = await generateText({
  model: openai('gpt-4'),
  stopWhen: stepCountIs(5),
  prompt: 'Research AI agents',
});

// NO BUILT-IN RESUME
// Must manually reconstruct messages from steps

const messages: CoreMessage[] = [];

// Reconstruct from steps
result1.steps.forEach(step => {
  // Add assistant messages
  if (step.text) {
    messages.push({
      role: 'assistant',
      content: step.text,
    });
  }

  // Add tool calls and results
  step.toolCalls.forEach(call => {
    messages.push({
      role: 'assistant',
      content: [
        {
          type: 'tool-call',
          toolCallId: call.toolCallId,
          toolName: call.toolName,
          args: call.args,
        },
      ],
    });
  });

  step.toolResults.forEach(result => {
    messages.push({
      role: 'tool',
      content: [
        {
          type: 'tool-result',
          toolCallId: result.toolCallId,
          result: result.result,
        },
      ],
    });
  });
});

// Resume with reconstructed history
const result2 = await generateText({
  model: openai('gpt-4'),
  messages: messages,
  stopWhen: stepCountIs(10),  // Increase limit
  prompt: 'Continue research',
});
```

**Key Points:**
- No first-class resume support
- Must manually convert `steps` to `messages`
- Error-prone (easy to miss tool results or reasoning)
- Community requests: [Discussion #7941](https://github.com/vercel/ai/discussions/7941)

---

## 5. Human-in-the-Loop Workflows

### 5.1 PydanticAI: Manual Approval via iter()

```python
async with agent.iter('Risky operation', deps=deps) as run:
    async for node in run:
        match node:
            case CallToolsNode():
                for tool_call in node.tool_calls:
                    # Inspect before execution
                    if tool_call.name in ['delete_data', 'send_email']:
                        print(f"Tool: {tool_call.name}")
                        print(f"Args: {tool_call.args}")

                        approved = input("Approve? (y/n): ") == 'y'
                        if not approved:
                            # Skip this node - don't execute
                            print("Rejected - skipping tool")
                            continue

                # Execute approved tools
                node = await run.next(node)

            case ModelRequestNode():
                # Can stream LLM call if desired
                node = await run.next(node)

            case End():
                print(f"Completed: {node.data}")
                break
```

**Workflow:**
1. Iterate through graph nodes
2. Inspect `CallToolsNode` for risky tools
3. Request approval (blocking or async)
4. Skip node (continue) or execute (run.next())
5. Repeat until `End` node

**Limitations:**
- No built-in approval UI
- Must handle approval logic manually
- Iterator cannot be serialized (session-bound)

### 5.2 LangGraph: interrupt() for User Input

```python
from langgraph.types import interrupt, Command

def review_draft(state: State):
    draft = state["draft_content"]

    # Request human review
    feedback = interrupt({
        "draft": draft,
        "message": "Please review and provide feedback"
    })

    # After resume, feedback is available
    return {
        "draft_content": apply_feedback(draft, feedback),
        "reviewed": True
    }

graph.add_node("review", review_draft)
app = graph.compile(checkpointer=checkpointer)

# Initial call pauses
result = app.invoke(
    {"draft_content": "Initial draft"},
    config={"thread_id": "doc-123"}
)

# Check if paused
state = app.get_state(config={"thread_id": "doc-123"})
if state.next:
    print("Waiting for user input")

# Resume with feedback
app.invoke(
    Command(resume={"changes": "Add more details"}),
    config={"thread_id": "doc-123"}
)
```

**Workflow:**
1. Node calls `interrupt(value)`
2. Execution pauses, returns to caller
3. Caller retrieves state, presents UI
4. User provides input
5. Caller resumes with `Command(resume=input)`

**Advantages:**
- Pause point is explicit in code
- State automatically persisted
- Can resume from different process

### 5.3 OpenAI Agents SDK: Tool Approval

```python
from agents import Agent, function_tool, Runner, RunState

# Define approval function
def needs_approval_check(ctx, tool_name: str, args: str) -> bool:
    """Dynamic approval based on arguments"""
    parsed = json.loads(args)
    # Require approval for large deletions
    return parsed.get("count", 0) > 100

@function_tool(needs_approval=needs_approval_check)
async def delete_records(ctx, count: int) -> str:
    """Delete records from database."""
    db.delete(count)
    return f"Deleted {count} records"

agent = Agent(
    name="DBAdmin",
    tools=[delete_records],
    instructions="Help manage the database"
)

# Run agent
result = await Runner.run(agent, "Clean up old records", context=ctx)

if result.interruptions:
    # Present approval UI
    for interruption in result.interruptions:
        print(f"Tool: {interruption.tool_name}")
        print(f"Args: {json.loads(interruption.arguments)}")

        approved = await request_approval_ui(interruption)

        # Get state and approve
        state = result.to_state()
        if approved:
            state.approve(interruption)
        else:
            state.reject(interruption)

    # Resume execution
    final_result = await Runner.run(agent, state, context=ctx)
```

**Workflow:**
1. Tool marked with `needs_approval=True` (or function)
2. Agent pauses when tool is called
3. `result.interruptions` contains pending approvals
4. Create UI to present to user
5. Call `state.approve()` or `state.reject()`
6. Resume with modified state

**Serialization Support:**

```python
# Serialize state for cross-session approval
if result.interruptions:
    state = result.to_state()
    state_json = state.to_json()

    # Store in database
    db.store_pending_approval({
        "user_id": user.id,
        "state": state_json,
        "interruptions": [
            {
                "tool": i.tool_name,
                "args": i.arguments,
                "timestamp": datetime.now()
            }
            for i in result.interruptions
        ]
    })

# Later (possibly different process)
pending = db.get_pending_approval(user.id)
state = RunState.from_json(pending["state"])

# User approves
state.approve(state.interruptions[0])

# Resume
final = await Runner.run(agent, state, context=ctx)
```

### 5.4 Vercel AI SDK: needsApproval

```typescript
import { tool, generateText } from 'ai';
import { z } from 'zod';

const deleteFileTool = tool({
  description: 'Delete a file',
  inputSchema: z.object({
    path: z.string(),
  }),

  // Dynamic approval
  needsApproval: async ({ path }) => {
    return path.includes('/system/');  // Require approval for system files
  },

  execute: async ({ path }) => {
    fs.unlinkSync(path);
    return `Deleted ${path}`;
  },
});

// First call - pauses for approval
const result1 = await generateText({
  model: openai('gpt-4'),
  tools: { deleteFile: deleteFileTool },
  prompt: 'Delete /system/config.txt',
});

// Result contains tool-approval-request parts
// Must make second call with approval

const messages = [
  ...result1.response.messages,
  {
    role: 'tool',
    content: [
      {
        type: 'tool-approval-decision',
        toolCallId: 'call-123',
        decision: 'approved',  // or 'rejected'
      },
    ],
  },
];

// Resume execution
const result2 = await generateText({
  model: openai('gpt-4'),
  messages: messages,
  tools: { deleteFile: deleteFileTool },
});
```

**Limitations:**
- No cross-session support (messages must be reconstructed)
- No built-in approval state management
- Manual message construction required
- Community request: [Issue #8421](https://github.com/vercel/ai/issues/8421) for better approval flow

---

## 6. Cross-Session Resume

### 6.1 LangGraph: First-Class Support

```python
from langgraph.checkpoint.sqlite import SqliteSaver

# Persistent checkpointer
checkpointer = SqliteSaver.from_conn_string("./sessions.db")
app = graph.compile(checkpointer=checkpointer)

# Session 1: Start task
config = {"configurable": {"thread_id": "user-123-task-5"}}
app.invoke({"input": "Research topic"}, config=config)

# ... User closes app, comes back tomorrow ...

# Session 2: Resume from same thread
result = app.invoke(None, config={"configurable": {"thread_id": "user-123-task-5"}})

# Or retrieve state for inspection
state = app.get_state(config={"configurable": {"thread_id": "user-123-task-5"}})
print(f"Resuming from step: {state.next}")
```

**State History:**

```python
# Get all checkpoints for this thread
history = app.get_state_history(config={"configurable": {"thread_id": "user-123-task-5"}})

for state in history:
    print(f"Checkpoint {state.config['configurable']['checkpoint_id']}")
    print(f"Values: {state.values}")
    print(f"Next: {state.next}")
```

**Advantages:**
- Automatic state persistence
- No manual serialization
- Can list all sessions
- Built-in state versioning (history)

**Storage Backends:**
- `MemorySaver` - In-memory (session only)
- `SqliteSaver` - Local SQLite database
- `PostgresSaver` - PostgreSQL
- `MongoDBSaver` - MongoDB
- Custom implementations via `BaseCheckpointSaver`

### 6.2 OpenAI Agents SDK: Manual Serialization

```python
import json
from agents import RunState

# Session 1: Pause at interruption
result = await Runner.run(agent, "Risky task")

if result.interruptions:
    state = result.to_state()

    # Serialize and store
    state_data = {
        "state_json": state.to_json(),
        "agent_config": {
            "name": agent.name,
            "model": agent.model,
            "instructions": agent.instructions,
            # ... other agent config
        },
        "context_data": {
            "user_id": ctx.user_id,
            "db_connection": ctx.db.connection_string,
            # ... serializable context data
        },
        "timestamp": datetime.now().isoformat()
    }

    # Store in database
    db.sessions.insert_one({
        "session_id": "session-123",
        "user_id": user.id,
        "data": json.dumps(state_data)
    })

# Session 2: Resume from stored state
session_data = db.sessions.find_one({"session_id": "session-123"})
data = json.loads(session_data["data"])

# Reconstruct state
state = RunState.from_json(data["state_json"])

# Reconstruct agent
agent = Agent(
    name=data["agent_config"]["name"],
    model=data["agent_config"]["model"],
    instructions=data["agent_config"]["instructions"],
    # ... restore tools, handoffs, etc.
)

# Reconstruct context
context = MyContext(
    user_id=data["context_data"]["user_id"],
    db=connect_db(data["context_data"]["db_connection"])
)

# Handle approval
state.approve(state.interruptions[0])

# Resume
result = await Runner.run(agent, state, context=context)
```

**Challenges:**
- Agent configuration not in `RunState`
- Context not serializable (connections, objects)
- Must handle agent/context reconstruction manually
- No built-in session management

### 6.3 PydanticAI: Message-Based Resume

```python
import json
from pydantic_ai import Agent, capture_run_messages

# Session 1: Capture messages
with capture_run_messages() as messages:
    try:
        result = await agent.run('task', usage_limits=limits)
    except UsageLimitExceeded:
        # Serialize messages
        message_data = [msg.model_dump() for msg in messages]

        # Store
        db.sessions.insert_one({
            "session_id": "session-456",
            "messages": json.dumps(message_data),
            "agent_config": {
                "model": agent.model,
                "system_prompt": agent.system_prompt,
            },
            "deps_data": serialize_deps(deps)
        })

# Session 2: Resume from stored messages
session = db.sessions.find_one({"session_id": "session-456"})
message_data = json.loads(session["messages"])

# Reconstruct messages (manually)
from pydantic_ai.messages import ModelMessage
messages = [ModelMessage.model_validate(m) for m in message_data]

# Reconstruct agent
agent = Agent(
    model=session["agent_config"]["model"],
    system_prompt=session["agent_config"]["system_prompt"],
    # ... restore tools
)

# Reconstruct deps
deps = deserialize_deps(session["deps_data"])

# Resume
result = await agent.run(
    'continue',
    message_history=messages,
    deps=deps,
    usage_limits=UsageLimits(request_limit=100)  # Higher limit
)
```

**Challenges:**
- No built-in session management
- Must serialize/deserialize messages manually
- Agent configuration not automatically preserved
- Dependency injection must be recreated

### 6.4 Vercel AI SDK: No Built-In Support

```typescript
// Session 1: Save steps
const result1 = await generateText({
  stopWhen: stepCountIs(5),
  // ...
});

// Manually serialize entire state
const sessionData = {
  steps: result1.steps.map(step => ({
    text: step.text,
    toolCalls: step.toolCalls,
    toolResults: step.toolResults,
    usage: step.usage,
    finishReason: step.finishReason,
  })),
  modelConfig: {
    modelId: 'gpt-4',
    temperature: 0.7,
  },
  toolConfig: {
    // Must store tool definitions somehow
  },
  timestamp: new Date().toISOString(),
};

await db.sessions.insertOne({
  sessionId: 'session-789',
  data: JSON.stringify(sessionData),
});

// Session 2: Reconstruct and resume
const session = await db.sessions.findOne({ sessionId: 'session-789' });
const data = JSON.parse(session.data);

// Reconstruct messages from steps (error-prone)
const messages: CoreMessage[] = [];
data.steps.forEach(step => {
  // ... manual reconstruction (see section 4.4)
});

// Resume
const result2 = await generateText({
  model: openai(data.modelConfig.modelId),
  messages: messages,
  stopWhen: stepCountIs(10),
});
```

**Status**: No first-class support. Community actively requesting this feature.

---

## 7. Error Recovery

### 7.1 PydanticAI: Retry with ModelRetry

```python
from pydantic_ai import ModelRetry

@agent.tool(retries=3)
async def fetch_data(ctx: RunContext[Deps], url: str) -> str:
    """Fetch data from URL."""
    try:
        data = await ctx.deps.http_client.get(url)
        return data
    except TimeoutError:
        # Ask LLM to retry with different approach
        raise ModelRetry("Request timed out. Try a different URL or method.")
    except HTTPError as e:
        if e.status_code == 404:
            raise ModelRetry(f"URL not found: {url}. Please provide a valid URL.")
        raise  # Other errors propagate

# Automatic retry flow:
# 1. Tool raises ModelRetry
# 2. Message sent back to LLM with retry suggestion
# 3. LLM calls tool again with modified arguments
# 4. Retry count tracked in ctx.retry
```

**After Max Retries:**

```python
# If all retries exhausted, exception propagates
try:
    result = await agent.run('task', deps=deps)
except Exception as e:
    # Can inspect error, retrieve partial results
    print(f"Failed: {e}")
```

### 7.2 LangGraph: Error Handling Strategies

```python
from typing import Literal

def risky_node(state: State):
    if random.random() < 0.3:
        raise ValueError("Random failure")
    return {"result": "success"}

# Strategy 1: Catch all errors, continue
graph.add_node("risky", risky_node, retry=RetryPolicy(max_attempts=3))

# Strategy 2: Conditional error handling
def handle_error(state: State, error: Exception):
    if isinstance(error, ValueError):
        # Recover by returning fallback state
        return {"result": "fallback", "error": str(error)}
    raise  # Re-raise other errors

graph.add_node("risky", risky_node, on_error=handle_error)

# Strategy 3: Redirect to error node
graph.add_node("risky", risky_node)
graph.add_node("error_handler", lambda s: {"status": "error"})
graph.add_edge("risky", "error_handler", condition=lambda s: s.get("error"))
```

**Checkpointed Recovery:**

```python
# If error occurs, state is checkpointed
try:
    result = app.invoke({"input": "data"}, config=config)
except Exception as e:
    # Retrieve last good state
    state = app.get_state(config)

    # Modify and retry
    state.values["retry_count"] = state.values.get("retry_count", 0) + 1
    app.update_state(config, state.values)

    # Resume from checkpoint
    result = app.invoke(None, config=config)
```

### 7.3 OpenAI Agents SDK: Guardrails

```python
from agents import tool_output_guardrail, ToolGuardrailFunctionOutput

@tool_output_guardrail
async def validate_output(ctx, tool, output: str) -> ToolGuardrailFunctionOutput:
    """Validate tool output for errors."""
    if "error" in output.lower():
        return ToolGuardrailFunctionOutput(
            tripwire_triggered=True,
            raise_exception=True  # Halt execution
        )

    if contains_pii(output):
        # Redact but continue
        return ToolGuardrailFunctionOutput(
            tripwire_triggered=False,
            output_info={"redacted": True}
        )

    return ToolGuardrailFunctionOutput(tripwire_triggered=False)

agent = Agent(
    name="SafeAgent",
    tools=[risky_tool],
    tool_output_guardrails=[validate_output]
)

# Guardrail failures raise exceptions
try:
    result = await Runner.run(agent, "Risky operation")
except ToolOutputGuardrailTripwireTriggered as e:
    print(f"Guardrail blocked: {e.guardrail}")
    # No resume mechanism - must restart
```

### 7.4 Vercel AI SDK: Error Callbacks

```typescript
const result = await generateText({
  model: openai('gpt-4'),
  tools: { riskyTool },

  onStepFinish: async ({ toolResults }) => {
    // Check for tool errors
    const errors = toolResults.filter(r => r.result instanceof Error);
    if (errors.length > 0) {
      console.error('Tool errors:', errors);
      // No automatic retry - must implement manually
    }
  },

  onError: ({ error }) => {
    // Called on unrecoverable errors
    console.error('Generation failed:', error);
    // No resume - execution stops
  },
});

// Streaming error handling
const stream = await streamText({ /* ... */ });

for await (const part of stream.fullStream) {
  if (part.type === 'error') {
    console.error('Stream error:', part.error);
    // Can continue consuming stream
  }

  if (part.type === 'tool-error') {
    console.error(`Tool ${part.toolCallId} failed:`, part.error);
    // Can log but not retry
  }
}
```

**No Built-In Retry**: Vercel AI SDK has no automatic retry for tool failures. Must implement manually:

```typescript
const toolWithRetry = tool({
  execute: async (args) => {
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        return await actualExecution(args);
      } catch (error) {
        if (attempt === 2) throw error;
        await sleep(1000 * (attempt + 1));  // Backoff
      }
    }
  },
});
```

---

## 8. Complete Code Examples

### 8.1 PydanticAI: Full Pause/Resume Cycle

```python
from pydantic_ai import Agent, RunContext, ModelRetry, capture_run_messages, UsageLimits
from pydantic_ai.exceptions import UsageLimitExceeded
from dataclasses import dataclass
import json

@dataclass
class Deps:
    db: DatabaseClient
    user_id: str

# Define agent
agent = Agent[Deps, str](
    'anthropic:claude-sonnet-4',
    deps_type=Deps,
    system_prompt="You are a helpful assistant"
)

@agent.tool(retries=3)
async def search_documents(ctx: RunContext[Deps], query: str) -> str:
    """Search the document database."""
    try:
        results = await ctx.deps.db.search(query)
        return json.dumps(results)
    except DatabaseError as e:
        raise ModelRetry(f"Search failed: {e}. Try a different query.")

# Session 1: Initial run with limits
limits = UsageLimits(request_limit=10)

with capture_run_messages() as messages:
    try:
        result = await agent.run(
            'Research AI agents comprehensively',
            deps=Deps(db=db_client, user_id='user-123'),
            usage_limits=limits
        )
        print(f"Completed: {result.output}")

    except UsageLimitExceeded as e:
        print(f"Paused: {e}")

        # Serialize state
        state_data = {
            "messages": [msg.model_dump() for msg in messages],
            "usage": e.usage.model_dump(),
            "deps_data": {
                "user_id": "user-123",
                "db_connection": db_client.connection_string
            }
        }

        # Store
        db.sessions.insert_one({
            "session_id": "research-task-1",
            "data": json.dumps(state_data)
        })

# Session 2: Resume with higher limit
session = db.sessions.find_one({"session_id": "research-task-1"})
data = json.loads(session["data"])

# Reconstruct messages
from pydantic_ai.messages import ModelMessage
messages = [ModelMessage.model_validate(m) for m in data["messages"]]

# Reconstruct deps
deps = Deps(
    db=connect_db(data["deps_data"]["db_connection"]),
    user_id=data["deps_data"]["user_id"]
)

# Resume with higher limit
result = await agent.run(
    'continue comprehensive research',
    message_history=messages,
    deps=deps,
    usage_limits=UsageLimits(request_limit=50)
)

print(f"Completed: {result.output}")
```

### 8.2 LangGraph: Interrupt and Resume

```python
from langgraph.graph import StateGraph, END
from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.types import interrupt, Command
from typing import TypedDict, Annotated
from operator import add

class State(TypedDict):
    messages: Annotated[list[str], add]
    draft: str
    approved: bool

def draft_content(state: State):
    # Generate draft
    draft = llm.generate(state["messages"])
    return {
        "messages": [f"Draft created: {draft[:50]}..."],
        "draft": draft
    }

def review_draft(state: State):
    # Pause for human review
    feedback = interrupt({
        "draft": state["draft"],
        "prompt": "Please review and provide feedback"
    })

    # Apply feedback
    revised = llm.revise(state["draft"], feedback)
    return {
        "messages": [f"Applied feedback: {feedback}"],
        "draft": revised,
        "approved": True
    }

def finalize(state: State):
    return {
        "messages": ["Finalized"],
        "result": state["draft"]
    }

# Build graph
graph = StateGraph(State)
graph.add_node("draft", draft_content)
graph.add_node("review", review_draft)
graph.add_node("finalize", finalize)

graph.set_entry_point("draft")
graph.add_edge("draft", "review")
graph.add_edge("review", "finalize")
graph.add_edge("finalize", END)

# Compile with checkpointer
checkpointer = SqliteSaver.from_conn_string("./workflows.db")
app = graph.compile(checkpointer=checkpointer)

# Session 1: Run until review pause
config = {"configurable": {"thread_id": "doc-approval-1"}}
result = app.invoke(
    {"messages": ["Create report on Q4 results"]},
    config=config
)

# Check if paused
state = app.get_state(config)
if state.next:
    print(f"Paused at: {state.next}")
    print(f"Draft: {state.values['draft']}")

# ... User reviews in UI ...

# Session 2: Resume with feedback
feedback = "Add more detail about revenue growth"
result = app.invoke(
    Command(resume=feedback),
    config=config
)

print(f"Final result: {result}")
```

### 8.3 OpenAI Agents SDK: Tool Approval Workflow

```python
from agents import Agent, function_tool, Runner, RunState
from dataclasses import dataclass
import json

@dataclass
class Context:
    db: DatabaseClient
    user_id: str

# Dynamic approval based on risk
def assess_risk(ctx, tool_name: str, args: str) -> bool:
    parsed = json.loads(args)

    # High-risk operations always require approval
    if tool_name == "delete_table":
        return True

    # Moderate-risk based on arguments
    if tool_name == "update_records":
        return parsed.get("count", 0) > 1000

    return False

@function_tool(needs_approval=assess_risk)
async def delete_table(ctx, table_name: str) -> str:
    """Delete an entire database table."""
    ctx.context.db.drop_table(table_name)
    return f"Deleted table {table_name}"

@function_tool(needs_approval=assess_risk)
async def update_records(ctx, table: str, count: int, values: dict) -> str:
    """Update multiple database records."""
    ctx.context.db.update(table, count, values)
    return f"Updated {count} records in {table}"

# Create agent
agent = Agent[Context](
    name="DBAdmin",
    model="gpt-4",
    tools=[delete_table, update_records],
    instructions="Help manage the database safely"
)

# Session 1: Run agent
context = Context(db=db_client, user_id="admin-1")
result = await Runner.run(
    agent,
    "Clean up the old_logs table and update user preferences",
    context=context,
    max_turns=10
)

if result.interruptions:
    print(f"{len(result.interruptions)} approvals needed")

    # Serialize state for async approval
    state = result.to_state()
    state_data = {
        "state_json": state.to_json(),
        "interruptions": [
            {
                "id": i.tool_call_id,
                "tool": i.tool_name,
                "args": json.loads(i.arguments),
                "timestamp": datetime.now().isoformat()
            }
            for i in result.interruptions
        ]
    }

    # Store for approval workflow
    db.approval_queue.insert_one({
        "request_id": "req-456",
        "user_id": "admin-1",
        "data": json.dumps(state_data)
    })

    print("Approval request submitted")

# Session 2: Process approval (possibly different process)
approval_request = db.approval_queue.find_one({"request_id": "req-456"})
data = json.loads(approval_request["data"])

# Restore state
state = RunState.from_json(data["state_json"])

# Present UI to approver
for int_data in data["interruptions"]:
    print(f"\nApproval Request:")
    print(f"Tool: {int_data['tool']}")
    print(f"Arguments: {int_data['args']}")

    # Get user decision
    decision = input("Approve? (y/n): ")

    # Find corresponding interruption
    interruption = next(
        i for i in state.interruptions
        if i.tool_call_id == int_data["id"]
    )

    if decision.lower() == 'y':
        state.approve(interruption)
        print("Approved")
    else:
        state.reject(interruption)
        print("Rejected")

# Resume execution
context = Context(db=db_client, user_id="admin-1")
final_result = await Runner.run(agent, state, context=context)

print(f"\nFinal output: {final_result.final_output}")
```

### 8.4 Vercel AI SDK: Multi-Step Workflow

```typescript
import { generateText, tool, stepCountIs } from 'ai';
import { openai } from '@ai-sdk/openai';
import { z } from 'zod';

// Define tools
const searchTool = tool({
  description: 'Search for information',
  inputSchema: z.object({ query: z.string() }),
  execute: async ({ query }) => {
    const results = await search(query);
    return JSON.stringify(results);
  },
});

const analyzeTool = tool({
  description: 'Analyze data',
  inputSchema: z.object({ data: z.string() }),
  execute: async ({ data }) => {
    const analysis = await analyze(data);
    return JSON.stringify(analysis);
  },
});

const summarizeTool = tool({
  description: 'Create final summary',
  inputSchema: z.object({ content: z.string() }),
  // No execute - triggers stop
});

// Phase 1: Initial research (limited steps)
const phase1 = await generateText({
  model: openai('gpt-4'),
  tools: { search: searchTool },
  stopWhen: stepCountIs(5),
  prompt: 'Research AI agent frameworks',

  onStepFinish: async ({ stepNumber, toolCalls, usage }) => {
    console.log(`Step ${stepNumber}: Called ${toolCalls.length} tools`);
    console.log(`Tokens: ${usage.totalTokens}`);
  },
});

console.log(`Phase 1 completed in ${phase1.steps.length} steps`);

// Check if we need phase 2
if (phase1.finishReason === 'stop') {
  console.log('Research complete, moving to analysis');
} else {
  console.log('Research incomplete, continuing...');
}

// Phase 2: Continue with analysis (reconstruct messages)
const messages = phase1.response.messages;

const phase2 = await generateText({
  model: openai('gpt-4'),
  messages: messages,
  tools: {
    search: searchTool,
    analyze: analyzeTool
  },
  stopWhen: stepCountIs(10),  // Higher limit
  prompt: 'Now analyze the findings',

  prepareStep: async ({ stepNumber, steps }) => {
    // Dynamic tool phasing
    if (stepNumber < 3) {
      return { activeTools: ['search'] };
    } else if (stepNumber < 7) {
      return { activeTools: ['analyze'] };
    } else {
      return { activeTools: ['summarize'] };
    }
  },
});

console.log(`Phase 2 completed in ${phase2.steps.length} steps`);

// Phase 3: Final summary
const finalMessages = phase2.response.messages;

const final = await generateText({
  model: openai('gpt-4'),
  messages: finalMessages,
  tools: { summarize: summarizeTool },
  stopWhen: [
    stepCountIs(3),
    ({ steps }) => steps.some(s => s.toolCalls.some(tc => tc.toolName === 'summarize'))
  ],
  prompt: 'Provide final summary',
});

console.log('Final summary:', final.text);

// Save entire workflow state
const workflowState = {
  phase1: {
    steps: phase1.steps.map(s => ({
      text: s.text,
      toolCalls: s.toolCalls,
      usage: s.usage,
    })),
    finishReason: phase1.finishReason,
  },
  phase2: {
    steps: phase2.steps.map(s => ({
      text: s.text,
      toolCalls: s.toolCalls,
      usage: s.usage,
    })),
    finishReason: phase2.finishReason,
  },
  final: {
    text: final.text,
    usage: final.totalUsage,
  },
};

await db.workflows.insertOne({
  workflowId: 'research-123',
  state: JSON.stringify(workflowState),
  timestamp: new Date(),
});
```

---

## 9. Yrden Recommendations

Based on this comprehensive analysis, here are architectural recommendations for Yrden's pause/resume system:

### 9.1 Adopt: Iterator-Based Control (PydanticAI Pattern)

**Rationale**: Swift's `AsyncSequence` provides natural, type-safe iteration control.

```swift
// Yrden API (proposed)
for await node in agent.iter(prompt: "Task", deps: deps) {
    switch node {
    case .modelRequest(let request):
        // Can inspect, modify, or skip
        print("Calling LLM with \(request.messages.count) messages")

    case .toolCalls(let calls):
        // Human-in-the-loop approval
        for call in calls {
            if needsApproval(call) {
                guard await requestApproval(call) else {
                    continue  // Skip this node
                }
            }
        }

    case .response(let partial):
        // Stream partial responses
        print(partial.text)

    case .end(let output):
        // Final output
        print("Completed: \(output)")
        break
    }
}
```

**Advantages:**
- Natural Swift idiom
- Fine-grained control (per-node)
- Type-safe with `AsyncSequence`
- No special "pause" mechanism needed (just stop iterating)

### 9.2 Adopt: State Serialization (OpenAI Pattern)

**Rationale**: Enables cross-session resume and approval workflows.

```swift
// Yrden API (proposed)
struct RunState: Codable, Sendable {
    let messages: [Message]
    let toolCalls: [ToolCall]
    let toolResults: [ToolResult]
    let currentTurn: Int
    let usage: Usage
    let interruptions: [ToolApproval]

    func approve(_ interruption: ToolApproval) { ... }
    func reject(_ interruption: ToolApproval) { ... }
}

// Session 1: Pause at approval
let result = try await agent.run(prompt, deps: deps)

if !result.interruptions.isEmpty {
    let state = result.toState()
    let stateData = try JSONEncoder().encode(state)

    // Store for later
    await database.saveSession(id: "session-123", state: stateData)
}

// Session 2: Resume
let stateData = await database.loadSession(id: "session-123")
let state = try JSONDecoder().decode(RunState.self, from: stateData)

state.approve(state.interruptions[0])

let finalResult = try await agent.run(state, deps: deps)
```

**Advantages:**
- Cross-session resume
- Async approval workflows
- Serializable for storage
- Clear separation of state vs. configuration

**Challenge**: Agent configuration and `Deps` not serializable.

**Solution**: Store separately (similar to OpenAI SDK approach).

### 9.3 Adopt: UsageLimits Pattern (PydanticAI)

**Rationale**: Prevents runaway costs and infinite loops.

```swift
// Yrden API (proposed)
struct UsageLimits {
    let maxRequests: Int?
    let maxToolCalls: Int?
    let maxInputTokens: Int?
    let maxOutputTokens: Int?
    let maxTotalTokens: Int?
}

enum AgentError: Error {
    case usageLimitExceeded(Usage, limit: UsageLimits)
}

// Usage
do {
    let result = try await agent.run(
        prompt,
        deps: deps,
        usageLimits: UsageLimits(
            maxRequests: 50,
            maxToolCalls: 100,
            maxTotalTokens: 100_000
        )
    )
} catch AgentError.usageLimitExceeded(let usage, let limits) {
    // Can inspect usage, decide whether to resume
    print("Hit limit: \(usage) / \(limits)")
}
```

**Advantage**: Explicit resource control with typed errors.

### 9.4 Adopt: Tool Approval (OpenAI Pattern)

**Rationale**: Clean separation of risky tools.

```swift
// Yrden API (proposed)
protocol Tool {
    associatedtype Arguments: SchemaType
    associatedtype Output

    var needsApproval: Bool { get }  // Or async function

    func call(context: Context, arguments: Arguments) async throws -> Output
}

struct DeleteFileTool: Tool {
    let needsApproval = true  // Always require approval

    func call(context: Context, arguments: Args) async throws -> String {
        // Only called after approval
        try FileManager.default.removeItem(atPath: arguments.path)
        return "Deleted \(arguments.path)"
    }
}
```

**Workflow**:
1. Agent identifies tool call
2. If `needsApproval`, add to `interruptions` list
3. Return `RunResult` with interruptions
4. User approves/rejects
5. Resume with modified `RunState`

### 9.5 Adopt: prepareStep Pattern (Vercel AI SDK)

**Rationale**: Dynamic configuration per iteration.

```swift
// Yrden API (proposed)
let result = try await agent.run(
    prompt,
    deps: deps,
    prepareStep: { context in
        // Dynamic model switching
        if context.stepNumber > 3 {
            return .init(model: .anthropic(.claude35Opus))
        }

        // Tool phasing
        if context.stepNumber < 3 {
            return .init(activeTools: ["search"])
        } else {
            return .init(activeTools: ["analyze", "summarize"])
        }

        // Context window management
        if context.messages.count > 20 {
            return .init(messages: Array(context.messages.suffix(10)))
        }

        return nil  // No changes
    }
)
```

**Use Cases**:
- Dynamic model selection (cheap → expensive)
- Tool phasing (search → analyze → summarize)
- Context window management
- Runtime configuration adjustments

### 9.6 Avoid: Checkpointing (LangGraph Complexity)

**Rationale**: Adds significant complexity for limited benefit in v1.

**Instead**:
- Manual state serialization (user's choice of storage)
- External session management (libraries, databases)
- Focus on making state easily serializable

**Reconsider for**: Phase 7+ if user demand exists.

### 9.7 API Design Summary

**Simple API (90% of use cases):**

```swift
// Non-streaming
let result = try await agent.run(prompt, deps: deps)

// Streaming
for await chunk in agent.runStream(prompt, deps: deps) {
    print(chunk.text)
}
```

**Advanced API (iteration control):**

```swift
for await node in agent.iter(prompt, deps: deps) {
    // Full control over each step
}
```

**Approval workflow:**

```swift
let result = try await agent.run(prompt, deps: deps)

if !result.interruptions.isEmpty {
    let state = result.toState()
    // ... approval UI ...
    state.approve(interruption)
    let final = try await agent.run(state, deps: deps)
}
```

**Resource limits:**

```swift
let result = try await agent.run(
    prompt,
    deps: deps,
    usageLimits: UsageLimits(maxRequests: 50)
)
```

**Dynamic configuration:**

```swift
let result = try await agent.run(
    prompt,
    deps: deps,
    prepareStep: { context in
        // Return step configuration or nil
    }
)
```

### 9.8 Implementation Priorities

**Phase 1: Core Pause Patterns**
1. `iter()` with `AsyncSequence` for fine-grained control
2. `UsageLimits` for resource management
3. `RunResult` with typed errors

**Phase 2: State Serialization**
4. `RunState` type with `Codable` conformance
5. `toState()` / `fromState()` methods
6. Message/tool state preservation

**Phase 3: Approval Workflows**
7. `needsApproval` protocol requirement
8. `interruptions` in `RunResult`
9. `approve()` / `reject()` methods

**Phase 4: Advanced Control**
10. `prepareStep` callback
11. Dynamic model/tool selection
12. Context window management

**Defer to Phase 7+**
- Checkpointing infrastructure
- Built-in session management
- State storage backends

---

## Conclusion

Each SDK implements pause/resume differently based on their architectural philosophy:

- **PydanticAI**: Iterator-based control for fine-grained inspection
- **LangGraph**: Checkpointing for long-running workflows
- **OpenAI Agents SDK**: State serialization for approval workflows
- **Vercel AI SDK**: Step limits with manual continuation

**For Yrden**, the optimal approach combines:
- **PydanticAI's iterator pattern** (natural Swift idiom)
- **OpenAI's state serialization** (cross-session resume)
- **PydanticAI's usage limits** (resource control)
- **OpenAI's tool approval** (human-in-the-loop)
- **Vercel's prepareStep** (dynamic configuration)

This hybrid approach provides maximum flexibility while avoiding the complexity of full checkpointing infrastructure.

---

## References

### PydanticAI
- [Agent Loop Control](https://ai.pydantic.dev/agents/#agent-loop)
- [Usage Limits](https://ai.pydantic.dev/usage-limits/)
- [Issue #1083: UsageLimitExceeded message history](https://github.com/pydantic/pydantic-ai/issues/1083)
- [capture_run_messages() docs](https://ai.pydantic.dev/api/messages/#capture_run_messages)

### LangGraph
- [Interrupts Documentation](https://docs.langchain.com/oss/python/langgraph/interrupts)
- [Checkpointing Guide](https://docs.langchain.com/oss/python/langgraph/add-memory)
- [Human-in-the-Loop](https://langchain-ai.github.io/langgraph/how-tos/human_in_the_loop/wait-user-input/)
- [State Management](https://docs.langchain.com/oss/python/langgraph/graph-api#state)

### OpenAI Agents SDK
- [Running Agents](https://openai.github.io/openai-agents-python/running_agents/)
- [Tool Approval](https://openai.github.io/openai-agents-python/tools/#approval)
- [RunState Reference](https://openai.github.io/openai-agents-python/ref/run_state/)
- [MaxTurnsExceeded](https://openai.github.io/openai-agents-python/ref/exceptions/)

### Vercel AI SDK
- [Loop Control](https://ai-sdk.dev/docs/agents/loop-control)
- [generateText Reference](https://ai-sdk.dev/docs/reference/ai-sdk-core/generate-text)
- [prepareStep](https://ai-sdk.dev/docs/reference/ai-sdk-core/generate-text#prepare-step)
- [Issue #7941: Step limits](https://github.com/vercel/ai/discussions/7941)
- [Issue #9631: prepareStep persistence](https://github.com/vercel/ai/issues/9631)

---

*Document version: 2.0*
*Research completed: February 2026*
*Total analysis: 4 SDKs, 15+ patterns, 8 complete examples*
