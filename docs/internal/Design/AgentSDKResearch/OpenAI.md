## OpenAI Agents SDK Research Appendix

This appendix provides an in-depth analysis of the OpenAI Agents SDK (Python and TypeScript) API surface, architecture, and design patterns relevant to Yrden's development.

---

### 1. Core Concepts & Types

#### Agent Class (Python)

The `Agent` class is the central abstraction, implemented as a generic dataclass:

```python
@dataclass
class Agent(AgentBase, Generic[TContext]):
    # Identity & Instructions
    name: str                           # Agent identifier
    instructions: str | Callable | None # System prompt (static or dynamic)
    prompt: Prompt | None               # OpenAI Responses API prompt template
    
    # Model Configuration
    model: str | Model = "gpt-4.1"      # Model identifier or instance
    model_settings: ModelSettings       # Temperature, reasoning effort, etc.
    
    # Capabilities
    tools: list[Tool]                   # Function tools available
    handoffs: list[Agent | Handoff]     # Sub-agents for delegation
    mcp_servers: list[MCPServer]        # MCP server connections
    
    # Guardrails
    input_guardrails: list[InputGuardrail]
    output_guardrails: list[OutputGuardrail]
    
    # Output
    output_type: Type | None            # Structured output schema (Pydantic/dataclass)
    
    # Behavior Control
    tool_use_behavior: ToolUseBehavior  # "run_llm_again" | "stop_on_first_tool" | StopAtTools | callable
    reset_tool_choice: bool = True      # Prevents infinite tool loops
    
    # Lifecycle
    hooks: AgentHooks                   # Agent-specific callbacks
```

**Key Methods:**

- `clone(**overrides)` - Create a modified copy of the agent
- `as_tool(...)` - Convert agent into a callable tool for other agents
- `get_system_prompt(context, agent)` - Resolve dynamic instructions

#### Agent Class (TypeScript)

```typescript
export class Agent<
  TContext = UnknownContext,
  TOutput extends AgentOutputType = TextOutput
> extends AgentHooks<TContext, TOutput> {
    name: string;
    instructions: string | ((ctx: RunContextWrapper<TContext>) => string);
    model: string | Model;
    modelSettings: ModelSettings;
    tools: Tool<TContext>[];
    handoffs: Array<Agent | Handoff>;
    mcpServers: MCPServer[];
    inputGuardrails: InputGuardrail[];
    outputGuardrails: OutputGuardrail[];
    outputType: TOutput;
    toolUseBehavior: ToolUseBehavior;
    resetToolChoice: boolean;
}
```

#### RunResult Types

**Python:**

```python
@dataclass
class RunResultBase:
    input: str | list[InputItem]            # Original input
    new_items: list[RunItem]                # Generated items (messages, tool calls, etc.)
    raw_responses: list[ModelResponse]      # LLM responses
    final_output: Any                       # Typed output or None
    input_guardrail_results: list           # Validation results
    output_guardrail_results: list
    tool_input_guardrail_results: list
    tool_output_guardrail_results: list
    context_wrapper: RunContextWrapper
    
    def to_input_list(self) -> list[InputItem]:
        """Merge input + new_items for subsequent runs"""
    
    def final_output_as(self, cls: Type[T]) -> T:
        """Type-cast final output"""

class RunResult(RunResultBase):
    _last_agent: Agent
    _current_turn: int
    max_turns: int = 10
    interruptions: list[ToolApprovalItem]   # Pending approvals
    
    def to_state(self) -> RunState:
        """Create resumable state from this result"""

class RunResultStreaming(RunResultBase):
    current_agent: Agent
    current_turn: int
    is_complete: bool
    
    async def stream_events(self) -> AsyncIterator[StreamEvent]:
        """Stream semantic events as they occur"""
    
    def cancel(self, mode: Literal["immediate", "after_turn"]):
        """Cancel execution"""
```

#### Item Types

The SDK defines granular item types for each execution artifact:

```python
# Message types
MessageOutputItem      # LLM-generated text/refusal
ReasoningItem         # Model reasoning output

# Tool types
ToolCallItem          # Tool invocation request
ToolCallOutputItem    # Tool execution result (text/image/file)
ToolApprovalItem      # Tool requiring approval before execution

# Handoff types
HandoffCallItem       # Handoff request
HandoffOutputItem     # Completed handoff

# MCP types
MCPListToolsItem
MCPApprovalRequestItem
MCPApprovalResponseItem
```

---

### 2. Execution Model

#### Agent Loop

The execution follows a turn-based loop:

```
┌─────────────────────────────────────────────────────────────┐
│  1. Prepare Input                                           │
│     - Load session history (if configured)                  │
│     - Apply input guardrails (first turn only)              │
│     - Merge with previous conversation items                │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  2. Call LLM                                                │
│     - Build request with tools, system prompt               │
│     - Apply call_model_input_filter if configured           │
│     - Execute model call (streaming or sync)                │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  3. Process Response                                        │
│     ┌─────────────────┐  ┌─────────────────┐               │
│     │ Final Output?   │  │ Tool Calls?     │               │
│     │ → Apply output  │  │ → Check approval│               │
│     │   guardrails    │  │ → Execute tools │               │
│     │ → Return result │  │ → Continue loop │               │
│     └─────────────────┘  └─────────────────┘               │
│     ┌─────────────────┐                                    │
│     │ Handoff?        │                                    │
│     │ → Switch agent  │                                    │
│     │ → Continue loop │                                    │
│     └─────────────────┘                                    │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  4. Check Termination                                       │
│     - Max turns exceeded? → Raise MaxTurnsExceeded          │
│     - Interruptions pending? → Return with state            │
│     - Otherwise → Continue to step 2                        │
└─────────────────────────────────────────────────────────────┘
```

**Final Output Conditions:**

A response is considered "final output" when:
1. It produces text/structured output matching `output_type`
2. There are no pending tool calls
3. There are no handoff requests

#### Runner API

```python
class Runner:
    @staticmethod
    async def run(
        agent: Agent[TContext],
        input: str | list[InputItem] | RunState,
        *,
        context: TContext = None,
        max_turns: int = 10,
        hooks: RunHooks = None,
        run_config: RunConfig = None,
        session: Session = None,
    ) -> RunResult:
        """Execute agent to completion"""
    
    @staticmethod
    def run_sync(...) -> RunResult:
        """Synchronous wrapper"""
    
    @staticmethod
    async def run_streamed(...) -> RunResultStreaming:
        """Execute with streaming events"""
```

