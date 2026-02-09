## PydanticAI API Surface Research

### Appendix A: PydanticAI Deep Dive

This appendix documents the PydanticAI framework API surface based on research of documentation and source code (February 2026).

---

### 1. Core Concepts & Types

#### Agent Generic Pattern

The `Agent` class is generic over two type parameters:

```python
class Agent(Generic[DepsT, OutputT]):
    """Agent for structured conversations with LLMs."""
```

- **`DepsT`** (Dependency Type): The type of object injected at runtime for tools and prompts to use. Defaults to `None`.
- **`OutputT`** (Output Type): The structured type the agent returns. Defaults to `str`.

Example:
```python
from pydantic_ai import Agent
from dataclasses import dataclass

@dataclass
class DatabaseConn:
    url: str
    
@dataclass
class AnalysisResult:
    summary: str
    confidence: float

# Fully typed agent
agent: Agent[DatabaseConn, AnalysisResult] = Agent(
    'openai:gpt-4',
    deps_type=DatabaseConn,
    output_type=AnalysisResult,
)
```

#### RunContext

`RunContext[DepsT]` provides runtime information to tools and dynamic prompts:

```python
@dataclass
class RunContext(Generic[DepsT]):
    deps: DepsT              # Injected dependencies
    retry: int               # Current retry count (0-indexed)
    usage: RunUsage          # Token/request usage so far
    metadata: dict | None    # Run metadata
    partial_output: bool     # True during streaming before final output
```

Key characteristics:
- Type-parameterized: `RunContext[str]` vs `RunContext[DatabaseConn]`
- Static type checking catches mismatches at development time
- Available in `@agent.tool`, `@agent.system_prompt`, and `@agent.output_validator`

#### Result Types

**AgentRunResult[OutputT]** - Returned by `run()` and `run_sync()`:
```python
@dataclass
class AgentRunResult(Generic[OutputT]):
    output: OutputT           # The validated output
    run_id: str               # Unique identifier
    timestamp: datetime       # When completed
    metadata: dict | None     # Run metadata
    
    def all_messages() -> list[ModelMessage]     # Full history
    def new_messages() -> list[ModelMessage]     # This run only
    def usage() -> RunUsage                      # Final usage stats
```

**StreamedRunResult[OutputT]** - Returned by `run_stream()`:
```python
class StreamedRunResult(Generic[OutputT]):
    is_complete: bool         # True after streaming finishes
    run_id: str
    metadata: dict | None
    
    async def stream_output() -> AsyncIterator[OutputT]  # Partial validated objects
    async def stream_text() -> AsyncIterator[str]        # Text chunks
    async def get_output() -> OutputT                    # Block until complete
    def all_messages() -> list[ModelMessage]
    def usage() -> RunUsage
```

---

### 2. Execution Model

#### Execution Methods

| Method | Returns | Use Case |
|--------|---------|----------|
| `run(prompt, deps=...)` | `AgentRunResult[OutputT]` | Standard async execution |
| `run_sync(prompt, deps=...)` | `AgentRunResult[OutputT]` | Synchronous (blocks event loop) |
| `run_stream(prompt, deps=...)` | `AsyncContextManager[StreamedRunResult]` | Stream output as it generates |
| `run_stream_events(prompt, deps=...)` | `AsyncIterator[AgentStreamEvent]` | Raw event stream |
| `iter(prompt, deps=...)` | `AsyncContextManager[AgentRun]` | Step-by-step graph iteration |

#### The iter() Method - Step-by-Step Control

`iter()` exposes the internal execution graph, allowing inspection and modification between steps:

```python
async with agent.iter('Analyze this data', deps=my_deps) as agent_run:
    async for node in agent_run:
        match node:
            case UserPromptNode():
                print(f"Starting with prompt")
            case ModelRequestNode():
                print(f"Calling LLM...")
                # Can call node.stream(agent_run.ctx) for streaming
            case CallToolsNode():
                print(f"Executing tools: {node.tool_calls}")
                # Human-in-the-loop approval point
            case End():
                print(f"Completed with: {node.data}")
```

**AgentNode Types:**
- `UserPromptNode` - Initial user input and system configuration
- `ModelRequestNode` - LLM API call (supports `.stream()`)
- `CallToolsNode` - Tool execution batch (supports `.stream()`)
- `End` - Terminal node with final result

