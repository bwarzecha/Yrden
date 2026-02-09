# Agent SDK Execution Models: Comprehensive Comparison

**Research Date**: February 2026
**Frameworks Analyzed**: OpenAI Agents, Claude Agent SDK, Cloudflare Agents, Vercel AI SDK, LangGraph, PydanticAI, AutoGen, CrewAI

---

## Table of Contents

1. [Execution Model Taxonomy](#1-execution-model-taxonomy)
2. [Control Flow Patterns](#2-control-flow-patterns)
3. [Streaming Architecture](#3-streaming-architecture)
4. [Iterator Patterns](#4-iterator-patterns)
5. [Hook Systems](#5-hook-systems)
6. [Blocking vs Non-blocking](#6-blocking-vs-non-blocking)
7. [Tradeoff Analysis](#7-tradeoff-analysis)
8. [Code Examples](#8-code-examples)
9. [Decision Framework](#9-decision-framework)

---

## 1. Execution Model Taxonomy

Agent SDKs use fundamentally different approaches to execute agentic workflows. These models can be classified into four major categories:

### 1.1 Run-to-Completion Model

**Definition**: Execution proceeds from start to finish in a single, uninterruptible flow. The application receives the final result after all processing completes.

**Characteristics**:
- **Encapsulated Loop**: Agent loop runs internally without external visibility
- **Final Result Only**: Application receives completed output, not intermediate steps
- **Retry Internalized**: Framework handles all retries and tool executions automatically
- **State Hidden**: Message history and tool results managed internally

**Frameworks Using This Model**:
- **OpenAI Agents SDK**: `Runner.run()` executes agent to completion
- **Claude Agent SDK**: `query()` function returns after full execution
- **Vercel AI SDK**: `generateText()` (non-streaming) blocks until done
- **CrewAI**: `crew.kickoff()` runs entire workflow and returns final result
- **AutoGen**: `agent.run()` executes task to completion

**Example Flow**:
```
Application Call → [Black Box: LLM calls + Tool execution + Retries] → Final Result
```

**When to Use**:
- Simple, single-purpose agents
- Fire-and-forget operations
- Batch processing workflows
- When intermediate steps aren't needed

**Limitations**:
- No mid-execution inspection
- Cannot pause for human approval during execution
- Limited control over retry/error handling
- Cannot modify context mid-run

---

### 1.2 Streaming-Observable Model

**Definition**: Execution progresses as a stream of events that applications can observe in real-time. The loop still runs autonomously, but applications receive granular updates.

**Characteristics**:
- **Event Emission**: Framework emits events for each step (tool call, text delta, completion)
- **Real-Time Updates**: Applications can display progress as it happens
- **Observation Only**: Events are read-only; cannot modify execution
- **Multiple Granularities**: Token-level, message-level, or step-level streams

**Frameworks Using This Model**:
- **OpenAI Agents SDK**: `Runner.run_streamed()` emits `StreamEvent` types
- **Claude Agent SDK**: `include_partial_messages=True` enables token streaming
- **Vercel AI SDK**: `streamText()` with `fullStream` provides complete event access
- **Cloudflare Agents**: WebSocket-based streaming with resumable streams
- **PydanticAI**: `run_stream_events()` yields `AgentStreamEvent` types
- **AutoGen**: `run_stream()` returns `AsyncIterator[StreamEvent]`

**Event Hierarchy (Common Pattern)**:
```
Level 1: Token deltas (text-delta, reasoning-delta)
Level 2: Semantic events (tool-call-start, tool-call-end, message-complete)
Level 3: Agent transitions (agent-switched, handoff-occurred)
Level 4: Execution lifecycle (start, finish, error)
```

**Example Flow**:
```
Application Call → Stream Opens
                 ↓
         [Event 1: text-delta] → Display
                 ↓
         [Event 2: tool-call-start] → Show indicator
                 ↓
         [Event 3: tool-result] → Update UI
                 ↓
         [Event 4: finish] → Close stream
```

**When to Use**:
- Interactive UIs requiring live updates
- Long-running operations needing progress feedback
- Real-time dashboards
- Debugging and observability

**Limitations**:
- Cannot pause execution mid-stream
- Cannot modify tool arguments after they're generated
- Cancellation may be delayed until current step completes
- Higher implementation complexity

---

### 1.3 Iterator-Based Model

**Definition**: Execution is externalized as an explicit iteration loop where the application controls advancement through individual steps.

**Characteristics**:
- **Explicit Steps**: Each iteration represents a distinct node in the execution graph
- **Application Control**: Application decides when to advance to next step
- **Inspection Before Execution**: Nodes can be examined before being executed
- **Modification Possible**: Some frameworks allow altering nodes before execution
- **Manual Driving**: Application must call `.next()` or iterate with `for await`

**Frameworks Using This Model**:
- **PydanticAI**: `agent.iter()` returns `AgentRun` with manual `next()` control
- **LangGraph**: `.stream()` with manual consumption of graph nodes

**Node Types (PydanticAI Example)**:
```typescript
type AgentNode =
  | UserPromptNode       // Initial input configuration
  | ModelRequestNode     // LLM API call about to be made
  | CallToolsNode        // Tool executions about to run
  | End                  // Terminal state with final result
```

**Example Flow**:
```python
async with agent.iter('prompt', deps=deps) as run:
    node = run.next_node  # Get first node (UserPromptNode)

    while not isinstance(node, End):
        # Inspect node
        if isinstance(node, CallToolsNode):
            # Human approval for sensitive operations
            if requires_approval(node.tool_calls):
                approved = await get_approval()
                if not approved:
                    continue  # Skip this node

        # Execute node and get next
        node = await run.next(node)

    # Access final result
    result = run.result
```

**When to Use**:
- Human-in-the-loop workflows with tool approval
- Complex error recovery requiring custom logic
- Step-by-step debugging
- Fine-grained control over execution flow
- Implementing custom retry strategies

**Limitations**:
- Higher complexity compared to run-to-completion
- Manual iteration boilerplate
- Requires understanding of graph structure
- More error-prone (missing `.next()` calls)

---

### 1.4 Graph-Based Model

**Definition**: Execution is structured as an explicit directed graph where nodes represent computations and edges represent transitions. The framework executes the graph with configurable routing.

**Characteristics**:
- **Explicit Graph Construction**: Nodes and edges defined upfront
- **Superstep Execution**: Nodes in parallel branches execute simultaneously
- **Transactional Semantics**: All-or-nothing state updates within supersteps
- **Checkpointing**: Graph state persisted at superstep boundaries
- **Dynamic Routing**: Conditional edges based on node outputs

**Frameworks Using This Model**:
- **LangGraph**: Primary execution model via `StateGraph`

**Graph Structure**:
```python
from langgraph.graph import StateGraph

graph = StateGraph(State)

# Add nodes
graph.add_node("research", research_node)
graph.add_node("analyze", analyze_node)
graph.add_node("write", write_node)

# Add edges
graph.add_edge("research", "analyze")
graph.add_conditional_edges(
    "analyze",
    should_continue,  # Router function
    {
        "write": "write",
        "research": "research",  # Loop back
        END: END
    }
)

graph.set_entry_point("research")
app = graph.compile(checkpointer=checkpointer)
```

**Superstep Example**:
```
Superstep 1: [Node A] [Node B] [Node C]  (parallel execution)
                ↓        ↓        ↓
           [All complete] → State update (atomic)
                ↓
Superstep 2: [Node D]  (depends on A, B, C outputs)
                ↓
           [Complete] → State update
                ↓
             END
```

**When to Use**:
- Complex branching workflows
- Map-reduce patterns with dynamic parallelism
- Workflows requiring persistent checkpoints
- Multi-step pipelines with conditional logic
- Distributed agent systems

**Limitations**:
- Steep learning curve (graph theory concepts)
- High boilerplate for simple workflows
- Debugging complexity increases with graph size
- Transactional failures roll back entire superstep
- Overkill for linear agent chains

---

### 1.5 Event-Driven Model

**Definition**: Execution is orchestrated through event handlers that respond to specific triggers. The framework dispatches events, and agents react based on subscribed patterns.

**Characteristics**:
- **Message Handlers**: Agents register handlers for message types
- **Pub-Sub Architecture**: Events published to topics, agents subscribe
- **Asynchronous Processing**: Handlers execute when messages arrive
- **Loose Coupling**: Agents don't directly call each other

**Frameworks Using This Model**:
- **Cloudflare Agents**: Based on Durable Objects event model
- **AutoGen Core**: `@message_handler` decorator pattern
- **CrewAI Flows**: `@listen` decorator for method chaining

**Pattern (AutoGen Core)**:
```python
from autogen_core import RoutedAgent, message_handler

class ResearchAgent(RoutedAgent):
    @message_handler
    async def handle_research_request(
        self,
        message: ResearchRequest,
        ctx: MessageContext
    ) -> None:
        result = await self.research(message.query)

        # Publish result to topic
        await self.publish_message(
            ResearchComplete(data=result),
            topic=ctx.topic_id
        )
```

**When to Use**:
- Multi-agent systems with decentralized coordination
- Long-running workflows spanning multiple processes
- Distributed systems with message queues
- Reactive architectures

**Limitations**:
- Harder to trace execution flow
- Requires understanding of event propagation
- Debugging challenges (events may be async/delayed)
- More infrastructure complexity

---

## 2. Control Flow Patterns

### 2.1 Linear Sequential

**Description**: Tasks execute in strict order. Each task completes before the next begins. Output from task N becomes input to task N+1.

**Visual**:
```
Task 1 → Output → Task 2 → Output → Task 3 → Output → END
```

**Frameworks**:
- **CrewAI**: `Process.sequential`
- **AutoGen**: `RoundRobinGroupChat` with fixed order
- **LangGraph**: Sequential edges in graph

**CrewAI Example**:
```python
from crewai import Crew, Process

crew = Crew(
    agents=[researcher, writer, editor],
    tasks=[research_task, write_task, edit_task],
    process=Process.sequential  # Tasks run in order
)

result = crew.kickoff(inputs={"topic": "AI"})
```

**Characteristics**:
- Predictable execution order
- No parallelism (sequential bottleneck)
- Simple to reason about
- Clear data dependencies

**When to Use**:
- Linear pipelines (research → write → edit)
- Tasks with strict dependencies
- Simple workflows without branching

---

### 2.2 Tool Loop (ReAct Pattern)

**Description**: Agent alternates between reasoning and tool usage until reaching a final answer or hitting a limit.

**Visual**:
```
User Prompt → LLM → Tool Calls? ┐
                 ↑                │
                 │    Yes         ↓
                 └─── Execute Tools

                      No
                      ↓
                  Final Output
```

**Frameworks**:
- **OpenAI Agents SDK**: Default agent behavior
- **Vercel AI SDK**: `generateText()` with tools
- **PydanticAI**: Agent loop with tool execution
- **Anthropic (via prompt caching)**: Extended Thinking mode
- **AutoGen**: `AssistantAgent` with tools

**OpenAI Example**:
```python
from agents import Agent, function_tool

@function_tool
async def search(query: str) -> str:
    return search_api(query)

agent = Agent(
    name="assistant",
    model="gpt-4",
    tools=[search],
    tool_use_behavior="run_llm_again"  # Continue after tool use
)

result = await Runner.run(agent, "Research quantum computing")
# Loop: LLM → search(quantum computing) → LLM processes result → final answer
```

**Stop Conditions**:
- **No tool calls**: LLM returns text without requesting tools
- **Max turns**: Iteration limit reached
- **Tool without execute**: Tool requiring approval encountered
- **Custom condition**: Application-defined stopping logic

**Characteristics**:
- Autonomous tool usage
- Can enter infinite loops (requires max_turns)
- LLM decides when to stop
- Multiple tool calls can occur per turn

---

### 2.3 Hierarchical Delegation

**Description**: A manager agent coordinates specialist agents. The manager analyzes tasks, delegates to appropriate subordinates, and validates outputs.

**Visual**:
```
          Manager Agent
         /      |      \
        ↓       ↓       ↓
    Agent A  Agent B  Agent C
    (Task 1) (Task 2) (Task 3)
        ↓       ↓       ↓
      Results → Manager validates → Final Output
```

**Frameworks**:
- **CrewAI**: `Process.hierarchical` with manager_llm
- **AutoGen**: `SelectorGroupChat` with model-based selection
- **OpenAI Agents SDK**: Handoffs with coordinator agent

**CrewAI Example**:
```python
crew = Crew(
    agents=[researcher, analyst, writer],
    tasks=[research, analyze, write],
    process=Process.hierarchical,
    manager_llm="gpt-4o"  # Manager coordinates delegation
)
```

**Manager Responsibilities**:
1. Analyze incoming tasks
2. Match tasks to agent capabilities
3. Delegate work
4. Review outputs
5. Request revisions if needed
6. Produce final integrated result

**When to Use**:
- Complex multi-agent coordination
- Tasks requiring different specializations
- Dynamic workload balancing

**Limitations**:
- Manager overhead (additional LLM calls)
- Single point of failure (manager)
- Can be slower than sequential for simple tasks

---

### 2.4 Handoff/Swarm Pattern

**Description**: Agents explicitly transfer control to peers. Each agent decides when to hand off and to whom. Coordination is decentralized.

**Visual**:
```
User → Travel Agent ─handoff→ Flights Agent ─handoff→ User
              │
              └─handoff→ Hotels Agent ─handoff→ User
```

**Frameworks**:
- **OpenAI Agents SDK**: `handoffs` parameter with transfer tools
- **AutoGen**: `Swarm` team with handoff termination
- **LangGraph**: Using `Command` to route to different subgraphs

**OpenAI Example**:
```python
spanish_agent = Agent(name="Spanish", instructions="Respond in Spanish")
english_agent = Agent(name="English", instructions="Respond in English")

triage = Agent(
    name="Triage",
    instructions="Route to language-appropriate agent",
    handoffs=[spanish_agent, english_agent]
)
# Creates transfer_to_spanish and transfer_to_english tools automatically
```

**AutoGen Example**:
```python
from autogen_agentchat.teams import Swarm

travel = AssistantAgent(
    "travel",
    handoffs=["refunds", "user"]
)

refunds = AssistantAgent(
    "refunds",
    handoffs=["user"]
)

team = Swarm(
    [travel, refunds],
    termination_condition=HandoffTermination(target="user")
)
```

**Characteristics**:
- Localized decision-making
- No central coordinator
- Agents share conversation context
- Flexible routing based on runtime conditions

**When to Use**:
- Customer service routing
- Domain-specific specialization
- Flexible workflows where path isn't predetermined

---

### 2.5 State Machine (Flow-Based)

**Description**: Execution follows a state graph with explicitly defined transitions. Each state represents a computation, and edges define allowed transitions.

**Visual**:
```
     [start]
        ↓
    [research]
        ↓
    [analyze] ─┐
        ↓      │ (needs_more_data)
    [write]    │
        ↑      │
        └──────┘
        ↓
     [END]
```

**Frameworks**:
- **LangGraph**: Core execution model via `StateGraph`
- **CrewAI Flows**: Using `@start`, `@listen`, `@router`
- **Cloudflare Agents**: Workflows with step-based execution

**CrewAI Flows Example**:
```python
from crewai.flow.flow import Flow, start, listen, router

class ArticleFlow(Flow):
    @start()
    def research(self):
        return {"findings": research_data}

    @router(research)
    def evaluate_quality(self, result):
        if result["findings"]["quality"] > 0.8:
            return "write"
        return "research_more"

    @listen("write")
    def write_article(self):
        return final_article

    @listen("research_more")
    def deep_dive(self):
        # Loop back to research
        return self.research()
```

**LangGraph Example**:
```python
from langgraph.graph import StateGraph, END

def should_continue(state):
    if state["needs_more_data"]:
        return "research"
    return "write"

graph = StateGraph(State)
graph.add_node("research", research_node)
graph.add_node("write", write_node)

graph.add_conditional_edges(
    "research",
    should_continue,
    {"research": "research", "write": "write"}
)

graph.add_edge("write", END)
```

**When to Use**:
- Complex branching logic
- Workflows with loops and retries
- Multi-step pipelines requiring checkpoints

---

### 2.6 Parallel Execution

**Description**: Multiple operations execute simultaneously. Results are aggregated before proceeding.

**Visual**:
```
         Start
           │
    ┌──────┼──────┐
    ↓      ↓      ↓
  Task A Task B Task C  (parallel)
    ↓      ↓      ↓
    └──────┼──────┘
           ↓
      Aggregate Results
           ↓
          END
```

**Frameworks**:
- **LangGraph**: Supersteps execute parallel nodes
- **LangGraph Send API**: Dynamic parallel task creation
- **Vercel AI SDK**: Parallel tool calls (when `parallel_tool_calls=True`)
- **PydanticAI**: Tools execute in parallel by default

**LangGraph Send Example**:
```python
from langgraph.graph import StateGraph, Send

def generate_tasks(state):
    # Dynamically create parallel tasks
    return [
        Send("process_item", {"item": item})
        for item in state["items"]
    ]

def aggregate(state):
    # Collect results from parallel executions
    return {"summary": combine(state["results"])}

graph = StateGraph(State)
graph.add_node("process_item", process_node, defer=False)
graph.add_node("aggregate", aggregate, defer=True)  # Waits for all

graph.add_conditional_edges("start", generate_tasks)
graph.add_edge("process_item", "aggregate")
```

**When to Use**:
- Independent tasks (no data dependencies)
- Map-reduce patterns
- Batch processing
- Reducing total execution time

---

## 3. Streaming Architecture

### 3.1 Stream Types Taxonomy

| Stream Type | Granularity | Use Case | Frameworks |
|-------------|-------------|----------|------------|
| **Token Stream** | Individual tokens | Real-time typing effect | Vercel, Claude SDK, OpenAI |
| **Text Stream** | Complete sentences/paragraphs | Progressive text display | All frameworks |
| **Event Stream** | Semantic events (tool calls, etc.) | Observability, debugging | OpenAI, Vercel, PydanticAI, AutoGen |
| **Object Stream** | Partial structured outputs | Progressive form filling | Vercel, PydanticAI |
| **Element Stream** | Array elements as they complete | List rendering | Vercel |
| **State Stream** | State changes in graph | Workflow monitoring | LangGraph |

---

### 3.2 Three-Tier Streaming Hierarchy

Most frameworks implement a three-tier hierarchy for streaming:

#### Tier 1: Token-Level (Raw Deltas)

**Purpose**: Provide immediate feedback character-by-character.

**OpenAI Example**:
```python
result = await Runner.run_streamed(agent, "Write a story")

async for event in result.stream_events():
    if event.type == "raw_response_event":
        if isinstance(event.data, ResponseTextDeltaEvent):
            print(event.data.delta, end="", flush=True)
```

**Vercel AI SDK Example**:
```typescript
const { textStream } = streamText({
    model: openai('gpt-4'),
    prompt: 'Write a story'
});

for await (const chunk of textStream) {
    process.stdout.write(chunk);  // "Once", " upon", " a", " time"
}
```

**Characteristics**:
- Highest frequency (hundreds of events per second)
- Immediate user feedback
- Requires handling partial words
- May include incomplete unicode sequences

#### Tier 2: Semantic-Level (Tool Calls, Messages)

**Purpose**: Notify when complete semantic units finish.

**OpenAI Example**:
```python
async for event in result.stream_events():
    if event.type == "run_item_stream_event":
        match event.name:
            case "tool_called":
                print(f"\n[Calling {event.item.name}]\n")
            case "tool_output":
                print(f"\n[Result: {event.item.output}]\n")
            case "message_output_created":
                print("Assistant response complete")
```

**Vercel AI SDK Example**:
```typescript
const { fullStream } = streamText({
    model: openai('gpt-4'),
    tools: { search, calculate }
});

for await (const part of fullStream) {
    switch (part.type) {
        case 'tool-call':
            console.log(`Tool: ${part.toolName}`);
            break;
        case 'tool-result':
            console.log(`Result: ${part.output}`);
            break;
    }
}
```

**Characteristics**:
- Medium frequency (1-10 events per tool call)
- Complete tool invocations
- Useful for progress indicators
- Can update UI with specific tool status

#### Tier 3: Agent-Level (Handoffs, State Changes)

**Purpose**: Track high-level coordination events.

**OpenAI Example**:
```python
async for event in result.stream_events():
    if event.type == "agent_updated_stream_event":
        print(f"Handed off to: {event.new_agent.name}")
```

**LangGraph Example**:
```python
for event in graph.stream(inputs):
    print(f"Node: {event['node']}")
    print(f"State: {event['state']}")
```

**Characteristics**:
- Low frequency (1-5 events per agent run)
- Coordination visibility
- Useful for workflow monitoring
- Critical for debugging handoffs

---

### 3.3 Stream Consumption Patterns

#### Pattern 1: Immediate Display

```python
# Vercel AI SDK
for await (const chunk of result.textStream) {
    process.stdout.write(chunk);
}
```

**Use Case**: Live typing effect in chat interfaces

#### Pattern 2: Buffered Accumulation

```python
# PydanticAI
accumulated = ""
async for chunk in result.stream_text():
    accumulated += chunk
    # Update UI every N characters or N milliseconds

print(f"Complete: {accumulated}")
```

**Use Case**: Reduce UI update frequency for performance

#### Pattern 3: Event-Driven React

```typescript
// OpenAI
for await (const event of result.streamEvents()) {
    switch (event.type) {
        case 'text-delta':
            updateTextDisplay(event.text);
            break;
        case 'tool-call':
            showToolIndicator(event.toolName);
            break;
    }
}
```

**Use Case**: Complex UIs with multiple update targets

#### Pattern 4: Hybrid (Token + Semantic)

```python
# Combine multiple stream types
async for event in result.stream_events():
    if event.type == "text_delta":
        display_token(event.delta)
    elif event.type == "tool_call_start":
        show_loading_indicator(event.tool_name)
    elif event.type == "tool_result":
        update_result_panel(event.output)
```

**Use Case**: Rich debugging interfaces, IDE integrations

---

### 3.4 Structured Output Streaming

**Challenge**: How to stream partial JSON objects that are progressively validated?

#### Vercel AI SDK Approach:

```typescript
const { partialOutputStream } = streamText({
    model: openai('gpt-4'),
    output: Output.object({
        schema: z.object({
            name: z.string(),
            bio: z.string(),
            skills: z.array(z.string())
        })
    })
});

for await (const partial of partialOutputStream) {
    // partial = { name: "John" }
    // partial = { name: "John", bio: "Software" }
    // partial = { name: "John", bio: "Software engineer", skills: ["JS"] }
    console.log(partial);
}
```

**Characteristics**:
- Partial objects validate against subset of schema
- Fields appear progressively
- Final object guaranteed valid

#### PydanticAI Approach:

```python
from pydantic import BaseModel

class Profile(BaseModel):
    name: str
    bio: str
    skills: list[str]

agent = Agent('openai:gpt-4', output_type=Profile)

async with agent.run_stream('Generate profile') as result:
    async for partial in result.stream_output(debounce_by=0.1):
        # partial is progressively built Profile
        print(f"Name: {partial.name}, Skills: {partial.skills}")
```

**Important Limitation**: First matching output terminates agent run (even with pending tool calls) unless `end_strategy='exhaustive'`.

---

### 3.5 Resumable Streaming

**Problem**: What happens if the client disconnects mid-stream?

#### Cloudflare Agents Solution:

```typescript
class ChatAgent extends AIChatAgent<Env> {
    // Automatically resumes from last position on reconnect
    async onChatMessage(onFinish) {
        return createDataStreamResponse({
            execute: async (dataStream) => {
                const stream = streamText({
                    model: openai('gpt-4'),
                    messages: this.messages,
                    onFinish
                });
                stream.mergeIntoDataStream(dataStream);
            }
        });
    }
}
```

**How it works**:
1. Agent stores stream position in persistent state
2. Client reconnects with same agent ID
3. Stream resumes from last acknowledged position

**Limitations**: Only Cloudflare Agents supports this natively due to Durable Objects persistence.

---

### 3.6 Cancellation Patterns

#### Immediate Cancellation

```python
# OpenAI
result = await Runner.run_streamed(agent, "Long task")
await asyncio.sleep(5)
result.cancel(mode="immediate")  # Stops immediately
```

#### Graceful Cancellation

```python
# OpenAI
result.cancel(mode="after_turn")  # Completes current turn, then stops
```

#### AbortSignal Pattern

```typescript
// Vercel AI SDK
const controller = new AbortController();

const result = streamText({
    model: openai('gpt-4'),
    prompt: 'Long task',
    abortSignal: controller.signal
});

// Later
controller.abort();
```

#### Token-Based Cancellation

```python
# AutoGen
from autogen_core import CancellationToken

token = CancellationToken()

task = asyncio.create_task(
    team.run(task="...", cancellation_token=token)
)

# Cancel after timeout
await asyncio.sleep(30)
token.cancel()
```

---

## 4. Iterator Patterns

### 4.1 Manual Node Iteration (PydanticAI)

**Pattern**: Application explicitly advances through execution graph nodes.

```python
from pydantic_ai import Agent
from pydantic_ai.agent import UserPromptNode, ModelRequestNode, CallToolsNode, End

agent = Agent('openai:gpt-4', tools=[search_tool, calc_tool])

async with agent.iter('Analyze data', deps=deps) as run:
    node = run.next_node

    while not isinstance(node, End):
        # Inspect before execution
        if isinstance(node, CallToolsNode):
            for tool_call in node.tool_calls:
                print(f"About to call: {tool_call.name}")

                # Human approval check
                if tool_call.name == "delete_data":
                    approved = await get_approval(tool_call)
                    if not approved:
                        continue  # Skip this iteration

        # Execute and advance
        node = await run.next(node)

    # Access final result
    final = run.result
```

**Node Types**:
- `UserPromptNode`: Initial configuration and system prompts
- `ModelRequestNode`: LLM API call (can be streamed via `node.stream()`)
- `CallToolsNode`: Tool execution batch (also streamable)
- `End`: Terminal node with final validated output

**Control Capabilities**:
- Skip nodes (don't call `.next()`)
- Access usage data between steps
- Stream individual node execution
- Implement custom approval logic

**Limitations**:
- Cannot modify tool arguments after LLM generates them
- Cannot inject new messages mid-iteration
- Cannot modify the message list directly

---

### 4.2 AsyncIterator Pattern (Streaming as Iteration)

**Pattern**: Iteration over stream events provides step-by-step observation without control.

```python
# Vercel AI SDK (TypeScript)
const result = await streamText({
    model: openai('gpt-4'),
    tools: { search },
    prompt: 'Research AI'
});

// result is AsyncIterable
for await (const event of result.fullStream) {
    // Events arrive as they occur
    if (event.type === 'tool-call') {
        console.log(`Calling ${event.toolName}`);
    }
}

// After iteration completes, access final result
const finalText = await result.text;
```

**Key Difference from PydanticAI**: This is **observation**, not **control**. You cannot skip or modify events.

---

### 4.3 LangGraph Stream Modes

LangGraph offers multiple iteration modes via `.stream()`:

```python
from langgraph.graph import StateGraph

graph = StateGraph(State)
# ... build graph

app = graph.compile()
```

#### Mode 1: Values (State Updates)

```python
for event in app.stream(inputs, stream_mode="values"):
    # event = complete state after each node
    print(event["messages"])
```

**Use Case**: Monitor state evolution over time.

#### Mode 2: Updates (Deltas)

```python
for event in app.stream(inputs, stream_mode="updates"):
    # event = {"node_name": partial_state_update}
    print(f"Node {list(event.keys())[0]} updated")
```

**Use Case**: See exactly what each node changed.

#### Mode 3: Messages (Agent Messages)

```python
for event in app.stream(inputs, stream_mode="messages"):
    # event = individual message (user, assistant, tool result)
    print(event.content)
```

**Use Case**: Message-by-message conversation tracking.

#### Mode 4: Custom

```python
from langgraph.graph import get_stream_writer

def my_node(state):
    writer = get_stream_writer()

    for i in range(10):
        writer("progress", {"percent": i * 10})
        process_chunk(i)

    return state

# Consume
for event in app.stream(inputs, stream_mode="custom"):
    print(f"Progress: {event['percent']}%")
```

**Use Case**: Custom progress reporting, metrics.

---

### 4.4 Combining Iteration with Streaming

**PydanticAI**: Stream individual nodes during manual iteration.

```python
async with agent.iter('prompt', deps=deps) as run:
    node = run.next_node

    while not isinstance(node, End):
        if isinstance(node, ModelRequestNode):
            # Stream LLM response token-by-token
            async for text in node.stream(run.ctx):
                print(text, end='', flush=True)

        node = await run.next(node)
```

**Benefit**: Fine-grained control (pause between nodes) + real-time streaming (within nodes).

---

## 5. Hook Systems

### 5.1 Hook Taxonomy

| Hook Type | When Fires | Can Modify? | Can Block? | Frameworks |
|-----------|-----------|-------------|------------|------------|
| **Pre-LLM** | Before model call | Yes (messages) | Yes | Claude SDK, CrewAI, Vercel |
| **Post-LLM** | After model returns | No | No | OpenAI, Claude SDK, AutoGen |
| **Pre-Tool** | Before tool execution | Yes (arguments) | Yes | OpenAI, Claude SDK, AutoGen |
| **Post-Tool** | After tool returns | Yes (result) | No | OpenAI, Claude SDK, AutoGen |
| **Step Finish** | After each agent turn | No | No | OpenAI, Vercel, CrewAI, AutoGen |
| **Run Finish** | After complete execution | No | No | All frameworks |
| **Agent Start** | When agent activates | No | No | OpenAI, AutoGen |
| **Agent End** | When agent completes | No | No | OpenAI, AutoGen |
| **Handoff** | During agent transfer | No | No | OpenAI, AutoGen |

---

### 5.2 Framework-Specific Implementations

#### OpenAI Agents SDK: Observation-Only Hooks

```python
from agents import RunHooks, RunContext

class MyHooks(RunHooks):
    async def on_llm_start(
        self,
        context: RunContext,
        agent: Agent,
        system_prompt: str,
        input_items: list[InputItem]
    ) -> None:
        # Can observe, cannot modify
        print(f"LLM call with {len(input_items)} items")

    async def on_tool_start(
        self,
        context: RunContext,
        agent: Agent,
        tool: Tool
    ) -> None:
        # Cannot modify arguments or block
        print(f"Executing {tool.name}")

result = await Runner.run(
    agent,
    "prompt",
    hooks=MyHooks()
)
```

**Key Limitation**: Hooks are purely observational. To modify, use `call_model_input_filter` or guardrails.

---

#### Claude SDK: Modification Hooks

```python
from claude_agent_sdk import PreToolUseHookInput, HookContext

async def security_hook(
    input_data: PreToolUseHookInput,
    tool_use_id: str,
    context: HookContext
) -> dict:
    # Can block tool execution
    if "rm -rf" in input_data["tool_input"].get("command", ""):
        return {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": "Dangerous command blocked"
            }
        }

    # Can modify arguments
    modified_input = input_data["tool_input"].copy()
    modified_input["timeout"] = 30

    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "updatedToolInput": modified_input
        }
    }

options = ClaudeAgentOptions(
    hooks={"PreToolUse": [HookMatcher(hooks=[security_hook])]}
)
```

**Capabilities**:
- Block execution (`permissionDecision: "deny"`)
- Modify tool inputs (`updatedToolInput`)
- Add context for LLM (`additionalContext`)

---

#### CrewAI: LLM Call Hooks

```python
from crewai.hooks import before_llm_call, after_llm_call, LLMCallHookContext

@before_llm_call
def inject_context(context: LLMCallHookContext):
    # IMPORTANT: Modify in-place, don't replace
    context.messages.append({
        "role": "system",
        "content": "Always be concise."
    })

    # Return False to block
    if "forbidden" in str(context.messages):
        return False

    return None  # Allow execution

@after_llm_call
def sanitize_response(context: LLMCallHookContext):
    if context.response and "SECRET" in context.response:
        # Return modified response
        return context.response.replace("SECRET", "[REDACTED]")

    return None  # Keep original
```

**Key Behavior**: `before_llm_call` can block by returning `False`. `after_llm_call` can transform response by returning a string.

---

#### Vercel AI SDK: Middleware Pattern

```typescript
import { wrapLanguageModel } from 'ai';

const loggingMiddleware = {
    // Transform params before model call
    transformParams: async ({ params }) => {
        console.log('Request:', params.prompt);
        return {
            ...params,
            temperature: params.temperature ?? 0.7  // Set defaults
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
        // Can transform chunks here
        return stream;
    }
};

const model = wrapLanguageModel(
    openai('gpt-4'),
    loggingMiddleware
);
```

**Use Cases**: RAG injection, caching, guardrails, logging.

---

#### AutoGen: Step Callbacks

```python
from autogen_agentchat.agents import AssistantAgent

def step_callback(step_info):
    print(f"Step {step_info['step_number']} completed")
    print(f"Token usage: {step_info['usage']}")

agent = AssistantAgent(
    name="assistant",
    model_client=model_client,
    step_callback=step_callback  # Called after each step
)
```

---

### 5.3 Common Hook Patterns

#### Pattern 1: Logging and Observability

```python
# OpenAI
class LoggingHooks(RunHooks):
    async def on_llm_start(self, context, agent, system_prompt, items):
        logger.info(f"LLM call: {len(items)} messages")

    async def on_tool_end(self, context, agent, tool, result):
        logger.info(f"Tool {tool.name} returned: {result[:100]}")
```

#### Pattern 2: Cost Tracking

```python
# Custom hook to accumulate token usage
class CostTracker(RunHooks):
    def __init__(self):
        self.total_tokens = 0

    async def on_llm_end(self, context, agent, response):
        self.total_tokens += response.usage.total_tokens
        print(f"Tokens so far: {self.total_tokens}")
```

#### Pattern 3: Input Sanitization

```python
# CrewAI
@before_llm_call
def redact_pii(context: LLMCallHookContext):
    for msg in context.messages:
        if msg["role"] == "user":
            msg["content"] = redact_ssn(msg["content"])
```

#### Pattern 4: Tool Approval

```python
# Claude SDK
async def approval_hook(input_data, tool_use_id, context):
    if input_data["tool_name"] == "delete_database":
        approved = await get_human_approval(tool_use_id)
        if not approved:
            return {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": "User denied"
                }
            }
    return {}  # Allow
```

---

## 6. Blocking vs Non-blocking

### 6.1 Execution Characteristics

| Framework | Model | Blocking Call | Non-Blocking Alternative |
|-----------|-------|---------------|--------------------------|
| **OpenAI** | Run-to-completion | `Runner.run()` | `Runner.run_streamed()` |
| **Claude SDK** | Run-to-completion | `query()` | `query()` with partial messages |
| **Vercel AI** | Run-to-completion | `generateText()` | `streamText()` |
| **PydanticAI** | Run-to-completion | `agent.run()` | `agent.run_stream()` |
| **AutoGen** | Run-to-completion | `agent.run()` | `agent.run_stream()` |
| **CrewAI** | Run-to-completion | `crew.kickoff()` | `crew.kickoff()` with `stream=True` |
| **LangGraph** | Graph execution | `app.invoke()` | `app.stream()` |
| **Cloudflare** | Event-driven | N/A (always async) | Native async architecture |

---

### 6.2 Blocking Semantics

**Blocking Call**: Application waits until agent completes all turns before receiving result.

```python
# OpenAI
result = await Runner.run(agent, "Complex task")
# Blocks here until all LLM calls, tool executions, retries complete
print(result.final_output)  # Final result
```

**Characteristics**:
- Simple to use (single await)
- No UI updates during execution
- Cannot display progress
- Cannot cancel mid-execution (without AbortSignal)

---

### 6.3 Non-Blocking Semantics

**Non-Blocking Call**: Application receives stream of events and can react in real-time.

```python
# OpenAI
result = await Runner.run_streamed(agent, "Complex task")

async for event in result.stream_events():
    # Updates as execution progresses
    match event.type:
        case "raw_response_event":
            update_ui(event.data.delta)
        case "run_item_stream_event":
            if event.name == "tool_called":
                show_progress(event.item.name)

# After streaming completes
print(result.final_output)
```

**Characteristics**:
- More complex to implement
- Enables live UI updates
- Can display progress indicators
- Can cancel more responsively
- Higher event processing overhead

---

### 6.4 Async vs Sync APIs

#### Fully Async (Recommended)

```python
# PydanticAI
result = await agent.run(prompt, deps=deps)
```

**Benefits**:
- Non-blocking event loop
- Efficient concurrency
- Can await multiple agents simultaneously

#### Sync Wrapper

```python
# PydanticAI
result = agent.run_sync(prompt, deps=deps)
```

**Use Case**: Running in synchronous context (Jupyter notebooks, simple scripts).

**Warning**: Blocks event loop - avoid in async applications.

---

### 6.5 Background Execution Pattern

```python
# Launch agent in background
task = asyncio.create_task(agent.run(prompt, deps=deps))

# Do other work
await other_operation()

# Wait for result when needed
result = await task
```

**Use Case**: Parallel agent execution, fire-and-forget operations.

---

## 7. Tradeoff Analysis

### 7.1 Run-to-Completion vs Iterator Model

| Aspect | Run-to-Completion | Iterator Model |
|--------|-------------------|----------------|
| **Complexity** | Low (single call) | High (manual loop) |
| **Control** | None (black box) | Full (inspect each step) |
| **Human-in-the-loop** | Limited (approval tools) | Native (pause between steps) |
| **Debugging** | Hard (no visibility) | Easy (step-through) |
| **Performance** | Fast (no overhead) | Slower (iteration cost) |
| **Error Recovery** | Automatic retries | Custom retry logic |
| **Use Case** | Simple agents | Complex workflows |

**Example Comparison**:

```python
# Run-to-Completion (OpenAI)
result = await Runner.run(agent, "Delete old files")
# Cannot pause for approval mid-execution

# Iterator Model (PydanticAI)
async with agent.iter("Delete old files", deps=deps) as run:
    node = run.next_node
    while not isinstance(node, End):
        if isinstance(node, CallToolsNode):
            for call in node.tool_calls:
                if call.name == "delete_file":
                    approved = await get_approval(call.arguments)
                    if not approved:
                        continue  # Skip deletion
        node = await run.next(node)
```

**Recommendation**: Use run-to-completion for simple agents. Use iterator model when human approval or custom error handling is required.

---

### 7.2 Sequential vs Hierarchical Processes

| Aspect | Sequential | Hierarchical |
|--------|-----------|--------------|
| **Coordination** | None (linear) | Manager agent |
| **Task Order** | Fixed at definition | Dynamic at runtime |
| **Agent Selection** | Pre-assigned | Manager delegates |
| **Overhead** | Minimal | Manager LLM calls |
| **Flexibility** | Low | High |
| **Predictability** | High (deterministic) | Lower (manager decisions) |
| **Best For** | Pipelines | Dynamic workloads |

**Cost Example**:

```python
# Sequential: 3 agent calls
research → analyze → write  # Fixed order

# Hierarchical: 4+ agent calls
manager analyzes → delegates to research →
manager reviews → delegates to analyze →
manager reviews → delegates to write →
manager validates final output
```

**Recommendation**: Use sequential for fixed pipelines. Use hierarchical when task routing needs to be dynamic based on runtime conditions.

---

### 7.3 Streaming vs Polling

| Aspect | Streaming | Polling |
|--------|-----------|---------|
| **Latency** | Immediate (real-time) | Delayed (poll interval) |
| **Complexity** | Higher (event handling) | Lower (simple checks) |
| **Network Efficiency** | High (single connection) | Low (repeated requests) |
| **Server Load** | Lower (push-based) | Higher (pull-based) |
| **Browser Support** | SSE, WebSocket | Fetch API |
| **Implementation** | AsyncIterator, events | setInterval |

**Streaming Example**:
```typescript
// Real-time updates
for await (const chunk of result.textStream) {
    display(chunk);  // Immediate
}
```

**Polling Example**:
```typescript
// Delayed updates
const interval = setInterval(async () => {
    const status = await fetch('/agent/status');
    display(status);
}, 1000);  // Check every second
```

**Recommendation**: Always prefer streaming for interactive UIs. Use polling only when streaming isn't supported (legacy systems, simple scripts).

---

### 7.4 Event-Driven vs Graph-Based

| Aspect | Event-Driven | Graph-Based |
|--------|--------------|-------------|
| **Structure** | Loose coupling (pub-sub) | Tight coupling (explicit edges) |
| **Execution Flow** | Implicit (reactions) | Explicit (graph topology) |
| **Debugging** | Hard (trace events) | Easier (visualize graph) |
| **Flexibility** | High (dynamic handlers) | Medium (predefined graph) |
| **Parallelism** | Natural (concurrent handlers) | Structured (supersteps) |
| **State Management** | Manual | Built-in (graph state) |
| **Best For** | Distributed systems | Predictable workflows |

**Event-Driven Example**:
```python
# Cloudflare Agents
class AgentA(RoutedAgent):
    @message_handler
    async def handle_task(self, msg: Task, ctx: MessageContext):
        result = await self.process(msg)
        # Publish event - any agent subscribed will react
        await self.publish_message(TaskComplete(result), topic=ctx.topic_id)
```

**Graph-Based Example**:
```python
# LangGraph
graph.add_node("task_a", task_a_node)
graph.add_node("task_b", task_b_node)
graph.add_edge("task_a", "task_b")  # Explicit flow
```

**Recommendation**: Use graph-based for workflows with clear structure and checkpointing needs. Use event-driven for distributed multi-agent systems with dynamic coordination.

---

### 7.5 High-Level vs Low-Level Abstraction

| Framework | Abstraction Level | Developer Control | Boilerplate |
|-----------|------------------|-------------------|-------------|
| **CrewAI** | Highest | Low | Minimal |
| **AutoGen** | High | Medium | Low |
| **OpenAI Agents** | Medium-High | Medium | Medium |
| **Claude SDK** | Medium | Medium-High | Medium |
| **Vercel AI SDK** | Medium | Medium-High | Medium |
| **PydanticAI** | Medium-Low | High | Medium-High |
| **LangGraph** | Low | Very High | High |
| **Cloudflare** | Low | Very High | High |

**High-Level (CrewAI)**:
```python
# 20 lines for multi-agent system
crew = Crew(
    agents=[researcher, writer],
    tasks=[research, write],
    process=Process.sequential
)
result = crew.kickoff(inputs={"topic": "AI"})
```

**Low-Level (LangGraph)**:
```python
# 50+ lines for equivalent system
from langgraph.graph import StateGraph

class State(TypedDict):
    messages: list[dict]
    research: str
    article: str

def research_node(state):
    # Manual research logic
    return {"research": research_data}

def write_node(state):
    # Manual writing logic
    return {"article": article_text}

graph = StateGraph(State)
graph.add_node("research", research_node)
graph.add_node("write", write_node)
graph.add_edge("research", "write")
graph.add_edge("write", END)
graph.set_entry_point("research")

app = graph.compile(checkpointer=checkpointer)
result = app.invoke({"messages": [...]})
```

**Tradeoff**:
- **High-level**: Fast development, limited customization
- **Low-level**: Full control, high development cost

**Recommendation**: Start with high-level frameworks for prototypes. Switch to low-level frameworks when custom control is needed.

---

### 7.6 Memory/State Management

| Framework | Memory Model | Persistence | Scope |
|-----------|--------------|-------------|-------|
| **CrewAI** | Automatic (4 types) | SQLite + ChromaDB | Crew-level |
| **AutoGen** | Session-based | Manual export/import | Agent-level |
| **OpenAI** | Session abstraction | SQLite, Redis, cloud | Run-level |
| **Claude SDK** | Automatic | Filesystem | Session-level |
| **LangGraph** | Checkpointing | Postgres, Redis, SQLite | Graph-level |
| **PydanticAI** | Manual | None built-in | Application-level |
| **Vercel AI** | Manual | None built-in | Application-level |
| **Cloudflare** | Automatic (Durable Objects) | SQLite (per agent) | Agent instance |

**Automatic Memory (CrewAI)**:
```python
crew = Crew(
    agents=[...],
    tasks=[...],
    memory=True  # Enables all 4 memory types automatically
)
```

**Manual Memory (PydanticAI)**:
```python
# Application manages history
messages = []

result1 = await agent.run("First query", message_history=messages)
messages.extend(result1.all_messages())

result2 = await agent.run("Follow-up", message_history=messages)
messages.extend(result2.all_messages())
```

**Tradeoff**:
- **Automatic**: Convenient, less control, vendor lock-in
- **Manual**: Full control, more code, flexible storage

---

## 8. Code Examples

### 8.1 Simple Single-Agent (Run-to-Completion)

#### OpenAI Agents SDK

```python
from agents import Agent, Runner, function_tool

@function_tool
async def search(query: str) -> str:
    """Search for information."""
    return search_api(query)

agent = Agent(
    name="assistant",
    model="gpt-4",
    tools=[search],
    instructions="You are a helpful research assistant."
)

# Blocking execution
result = await Runner.run(
    agent,
    "What are the latest developments in quantum computing?",
    max_turns=10
)

print(result.final_output)
print(f"Token usage: {result.usage()}")
```

---

### 8.2 Streaming with Progress Updates

#### Vercel AI SDK

```typescript
import { streamText } from 'ai';
import { openai } from '@ai-sdk/openai';

const result = streamText({
    model: openai('gpt-4'),
    tools: {
        search: tool({
            description: 'Search the web',
            parameters: z.object({ query: z.string() }),
            execute: async ({ query }) => searchAPI(query)
        })
    },
    prompt: 'Research quantum computing'
});

// Stream multiple output types
for await (const part of result.fullStream) {
    switch (part.type) {
        case 'text-delta':
            process.stdout.write(part.text);
            break;
        case 'tool-call':
            console.log(`\n[Searching: ${part.input.query}]\n`);
            break;
        case 'tool-result':
            console.log(`[Found: ${part.output.substring(0, 50)}...]\n`);
            break;
    }
}

// Access final result after streaming
const finalText = await result.text;
console.log(`\nComplete. Total tokens: ${(await result.usage).totalTokens}`);
```

---

### 8.3 Manual Iteration with Human Approval

#### PydanticAI

```python
from pydantic_ai import Agent, RunContext
from pydantic_ai.agent import CallToolsNode, End

@agent.tool
async def delete_file(ctx: RunContext[Deps], path: str) -> str:
    """Delete a file from the system."""
    os.remove(path)
    return f"Deleted {path}"

async with agent.iter('Clean up old files', deps=deps) as run:
    node = run.next_node

    while not isinstance(node, End):
        if isinstance(node, CallToolsNode):
            # Inspect each tool call before execution
            for tool_call in node.tool_calls:
                if tool_call.name == "delete_file":
                    # Show user what will be deleted
                    path = tool_call.arguments["path"]
                    print(f"Agent wants to delete: {path}")

                    # Request approval
                    approved = input("Allow? (y/n): ").lower() == 'y'

                    if not approved:
                        print("Skipping deletion")
                        continue  # Don't execute this node

        # Execute approved node
        node = await run.next(node)

    # Get final result
    result = run.result
```

---

### 8.4 Multi-Agent Hierarchical Crew

#### CrewAI

```python
from crewai import Agent, Task, Crew, Process

# Define specialized agents
researcher = Agent(
    role="Research Analyst",
    goal="Find accurate, current information",
    backstory="10 years of research experience",
    tools=[search_tool],
    verbose=True
)

analyst = Agent(
    role="Data Analyst",
    goal="Analyze data and extract insights",
    backstory="Expert in statistical analysis",
    tools=[calculate_tool],
    verbose=True
)

writer = Agent(
    role="Technical Writer",
    goal="Create clear, engaging content",
    backstory="Published technical author",
    verbose=True
)

# Define sequential tasks
research_task = Task(
    description="Research {topic} and gather key facts",
    expected_output="A comprehensive research report",
    agent=researcher
)

analysis_task = Task(
    description="Analyze the research findings",
    expected_output="Data-driven insights",
    agent=analyst,
    context=[research_task]  # Depends on research output
)

writing_task = Task(
    description="Write an article based on analysis",
    expected_output="A polished article",
    agent=writer,
    context=[analysis_task]
)

# Orchestrate with hierarchical manager
crew = Crew(
    agents=[researcher, analyst, writer],
    tasks=[research_task, analysis_task, writing_task],
    process=Process.hierarchical,
    manager_llm="gpt-4o",  # Manager coordinates delegation
    verbose=True
)

# Execute
result = crew.kickoff(inputs={"topic": "AI Agent Frameworks"})
print(result.raw)
```

---

### 8.5 Graph-Based Workflow with Loops

#### LangGraph

```python
from langgraph.graph import StateGraph, END
from typing import TypedDict

class State(TypedDict):
    query: str
    research: str
    quality_score: float
    iterations: int

def research_node(state):
    # Perform research
    research = do_research(state["query"])
    quality = evaluate_quality(research)

    return {
        "research": research,
        "quality_score": quality,
        "iterations": state.get("iterations", 0) + 1
    }

def should_continue(state):
    # Loop if quality is low and haven't exceeded iterations
    if state["quality_score"] < 0.8 and state["iterations"] < 3:
        return "research"  # Loop back
    return "write"

def write_node(state):
    article = write_article(state["research"])
    return {"article": article}

# Build graph
graph = StateGraph(State)
graph.add_node("research", research_node)
graph.add_node("write", write_node)

# Conditional edge for loop or continue
graph.add_conditional_edges(
    "research",
    should_continue,
    {
        "research": "research",  # Loop back
        "write": "write"         # Continue to write
    }
)

graph.add_edge("write", END)
graph.set_entry_point("research")

# Compile with checkpointing
app = graph.compile(checkpointer=checkpointer)

# Execute
result = app.invoke({"query": "AI agents"})
print(result["article"])
```

---

### 8.6 Event-Driven Multi-Agent System

#### AutoGen Core

```python
from autogen_core import RoutedAgent, message_handler, MessageContext

# Define message types
class ResearchRequest(BaseModel):
    query: str

class ResearchComplete(BaseModel):
    findings: str

class WriteRequest(BaseModel):
    research: str

# Research agent
class ResearchAgent(RoutedAgent):
    @message_handler
    async def handle_research(
        self,
        message: ResearchRequest,
        ctx: MessageContext
    ) -> None:
        findings = await self.research(message.query)

        # Publish completion event
        await self.publish_message(
            ResearchComplete(findings=findings),
            topic=ctx.topic_id
        )

# Writing agent (reacts to research completion)
class WritingAgent(RoutedAgent):
    @message_handler
    async def handle_write(
        self,
        message: ResearchComplete,
        ctx: MessageContext
    ) -> None:
        article = await self.write(message.findings)

        # Publish final result
        await self.publish_message(
            ArticleComplete(content=article),
            topic=ctx.topic_id
        )

# Register agents with runtime
runtime = SingleThreadedAgentRuntime()
await runtime.register("researcher", ResearchAgent)
await runtime.register("writer", WritingAgent)

# Trigger workflow by publishing initial message
await runtime.publish_message(
    ResearchRequest(query="AI agents"),
    topic="default"
)

# Agents react to events automatically
await runtime.stop_when_idle()
```

---

### 8.7 Flow-Based State Machine

#### CrewAI Flows

```python
from crewai.flow.flow import Flow, start, listen, router
from pydantic import BaseModel

class ArticleState(BaseModel):
    topic: str = ""
    research: str = ""
    quality_score: float = 0.0
    iterations: int = 0
    article: str = ""

class ResearchFlow(Flow[ArticleState]):
    @start()
    def initialize(self):
        self.state.topic = "AI Agents"
        return self.state.topic

    @listen(initialize)
    def research(self, topic):
        research = ResearchCrew().crew().kickoff(inputs={"topic": topic})
        self.state.research = research.raw
        self.state.quality_score = evaluate(research.raw)
        self.state.iterations += 1

        return research.raw

    @router(research)
    def evaluate_quality(self, research):
        # Route based on quality
        if self.state.quality_score < 0.8 and self.state.iterations < 3:
            return "research_more"
        return "write"

    @listen("research_more")
    def deeper_research(self):
        # Loop back to research
        return self.research(self.state.topic)

    @listen("write")
    def write_article(self):
        article = WritingCrew().crew().kickoff(
            inputs={"research": self.state.research}
        )
        self.state.article = article.raw
        return article.raw

# Execute flow
flow = ResearchFlow()
result = flow.kickoff()
print(flow.state.article)
```

---

### 8.8 Durable Event-Driven Agent

#### Cloudflare Agents

```typescript
import { AIChatAgent, createDataStreamResponse } from 'agents';
import { streamText } from 'ai';
import { openai } from '@ai-sdk/openai';

class ResearchAgent extends AIChatAgent<Env> {
    // Persistent state (survives restarts)
    initialState = {
        research_history: [],
        current_quality: 0.0
    };

    async onChatMessage(onFinish) {
        return createDataStreamResponse({
            execute: async (dataStream) => {
                const stream = streamText({
                    model: openai('gpt-4o-mini'),
                    system: this.buildSystemPrompt(),
                    messages: this.messages,
                    tools: {
                        search: tool({
                            description: 'Search for information',
                            parameters: z.object({ query: z.string() }),
                            execute: async ({ query }) => {
                                const result = await searchAPI(query);

                                // Update persistent state
                                this.setState({
                                    ...this.state,
                                    research_history: [
                                        ...this.state.research_history,
                                        { query, result, timestamp: Date.now() }
                                    ]
                                });

                                return result;
                            }
                        })
                    },
                    onFinish,
                    maxSteps: 5
                });

                stream.mergeIntoDataStream(dataStream);
            }
        });
    }

    buildSystemPrompt() {
        // Incorporate research history from state
        const history = this.state.research_history
            .slice(-3)
            .map(r => `Previous search: ${r.query}`)
            .join('\n');

        return `You are a research assistant.\n${history}`;
    }
}

// Deploy as Durable Object
export default {
    async fetch(request, env) {
        return routeAgentRequest(request, env);
    }
};
```

---

## 9. Decision Framework

### 9.1 Choosing an Execution Model

```
┌─────────────────────────────────────────┐
│ Do you need fine-grained loop control?  │
└─────────────┬───────────────────────────┘
              │
        ┌─────┴─────┐
       Yes          No
        │            │
        ▼            ▼
┌───────────────┐  ┌────────────────────────────┐
│ Iterator      │  │ Is the workflow complex    │
│ Model         │  │ with branching/loops?      │
│               │  └────────────┬───────────────┘
│ PydanticAI    │               │
│ LangGraph     │         ┌─────┴─────┐
└───────────────┘        Yes          No
                          │            │
                          ▼            ▼
                ┌──────────────────┐  ┌─────────────────────┐
                │ Graph Model      │  │ Run-to-Completion   │
                │                  │  │                     │
                │ LangGraph        │  │ OpenAI, Claude SDK  │
                └──────────────────┘  │ Vercel, AutoGen     │
                                      │ CrewAI              │
                                      └─────────────────────┘
```

---

### 9.2 Choosing by Use Case

#### Use Case: Chat Bot (Simple Q&A)

**Recommendation**: Run-to-Completion (OpenAI, Claude SDK, Vercel AI)

**Rationale**:
- No complex workflows
- Single turn sufficient
- Streaming for UX
- Low complexity

**Example**: Customer support bot, FAQ assistant

---

#### Use Case: Research Assistant (Multi-Step with Tools)

**Recommendation**: Streaming-Observable (OpenAI, Vercel, PydanticAI)

**Rationale**:
- Tool usage visibility needed
- Progress updates important
- Moderate complexity
- No human approval required

**Example**: Research agent that searches web, analyzes data, generates report

---

#### Use Case: Data Analysis Pipeline (Fixed Steps)

**Recommendation**: Sequential Process (CrewAI, AutoGen RoundRobin)

**Rationale**:
- Linear workflow
- Clear task dependencies
- Multi-agent specialization
- Predictable execution

**Example**: Data ingestion → Cleaning → Analysis → Visualization

---

#### Use Case: Workflow Automation (Branching Logic)

**Recommendation**: Graph-Based (LangGraph)

**Rationale**:
- Complex conditional logic
- Loops for retries
- Persistent checkpoints
- Parallel execution needed

**Example**: Document processing with quality checks, retries, and approval gates

---

#### Use Case: Autonomous Agent (Requires Approval)

**Recommendation**: Iterator Model (PydanticAI)

**Rationale**:
- Human-in-the-loop critical
- Need to inspect tool calls before execution
- Custom error handling
- Fine-grained control

**Example**: DevOps agent that can modify production systems

---

#### Use Case: Multi-Agent Coordination (Dynamic Routing)

**Recommendation**: Hierarchical or Swarm (CrewAI, AutoGen, OpenAI)

**Rationale**:
- Multiple specialists needed
- Dynamic task routing
- Manager coordinates work
- Handles diverse capabilities

**Example**: Customer support triage system routing to billing, technical, or account specialists

---

#### Use Case: Long-Running Distributed System

**Recommendation**: Event-Driven (Cloudflare Agents, AutoGen Core)

**Rationale**:
- Spans multiple processes
- Durable state required
- Async coordination
- High availability

**Example**: Multi-day approval workflows, distributed research teams

---

### 9.3 Framework Selection Matrix

| Requirement | Primary Recommendation | Alternative |
|-------------|----------------------|-------------|
| **Simple chat bot** | OpenAI, Claude SDK | Vercel AI |
| **Streaming UI** | Vercel AI, PydanticAI | OpenAI |
| **Human approval** | PydanticAI (iter) | Claude SDK (hooks) |
| **Multi-agent team** | CrewAI, AutoGen | OpenAI |
| **Complex workflows** | LangGraph | CrewAI Flows |
| **Distributed system** | Cloudflare, AutoGen Core | LangGraph |
| **Production at scale** | Cloudflare, LangGraph | OpenAI |
| **Rapid prototyping** | CrewAI, AutoGen | Vercel AI |
| **Full control** | PydanticAI, LangGraph | Vercel AI |
| **Minimal boilerplate** | CrewAI | AutoGen |

---

### 9.4 Performance Considerations

| Framework | Cold Start | Latency (Sequential) | Latency (Parallel) | Streaming Overhead |
|-----------|-----------|---------------------|-------------------|-------------------|
| **OpenAI** | Fast | Low | Medium | Low |
| **Claude SDK** | Fast | Low | N/A (single agent) | Low |
| **Vercel AI** | Fast | Low | Low | Low |
| **PydanticAI** | Fast | Low | Low | Medium (iteration) |
| **AutoGen** | Medium | Medium | Low | Medium |
| **CrewAI** | Medium | Medium (sequential) | High (manager overhead) | Low |
| **LangGraph** | Medium | Medium | Low (supersteps) | Medium |
| **Cloudflare** | Very Fast (<5ms) | Low | Low | Very Low (native) |

**Notes**:
- **Cold Start**: Time to initialize framework
- **Latency**: Overhead beyond LLM API calls
- **Parallel**: Executing multiple operations simultaneously
- **Streaming Overhead**: Cost of event emission/processing

---

### 9.5 Final Recommendations

#### For Swift (Yrden) Implementation

Based on this comprehensive analysis, here are the key patterns to adopt for Yrden:

1. **Primary Execution Model**: **Iterator-Based** (like PydanticAI)
   - Reason: Maximum control for human-in-the-loop
   - Implementation: `for await let node in agent.iter()`
   - Alternative: Run-to-completion for simple cases

2. **Streaming Architecture**: **Three-Tier Hierarchy**
   - Token-level: Real-time text updates
   - Semantic-level: Tool calls, messages
   - Agent-level: Handoffs, state transitions

3. **Hook System**: **Observation + Modification Split**
   - Observation hooks (like OpenAI): `onToolStart`, `onToolEnd`
   - Modification filters (like Vercel middleware): Transform before LLM
   - Approval mechanism: Via iterator pattern, not hooks

4. **Tool Execution**: **Parallel with Approval**
   - Default: Execute tools in parallel (like PydanticAI)
   - Override: Pause via iterator for approval
   - Retry: `ModelRetry` signal for LLM feedback

5. **State Management**: **Manual (Flexible)**
   - No automatic persistence (avoid framework lock-in)
   - Provide session protocol for custom implementations
   - Application owns message history

6. **Multi-Agent**: **Handoff Pattern** (Phase 6)
   - Peer-to-peer transfers (like OpenAI, AutoGen Swarm)
   - No hierarchical manager (too much overhead)
   - Agents call other agents via tools

7. **Error Handling**: **Typed Results**
   - `Result<T, AgentError>` instead of exceptions
   - `ModelRetry` for LLM-visible feedback
   - Structured error types for recovery

8. **Simplifications for v1**:
   - Skip graph-based execution (LangGraph-style)
   - Skip event-driven architecture (Cloudflare-style)
   - Skip automatic memory (add later)
   - Focus on single-agent + handoffs

---

## Conclusion

This comprehensive analysis reveals that agent SDK execution models exist on a spectrum from high-abstraction/low-control (CrewAI) to low-abstraction/high-control (LangGraph, Cloudflare). The optimal choice depends on the specific requirements:

- **Simple agents**: Run-to-completion (OpenAI, Claude SDK, Vercel)
- **Human approval**: Iterator-based (PydanticAI)
- **Complex workflows**: Graph-based (LangGraph)
- **Multi-agent**: Hierarchical/Swarm (CrewAI, AutoGen, OpenAI)
- **Distributed systems**: Event-driven (Cloudflare, AutoGen Core)

For Yrden, the **PydanticAI-style iterator model** provides the best balance of control, simplicity, and Swift compatibility. Start with iterator-based execution and run-to-completion convenience methods, then add multi-agent handoffs and optional graph-based workflows in later phases.

---

**End of Document**
**Total Length**: ~17,000 words / 550+ lines