#### Max Turns Handling

When `max_turns` is exceeded:

```python
# Raises MaxTurnsExceeded exception
try:
    result = await Runner.run(agent, input, max_turns=5)
except MaxTurnsExceeded as e:
    # Exception contains partial data via e.run_data
    # But no access to final output (since it wasn't produced)
    pass
```

**Key Limitation:** When `MaxTurnsExceeded` is raised, you cannot access a "partial response" from the model. The exception contains run metadata but not intermediate outputs in a directly usable form.

#### Streaming Behavior

```python
# Streaming execution
result = await Runner.run_streamed(agent, "Hello")

async for event in result.stream_events():
    match event:
        case RawResponsesStreamEvent():
            # Token-level deltas from LLM
            # e.g., response.output_text.delta
            print(event.data.delta, end="")
        
        case RunItemStreamEvent():
            # Semantic item completion
            # e.g., tool call finished, message completed
            print(f"Item: {event.item}")
        
        case AgentUpdatedStreamEvent():
            # Agent switched (handoff occurred)
            print(f"Now running: {event.agent.name}")

# After streaming completes
print(f"Final: {result.final_output}")
```

---

### 3. Hook/Callback System

#### RunHooks (Global)

Applied to all agents in a run:

```python
class RunHooks(Generic[TContext]):
    async def on_agent_start(
        self, 
        context: RunContextWrapper[TContext], 
        agent: Agent
    ) -> None:
        """Called when agent becomes active (including handoffs)"""
    
    async def on_agent_end(
        self,
        context: RunContextWrapper[TContext],
        agent: Agent,
        output: Any
    ) -> None:
        """Called when agent produces final output"""
    
    async def on_handoff(
        self,
        context: RunContextWrapper[TContext],
        from_agent: Agent,
        to_agent: Agent
    ) -> None:
        """Called during handoff"""
    
    async def on_tool_start(
        self,
        context: RunContextWrapper[TContext],
        agent: Agent,
        tool: Tool
    ) -> None:
        """Called before tool execution"""
    
    async def on_tool_end(
        self,
        context: RunContextWrapper[TContext],
        agent: Agent,
        tool: Tool,
        result: str
    ) -> None:
        """Called after tool execution"""
    
    async def on_llm_start(
        self,
        context: RunContextWrapper[TContext],
        agent: Agent,
        system_prompt: str,
        input_items: list[InputItem]
    ) -> None:
        """Called before LLM invocation"""
    
    async def on_llm_end(
        self,
        context: RunContextWrapper[TContext],
        agent: Agent,
        response: ModelResponse
    ) -> None:
        """Called after LLM returns"""
```

#### AgentHooks (Per-Agent)

Same interface but scoped to a specific agent:

```python
class AgentHooks(Generic[TContext]):
    async def on_start(self, context, agent) -> None: ...
    async def on_end(self, context, agent, output) -> None: ...
    async def on_handoff(self, context, agent, source) -> None: ...
    async def on_tool_start(self, context, agent, tool) -> None: ...
    async def on_tool_end(self, context, agent, tool, result) -> None: ...
    async def on_llm_start(self, context, agent, system_prompt, input_items) -> None: ...
    async def on_llm_end(self, context, agent, response) -> None: ...
```

**What Can Be Modified vs Observed:**

| Hook | Observable | Modifiable |
|------|------------|------------|
| `on_agent_start` | Agent context | No |
| `on_agent_end` | Agent output | No |
| `on_tool_start` | Tool, arguments | No |
| `on_tool_end` | Tool result | No |
| `on_llm_start` | System prompt, inputs | No (use `call_model_input_filter`) |
| `on_llm_end` | Model response | No |

**Key Insight:** Hooks are purely observational. For modification, use:
- `call_model_input_filter` in `RunConfig` - Transform inputs before LLM call
- Custom tools that wrap/modify behavior
- Guardrails for validation/rejection

---

### 4. Tool Execution

#### Function Tool Definition

```python
from agents import function_tool, RunContextWrapper

# Basic tool
@function_tool
async def get_weather(city: str) -> str:
    """Fetch current weather for a city.
    
    Args:
        city: The city name to look up
    """
    return f"Weather in {city}: Sunny, 72°F"

# Tool with context access
@function_tool
async def fetch_user_data(
    ctx: RunContextWrapper[MyContext],
    user_id: int
) -> str:
    """Fetch user data from database."""
    db = ctx.context.database
    return await db.get_user(user_id)

# Tool with custom configuration
@function_tool(
    name_override="search_documents",
    failure_error_function=lambda ctx, e: f"Search failed: {e}"
)
async def search(query: str, limit: int = 10) -> str:
    """Search the document store."""
    ...
```

**function_tool Parameters:**

- `name_override: str` - Custom tool name (default: function name)
- `use_docstring_info: bool` - Parse docstrings for descriptions (default: True)
- `failure_error_function: Callable` - Custom error handler for crashes
- `is_enabled: bool | Callable` - Conditionally enable tool

**Tool Output Types:**

```python
from agents import ToolOutputText, ToolOutputImage, ToolOutputFileContent

@function_tool
async def generate_chart(data: list[float]) -> ToolOutputImage:
    image_bytes = create_chart(data)
    return ToolOutputImage(data=base64.b64encode(image_bytes).decode())
```

#### Tool Approval / Human-in-the-Loop

```python
# Define tool with approval requirement
@function_tool(needs_approval=True)  # Always require approval
async def delete_file(path: str) -> str: ...

# Dynamic approval based on arguments
def needs_approval(ctx: ToolContext, tool_name: str, args: str) -> bool:
    parsed = json.loads(args)
    return parsed.get("city") == "Oakland"  # Only approve Oakland requests

@function_tool(needs_approval=needs_approval)
async def get_temperature(city: str) -> str: ...
```

**Approval Flow:**

```python
# Run agent - will pause on approval-required tools
result = await Runner.run(agent, "Delete important.txt")

if result.interruptions:
    # Save state for later
    state = result.to_state()
    state_json = state.to_json()
    
    # ... Later (possibly different process) ...
    
    state = RunState.from_json(state_json)
    
    for interruption in state.interruptions:
        if user_approves(interruption):
            state.approve(interruption)
        else:
            state.reject(interruption)
    
    # Resume execution
    result = await Runner.run(agent, state)
```