**Manual Node Driving:**
```python
async with agent.iter('prompt', deps=deps) as run:
    node = run.next_node  # Get first node
    while not isinstance(node, End):
        # Inspect node before execution
        if isinstance(node, CallToolsNode):
            if requires_approval(node.tool_calls):
                approved = await get_human_approval(node)
                if not approved:
                    # Skip this node or modify it
                    continue
        node = await run.next(node)  # Execute and get next
    
    result = run.result  # AgentRunResult available after End
```

---

### 3. Tool Definition

#### Registration Patterns

**Decorator-based (recommended):**
```python
@agent.tool
async def search(ctx: RunContext[MyDeps], query: str, limit: int = 10) -> str:
    """Search the knowledge base.
    
    Args:
        query: The search terms
        limit: Maximum results to return
    """
    results = await ctx.deps.search_client.search(query, limit)
    return format_results(results)

@agent.tool_plain  # No context access
def calculate(expression: str) -> float:
    """Evaluate a mathematical expression."""
    return eval(expression)  # (use safe_eval in production)
```

**Constructor-based:**
```python
agent = Agent(
    'openai:gpt-4',
    tools=[search, calculate, Tool.from_schema(...)]
)
```

#### Tool Schema Generation

Parameters are extracted from function signatures. Docstrings (Google, NumPy, Sphinx formats) provide descriptions:

```python
@agent.tool
def get_weather(
    ctx: RunContext[Deps],
    city: str,           # Extracted to schema
    unit: str = "celsius"  # Optional with default
) -> str:
    """Get weather for a city.
    
    Args:
        city: City name to look up
        unit: Temperature unit (celsius or fahrenheit)
    """
```

Generates schema:
```json
{
  "name": "get_weather",
  "description": "Get weather for a city.",
  "parameters": {
    "type": "object",
    "properties": {
      "city": {"type": "string", "description": "City name to look up"},
      "unit": {"type": "string", "description": "Temperature unit", "default": "celsius"}
    },
    "required": ["city"]
  }
}
```

#### Tool Retries and ModelRetry

**Automatic validation retries:** When Pydantic validation fails on tool arguments, an error is sent back to the model.

**Explicit retry via ModelRetry:**
```python
from pydantic_ai import ModelRetry

@agent.tool(retries=3)
async def get_user(ctx: RunContext[Deps], username: str) -> dict:
    """Look up user by username."""
    user = await ctx.deps.db.find_user(username)
    if not user:
        raise ModelRetry(f"User '{username}' not found. Try the full name or email.")
    if user.is_deleted:
        raise ModelRetry("That user was deleted. Please use a different user.")
    return user.to_dict()
```

Key behaviors:
- `ModelRetry` message is sent back to the LLM as feedback
- Retry count tracked in `ctx.retry`
- Tool timeout triggers retry (configurable via `tool_timeout`)
- Parallel tool calls execute concurrently by default

#### Dynamic Tools (prepare)

Customize tool definitions per-step:
```python
from pydantic_ai import Tool, ToolDefinition

async def prepare_search(
    ctx: RunContext[Deps], 
    tool_def: ToolDefinition
) -> ToolDefinition | None:
    if not ctx.deps.has_search_access:
        return None  # Hide tool from this run
    tool_def.description += f" (Searching index: {ctx.deps.index_name})"
    return tool_def

agent = Agent(
    'openai:gpt-4',
    tools=[Tool(search, prepare=prepare_search)]
)
```

---

### 4. Result Validation

#### @agent.output_validator Pattern

```python
from pydantic_ai import Agent, ModelRetry, RunContext
from dataclasses import dataclass

@dataclass
class SQLQuery:
    query: str
    tables: list[str]

agent = Agent('openai:gpt-4', output_type=SQLQuery)

@agent.output_validator
async def validate_sql(ctx: RunContext[DatabaseConn], output: SQLQuery) -> SQLQuery:
    """Validate SQL is syntactically correct and authorized."""
    # Skip validation during streaming partial outputs
    if ctx.partial_output:
        return output
    
    try:
        await ctx.deps.execute(f"EXPLAIN {output.query}")
    except SyntaxError as e:
        raise ModelRetry(f"SQL syntax error: {e}. Please fix and try again.")
    
    # Check table authorization
    for table in output.tables:
        if table not in ctx.deps.allowed_tables:
            raise ModelRetry(f"Access denied to table '{table}'. Allowed: {ctx.deps.allowed_tables}")
    
    return output
```

Key behaviors:
- Multiple validators can be chained
- Check `ctx.partial_output` to avoid side effects during streaming
- `ModelRetry` sends feedback to model for correction
- Validation runs after Pydantic structural validation succeeds

---

### 5. System Prompts

#### Static vs Dynamic