#### Handoffs Between Agents

```python
from agents import Agent, handoff, Handoff

# Simple handoff
spanish_agent = Agent(name="Spanish", instructions="Respond in Spanish")
english_agent = Agent(name="English", instructions="Respond in English")

triage_agent = Agent(
    name="Triage",
    instructions="Route to appropriate language agent",
    handoffs=[spanish_agent, english_agent]  # Creates transfer_to_spanish, transfer_to_english
)

# Customized handoff
escalation_handoff = handoff(
    agent=support_agent,
    tool_name_override="escalate_to_support",
    tool_description_override="Escalate complex issues to human support",
    input_type=EscalationReason,  # Pydantic model for structured input
    on_handoff=lambda ctx, input: log_escalation(input),
    input_filter=lambda data: data.remove_tool_calls()  # Filter conversation history
)

main_agent = Agent(handoffs=[escalation_handoff])
```

---

### 5. Guardrails

#### Input Guardrails

```python
from agents import InputGuardrail, input_guardrail, GuardrailFunctionOutput

@input_guardrail
async def check_content_policy(
    ctx: RunContextWrapper,
    agent: Agent,
    input: str | list[InputItem]
) -> GuardrailFunctionOutput:
    """Check if input violates content policy."""
    is_violation = await check_policy(input)
    return GuardrailFunctionOutput(
        output_info={"checked": True},
        tripwire_triggered=is_violation
    )

agent = Agent(
    input_guardrails=[check_content_policy]
)
```

**Execution Modes:**

```python
InputGuardrail(
    guardrail_function=my_guardrail,
    run_in_parallel=True  # Default: run alongside LLM (best latency)
)

InputGuardrail(
    guardrail_function=my_guardrail,
    run_in_parallel=False  # Block: prevent LLM call if triggered
)
```

**Key Behavior:** Input guardrails only run on the *first* agent in a workflow. Handoff targets do not re-run input guardrails.

#### Output Guardrails

```python
@output_guardrail
async def validate_output_format(
    ctx: RunContextWrapper,
    agent: Agent,
    output: Any
) -> GuardrailFunctionOutput:
    """Ensure output meets format requirements."""
    is_valid = validate_format(output)
    return GuardrailFunctionOutput(
        output_info={"format_valid": is_valid},
        tripwire_triggered=not is_valid
    )
```

**Key Behavior:** Output guardrails always run *after* agent completion. No `run_in_parallel` option.

#### Tool Guardrails

```python
from agents import tool_input_guardrail, tool_output_guardrail

@tool_input_guardrail
async def block_sensitive_args(
    ctx: ToolContext,
    tool: FunctionTool,
    args: str
) -> ToolGuardrailFunctionOutput:
    """Block tool calls with sensitive arguments."""
    if "password" in args.lower():
        return ToolGuardrailFunctionOutput(
            tripwire_triggered=False,
            reject_content="Cannot process requests involving passwords"
        )
    return ToolGuardrailFunctionOutput(tripwire_triggered=False)

@tool_output_guardrail
async def redact_ssn(
    ctx: ToolContext,
    tool: FunctionTool,
    output: str
) -> ToolGuardrailFunctionOutput:
    """Redact SSN from tool output."""
    if contains_ssn(output):
        return ToolGuardrailFunctionOutput(
            tripwire_triggered=True,  # Halt execution
            raise_exception=True
        )
    return ToolGuardrailFunctionOutput(tripwire_triggered=False)
```

**Response Strategies:**

- `reject_content` - Inform model the call failed, continue execution
- `raise_exception=True` - Halt execution entirely

**Limitation:** Tool guardrails only apply to `function_tool`-created tools. Hosted tools and local runtime tools bypass this pipeline.

---

### 6. State Management & Continuation

#### RunState

```python
@dataclass
class RunState(Generic[TContext]):
    input: str | list[InputItem]
    new_items: list[RunItem]
    raw_responses: list[ModelResponse]
    current_agent: Agent
    current_turn: int
    interruptions: list[ToolApprovalItem]
    
    def approve(self, interruption: ToolApprovalItem) -> None:
        """Mark interruption as approved"""
    
    def reject(self, interruption: ToolApprovalItem) -> None:
        """Mark interruption as rejected"""
    
    def to_json(self) -> str:
        """Serialize state for persistence"""
    
    @classmethod
    def from_json(cls, json_str: str) -> RunState:
        """Deserialize state"""
```

#### Continuation Patterns

**Pattern 1: Manual History Management**

```python
# First turn
result = await Runner.run(agent, "Hello")
history = result.to_input_list()

# Second turn
result = await Runner.run(agent, history + [{"role": "user", "content": "Follow up"}])
```

**Pattern 2: Sessions (Automatic)**

```python
from agents import SQLiteSession

session = SQLiteSession(db_path="chat.db", session_id="user-123")

# Session automatically loads/stores history
result = await Runner.run(agent, "Hello", session=session)
result = await Runner.run(agent, "Follow up", session=session)
```

**Pattern 3: Tool Approval Continuation**

```python
# Initial run hits approval requirement
result = await Runner.run(agent, "Delete all files")

if result.interruptions:
    # Get resumable state
    state = result.to_state()
    
    # Process approvals
    for interruption in result.interruptions:
        if should_approve(interruption):
            state.approve(interruption)
        else:
            state.reject(interruption)
    
    # Resume from state
    result = await Runner.run(agent, state)
```

**Pattern 4: Server-Managed Conversation**

```python
# Using OpenAI's Responses API conversation management
result = await Runner.run(
    agent, 
    "Hello",
    run_config=RunConfig(conversation_id="conv-123")
)

# Continue same conversation
result = await Runner.run(
    agent,
    "Follow up",
    run_config=RunConfig(previous_response_id=result.last_response_id)
)
```

---

### 7. Limitations & Tradeoffs

#### Known Limitations

| Limitation | Impact | Workaround |
|------------|--------|------------|
| **No partial response on MaxTurnsExceeded** | Cannot access intermediate outputs when limit hit | Use larger `max_turns`, or implement custom turn tracking with hooks |
| **Input guardrails only on first agent** | Security gaps possible in handoff chains | Apply guardrails explicitly in downstream agents |
| **Tool guardrails only for function_tool** | Hosted/runtime tools bypass validation | Wrap hosted tools in function_tool proxies |
| **Hooks are observation-only** | Cannot modify execution flow from hooks | Use guardrails, input filters, or custom tools |
| **State serialization requires agent recreation** | Agents not serialized with state | Store agent configuration separately |
| **Streaming + structured output** | Token streaming limited for structured outputs | Model buffers JSON internally |