```python
# Static - defined at creation
agent = Agent(
    'openai:gpt-4',
    system_prompt="You are a helpful assistant.",
    instructions="Always be concise."  # Preferred for agent-specific guidance
)

# Dynamic - computed at runtime
@agent.system_prompt
def add_user_context(ctx: RunContext[User]) -> str:
    return f"The current user is {ctx.deps.name} (role: {ctx.deps.role})."

@agent.system_prompt  # Can have multiple
async def add_time_context() -> str:  # Context parameter optional
    return f"Current time: {datetime.now().isoformat()}"
```

#### Instructions vs System Prompts

Critical distinction:
- **instructions**: Excluded when explicit `message_history` is provided (isolated per agent)
- **system_prompt**: Retained across message histories (persistent context)

```python
# Use instructions for agent-specific behavior
agent = Agent(
    'openai:gpt-4',
    instructions="You are a code reviewer. Focus on security issues."
)

# Use system_prompt for cross-agent continuity
agent = Agent(
    'openai:gpt-4',
    system_prompt="The user's name is Alice."  # Preserved if history passed to another agent
)
```

---

### 6. Streaming

#### Basic Text Streaming

```python
async with agent.run_stream('Write a story', deps=deps) as result:
    async for text in result.stream_text():
        print(text, end='', flush=True)
    
    print(f"\nUsage: {result.usage()}")
```

#### Streaming Structured Output

```python
from dataclasses import dataclass

@dataclass
class Profile:
    name: str
    bio: str
    skills: list[str]

agent = Agent('openai:gpt-4', output_type=Profile)

async with agent.run_stream('Generate a profile for a Python dev') as result:
    async for partial in result.stream_output(debounce_by=0.1):
        # partial is progressively built Profile
        # Early chunks may have empty/partial fields
        print(f"Name: {partial.name}, Skills so far: {partial.skills}")
```

#### Event Streaming

```python
async for event in agent.run_stream_events('Query', deps=deps):
    match event:
        case PartDeltaEvent(delta=delta):
            print(delta, end='')
        case FunctionToolCallEvent(name=name, args=args):
            print(f"\n[Tool: {name}({args})]")
        case AgentRunResultEvent(result=result):
            print(f"\nFinal: {result.output}")
```

#### Important Streaming Limitation

> "The first output that matches the output type is considered final output of the agent run, even when the model generates (additional) tool calls after this."

With default `end_strategy='early'`, if text appears before tool calls complete, those tools won't execute. Use `end_strategy='exhaustive'` or `iter()` for full control.

---

### 7. Usage Limits

#### Configuration

```python
from pydantic_ai import UsageLimits

limits = UsageLimits(
    request_limit=50,           # Max LLM API calls (default: 50)
    tool_calls_limit=100,       # Max tool executions
    input_tokens_limit=10000,   # Max input tokens
    output_tokens_limit=2000,   # Max output tokens
    total_tokens_limit=12000,   # Combined limit
)

result = await agent.run('Complex analysis', deps=deps, usage_limits=limits)
```

#### Behavior When Exceeded

```python
from pydantic_ai.exceptions import UsageLimitExceeded

try:
    result = await agent.run('Analyze everything', deps=deps, usage_limits=limits)
except UsageLimitExceeded as e:
    print(f"Limit exceeded: {e}")
    # e.g., "Exceeded the request_limit of 50 (requests=51)"
```

Key behaviors:
- `tool_calls_limit` checked **before** execution; parallel calls that would exceed limit are all blocked
- `request_limit` prevents infinite loops in agentic execution
- Raises `UsageLimitExceeded` when breached

#### Recovering Message History on Limit Exceeded

Use `capture_run_messages()` to access history even when limits are hit:

```python
from pydantic_ai import capture_run_messages

with capture_run_messages() as messages:
    try:
        result = await agent.run('prompt', deps=deps, usage_limits=limits)
    except UsageLimitExceeded:
        # messages contains full conversation up to the error
        print(f"Captured {len(messages)} messages before failure")
        for msg in messages:
            print(msg)
```

---

### 8. Context Engineering Capabilities

#### Message History Continuation

```python
# First run
result1 = await agent.run('What is Python?', deps=deps)

# Continue conversation
result2 = await agent.run(
    'Give me an example',
    deps=deps,
    message_history=result1.all_messages()
)
```

#### History Processors

Transform message history before each LLM call:

```python
def keep_recent_messages(messages: list[ModelMessage]) -> list[ModelMessage]:
    """Keep only last 10 messages to manage context window."""
    return messages[-10:]

async def summarize_old_messages(
    ctx: RunContext[Deps], 
    messages: list[ModelMessage]
) -> list[ModelMessage]:
    """Summarize old messages using a separate agent."""
    if len(messages) > 20:
        old = messages[:-10]
        summary = await summarizer_agent.run(format_for_summary(old))
        return [create_summary_message(summary)] + messages[-10:]
    return messages

agent = Agent(
    'openai:gpt-4',
    history_processors=[keep_recent_messages, summarize_old_messages]
)
```

#### Modification During iter()

The `iter()` API allows inspection and modification between steps but **does not allow direct message modification**. You can:
- Skip nodes (continue iteration)
- Inject approval logic before `CallToolsNode`
- Access usage data via `agent_run.usage()`
- Stream from individual nodes

You **cannot**:
- Directly modify the message list mid-iteration
- Inject new messages between steps
- Change tool arguments after they're determined

For message modification, use `history_processors` which run before each LLM request.

---

### 9. Dependency Injection

#### Pattern

```python
from dataclasses import dataclass
from pydantic_ai import Agent, RunContext

@dataclass
class MyDeps:
    db: DatabaseConnection
    api_client: APIClient
    user_id: str

agent: Agent[MyDeps, str] = Agent('openai:gpt-4', deps_type=MyDeps)

@agent.tool
async def get_user_data(ctx: RunContext[MyDeps]) -> dict:
    return await ctx.deps.db.fetch_user(ctx.deps.user_id)

@agent.system_prompt
def personalize(ctx: RunContext[MyDeps]) -> str:
    return f"You are assisting user {ctx.deps.user_id}"

# Runtime injection
deps = MyDeps(db=db_conn, api_client=client, user_id="user123")
result = await agent.run('Get my profile', deps=deps)
```

#### Type Safety

Mismatched types caught at development time:
```python
@agent.tool
async def bad_tool(ctx: RunContext[str]) -> str:  # Wrong type!
    return ctx.deps.upper()

# Type checker error: Expected RunContext[MyDeps], got RunContext[str]
```

#### Override Context Manager

Temporarily override agent configuration:
```python
with agent.override(deps=different_deps, model='openai:gpt-3.5-turbo'):
    result = await agent.run('Quick query')
# Original configuration restored
```

---

### 10. Limitations & Design Constraints

#### What You CANNOT Do

1. **Modify messages during iteration**: `iter()` allows inspection but not mutation of the message stream
2. **Access partial history after UsageLimitExceeded without capture**: Must use `capture_run_messages()` context manager
3. **Multiple outputs per run**: First matching output terminates (use `end_strategy='exhaustive'` for tool completion)
4. **Non-JSON tool returns**: Tools must return JSON-serializable values
5. **Synchronous tools in async agents**: Tools should match agent's async model
6. **Recursive type schemas**: Not supported for structured output

#### Known Issues

1. **Issue #1083**: UsageLimitExceeded loses message history - solved via `capture_run_messages()`
2. **Streaming + early termination**: Default `end_strategy='early'` may skip pending tool calls
3. **Multiple calls in capture_run_messages**: Only first run's messages captured

#### Design Tradeoffs

| Choice | Benefit | Tradeoff |
|--------|---------|----------|
| Generic `Agent[Deps, Output]` | Full type safety | More verbose declarations |
| `ModelRetry` exception | Clean feedback to LLM | Control flow via exceptions |
| Decorator-based tools | Ergonomic registration | Less portable than standalone functions |
| `history_processors` | Flexible context engineering | Runs on every request (performance) |
| `iter()` graph model | Fine-grained control | More complex than simple `run()` |

#### Provider-Specific Limitations

- Not all providers support all features (e.g., structured output modes vary)
- Token counting accuracy depends on provider
- Some providers don't support `count_tokens_before_request`

---

### Summary: Key Patterns for Yrden Implementation

Based on this research, these PydanticAI patterns should be prioritized for Yrden:

1. **`Agent[Deps, Output]` generics** - Type-safe dependency injection and output
2. **`RunContext`** - Unified context access for tools and prompts  
3. **`iter()` with node types** - Step-by-step control for human-in-the-loop
4. **`ModelRetry`** - Typed error for LLM retry feedback
5. **`@agent.tool` with retries** - Declarative tool configuration
6. **`@agent.output_validator`** - Post-generation validation with retry
7. **`history_processors`** - Context window management hooks
8. **`UsageLimits`** - Resource consumption guardrails
9. **`capture_run_messages`** - Error recovery and debugging
10. **Dynamic vs static prompts** - Runtime context injection
Now let me compile all this additional research into a continuation of the document.