#### What You CAN'T Do

1. **Modify LLM request from hooks** - Use `call_model_input_filter` instead
2. **Pause execution mid-tool** - Only approval interruptions are supported
3. **Access intermediate reasoning** - Reasoning items are captured but may be incomplete
4. **Retry specific tool calls** - Must re-run entire turn or implement custom retry logic
5. **Stream partial structured output** - JSON is validated complete, no partial parsing
6. **Cancel individual tool calls** - Cancellation is per-turn or immediate
7. **Inject messages mid-turn** - Input manipulation must happen before turn starts

#### Design Constraints

1. **Single context type per run** - All agents, tools, and hooks must use compatible context types
2. **Handoffs replace current agent** - No "sub-agent" pattern without using `as_tool()`
3. **Guardrail tripwire halts execution** - No "warn and continue" for tripwires (use `reject_content` instead)
4. **Session persistence is turn-boundary** - Mid-turn crashes lose that turn's progress
5. **MCP tools are discovered per-run** - Tool list refreshes each execution

#### Exception Types

```python
# Base exception
class AgentsException(Exception):
    run_data: Optional[RunData]  # Partial execution data

# Specific exceptions
class MaxTurnsExceeded(AgentsException): ...
class ModelBehaviorError(AgentsException): ...  # Malformed output, invalid tool calls
class UserError(AgentsException): ...           # SDK misuse

# Guardrail exceptions
class InputGuardrailTripwireTriggered(AgentsException):
    guardrail_result: GuardrailResult

class OutputGuardrailTripwireTriggered(AgentsException):
    guardrail_result: GuardrailResult

class ToolInputGuardrailTripwireTriggered(AgentsException):
    guardrail: ToolInputGuardrail
    output: ToolGuardrailFunctionOutput

class ToolOutputGuardrailTripwireTriggered(AgentsException):
    guardrail: ToolOutputGuardrail
    output: ToolGuardrailFunctionOutput
```

---

### 8. Comparison with Yrden Design Goals

| Feature | OpenAI Agents SDK | Yrden Target | Notes |
|---------|-------------------|--------------|-------|
| Multi-provider | OpenAI + LiteLLM | Anthropic, OpenAI, Bedrock, MLX | Yrden prioritizes first-party providers |
| Structured output | Pydantic models | `@Schema` macro | Swift's compile-time approach |
| Loop control | `run_streamed()` + events | `.iter()` AsyncSequence | More granular iteration in Yrden |
| Tool approval | `needs_approval` + interruptions | Similar pattern needed | Good reference implementation |
| Guardrails | Input/Output/Tool | Similar design | Consider tripwire vs. rejection distinction |
| Context/DI | Generic `TContext` | Generic `Deps` | Nearly identical pattern |
| Handoffs | Built-in | Planned Phase 6 | OpenAI pattern is solid reference |
| MCP | Full support | Planned Phase 5 | Good transport abstraction |
| Sessions | SQLite, Redis, etc. | Not prioritized | Could add later |
| Tracing | Built-in + integrations | Not prioritized | Could add later |

#### Key Takeaways for Yrden

1. **Adopt the interruption/state pattern** for tool approval - Well-designed, serializable
2. **Separate hooks from modification points** - Hooks observe, filters/guardrails modify
3. **Consider tripwire vs reject distinction** in guardrails - Different severity levels
4. **Plan for state serialization early** - Agent recreation from state is tricky
5. **Input guardrails on first agent only** is a reasonable constraint
6. **tool_use_behavior pattern** is useful for controlling when loop continues

---

### 9. TypeScript SDK Differences

The TypeScript SDK (`@openai/agents`) mirrors Python closely but with some differences:

**Type System:**
- Uses Zod v4 for schema validation (required dependency)
- Generic type parameters: `Agent<TContext, TOutput>`
- Strong typing throughout with TypeScript conventions

**Streaming:**
- `StreamedRunResult` implements `AsyncIterable<RunStreamEvent>`
- `toStream()` and `toTextStream()` for ReadableStream conversion

**Platform:**
- Requires Node.js 22+
- Experimental Deno/Bun support
- Future: voice pipeline, long-running function suspension

**API Parity:**
- Same core concepts: Agent, Runner, Guardrails, Handoffs
- Same hook system
- Same state management patterns

---

*Research conducted February 2026. Sources: OpenAI Agents SDK Python repository (github.com/openai/openai-agents-python), TypeScript repository (github.com/openai/openai-agents-js), and official documentation (openai.github.io/openai-agents-python).*
Let me search for examples from the repository structure we found earlier.
Let me try accessing the documentation site structure differently.
Let me search for additional patterns and advanced features in the source code.
Now let me search for information on ModelSettings and streaming event types.
Let me search for more details on advanced patterns and the JavaScript SDK comparison.
Now let me compile all the additional research into an extended documentation section.
Now let me create a comprehensive continuation document with the additional research findings.

---

## OpenAI Agents SDK Research Appendix (Continued)

### 10. Advanced Agent Configuration

#### Tool Use Behavior (Detailed)

The `tool_use_behavior` parameter provides fine-grained control over when the agent loop terminates:

**Option 1: `"run_llm_again"` (Default)**
```python
agent = Agent(
    name="Assistant",
    tool_use_behavior="run_llm_again",  # Default
    tools=[search_tool, calculator_tool]
)
# Flow: LLM → Tool → LLM processes result → Final output
```

**Option 2: `"stop_on_first_tool"`**
```python
agent = Agent(
    name="QuickSearch",
    tool_use_behavior="stop_on_first_tool",
    tools=[search_tool, calculator_tool]
)
# Flow: LLM → First tool call → Return tool output immediately
# (LLM never processes the tool result)
```

**Option 3: `StopAtTools` (Selective Stopping)**
```python
from agents.agent import StopAtTools

agent = Agent(
    name="SelectiveStop",
    tool_use_behavior=StopAtTools(stop_at_tool_names=["get_weather"]),
    tools=[get_weather, sum_two_numbers]
)
# Stops only when get_weather is called
# Other tools follow "run_llm_again" behavior
```