## PydanticAI API Surface Research (Continued)

### 11. Model Configuration & Providers

#### Model Specification Format

Models use a simple naming convention:
```python
# provider:model-name
agent = Agent('openai:gpt-4')
agent = Agent('anthropic:claude-3-5-sonnet-20241022')
agent = Agent('openrouter:google/gemini-2.5-pro-preview')
```

PydanticAI automatically selects the appropriate model class and provider based on the prefix.

#### Supported Providers

**Built-in providers (11 total):**
- OpenAI
- Anthropic
- Google Gemini
- xAI (Grok)
- AWS Bedrock
- Cerebras
- Cohere
- Groq
- Hugging Face
- Mistral
- OpenRouter
- Outlines

**OpenAI-compatible providers** (via `OpenAIChatModel`):
- Azure AI Foundry
- DeepSeek
- Fireworks AI
- GitHub Models
- DashScope
- Ollama (local)
- vLLM (local)
- LM Studio (local)

#### ModelSettings Configuration

```python
from pydantic_ai import ModelSettings

settings = ModelSettings(
    # Core parameters
    temperature=0.7,           # Randomness (0.0 = deterministic, 2.0 = creative)
    max_tokens=1000,           # Maximum response length
    top_p=0.9,                 # Nucleus sampling (alternative to temperature)
    timeout=30.0,              # Request timeout in seconds
    parallel_tool_calls=True,  # Enable concurrent tool execution
    seed=42,                   # For deterministic outputs (best-effort)
    
    # Penalty parameters
    presence_penalty=0.0,      # Penalize tokens that appeared (-2.0 to 2.0)
    frequency_penalty=0.0,     # Penalize by frequency (-2.0 to 2.0)
    
    # Advanced
    logit_bias={'1234': 10},   # Boost/reduce specific token probabilities
    stop_sequences=['END'],    # Stop generation at these sequences
    extra_headers={},          # Custom HTTP headers
    extra_body={},             # Provider-specific parameters
)

agent = Agent('openai:gpt-4', model_settings=settings)

# Per-run override
result = await agent.run(
    'prompt',
    model_settings=ModelSettings(temperature=0.0)
)
```

**Provider support varies** - not all parameters work with all providers. Check provider documentation.

#### FallbackModel Configuration

```python
from pydantic_ai import FallbackModel

# Basic fallback chain
fallback_model = FallbackModel(
    default_model='openai:gpt-4',
    'anthropic:claude-3-5-sonnet-20241022',  # Try if GPT-4 fails
    'openai:gpt-3.5-turbo',                   # Last resort
)

agent = Agent(fallback_model)

# Custom fallback condition
from pydantic_ai.exceptions import ModelAPIError, UsageLimitExceeded

def should_fallback(exc: Exception) -> bool:
    """Fallback on API errors but not on usage limits."""
    return isinstance(exc, ModelAPIError) and not isinstance(exc, UsageLimitExceeded)

fallback_model = FallbackModel(
    'openai:gpt-4',
    'anthropic:claude-3-5-sonnet-20241022',
    fallback_on=should_fallback
)
```

**Fallback behavior:**
- Tries models sequentially until one succeeds
- Default: fallback on `ModelAPIError` (network errors, 5xx, auth failures)
- If all fail: raises `FallbackExceptionGroup` with all errors
- Model name: `fallback:gpt-4,claude-3-5-sonnet,gpt-3.5-turbo`

**Per-model settings:**
```python
fallback_model = FallbackModel(
    OpenAIModel('gpt-4', settings=ModelSettings(temperature=0.2)),
    AnthropicModel('claude-3-5-sonnet-20241022', settings=ModelSettings(temperature=0.7))
)
```

---

### 12. Message Types & Multimodal Content

#### Message Structure

```python
from pydantic_ai.messages import (
    ModelMessage,      # Union[ModelRequest, ModelResponse]
    ModelRequest,      # Messages sent to LLM
    ModelResponse,     # Messages received from LLM
)

# Request parts
from pydantic_ai.messages import (
    SystemPromptPart,
    UserPromptPart,
    ToolReturnPart,
    RetryPromptPart,
)

# Response parts
from pydantic_ai.messages import (
    TextPart,
    ToolCallPart,
    ThinkingPart,      # For models that support "thinking" (o1, etc.)
)
```

#### Multimodal Content Types

**Images:**
```python
from pydantic_ai.messages import ImageUrl, BinaryImage

# URL-based
UserPromptPart(content=[
    "What's in this image?",
    ImageUrl(url="https://example.com/image.jpg")
])

# Binary data
with open('image.jpg', 'rb') as f:
    UserPromptPart(content=[
        "Describe this",
        BinaryImage(data=f.read(), media_type="image/jpeg")
    ])
```

**Audio, Video, Documents:**
```python
from pydantic_ai.messages import AudioUrl, VideoUrl, DocumentUrl

UserPromptPart(content=[
    "Transcribe this audio",
    AudioUrl(url="https://example.com/audio.mp3")
])

UserPromptPart(content=[
    "Summarize this video",
    VideoUrl(url="https://example.com/video.mp4")
])

UserPromptPart(content=[
    "Extract data from this PDF",
    DocumentUrl(url="https://example.com/doc.pdf")
])
```

**Provider-specific metadata:**
```python
ImageUrl(
    url="https://example.com/image.jpg",
    vendor_metadata={'detail': 'high'}  # OpenAI image detail level
)
```

#### ToolReturn for Rich Tool Output

Separate programmatic return value from model-facing context:

```python
from pydantic_ai.messages import ToolReturn

@agent.tool
async def analyze_chart(ctx: RunContext[Deps], chart_id: str) -> ToolReturn[dict]:
    """Analyze a chart and return data with visual context."""
    chart_data = await ctx.deps.db.get_chart(chart_id)
    chart_image = await ctx.deps.render_chart(chart_data)
    
    return ToolReturn(
        output=chart_data,  # Typed return value (dict)
        model_content=[      # What the model sees
            f"Chart analysis: {chart_data['summary']}",
            BinaryImage(data=chart_image, media_type="image/png")
        ]
    )
```

**Use cases:**
- Return structured data to application, send images to model
- Provide detailed context to model while keeping clean return types
- Attach documents, audio, or video as additional context

#### Prompt Caching

For supported providers (Anthropic, Bedrock):
```python
from pydantic_ai.messages import CachePoint

UserPromptPart(content=[
    "Here's a large document to analyze:\n\n",
    long_document_text,
    CachePoint(),  # Cache up to this point
    "\n\nQuestion: What is the main theme?"
])
```

---

### 13. Toolsets - Reusable Tool Collections

#### Basic FunctionToolset

```python
from pydantic_ai.toolset import FunctionToolset

# Create toolset
math_toolset = FunctionToolset()

@math_toolset.tool
def add(a: float, b: float) -> float:
    """Add two numbers."""
    return a + b

@math_toolset.tool
def multiply(a: float, b: float) -> float:
    """Multiply two numbers."""
    return a * b

# Use in agent
agent = Agent('openai:gpt-4', toolsets=[math_toolset])
```

#### Dynamic Toolsets

```python
from pydantic_ai import Agent, RunContext
from pydantic_ai.toolset import FunctionToolset

@agent.toolset
def get_customer_toolset(ctx: RunContext[Deps]) -> FunctionToolset:
    """Build toolset based on customer permissions."""
    toolset = FunctionToolset()
    
    @toolset.tool
    def get_balance() -> float:
        return ctx.deps.db.get_balance(ctx.deps.customer_id)
    
    # Only add refund tool for premium customers
    if ctx.deps.customer_tier == 'premium':
        @toolset.tool
        def request_refund(amount: float) -> str:
            return f"Refund requested: ${amount}"
    
    return toolset
```

#### Toolset Composition

```python
from pydantic_ai.toolset import (
    CombinedToolset,
    FilteredToolset,
    PrefixedToolset,
    ApprovalRequiredToolset,
)

# Combine multiple toolsets
all_tools = CombinedToolset(math_toolset, string_toolset, date_toolset)

# Filter tools dynamically
def should_include(tool_name: str, ctx: RunContext[Deps]) -> bool:
    return ctx.deps.has_permission(tool_name)

filtered = FilteredToolset(all_tools, filter_func=should_include)

# Prevent name conflicts
prefixed = PrefixedToolset(math_toolset, prefix="math_")
# Tools become: math_add, math_multiply

# Require approval for sensitive tools
approved = ApprovalRequiredToolset(
    admin_toolset,
    requires_approval=['delete_user', 'change_permissions']
)
```

#### External Toolsets (MCP, LangChain)

```python
from pydantic_ai.toolset import ExternalToolset

# MCP server
mcp_toolset = ExternalToolset.from_mcp_server(
    "filesystem",  # Server name
    command="uvx",
    args=["mcp-server-filesystem", "/path/to/root"]
)

# LangChain tools
from langchain.tools import WikipediaQueryRun

langchain_toolset = ExternalToolset.from_langchain(
    WikipediaQueryRun(api_wrapper=wrapper)
)

agent = Agent('openai:gpt-4', toolsets=[mcp_toolset, langchain_toolset])
```