**Option 4: `ToolsToFinalOutputFunction` (Custom Logic)**
```python
def custom_stop_logic(
    ctx: RunContextWrapper,
    agent: Agent,
    tool_calls: list[ToolCall]
) -> bool:
    """Return True to stop, False to continue"""
    # Custom logic: stop if any high-priority tool is called
    high_priority = ["urgent_search", "critical_action"]
    return any(tc.name in high_priority for tc in tool_calls)

agent = Agent(
    name="CustomControl",
    tool_use_behavior=custom_stop_logic,
    tools=[...]
)
```

**Important Behavior Note:** When `stop_on_first_tool` is enabled, the agent will still continue if *no* tool is called. This is by design - the behavior only activates when a tool is actually invoked.

#### Reset Tool Choice

```python
agent = Agent(
    name="ToolUser",
    tools=[my_tool],
    reset_tool_choice=True  # Default - prevents infinite loops
)
```

**When `True` (default):**
- First turn: Agent can choose to call tools
- Subsequent turns: Tool choice resets to "auto"
- Prevents: Agent repeatedly calling the same tool in a loop

**When `False`:**
- Tool selection strategy persists across turns
- Risk: May cause infinite loops if agent always chooses tools
- Use case: When you want forced tool use throughout execution

---

### 11. Context System Deep Dive

#### Context as Dependency Injection

```python
from dataclasses import dataclass
from agents import Agent, Runner, function_tool, RunContextWrapper

@dataclass
class MyContext:
    database: DatabaseClient
    api_client: APIClient
    user_id: str
    session_data: dict

# Tool accessing context
@function_tool
async def fetch_user_profile(
    ctx: RunContextWrapper[MyContext],
    user_id: str
) -> str:
    # Access dependency-injected services
    db = ctx.context.database
    profile = await db.get_user(user_id)
    return f"User: {profile.name}"

# Agent with typed context
agent = Agent[MyContext](  # Generic type parameter
    name="UserAgent",
    tools=[fetch_user_profile]
)

# Run with context
context = MyContext(
    database=db_client,
    api_client=api_client,
    user_id="user-123",
    session_data={}
)
result = await Runner.run(agent, "Get my profile", context=context)
```

#### ToolContext for Metadata

```python
from agents import ToolContext

@function_tool
async def advanced_tool(
    ctx: ToolContext[MyContext],  # Extended context
    query: str
) -> str:
    # Access tool-specific metadata
    tool_name = ctx.tool_name          # "advanced_tool"
    call_id = ctx.tool_call_id         # Unique call identifier
    args_json = ctx.tool_arguments      # Raw JSON string
    
    # Also access app context
    db = ctx.context.database
    
    # Can use call_id for logging, tracing
    logger.info(f"Tool {tool_name} called with ID {call_id}")
    
    return result
```

#### Context Constraints

**Critical Rule:** All agents, tools, and hooks in a single run must use the **same context type**.

```python
# ❌ WRONG - Type mismatch
agent1 = Agent[DatabaseContext](...)
agent2 = Agent[APIContext](...)  # Different type!
agent1.handoffs = [agent2]  # Type error

# ✅ CORRECT - Same context type
agent1 = Agent[AppContext](...)
agent2 = Agent[AppContext](...)
agent1.handoffs = [agent2]
```

---

### 12. RunConfig Comprehensive Reference

```python
@dataclass
class RunConfig:
    # Model overrides
    model: str | Model | None = None
    model_provider: ModelProvider | None = None
    model_settings: ModelSettings | None = None
    
    # Global guardrails
    input_guardrails: list[InputGuardrail] = field(default_factory=list)
    output_guardrails: list[OutputGuardrail] = field(default_factory=list)
    
    # Handoff configuration
    handoff_input_filter: InputFilterFunction | None = None
    nest_handoff_history: bool = False  # Beta feature
    handoff_history_mapper: Callable | None = None
    
    # Input manipulation
    call_model_input_filter: CallModelInputFilterFunction | None = None
    
    # Tracing
    tracing: dict | None = None  # {"api_key": "...", "workflow_name": "..."}
    trace_workflow_name: str | None = None
    trace_id: str | None = None
    trace_include_sensitive_data: bool = True
    
    # Session management
    session_settings: SessionSettings | None = None
    
    # OpenAI Conversations API
    conversation_id: str | None = None      # Reuse conversation
    previous_response_id: str | None = None # Chain responses

# Usage examples
result = await Runner.run(
    agent,
    "Hello",
    run_config=RunConfig(
        model="gpt-4o",  # Override agent's model
        model_settings=ModelSettings(temperature=0.0),
        nest_handoff_history=True,
        tracing={"api_key": "sk-trace-123", "workflow_name": "CustomerSupport"},
        trace_include_sensitive_data=False  # Redact LLM data from traces
    )
)
```

#### Call Model Input Filter

Transform inputs immediately before LLM invocation:

```python
def trim_history(
    context: RunContextWrapper,
    agent: Agent,
    input_items: list[InputItem]
) -> list[InputItem]:
    """Keep only last 10 messages to reduce tokens"""
    return input_items[-10:]

def redact_sensitive(
    context: RunContextWrapper,
    agent: Agent,
    input_items: list[InputItem]
) -> list[InputItem]:
    """Remove PII from inputs"""
    for item in input_items:
        if isinstance(item, MessageInputItem):
            item.content = redact_pii(item.content)
    return input_items

result = await Runner.run(
    agent,
    input,
    run_config=RunConfig(call_model_input_filter=trim_history)
)
```

---

### 13. Sessions System

Sessions automate conversation history management:

**Manual Approach (No Session):**
```python
# Turn 1
result1 = await Runner.run(agent, "Hello")
history = result1.to_input_list()

# Turn 2
result2 = await Runner.run(agent, history + [{"role": "user", "content": "How are you?"}])
history = result2.to_input_list()

# Turn 3...
```

**Automated Approach (With Session):**
```python
from agents import SQLiteSession

session = SQLiteSession(db_path="conversations.db", session_id="user-123")

# Turn 1
result1 = await Runner.run(agent, "Hello", session=session)
# Session automatically stores new items

# Turn 2
result2 = await Runner.run(agent, "How are you?", session=session)
# Session automatically retrieves and prepends history

# Turn 3...
result3 = await Runner.run(agent, "Tell me more", session=session)
```