---

### 14. Output Modes & Structured Output

#### Three Output Approaches

**1. ToolOutput (Default) - Universal compatibility:**
```python
from pydantic_ai import Agent
from pydantic import BaseModel

class UserProfile(BaseModel):
    name: str
    age: int

# Default: uses tool calling
agent = Agent('openai:gpt-4', output_type=UserProfile)
```

**2. NativeOutput - Provider structured output:**
```python
from pydantic_ai.output import NativeOutput

# Use OpenAI's native structured output mode
agent = Agent(
    'openai:gpt-4',
    output_type=NativeOutput(UserProfile, name="user_profile")
)
```

**3. PromptedOutput - Text instructions:**
```python
from pydantic_ai.output import PromptedOutput

# Inject schema into prompt (least reliable)
agent = Agent(
    'openai:gpt-4',
    output_type=PromptedOutput(UserProfile)
)
```

#### Output Functions

Alternative to validators - model calls function to produce final output:

```python
from pydantic_ai import Agent, RunContext, ModelRetry
from dataclasses import dataclass

@dataclass
class QueryResult:
    rows: list[dict]
    
@dataclass  
class InvalidQuery:
    error: str

def execute_query(ctx: RunContext[Deps], sql: str) -> QueryResult:
    """Execute a SQL query on the database."""
    if not sql.upper().startswith('SELECT'):
        raise ModelRetry('Only SELECT queries allowed')
    
    try:
        rows = ctx.deps.db.execute(sql)
        return QueryResult(rows=rows)
    except Exception as e:
        # Don't retry - return error output
        return InvalidQuery(error=str(e))

agent = Agent(
    'openai:gpt-4',
    output_type=[execute_query, InvalidQuery]  # Union of output functions
)
```

**Key differences from validators:**
- Model explicitly calls the function (like a tool)
- Ends the agent run immediately
- Result is not passed back to model
- Can raise `ModelRetry` to ask for different arguments
- Better for branching output types (avoids `isinstance` checks)

---

### 15. Testing & Evaluation

#### TestModel for Unit Tests

```python
from pydantic_ai.models.test import TestModel

# Basic usage - generates valid data automatically
test_model = TestModel()

with agent.override(model=test_model):
    result = await agent.run('Test prompt', deps=test_deps)
    # TestModel calls all tools, returns valid structured output

# Custom output text
test_model = TestModel(custom_output_text="Mocked response text")

# Custom output for structured types
from pydantic import BaseModel

class Report(BaseModel):
    summary: str
    score: int

test_model = TestModel(
    custom_output=Report(summary="Test summary", score=95)
)
```

#### FunctionModel for Custom Logic

```python
from pydantic_ai.models.function import FunctionModel, AgentInfo

async def custom_model_logic(messages, info: AgentInfo):
    """Custom model behavior for testing."""
    # Extract last user message
    user_msg = messages[-1].parts[-1].content
    
    # Simulate specific tool call
    if 'weather' in user_msg.lower():
        return ToolCallPart(
            name='get_weather',
            arguments={'city': 'San Francisco'}
        )
    
    return TextPart(content="Default response")

function_model = FunctionModel(custom_model_logic)

with agent.override(model=function_model):
    result = await agent.run('What is the weather?', deps=deps)
```

#### Message Capture for Assertions

```python
from pydantic_ai import capture_run_messages

with capture_run_messages() as messages:
    result = await agent.run('Test prompt', deps=deps)

# Assert on message exchange
assert len(messages) == 3
assert isinstance(messages[0], ModelRequest)
assert isinstance(messages[1], ModelResponse)

# Check tool calls
tool_call = messages[1].parts[0]
assert tool_call.name == 'search'
assert tool_call.arguments == {'query': 'test'}
```

#### Prevent Accidental LLM Calls

```python
# In conftest.py
import os
os.environ['ALLOW_MODEL_REQUESTS'] = 'False'

# Tests will fail if real LLM calls attempted
```

---

### 16. Observability & Debugging

#### Logfire Integration

```python
import logfire
from pydantic_ai import Agent

# Setup
logfire.configure()
logfire.instrument_pydantic_ai()

# Optionally instrument HTTPX for full request tracing
logfire.instrument_httpx()

agent = Agent('openai:gpt-4', tools=[...])

# All runs automatically traced
result = await agent.run('prompt', deps=deps)
```

**What gets traced:**
- Agent run spans (duration, success/failure)
- Individual model requests (prompts, responses, tokens)
- Tool calls (arguments, return values, errors)
- HTTP requests to providers (full request/response)
- Nested agent calls (delegation chains)

**Querying with SQL:**
```sql
SELECT 
    span_name,
    duration_ms,
    attributes['gen_ai.response.model'] as model,
    attributes['gen_ai.usage.input_tokens'] as input_tokens
FROM traces
WHERE service_name = 'my-agent'
ORDER BY start_time DESC;
```

#### Alternative Observability (OpenTelemetry)

```bash
# Route to Langfuse
export OTEL_EXPORTER_OTLP_ENDPOINT=https://cloud.langfuse.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer sk-..."

# Route to Weights & Biases Weave
export OTEL_EXPORTER_OTLP_ENDPOINT=https://api.wandb.ai/v1/otel
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer ..."
```

---

### 17. Multi-Agent Coordination

#### Agent Delegation Pattern

```python
from pydantic_ai import Agent, RunContext

# Delegate agent (generates content)
content_agent = Agent('openai:gpt-4', output_type=str)

# Parent agent (selects and coordinates)
coordinator_agent = Agent('openai:gpt-4', output_type=str)

@coordinator_agent.tool
async def generate_content(
    ctx: RunContext[Deps],
    topic: str,
    style: str
) -> str:
    """Generate content using specialized agent."""
    result = await content_agent.run(
        f"Write about {topic} in {style} style",
        deps=ctx.deps,        # Share dependencies
        usage=ctx.usage,      # Accumulate token usage
    )
    return result.output

# Usage tracks both agents
result = await coordinator_agent.run(
    "Create a technical blog post about AI",
    deps=deps
)
print(result.usage())  # Includes tokens from both agents
```

#### Programmatic Handoffs

```python
# Sequential agent calls with control flow
initial_result = await research_agent.run(
    "Research topic",
    deps=deps
)

# Application logic decides next step
if initial_result.output.needs_analysis:
    analysis = await analysis_agent.run(
        f"Analyze: {initial_result.output.data}",
        message_history=initial_result.all_messages(),  # Preserve context
        deps=deps
    )
    
    final_result = await summary_agent.run(
        "Summarize findings",
        message_history=analysis.all_messages(),
        deps=deps
    )
```

---

### 18. Advanced Patterns

#### Context Window Management

```python
def keep_recent_messages(messages: list[ModelMessage]) -> list[ModelMessage]:
    """Keep only last 10 messages."""
    return messages[-10:]

async def summarize_old_context(
    ctx: RunContext[Deps],
    messages: list[ModelMessage]
) -> list[ModelMessage]:
    """Summarize messages older than 20 turns."""
    if len(messages) > 20:
        old_messages = messages[:-10]
        summary_text = await summarize_agent.run(
            format_for_summary(old_messages)
        )
        summary_msg = create_system_message(summary_text.output)
        return [summary_msg] + messages[-10:]
    return messages

agent = Agent(
    'openai:gpt-4',
    history_processors=[keep_recent_messages, summarize_old_context]
)
```

#### Human-in-the-Loop with iter()

```python
async with agent.iter('Risky operation', deps=deps) as run:
    async for node in run:
        if isinstance(node, CallToolsNode):
            for tool_call in node.tool_calls:
                if tool_call.name in ['delete_data', 'send_email']:
                    approved = await request_approval(tool_call)
                    if not approved:
                        # Skip this iteration - don't execute tools
                        continue
        
        # Execute approved node
        node = await run.next(node)
```

#### Dynamic Model Selection

```python
@agent.system_prompt
async def select_model(ctx: RunContext[Deps]) -> str:
    # Change model based on query complexity
    if ctx.retry > 0:
        # Use better model on retry
        with agent.override(model='openai:gpt-4'):
            pass
    return "Context for this request..."
```

---

### Summary: Additional Key Patterns for Yrden

Based on this continued research, these additional patterns should be considered:

1. **Toolsets** - Reusable, composable tool collections with filtering and prefixing
2. **Multimodal content** - Images, audio, video, documents in messages
3. **ToolReturn** - Separate programmatic returns from model context
4. **Output functions** - Model-called functions as alternative to validators
5. **TestModel/FunctionModel** - Deterministic testing without LLM calls
6. **FallbackModel** - Sequential model fallback with custom conditions
7. **ModelSettings** - Comprehensive per-request configuration
8. **History processors** - Message transformation pipeline
9. **Agent delegation** - Tools that call other agents
10. **Prompt caching** - Optimize costs for repeated context