#### Available Session Types

| Session Type | Use Case | Backend |
|--------------|----------|---------|
| `SQLiteSession` | Simple local storage | SQLite (file or :memory:) |
| `SQLAlchemySession` | Production databases | PostgreSQL, MySQL, etc. |
| `AdvancedSQLiteSession` | Branching conversations | SQLite + analytics |
| `EncryptedSession` | Data security | Wraps any session with encryption |
| `OpenAIConversationsSession` | Cloud storage | OpenAI Conversations API |
| `OpenAIResponsesCompactionSession` | History compression | OpenAI Responses API |
| `DaprSession` | Cloud-native | 30+ Dapr state stores |

#### Custom Session Implementation

```python
from agents import SessionABC

class RedisSession(SessionABC):
    def __init__(self, redis_client, session_id: str):
        self.redis = redis_client
        self.session_id = session_id
    
    async def get_items(self) -> list[RunItem]:
        """Retrieve conversation history"""
        data = await self.redis.get(f"session:{self.session_id}")
        return json.loads(data) if data else []
    
    async def add_items(self, items: list[RunItem]) -> None:
        """Store new items"""
        current = await self.get_items()
        current.extend(items)
        await self.redis.set(f"session:{self.session_id}", json.dumps(current))
    
    async def pop_item(self) -> RunItem | None:
        """Remove last item"""
        items = await self.get_items()
        if items:
            removed = items.pop()
            await self.redis.set(f"session:{self.session_id}", json.dumps(items))
            return removed
        return None
    
    async def clear_session(self) -> None:
        """Clear all history"""
        await self.redis.delete(f"session:{self.session_id}")
```

---

### 14. Structured Outputs

#### Basic Usage

```python
from pydantic import BaseModel
from agents import Agent, Runner

class WeatherReport(BaseModel):
    location: str
    temperature: float
    conditions: str
    humidity: int

agent = Agent(
    name="WeatherBot",
    instructions="Provide weather information",
    output_type=WeatherReport  # Enforces structured output
)

result = await Runner.run(agent, "What's the weather in SF?")
weather: WeatherReport = result.final_output  # Typed!

print(weather.temperature)  # 72.5
print(weather.conditions)   # "Sunny"
```

#### Supported Output Types

```python
# Pydantic models
from pydantic import BaseModel
class Response(BaseModel):
    answer: str
    confidence: float

# Python dataclasses
from dataclasses import dataclass
@dataclass
class Analysis:
    summary: str
    score: int

# Built-in types
agent = Agent(output_type=str)  # Plain string
agent = Agent(output_type=int)  # Integer
agent = Agent(output_type=bool) # Boolean
```

#### With Tools

```python
class SearchResult(BaseModel):
    query: str
    results: list[str]
    total_found: int

agent = Agent(
    name="Searcher",
    instructions="Search and return structured results",
    tools=[search_tool],
    output_type=SearchResult
)

# Agent can use tools, but final output MUST match SearchResult schema
result = await Runner.run(agent, "Find articles about AI")
search_data: SearchResult = result.final_output
```

---

### 15. Streaming Events (Detailed)

#### Event Type Hierarchy

```python
# Top-level union type
StreamEvent = RawResponsesStreamEvent | RunItemStreamEvent | AgentUpdatedStreamEvent

# 1. Raw LLM events (token-level)
@dataclass
class RawResponsesStreamEvent:
    type: Literal["raw_response_event"]
    data: ResponseStreamEvent  # OpenAI Responses API event
    # Subtypes: ResponseTextDeltaEvent, ResponseToolCallDeltaEvent, etc.

# 2. Semantic events (item-level)
@dataclass
class RunItemStreamEvent:
    type: Literal["run_item_stream_event"]
    name: Literal[
        "message_output_created",
        "reasoning_item_created",
        "tool_called",
        "tool_output",
        "handoff_requested",
        "handoff_occured",
        "mcp_list_tools",
        "mcp_approval_requested",
        "mcp_approval_response"
    ]
    item: RunItem  # MessageOutputItem, ToolCallItem, etc.

# 3. Agent transition events
@dataclass
class AgentUpdatedStreamEvent:
    type: Literal["agent_updated_stream_event"]
    new_agent: Agent
```

#### Streaming Patterns

**Pattern 1: Token-by-Token Text Streaming**
```python
result = await Runner.run_streamed(agent, "Tell me a story")

async for event in result.stream_events():
    if event.type == "raw_response_event":
        if isinstance(event.data, ResponseTextDeltaEvent):
            print(event.data.delta, end="", flush=True)
```

**Pattern 2: Semantic Progress Updates**
```python
async for event in result.stream_events():
    if event.type == "run_item_stream_event":
        match event.name:
            case "tool_called":
                tool_call: ToolCallItem = event.item
                print(f"Calling {tool_call.name}...")
            case "tool_output":
                tool_output: ToolCallOutputItem = event.item
                print(f"Tool returned: {tool_output.output[:50]}...")
            case "message_output_created":
                message: MessageOutputItem = event.item
                print(f"Final message: {message.content}")
```

**Pattern 3: Multi-Agent Tracking**
```python
current_agent = agent

async for event in result.stream_events():
    if event.type == "agent_updated_stream_event":
        current_agent = event.new_agent
        print(f"Handed off to: {current_agent.name}")
    elif event.type == "run_item_stream_event":
        print(f"[{current_agent.name}] {event.name}")
```

**Pattern 4: Combined Streaming**
```python
async for event in result.stream_events():
    match event:
        case RawResponsesStreamEvent(data=ResponseTextDeltaEvent(delta=text)):
            # Token-level
            print(text, end="")
        
        case RunItemStreamEvent(name="tool_called", item=tool_call):
            # Item-level
            print(f"\n[Calling {tool_call.name}]\n")
        
        case AgentUpdatedStreamEvent(new_agent=agent):
            # Agent-level
            print(f"\n=== Switched to {agent.name} ===\n")
```

#### Cancellation

```python
result = await Runner.run_streamed(agent, "Long running task")

# Cancel after 5 seconds
await asyncio.sleep(5)
result.cancel(mode="immediate")  # Stop immediately

# Or let current turn finish
result.cancel(mode="after_turn")  # Graceful shutdown
```

---

### 16. ModelSettings (Complete Reference)

```python
from agents import ModelSettings, Reasoning

settings = ModelSettings(
    # Sampling parameters
    temperature=0.7,                    # Randomness (0.0-2.0)
    top_p=0.95,                         # Nucleus sampling
    frequency_penalty=0.0,              # Reduce repetition (-2.0 to 2.0)
    presence_penalty=0.0,               # Encourage diversity (-2.0 to 2.0)
    
    # Tool configuration
    tool_choice="auto",                 # "auto", "required", "none", or tool name
    parallel_tool_calls=True,           # Allow multiple tools per turn
    
    # Output control
    max_tokens=1000,                    # Max output length
    truncation="auto",                  # "auto" or "disabled"
    verbosity="medium",                 # "low", "medium", "high"
    
    # Reasoning models (o1, o3, gpt-5.x)
    reasoning=Reasoning(
        effort="high"                   # "none", "minimal", "low", "medium", "high", "xhigh"
    ),
    
    # Persistence
    store=True,                         # Store responses in OpenAI
    prompt_cache_retention="24h",       # "in_memory" or "24h"
    
    # Debugging
    response_include=["usage"],         # Additional response fields
    top_logprobs=5,                     # Token probability info
    include_usage=True,                 # Token usage (Chat Completions only)
    
    # Custom data
    metadata={"user_id": "123"},        # Key-value pairs
    
    # Provider-specific extensions
    extra_query={"custom_param": "value"},
    extra_body={"vendor_option": True},
    extra_headers={"X-Custom": "header"},
    extra_args={"litellm_param": "value"}  # LiteLLM integration
)

agent = Agent(
    name="Assistant",
    model_settings=settings
)
```

#### Reasoning Effort Levels (2026 Update)

| Effort | Use Case | Latency | Cost | Reliability |
|--------|----------|---------|------|-------------|
| `"none"` | Fast responses, simple tasks | Lowest | Lowest | Standard |
| `"minimal"` | Slightly complex queries | Very Low | Low | Good |
| `"low"` | Moderate reasoning needed | Low | Low | Better |
| `"medium"` | Complex analysis | Medium | Medium | High |
| `"high"` | Expert-level reasoning | High | High | Very High |
| `"xhigh"` | Maximum reliability (gpt-5.2+) | Highest | Highest | Maximum |

**New in 2026:**
- `"none"` - New default for gpt-5.1 (faster than previous `"medium"`)
- `"xhigh"` - Added in gpt-5.2 for critical applications
- Concise reasoning summaries available

---

### 17. TypeScript SDK Differences

#### Streaming API

```typescript
import { Agent, run } from '@openai/agents';

// Enable streaming
const result = await run(agent, 'Tell me a story', {
  stream: true,
});

// Text-only streaming (Node.js compatible)
result
  .toTextStream({ compatibleWithNodeStreams: true })
  .pipe(process.stdout);

// Wait for completion
await result.completed;

// Event-by-event processing
for await (const event of result) {
  switch (event.type) {
    case 'raw_model_stream_event':
      console.log(event.data);
      break;
    case 'run_item_stream_event':
      console.log(`Item: ${event.name}`);
      break;
    case 'agent_updated_stream_event':
      console.log(`Agent: ${event.new_agent.name}`);
      break;
  }
}
```

#### Agent Hooks (TypeScript)

```typescript
// Streaming hooks for agent-as-tool
const managerAgent = new Agent({
  name: 'Manager',
  tools: [
    researchAgent.asTool({
      // Option 1: Catch-all hook
      onStream: (event) => {
        console.log(event.type, event);
      }
    }),
    
    analysisAgent.asTool({
      // Option 2: Selective event handling
      on: (eventName, handler) => {
        if (eventName === 'tool_called') {
          handler(event);
        }
      }
    })
  ]
});

// Lifecycle hooks
agent.on('start', (ctx, agent) => {
  console.log(`Agent ${agent.name} starting`);
});

agent.on('end', (ctx, agent, output) => {
  console.log(`Agent ${agent.name} completed`);
});
```

#### Zod for Schema Validation

```typescript
import { z } from 'zod';

const WeatherSchema = z.object({
  location: z.string(),
  temperature: z.number(),
  conditions: z.enum(['sunny', 'cloudy', 'rainy']),
  humidity: z.number().min(0).max(100)
});

const agent = new Agent<undefined, typeof WeatherSchema>({
  name: 'WeatherBot',
  instructions: 'Provide weather information',
  outputType: WeatherSchema
});

const result = await run(agent, 'Weather in SF?');
const weather = result.finalOutput;  // Typed via Zod
```

#### Key Differences from Python

| Feature | Python | TypeScript |
|---------|--------|------------|
| Schema validation | Pydantic | Zod v4 (required) |
| Async execution | `asyncio` | Native async/await |
| Type parameters | `Agent[TContext]` | `Agent<TContext, TOutput>` |
| Streaming text | `.stream_events()` | `.toTextStream()` |
| Node compatibility | N/A | ReadableStream support |
| Platform support | Python 3.9+ | Node.js 22+, Deno/Bun (experimental) |

---

### 18. Production Patterns

#### Pattern: Human-in-the-Loop with State Persistence

```python
import json
from agents import Agent, Runner, function_tool, RunState

@function_tool(needs_approval=True)
async def delete_database(table_name: str) -> str:
    """Delete an entire database table."""
    # This will require approval before execution
    execute_sql(f"DROP TABLE {table_name}")
    return f"Deleted {table_name}"

agent = Agent(
    name="DBAdmin",
    tools=[delete_database],
    instructions="Help manage the database"
)

# Initial run
result = await Runner.run(agent, "Clean up old tables")

if result.interruptions:
    # Serialize state
    state = result.to_state()
    state_json = state.to_json()
    
    # Save to database/queue for async processing
    await queue.push({
        "state": state_json,
        "interruptions": [
            {
                "tool": i.tool_name,
                "arguments": i.arguments,
                "timestamp": datetime.now()
            }
            for i in result.interruptions
        ]
    })
    
    # ... Later (different process/thread) ...
    
    # Retrieve from queue
    job = await queue.pop()
    state = RunState.from_json(job["state"])
    
    # Get human approval
    for interruption in state.interruptions:
        approved = await get_human_approval(
            tool_name=interruption.tool_name,
            arguments=interruption.arguments
        )
        
        if approved:
            state.approve(interruption)
        else:
            state.reject(interruption)
    
    # Resume execution
    final_result = await Runner.run(agent, state)
```

#### Pattern: Multi-Agent Triage with Handoffs

```python
from agents import Agent, Handoff, handoff

# Specialized agents
spanish_agent = Agent(
    name="SpanishExpert",
    instructions="You are fluent in Spanish. Respond in Spanish.",
    handoff_description="Transfer to Spanish language specialist"
)

technical_agent = Agent(
    name="TechnicalSupport",
    instructions="You handle technical issues with deep expertise.",
    handoff_description="Transfer to technical support specialist"
)

billing_agent = Agent(
    name="BillingDepartment",
    instructions="You handle billing and payment issues.",
    handoff_description="Transfer to billing department"
)

# Triage agent that routes requests
triage_agent = Agent(
    name="TriageAgent",
    instructions="""
    You are a routing agent. Analyze the user's request and transfer to:
    - SpanishExpert for Spanish language requests
    - TechnicalSupport for technical issues
    - BillingDepartment for billing/payment questions
    
    Never try to answer directly - always transfer.
    """,
    handoffs=[spanish_agent, technical_agent, billing_agent]
)

# Usage
result = await Runner.run(triage_agent, "¿Cuál es mi saldo?")
print(f"Handled by: {result.last_agent.name}")  # "SpanishExpert"
```

#### Pattern: Guardrails for Safety

```python
from agents import input_guardrail, output_guardrail, GuardrailFunctionOutput

@input_guardrail
async def content_policy_check(ctx, agent, input_text):
    """Block policy violations before LLM call"""
    violations = await moderation_api.check(input_text)
    
    if violations:
        return GuardrailFunctionOutput(
            output_info={"violations": violations},
            tripwire_triggered=True  # Halt execution
        )
    
    return GuardrailFunctionOutput(tripwire_triggered=False)

@output_guardrail
async def pii_redaction(ctx, agent, output):
    """Redact PII from final output"""
    if contains_pii(output):
        # Log but don't halt
        logger.warning("PII detected in output")
        # Could modify output here if needed
    
    return GuardrailFunctionOutput(tripwire_triggered=False)

agent = Agent(
    name="SafeAgent",
    input_guardrails=[content_policy_check],
    output_guardrails=[pii_redaction]
)
```

---

## Summary: Key Takeaways for Yrden

Based on the comprehensive research of the OpenAI Agents SDK, here are the most valuable patterns and design decisions to adopt:

### 1. **Adopt the Interruption Pattern**
- Tool approval via `needs_approval` flag
- `RunState` serialization for pause/resume
- Separate `approve()` and `reject()` methods
- This enables human-in-the-loop without blocking

### 2. **Tool Use Behavior Controls**
- Support multiple termination strategies:
  - Always process tool results (default)
  - Stop on first tool
  - Stop on specific tools
  - Custom stop logic
- This provides flexibility for different use cases

### 3. **Streaming Event Hierarchy**
- Three levels: Raw (token), Semantic (item), Agent (transition)
- Allows consumers to choose granularity
- Yrden should match this: `TokenDelta`, `ItemComplete`, `AgentSwitch`

### 4. **Guardrail Design**
- Input (before), Output (after), Tool (both)
- `tripwire` (halt) vs. `reject_content` (continue with feedback)
- Parallel vs. blocking execution for input guardrails
- Tool guardrails only for function tools (not hosted tools)

### 5. **Context as Dependency Injection**
- Generic type parameter: `Agent<TContext>`
- Same context type throughout run (enforced by type system)
- `RunContextWrapper` vs. `ToolContext` distinction
- Clean pattern for sharing services (DB, API clients, etc.)

### 6. **RunConfig Global Overrides**
- Model/provider/settings overrides
- Global guardrails
- Input filters (transform before LLM)
- Handoff behavior
- Tracing configuration

### 7. **Session Abstraction**
- Protocol-based design (`SessionABC`)
- Automatic history retrieval/storage
- Multiple implementations (SQLite, Redis, cloud, etc.)
- Yrden can defer this to Phase 7+

### 8. **Limitations to Acknowledge**
- No partial response on `MaxTurnsExceeded` (accepted tradeoff)
- Input guardrails only on first agent (document clearly)
- Hooks are observation-only (provide filters for modification)
- State serialization requires agent reconstruction (store config separately)

### 9. **TypeScript Parity**
- Zod for schema validation (Swift equivalent: `@Schema` macro)
- Event-driven streaming with AsyncIterable
- Generic types: `Agent<TContext, TOutput>`
- Same core concepts across languages

### 10. **Advanced Features to Consider**
- `reset_tool_choice` to prevent infinite loops
- `nest_handoff_history` for conversation compaction
- Reasoning effort levels for o1/o3-style models
- MCP with multiple transport types
- Voice agents (future consideration)

---

### Sources

- [OpenAI Agents SDK Python Documentation](https://openai.github.io/openai-agents-python/)
- [OpenAI Agents SDK TypeScript Documentation](https://openai.github.io/openai-agents-js/)
- [Running Agents Guide](https://openai.github.io/openai-agents-python/running_agents/)
- [Runner Reference](https://openai.github.io/openai-agents-python/ref/run/)
- [Agent Reference](https://openai.github.io/openai-agents-python/ref/agent/)
- [Configuring the SDK](https://openai.github.io/openai-agents-python/config/)
- [ModelSettings Reference](https://openai.github.io/openai-agents-python/ref/model_settings/)
- [Streaming Documentation](https://openai.github.io/openai-agents-python/streaming/)
- [Streaming Events Reference](https://openai.github.io/openai-agents-python/ref/stream_events/)
- [Sessions Documentation](https://openai.github.io/openai-agents-python/sessions/)
- [Tracing Documentation](https://openai.github.io/openai-agents-python/tracing/)
- [Tools Documentation](https://openai.github.io/openai-agents-python/tools/)
- [TypeScript Streaming Guide](https://openai.github.io/openai-agents-js/guides/streaming/)
- [TypeScript Agents Guide](https://openai.github.io/openai-agents-js/guides/agents/)
- [GitHub Repository (Python)](https://github.com/openai/openai-agents-python)
- [GitHub Repository (TypeScript)](https://github.com/openai/openai-agents-js)

*Research completed February 2026.*
