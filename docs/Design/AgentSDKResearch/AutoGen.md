## Appendix: Microsoft AutoGen API Research

### Overview

Microsoft AutoGen is an open-source framework for building multi-agent AI applications. Originally released as a research project, it has evolved significantly through several major versions. As of 2026, AutoGen v0.4 represents a complete architectural rewrite, while v0.2 remains available for legacy support. Microsoft has also announced the Microsoft Agent Framework (combining AutoGen and Semantic Kernel), with GA planned for Q1 2026.

**Key Documentation Sources:**
- [AutoGen Documentation](https://microsoft.github.io/autogen/stable/)
- [GitHub Repository](https://github.com/microsoft/autogen)

---

### 1. Core Concepts and Types

#### Package Architecture (v0.4)

AutoGen v0.4 is structured into three main packages:

| Package | Purpose |
|---------|---------|
| **autogen-core** | Event-driven foundation for scalable multi-agent systems |
| **autogen-agentchat** | High-level API for conversational agents (recommended starting point) |
| **autogen-ext** | Extensions for LLM clients, code execution, MCP integration |

```bash
pip install -U "autogen-agentchat" "autogen-ext[openai]"
```

#### AssistantAgent

The primary agent implementation for task execution. Described as a "kitchen sink" agent for prototyping:

```python
from autogen_agentchat.agents import AssistantAgent
from autogen_ext.models.openai import OpenAIChatCompletionClient

model_client = OpenAIChatCompletionClient(model="gpt-4.1-nano")
agent = AssistantAgent(
    name="assistant",
    model_client=model_client,
    tools=[web_search],  # Optional list of callable functions
    system_message="Use tools to solve tasks.",
    handoffs=["user"],   # Optional: agents to hand off to
)
```

**Key characteristics:**
- Uses language models for reasoning
- Supports tool integration via the `tools` parameter
- Executes tools directly within the same `run()` call
- Can reflect on tool outputs with `reflect_on_tool_use=True`
- Stateful: calling `run()` with new messages adds to internal history

#### UserProxyAgent

Acts as a human representative within agent teams:

```python
from autogen_agentchat.agents import UserProxyAgent

user_proxy = UserProxyAgent(
    "user_proxy",
    input_func=input  # Custom input handler
)
```

When the team calls this agent, execution pauses and transfers control to the application/user.

#### Common Agent Interface

All agents implement shared attributes and methods:
- `name` and `description` properties
- `run()` - Synchronous task execution
- `run_stream()` - Streaming message iterations
- Both return `TaskResult` objects containing execution history

---

### 2. Execution Model

#### The `run()` Pattern

```python
# Simple execution
result = await agent.run(task="Analyze Q4 sales data")

# Streaming execution
async for message in agent.run_stream(task="Analyze Q4 sales"):
    print(message)

# Access conversation history
for msg in result.messages:
    print(f"{msg.source}: {msg.content}")
```

#### Team Execution

Teams coordinate multiple agents toward shared goals:

```python
from autogen_agentchat.teams import RoundRobinGroupChat
from autogen_agentchat.conditions import TextMentionTermination

team = RoundRobinGroupChat(
    [assistant, critic],
    termination_condition=TextMentionTermination("APPROVE")
)

result = await team.run(task="Write a poem about AI")
```

#### Termination Conditions

Termination conditions determine when conversations stop. They are stateful callables that evaluate messages:

| Condition | Description |
|-----------|-------------|
| `MaxMessageTermination` | Stops after N messages |
| `TextMentionTermination` | Halts when specific text appears |
| `TokenUsageTermination` | Based on token consumption |
| `TimeoutTermination` | Duration limit in seconds |
| `HandoffTermination` | Responds to explicit handoffs |
| `SourceMatchTermination` | After specific agent responds |
| `ExternalTermination` | Programmatic control from outside |
| `FunctionCallTermination` | When specific functions execute |

**Composable conditions:**

```python
# Combine with OR logic
max_msg = MaxMessageTermination(max_messages=10)
text_stop = TextMentionTermination("APPROVE")
combined = max_msg | text_stop  # Stop on either condition

# Combine with AND logic
combined = max_msg & text_stop  # Both must be satisfied
```

---

### 3. Tool/Function Execution

#### Defining Tools

Tools are Python functions or `BaseTool` subclasses. `FunctionTool` wraps functions automatically:

```python
from autogen_core.tools import FunctionTool

async def web_search(query: str) -> str:
    """Search the web for information.
    
    Args:
        query: The search query string
    """
    return f"Results for: {query}"

# Tool is automatically converted to JSON schema for LLM
agent = AssistantAgent(
    name="assistant",
    model_client=model_client,
    tools=[web_search],
)
```

**Key points:**
- Descriptions and type annotations inform the LLM about proper usage
- Tools generate JSON schemas automatically via `BaseTool`
- Results are converted to strings for model consumption

#### Code Execution

AutoGen provides two command-line code executors:

**DockerCommandLineCodeExecutor** (recommended for security):

```python
from autogen_ext.code_executors.docker import DockerCommandLineCodeExecutor
from autogen_ext.tools.code_execution import PythonCodeExecutionTool

code_executor = DockerCommandLineCodeExecutor(
    image="python:3-slim",  # Customizable
    auto_remove=True,       # Clean up containers
)
await code_executor.start()
code_tool = PythonCodeExecutionTool(code_executor)
```

**LocalCommandLineCodeExecutor** (use with caution):

```python
from autogen_ext.code_executors.local import LocalCommandLineCodeExecutor

executor = LocalCommandLineCodeExecutor(
    virtual_env_context=venv_context,  # Optional: isolate dependencies
    work_dir="./workspace",
)
```

**Security considerations:**
- Local execution has a sanitization list against dangerous commands
- Docker provides robust isolation but requires Docker installation
- Virtual environments help isolate dependencies without full containerization

---

### 4. State Management

#### Saving and Loading State

AutoGen provides `save_state()` and `load_state()` methods for persistence:

```python
# Save agent state
agent_state = await agent.save_state()

# State is a JSON-serializable dictionary
import json
with open("agent_state.json", "w") as f:
    json.dump(agent_state, f)

# Load state later
with open("agent_state.json", "r") as f:
    agent_state = json.load(f)
await agent.load_state(agent_state)
```

#### Team State

When saving team state, all constituent agents' states are captured:

```python
team_state = await team.save_state()
# Contains nested agent states, message threads, turn info
```

#### State Contents

For `AssistantAgent`, state includes:
- Message history (user and assistant messages)
- Model context information
- Metadata (type and version)

**Custom agents** should override `save_state()` and `load_state()` methods to customize persistence behavior.

#### Resume Capabilities

```python
# Run team, save state, resume later
result = await team.run(task="Start analysis")
state = await team.save_state()

# Later...
await team.load_state(state)
result = await team.run()  # Continues with context
```

**Known limitations:**
- GroupChat resumption has historical issues with message injection
- Some internal state may not fully persist across sessions
- Custom error handling needed for complex recovery scenarios

---

### 5. Multi-Agent Patterns

#### Team Types

| Team Type | Description | Speaker Selection |
|-----------|-------------|-------------------|
| `RoundRobinGroupChat` | Sequential turns | Fixed order |
| `SelectorGroupChat` | Model-based selection | LLM chooses next speaker |
| `Swarm` | Handoff-based coordination | Agent-initiated transfers |
| `MagenticOneGroupChat` | Specialized for web/file tasks | Domain-specific |

#### RoundRobinGroupChat

```python
from autogen_agentchat.teams import RoundRobinGroupChat

# Agents take turns in order
team = RoundRobinGroupChat(
    [writer, critic, editor],
    termination_condition=TextMentionTermination("FINAL"),
    max_turns=10,
)
```

#### SelectorGroupChat

Uses an LLM to dynamically select the next speaker:

```python
from autogen_agentchat.teams import SelectorGroupChat

team = SelectorGroupChat(
    [researcher, analyst, writer],
    model_client=model_client,
    termination_condition=termination,
    allow_repeated_speaker=False,  # Prevent consecutive turns
)
```

**Configuration options:**
- `selector_prompt`: Customize selection guidance
- `selector_func`: Override with custom logic
- `candidate_func`: Filter available agents per turn

#### Swarm (Handoff Pattern)

Agents delegate tasks through explicit handoffs:

```python
travel_agent = AssistantAgent(
    "travel_agent",
    model_client=model_client,
    handoffs=["flights_refunder", "user"],
    system_message="Route refund requests to flights_refunder."
)

flights_refunder = AssistantAgent(
    "flights_refunder",
    model_client=model_client,
    handoffs=["user"],
    system_message="Process refund requests."
)

team = Swarm(
    [travel_agent, flights_refunder],
    termination_condition=HandoffTermination(target="user"),
)
```

**Key characteristics:**
- Speaker selection based on most recent `HandoffMessage`
- All agents share the same message context
- Localized decision-making vs. central orchestration
- Requires models that support tool calling
- Recommend `parallel_tool_calls=False` for OpenAI

---

### 6. Human-in-the-Loop

#### Two Primary Mechanisms

1. **During execution** via `UserProxyAgent`
2. **Between runs** using termination conditions and `max_turns`

#### UserProxyAgent Pattern

```python
from autogen_agentchat.agents import UserProxyAgent
from autogen_agentchat.teams import RoundRobinGroupChat

user_proxy = UserProxyAgent("user_proxy", input_func=input)
team = RoundRobinGroupChat([assistant, user_proxy])

stream = team.run_stream(task="Write a poem")
await Console(stream)  # Pauses for input when user_proxy speaks
```

**For web services:**

```python
async def _user_input(prompt: str, cancellation_token) -> str:
    data = await websocket.receive_json()
    message = TextMessage.model_validate(data)
    return message.content

user_proxy = UserProxyAgent("user_proxy", input_func=_user_input)
```

#### Max Turns Pattern

Pause after each agent responds:

```python
team = RoundRobinGroupChat([assistant], max_turns=1)

while True:
    stream = team.run_stream(task=task)
    await Console(stream)
    task = input("Enter feedback: ")  # Turn counter resets
```

#### HandoffTermination Pattern

Agents explicitly hand off to users:

```python
lazy_agent = AssistantAgent(
    "lazy_assistant",
    model_client=model_client,
    handoffs=[Handoff(target="user", message="Transfer to user.")],
    system_message="If unable to complete, transfer to user."
)

termination = HandoffTermination(target="user")
team = RoundRobinGroupChat([lazy_agent], termination_condition=termination)

# Team stops when agent hands off to "user"
result = await team.run(task="Complex task")
# Application receives control, can provide feedback and restart
```

**Important caveat:** `UserProxyAgent` blocks execution and can leave teams "in an unstable state that cannot be saved or resumed." Best for brief approvals, not long async interactions.

---

### 7. Context Engineering

#### Memory Management

AutoGen provides a `Memory` protocol with key methods:

```python
from autogen_agentchat.memory import ListMemory

memory = ListMemory()
await memory.add("User prefers metric units", source="preferences")

agent = AssistantAgent(
    name="assistant",
    model_client=model_client,
    memory=[memory],  # Memory is queried before each response
)
```

**Memory implementations:**

| Implementation | Description |
|----------------|-------------|
| `ListMemory` | Chronological list, appends to context |
| `ChromaDBVectorMemory` | Semantic search via embeddings |
| `RedisMemory` | Persistent vector storage |
| `Mem0Memory` | Cloud-based with metadata filtering |

#### Message Transforms (v0.2 pattern, still relevant)

Handle context window limits with transforms:

```python
from autogen.agentchat.contrib.text_message_compressor import TextMessageCompressor
from autogen.agentchat.contrib.transform_messages import TransformMessages

# Compress messages over 1000 tokens
compress = TextMessageCompressor(
    min_tokens=1000,
    filter_dict={"role": ["system"]}  # Don't compress system prompts
)

# Inject agent names into content for non-OpenAI models
name_transform = TextMessageContentName(
    position="start",
    format_string="'{name}' said:\n"
)

transforms = TransformMessages(transforms=[compress, name_transform])
transforms.add_to_agent(agent)
```

#### Context Window Strategies

- **Compression**: LLMLingua integration for intelligent summarization
- **Truncation**: Keep recent K messages, drop older ones
- **Retrieval**: Fetch related history based on latest message
- **Hierarchical memory**: Short-term (verbatim) + medium-term (summaries) + long-term (integrated)

---

### 8. AutoGen 0.4 vs 0.2 Differences

#### Architectural Changes

| Aspect | v0.2 | v0.4 |
|--------|------|------|
| Architecture | Synchronous, conversation-first | Asynchronous, event-driven |
| Agent communication | `send()` method | `on_messages()`, `on_messages_stream()` |
| Tool registration | Register on proxy agents | Pass directly to agent via `tools` parameter |
| Group chat | `GroupChat` + `GroupChatManager` | Specialized team classes |
| State persistence | Manual message export/import | Built-in `save_state()`/`load_state()` |
| Caching | Automatic | Optional `ChatCompletionCache` wrapper |

#### Model Client Configuration

**v0.2:**
```python
config_list = [{"model": "gpt-4", "api_key": "..."}]
llm_config = {"config_list": config_list}
```

**v0.4:**
```python
from autogen_ext.models.openai import OpenAIChatCompletionClient
model_client = OpenAIChatCompletionClient(model="gpt-4o")
```

#### Tool Usage

**v0.2:**
```python
@user_proxy.register_for_execution()
@assistant.register_for_llm(description="Search the web")
def web_search(query: str) -> str:
    return f"Results for {query}"
```

**v0.4:**
```python
def web_search(query: str) -> str:
    """Search the web."""
    return f"Results for {query}"

agent = AssistantAgent(tools=[web_search])  # Direct passing
```

#### Migration Notes

- v0.4 is a "from-the-ground-up rewrite" with breaking changes
- AgentChat API is most similar to v0.2 for easier migration
- Some features still pending: Model Client cost tracking, Teachable Agent, full RAG integration
- The `pyautogen` PyPI package is no longer maintained by Microsoft since v0.2.34

---

### 9. Limitations and Tradeoffs

#### Current Status (2026)

Microsoft consolidated AutoGen into **maintenance mode** in October 2025:
- Bug fixes and security updates continue
- No new features planned
- Microsoft Agent Framework (AutoGen + Semantic Kernel) planned for GA Q1 2026

#### Technical Limitations

| Limitation | Description |
|------------|-------------|
| **Steep learning curve** | Multi-agent intricacies can be complex for newcomers |
| **Unpredictability** | Conversation-first model can lead to loops or off-topic spiraling |
| **Debugging challenges** | Non-deterministic behavior difficult to trace |
| **High token consumption** | Multi-agent conversations generate substantial API costs |
| **Production maturity** | Often requires custom observability and scaling solutions |
| **Failure recovery** | Developer responsibility; no built-in retry/recovery |

#### What AutoGen Cannot Do Easily

1. **Simple single-agent tasks**: Overhead of multi-agent architecture is unnecessary
2. **Deterministic workflows**: The conversational approach prioritizes flexibility over predictability
3. **Fine-grained token control**: Session-level cost accounting requires custom implementation
4. **Complex state recovery**: GroupChat resumption has known edge cases
5. **Cross-cloud portability**: Deep Azure integration can limit flexibility

#### Inherited LLM Limitations

- Data biases in model outputs
- Limited real-world understanding
- "Black box" transparency issues
- Security risks from LLM-generated code execution

#### Security Considerations

> "Allowing LLM agents to make changes in external environments through code execution or function calls, such as install packages, could pose significant risks."

Developers must implement appropriate safeguards for:
- Code execution sandboxing
- Tool call validation
- Human approval for sensitive operations

#### When NOT to Use AutoGen

- Simple, single-purpose agents
- Highly deterministic workflows requiring exact control
- Resource-constrained environments (high token usage)
- Teams without experience in async Python patterns
- Projects requiring vendor portability

---

### Code Examples Summary

#### Minimal Agent

```python
from autogen_agentchat.agents import AssistantAgent
from autogen_ext.models.openai import OpenAIChatCompletionClient

model_client = OpenAIChatCompletionClient(model="gpt-4o")
agent = AssistantAgent(name="assistant", model_client=model_client)

result = await agent.run(task="What is 2 + 2?")
print(result.messages[-1].content)
```

#### Two-Agent Reflection Pattern

```python
writer = AssistantAgent(
    "writer",
    model_client=model_client,
    system_message="Write content as requested."
)

critic = AssistantAgent(
    "critic",
    model_client=model_client,
    system_message="Provide constructive feedback. Say APPROVE when satisfied."
)

team = RoundRobinGroupChat(
    [writer, critic],
    termination_condition=TextMentionTermination("APPROVE"),
    max_turns=10,
)

result = await team.run(task="Write a haiku about coding.")
```

#### Tool-Using Agent with Code Execution

```python
from autogen_ext.code_executors.docker import DockerCommandLineCodeExecutor
from autogen_ext.tools.code_execution import PythonCodeExecutionTool

async with DockerCommandLineCodeExecutor() as executor:
    code_tool = PythonCodeExecutionTool(executor)
    
    coder = AssistantAgent(
        "coder",
        model_client=model_client,
        tools=[code_tool],
        system_message="Write and execute Python code to solve tasks."
    )
    
    result = await coder.run(task="Calculate the 50th Fibonacci number.")
```

#### Human-in-the-Loop with Handoff

```python
assistant = AssistantAgent(
    "assistant",
    model_client=model_client,
    handoffs=[Handoff(target="user", message="Need human input.")],
    system_message="Help with tasks. Hand off to user if uncertain."
)

team = RoundRobinGroupChat(
    [assistant],
    termination_condition=HandoffTermination(target="user"),
)

while True:
    result = await team.run(task=user_input)
    if result.stop_reason == "handoff":
        user_input = input("Your response: ")
    else:
        break
```

---

### References

- [AutoGen Stable Documentation](https://microsoft.github.io/autogen/stable/)
- [AutoGen GitHub Repository](https://github.com/microsoft/autogen)
- [Migration Guide v0.2 to v0.4](https://microsoft.github.io/autogen/dev/user-guide/agentchat-user-guide/migration-guide.html)
- [AutoGen 0.2 Documentation](https://microsoft.github.io/autogen/0.2/docs/)
- [SelectorGroupChat Documentation](https://microsoft.github.io/autogen/stable//user-guide/agentchat-user-guide/selector-group-chat.html)
- [Swarm Documentation](https://microsoft.github.io/autogen/stable//user-guide/agentchat-user-guide/swarm.html)
- [Human-in-the-Loop Tutorial](https://microsoft.github.io/autogen/stable//user-guide/agentchat-user-guide/tutorial/human-in-the-loop.html)
- [State Management Tutorial](https://microsoft.github.io/autogen/stable//user-guide/agentchat-user-guide/tutorial/state.html)
- [Memory and RAG Documentation](https://microsoft.github.io/autogen/stable//user-guide/agentchat-user-guide/memory.html)
- [Core Framework Tools](https://microsoft.github.io/autogen/stable//user-guide/core-user-guide/components/tools.html)
- [Command Line Code Executors](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/components/command-line-code-executors.html)
- [Handoffs Design Pattern](https://microsoft.github.io/autogen/stable//user-guide/core-user-guide/design-patterns/handoffs.html)
- [Choosing Agent Frameworks in 2026](https://dev.to/clickit_devops/choosing-the-right-agent-framework-in-2026-is-autogen-enough-3332)
- [AutoGen vs AG2 Comparison](https://www.gettingstarted.ai/autogen-vs-ag2/)
Now let me compile the additional research into a continuation of the markdown document.

---

## Appendix: Microsoft AutoGen API Research (Continued)

### 10. Reflection and Validation Patterns

#### The Reflection Design Pattern

Reflection implements iterative improvement through dual-agent collaboration. The pattern employs two agents: a generator and a critic. According to the [reflection documentation](https://microsoft.github.io/autogen/stable//user-guide/core-user-guide/design-patterns/reflection.html), "reflection is a design pattern where an LLM generation is followed by a reflection, which in itself is another LLM generation conditioned on the output of the first one."

**Implementation Architecture:**

The pattern uses four custom message types to orchestrate the workflow:
- `CodeWritingTask`: Initial request from application
- `CodeReviewTask`: Code submission for evaluation
- `CodeReviewResult`: Reviewer feedback with approval status
- `CodeWritingResult`: Final approved code

**Validation Dimensions:**

The reviewer agent evaluates outputs across three key dimensions:
1. **Correctness**: Logic validation
2. **Efficiency**: Performance and resource optimization  
3. **Safety**: Input validation and error handling

Feedback is structured and specific, such as: "The function remains efficient with a time complexity of O(n) due to the use of a generator expression."

**Retry Mechanism:**

The generator agent implements conditional retry logic:
1. Receives `CodeReviewResult` message
2. If `approved: false`, reconstructs message history and generates revision
3. Publishes new `CodeReviewTask` with updated code
4. Process continues until `approved: true`

The reviewer agent maintains session memory to track iterations: "If previous feedback was provided, see if it was addressed," enabling progressive refinement where each iteration acknowledges prior suggestions.

**Tool Reflection:**

AssistantAgent supports reflection on tool outputs via the `reflect_on_tool_use=True` parameter. As described in [tool documentation](https://sparkco.ai/blog/mastering-retry-logic-agents-a-deep-dive-into-2025-best-practices), "when handling a user message, the ToolUseAgent class first uses the model client to generate a list of function calls to the tools, and then run the tools and generate a reflection on the results of the tool execution."

This is particularly useful when tools don't return well-formed natural language strings, allowing the model to summarize tool output for better agent comprehension.

#### Result Validators

Modern AutoGen implementations (2025-2026) incorporate sophisticated retry strategies that "not only consider the type of error but also the operational context, improving decision-making in real-time scenarios," according to [retry logic research](https://sparkco.ai/blog/mastering-retry-logic-agents-a-deep-dive-into-2025-best-practices).

---

### 11. Context Management and Dependencies

#### Shared State Management

AutoGen's state management is particularly useful in web applications where stateless endpoints respond to requests and need to load the state of the application from persistent storage, according to [state management discussions](https://github.com/microsoft/autogen/discussions/6005).

**State Composition:**

For `AssistantAgent`, state consists of the `model_context`, which can be any of the `ChatCompletionContext` types:
- `UnboundedChatCompletionContext` (default - full conversation history)
- `BufferedChatCompletionContext` (last N messages)
- `TokenLimitedChatCompletionContext` (token-based limits)

**Context Configuration:**

```python
from autogen_agentchat.agents import AssistantAgent
from autogen_agentchat.context import BufferedChatCompletionContext

agent = AssistantAgent(
    name="assistant",
    model_client=model_client,
    model_context=BufferedChatCompletionContext(buffer_size=10)
)
```

#### Memory Integration

AutoGen provides a `Memory` protocol for maintaining conversation context beyond immediate message history. The framework includes several implementations as detailed in the [memory documentation](https://microsoft.github.io/autogen/stable//user-guide/agentchat-user-guide/memory.html):

| Implementation | Description |
|----------------|-------------|
| `ListMemory` | Chronological list appended to context |
| `ChromaDBVectorMemory` | Semantic search via embeddings |
| `RedisMemory` | Persistent vector storage |
| `Mem0Memory` | Cloud-based with metadata filtering |

**Usage Pattern:**

```python
from autogen_agentchat.memory import ListMemory

memory = ListMemory()
await memory.add("User prefers metric units", source="preferences")

agent = AssistantAgent(
    name="assistant",
    model_client=model_client,
    memory=[memory],  # Memory is queried before each response
)
```

#### Message Transforms

AutoGen supports message transformation for context window management, particularly valuable for non-OpenAI models with limited context sizes. The [transforms documentation](https://microsoft.github.io/autogen/0.2/docs/topics/non-openai-models/transforms-for-nonopenai-models/) describes two key transform types:

**Name Incorporation Transform:**

Non-OpenAI models don't receive agent names in message metadata. The `TextMessageContentName` transform injects agent identities directly into message content: "inject the agent's name for a message into the start of the message content."

**Text Compression Transform:**

The `TextMessageCompressor` reduces token usage when messages exceed a threshold (e.g., 1,000 tokens). It uses LLMLingua to intelligently compress content while preserving meaning.

```python
from autogen.agentchat.contrib.text_message_compressor import TextMessageCompressor
from autogen.agentchat.contrib.transform_messages import TransformMessages

compress = TextMessageCompressor(
    min_tokens=1000,
    filter_dict={"role": ["system"]}  # Don't compress system prompts
)

name_transform = TextMessageContentName(
    position="start",
    format_string="'{name}' said:\n"
)

transforms = TransformMessages(transforms=[compress, name_transform])
transforms.add_to_agent(agent)
```

Example results: "1282 tokens saved with text compression" shown during execution.

#### Context Overflow Strategies

The [roadmap for context overflow](https://github.com/microsoft/autogen/issues/156) includes:
1. **Compression** using LLMs to compress previous messages
2. **Retrieval** of related history messages based on latest message
3. **Truncation** keeping recent K messages
4. **Specific truncation** such as removing failed code executions

**MemGPT Integration:**

MemGPT is designed to handle memory management and context retention within AutoGen. According to [memory management research](https://medium.com/@shmilysyg/memory-management-within-autogen-1-2-1e6303ba5d7a), it provides:
- **Context Retention**: Tracking conversation history for reference
- **Memory Configuration**: Retaining specific numbers of past messages
- **Stateful Interaction**: Ensuring agents build upon previous exchanges

---

### 12. Streaming and Observability

#### Streaming API Surface

AutoGen v0.4 features comprehensive streaming capabilities. The `run_stream()` method returns an async iterator of messages that subclass `BaseAgentEvent` or `BaseChatMessage`, followed by a `TaskResult`.

**Core Methods:**

According to the [AgentChat base classes reference](https://microsoft.github.io/autogen/stable//reference/python/autogen_agentchat.base.html):

- `on_messages()`: "Handles incoming messages and returns a response"
- `on_messages_stream()`: "Handles incoming messages and returns a stream of inner messages and the final item is the response"

**Response Structure:**

The `Response` class contains:
- `chat_message`: A single `BaseChatMessage` output from the agent
- `inner_messages`: Optional sequence of intermediate `BaseAgentEvent` or `BaseChatMessage` objects representing agent reasoning/work

**Task Execution API:**

`TaskRunner` protocol defines:
- `run()`: Returns `TaskResult` with full conversation
- `run_stream()`: Produces async generator yielding individual events/messages with `TaskResult` as final item

Both methods accept optional `cancellation_token` and `output_task_messages` parameter for filtering intermediate task messages.

#### OpenTelemetry Integration

AutoGen has built-in OpenTelemetry support, following [Semantic Conventions for GenAI Systems](https://opentelemetry.io/blog/2025/ai-agent-observability/). The [telemetry documentation](https://microsoft.github.io/autogen/stable//user-guide/core-user-guide/framework/telemetry.html) describes instrumentation for:

**Instrumented Components:**

1. **Runtime**: `SingleThreadedAgentRuntime` and `GrpcWorkerAgentRuntime`
2. **Tools**: `BaseTool` with `execute_tool` spans following GenAI semantic conventions
3. **AgentChat Agents**: `BaseChatAgent` with `create_agent` and `invoke_agent` spans

**Setup Requirements:**

```bash
pip install opentelemetry-sdk
pip install opentelemetry-exporter-otlp-proto-grpc
pip install opentelemetry-instrumentation-openai
```

**Implementation Pattern:**

```python
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

# Configure provider
exporter = OTLPSpanExporter(endpoint="http://localhost:4317")
provider = TracerProvider()
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)

# Pass to runtime
runtime = SingleThreadedAgentRuntime(tracer_provider=provider)
```

**Disabling Telemetry:**

Two options:
- Pass `trace_provider=opentelemetry.trace.NoOpTracerProvider()` to runtime
- Set environment variable `AUTOGEN_DISABLE_RUNTIME_TRACING=true`

**Integration with Observability Platforms:**

AutoGen works with multiple backends according to [SigNoz integration docs](https://signoz.io/docs/autogen-observability/):
- SigNoz
- Jaeger (recommended for local development)
- Langfuse
- Arize Phoenix (via OpenInference)

Launch Jaeger locally via Docker with OTLP enabled on port 4317, accessible at `http://localhost:16686` for visualization.

---

### 13. Cancellation and Timeout Management

#### CancellationToken API

AutoGen provides a `CancellationToken` class for canceling pending async calls. According to [GitHub discussions](https://github.com/microsoft/autogen/discussions/5937), it includes:

- `cancel()`: Triggers cancellation
- `is_cancelled()`: Checks cancellation status

**Usage Pattern:**

```python
from autogen_core import CancellationToken

cancellation_token = CancellationToken()

# Start team with cancellation support
task = asyncio.create_task(
    team.run(task="Long running task", cancellation_token=cancellation_token)
)

# Cancel after timeout
await asyncio.sleep(30)
cancellation_token.cancel()
```

**TimeoutTermination:**

AutoGen also provides a `TimeoutTermination` condition that stops after a specified duration in seconds:

```python
from autogen_agentchat.conditions import TimeoutTermination

team = RoundRobinGroupChat(
    [agent1, agent2],
    termination_condition=TimeoutTermination(timeout=60.0),
)
```

#### Known Issues

According to [GitHub issue #4029](https://github.com/microsoft/autogen/issues/4029):
- Cancellation token support needs consistent propagation through the call stack
- Some components (speaker selection logic) may continue even after cancellation
- MCP tools have a 5-second default timeout that can fail for long-running operations

A bug was identified where example code created new `CancellationToken` instances instead of using the shared token, making timeouts ineffective.

---

### 14. Error Handling and Retry Strategies

#### Retry Configuration

AutoGen allows configuration of `max_retries` and `timeout` for handling API errors. According to the [FAQ documentation](https://microsoft.github.io/autogen/0.2/docs/FAQ/):

- `max_retries`: Total number of times allowed for retrying failed requests
- `timeout`: Timeout in seconds for a single client request

**Practical Error Handling:**

A [February 2025 blog post](https://singhrajeev.com/2025/02/08/getting-started-with-autogen-a-framework-for-building-multi-agent-generative-ai-applications/) describes error handling flow:

"If the WebSurfer agent encounters an error, the UserProxyAgent prompts for user input and retries the task. If retries fail, the task is passed to the AssistantAgent, ensuring that the user still receives a response."

This demonstrates AutoGen's ability to handle errors through:
- Automatic retries
- Fallback to alternative agents
- Human-in-the-loop intervention

#### Runtime Exception Handling

The `ignore_unhandled_exceptions` parameter (from [autogen_core reference](https://microsoft.github.io/autogen/stable//reference/python/autogen_core.html)) determines whether to ignore unhandled exceptions in agent event handlers. Defaults to `True`.

Any background exceptions will be raised on the next call to `process_next` or from an awaited stop.

#### Known Limitations

[GitHub issue #5274](https://github.com/microsoft/autogen/issues/5274) proposes supporting configurable error handling in tools:
- If a custom agent raises an exception, there's an error in processing but the agent continues
- Tools need configurable error handling strategies
- Need for typed error responses vs. exceptions

---

### 15. MCP (Model Context Protocol) Integration

#### Core MCP Components

AutoGen v0.4 includes comprehensive MCP support through the `autogen_ext.tools.mcp` module. The [MCP reference documentation](https://microsoft.github.io/autogen/stable//reference/python/autogen_ext.tools.mcp.html) describes three main components:

**McpWorkbench:**

"A workbench wrapping an MCP server, providing interfaces to list and call tools from the server."

Key methods:
- `list_tools()` - Returns available tools as `ToolSchema` objects
- `call_tool(name, arguments)` - Executes a named tool with given parameters
- `list_prompts()`, `list_resources()`, `list_resource_templates()` - Access MCP server capabilities
- `read_resource(uri)`, `get_prompt(name)` - Retrieve specific resources/prompts
- `start()`, `stop()`, `reset()` - Lifecycle management

**Security Warning:** Only connect to trusted MCP servers; `StdioServerParams` executes local commands.

**StdioMcpToolAdapter:**

Wraps MCP tools communicating over standard input/output.

Use cases:
- Command-line tools
- Local services implementing MCP protocol

**SseMcpToolAdapter:**

Wraps MCP tools using Server-Sent Events (HTTP) communication.

Use cases:
- Remote MCP services
- Cloud-based tools
- Web APIs

#### Server Parameter Types

**StdioServerParams:**
- `command`: Executable to run
- `args`: Command arguments
- `env`: Environment variables
- `cwd`: Working directory
- `encoding`: Text encoding (default utf-8)
- `read_timeout_seconds`: Read timeout

**SseServerParams:**
- `url`: Server endpoint
- `headers`: HTTP headers
- `timeout`: Connection timeout (default 5s)
- `sse_read_timeout`: Read timeout (default 300s)

**StreamableHttpServerParams:**
- `url`: Server endpoint
- `headers`: HTTP headers
- `timeout`: Request timeout (default 30s)
- `sse_read_timeout`: Read timeout
- `terminate_on_close`: Terminate on connection close (default true)

#### Integration Pattern

According to [integration tutorials](https://newsletter.victordibia.com/p/how-to-use-mcp-anthropic-mcp-tools):

```python
from autogen_ext.tools.mcp import McpWorkbench, SseServerParams

playwright_server_params = SseServerParams(
    url="http://localhost:8931/sse",
)

async with McpWorkbench(playwright_server_params) as workbench:
    tools = await workbench.list_tools()
    
    agent = AssistantAgent(
        name="assistant",
        model_client=model_client,
        tools=tools,  # MCP tools directly usable
    )
```

**Factory Function:**

`mcp_server_tools()` creates adapters for all available tools from an MCP server, returning a list compatible with AutoGen agents. This simplifies integration: "creates a list of MCP tool adapters that can be used with AutoGen agents by connecting to an MCP server."

---

### 16. Distributed Runtime and Cross-Language Support

#### Distributed Architecture

AutoGen's distributed runtime is "suitable for multi-process applications where agents may be implemented in different programming languages and running on different machines," according to [distributed runtime documentation](https://microsoft.github.io/autogen/stable//user-guide/core-user-guide/framework/distributed-agent-runtime.html).

**Core Components:**

**GrpcWorkerAgentRuntimeHost:**

The central service that maintains connections to worker runtimes, routes messages, and manages RPC sessions.

```python
from autogen_ext.runtimes.grpc import GrpcWorkerAgentRuntimeHost

host = GrpcWorkerAgentRuntimeHost(address="localhost:50051")
host.start()
```

**GrpcWorkerAgentRuntime:**

Worker processes that execute application code and agents. They connect to the host and advertise their supported agents.

```python
from autogen_ext.runtimes.grpc import GrpcWorkerAgentRuntime

worker = GrpcWorkerAgentRuntime(host_address="localhost:50051")
await worker.start()
```

#### Communication Pattern

Agents across different workers communicate through a pub-sub model:
- Agents publish to topics (e.g., "DefaultTopicId")
- Messages reach all subscribers
- The host service acts as a message broker
- Workers advertise their agents for correct routing
- Agents use `@message_handler` decorators to process incoming messages

#### Cross-Language Support

According to [runtime implementation research](https://www.prasanna.dev/posts/distributed-runtime-autogen):

"They have proto files checked into the repository: `agentworker.proto` for unary messages and `cloudevent.proto` for the bidirectional stream. The language of choice can generate the client and server code from these proto files."

The Core API "supports cross-language support for .NET and Python."

**Important requirement:** "All message types MUST use shared protobuf schemas for all cross-agent message types" to ensure compatibility across language boundaries.

#### Installation

```bash
pip install "autogen-ext[grpc]"
```

#### Lifecycle Management

- Stop workers and hosts using `stop()` methods
- Use `stop_when_signal()` to run until receiving termination signals (SIGTERM)

---

### 17. Cost Tracking and Usage Monitoring

#### Built-in Usage Tracking (v0.2 pattern)

AutoGen v0.2 provides built-in cost tracking through `OpenAIWrapper`, as described in the [AG2 usage tracking docs](https://docs.ag2.ai/latest/docs/use-cases/notebooks/notebooks/agentchat_cost_token_tracking/):

```python
# Agent-level tracking
agent.print_usage_summary()
agent.get_actual_usage()
agent.get_total_usage()

# Multi-agent tracking
from autogen import gather_usage_summary
usage = gather_usage_summary([agent1, agent2, agent3])
```

The `OpenAIWrapper` "tracks token counts and costs of your API calls," with `create()` initiating requests and `print_usage_summary()` retrieving detailed reports including total cost and token usage for both cached and actual requests.

**Price Management:**

AutoGen attempts to keep token prices up-to-date, but "you can pass in a price field in config_list if the token price is not listed or up-to-date."

#### Third-Party Monitoring

**AgentOps Integration:**

According to [AgentOps ecosystem documentation](https://microsoft.github.io/autogen/0.2/docs/ecosystem/agentops/):

"AgentOps gives you the ability to monitor LLM calls, costs, latency, agent failures, multi-agent interactions, tool usage, session-wide statistics, and more."

Integration requires just two lines:

```python
import agentops
agentops.init(api_key="...")

# All AutoGen agents now automatically tracked
```

Capabilities include:
- LLM call monitoring
- Cost tracking per session
- Latency measurements
- Agent failure detection
- Multi-agent interaction visualization
- Tool usage analytics

**SelectorGroupChat Tracking:**

[GitHub discussion #6761](https://github.com/microsoft/autogen/discussions/6761) addresses token tracking in `SelectorGroupChat` instances, indicating ongoing community interest in granular usage monitoring.

---

### 18. Custom Agent Implementation

#### Two Implementation Approaches

According to [custom agents documentation](https://microsoft.github.io/autogen/stable//user-guide/agentchat-user-guide/custom-agents.html), AutoGen provides two paths for custom agents:

**1. AgentChat API - BaseChatAgent**

For high-level conversational agents:

```python
from autogen_agentchat.base import BaseChatAgent, Response
from autogen_agentchat.messages import BaseChatMessage

class CustomAgent(BaseChatAgent):
    async def on_messages(
        self, 
        messages: list[BaseChatMessage],
        cancellation_token: CancellationToken
    ) -> Response:
        # Process messages and return response
        return Response(chat_message=reply, inner_messages=[])
    
    async def on_reset(self, cancellation_token: CancellationToken) -> None:
        # Reset agent state
        self._message_history = []
    
    @property
    def produced_message_types(self) -> list[type[BaseChatMessage]]:
        return [TextMessage]
```

**Required implementations:**
- `on_messages()`: "The abstract method that defines the behavior of the agent in response to messages"
- `on_reset()`: Resets agent to initial state
- `produced_message_types`: Property listing message types the agent generates

**Optional:**
- `on_messages_stream()`: For progressive message generation. "If this method is not implemented, the agent uses the default implementation that calls the on_messages() method and yields all messages in the response."

**Critical behavior:** "The on_messages method may be called with an empty list of messages, in which case it means the agent was called previously and is now being called again, without any new messages from the caller."

**2. Core API - RoutedAgent**

For event-driven agents in the Core framework:

```python
from autogen_core import RoutedAgent, message_handler

class CustomAgent(RoutedAgent):
    @message_handler
    async def handle_task(
        self, 
        message: TaskMessage, 
        ctx: MessageContext
    ) -> None:
        # Process specific message type
        await self.publish_message(ResponseMessage(...), topic=ctx.topic_id)
    
    async def save_state(self) -> Mapping[str, Any]:
        # Return serializable state
        return {"context": self._context}
```

According to [GitHub discussion #6005](https://github.com/microsoft/autogen/discussions/6005): "In core, when writing an Agent class inheriting the RoutedAgent, we must have the save_state method where to save the context we must return a AssistantAgentState dump."

**Protocol Pattern:**

"The @message_handler decorator tells the runtime what type of messages this agent can handle (through type hints), and the runtime uses this information to route messages to the appropriate handler method of the right agent instance."

#### Integration Between APIs

If you have an AgentChat agent and want to use it in the Core API, you can create a wrapper `RoutedAgent` that delegates messages to the AgentChat agent.

#### State Serialization

Custom agents can be made declarative by inheriting from `Component` with `_from_config()` and `_to_config()` methods for serialization, enabling configuration-based agent instantiation.

---

### 19. Model Client Interface

#### ChatCompletionClient Protocol

AutoGen-core implements a protocol for model clients, with autogen-ext providing implementations for popular model services. According to [model clients documentation](https://microsoft.github.io/autogen/stable//user-guide/core-user-guide/components/model-clients.html):

**Core Methods:**

1. **`create()`** - Executes a single chat completion request with messages and returns a `CreateResult` object containing the model's response, token usage, and finish reason.

2. **`create_stream()`** - Enables streaming token responses, yielding string chunks followed by a final `CreateResult` object.

Note: "The default usage response is to return zero values."

**Parameters:**

Both methods accept:
- `messages`: List of message objects (SystemMessage, UserMessage, etc.)
- `response_format`: Optional Pydantic BaseModel for structured output
- `extra_create_args`: Additional configuration per request
- `cancellation_token`: For canceling async operations

#### Built-in Implementations

| Implementation | Provider |
|----------------|----------|
| `OpenAIChatCompletionClient` | OpenAI and compatible APIs (Gemini, etc.) |
| `AzureOpenAIChatCompletionClient` | Azure OpenAI |
| `AzureAIChatCompletionClient` | GitHub/Azure-hosted models |
| `OllamaChatCompletionClient` | Local models via Ollama |
| `AnthropicChatCompletionClient` | Anthropic models |
| `SKChatCompletionAdapter` | Semantic Kernel integration |

**Usage Pattern:**

```python
from autogen_ext.models.openai import OpenAIChatCompletionClient
from autogen_core.models import SystemMessage, UserMessage

model_client = OpenAIChatCompletionClient(
    model="gpt-4o",
    api_key="...",
    temperature=0.7
)

result = await model_client.create(
    messages=[
        SystemMessage(content="You are helpful."),
        UserMessage(content="What is 2+2?", source="user")
    ]
)

print(result.content)
```

#### Structured Output

OpenAI and Azure clients support structured output via Pydantic models:

```python
from pydantic import BaseModel

class Answer(BaseModel):
    result: int
    explanation: str

result = await model_client.create(
    messages=[UserMessage(content="What is 2+2?", source="user")],
    response_format=Answer
)

# result.content is now an Answer instance
```

#### Caching

`ChatCompletionCache` wraps any client using `CacheStore` implementations:

```python
from autogen_core.cache import ChatCompletionCache, DiskCacheStore

cached_client = ChatCompletionCache(
    model_client,
    cache_store=DiskCacheStore("./cache")
)
```

Available cache stores:
- `DiskCacheStore`: Local filesystem
- `RedisStore`: Redis-backed persistence

#### Custom Model Clients

Create custom implementations for OpenAI-compatible endpoints:

```python
custom_client = OpenAIChatCompletionClient(
    base_url="https://api.custom-provider.com/v1",
    api_key="...",
    model_info={
        "vision": True,
        "function_calling": True,
        "json_output": True
    }
)
```

---

### 20. Message Type System

#### Message Hierarchy

AutoGen employs a hierarchical message system built on `BaseChatMessage`. According to [messages documentation](https://microsoft.github.io/autogen/stable//user-guide/agentchat-user-guide/tutorial/messages.html), this foundation "facilitates communication and information exchange with other agents, orchestrators, and applications."

**Message Categories:**

1. **Agent-to-agent communication** - Concrete subclasses for inter-agent dialogue
2. **Internal events** - Agent-specific operational messages (BaseAgentEvent)

#### Core Message Types

**TextMessage:**

The fundamental communication unit accepting two parameters:
- `content`: String containing the message content
- `source`: String identifier for the message source

```python
from autogen_agentchat.messages import TextMessage

text_message = TextMessage(
    content="Hello, world!", 
    source="User"
)
```

**MultiModalMessage:**

Extends capabilities to diverse content types. "Accepts a list of strings or Image objects," enabling agents to process and exchange visual information alongside textual data.

```python
from autogen_agentchat.messages import MultiModalMessage
from autogen_core import Image

multi_modal_message = MultiModalMessage(
    content=["Can you describe this image?", img_object],
    source="User"
)
```

#### Model-Level Message Types

According to [autogen_core.models reference](https://microsoft.github.io/autogen/stable//reference/python/autogen_core.models.html), lower-level message types for model communication include:

- `SystemMessage`: Developer instructions for the model
- `UserMessage`: End-user input or data provided to model
- `AssistantMessage`: Messages sampled from the language model
- `FunctionExecutionResultMessage`: Tool/function execution results

These types are used in `ChatCompletionClient.create()` calls.

#### Custom Message Types

"You can create custom message types by subclassing the base class `BaseChatMessage` or `BaseAgentEvent`, which allows you to define your own message formats and behaviors, tailored to your application."

Custom messages enable domain-specific protocols for specialized agent interactions.

---

### Sources

- [Reflection Design Pattern](https://microsoft.github.io/autogen/stable//user-guide/core-user-guide/design-patterns/reflection.html)
- [Getting Started with AutoGen: AI Agentic Design Patterns](https://medium.com/@shmilysyg/getting-started-with-autogen-ai-agentic-design-patterns-2-3-3d9a94159393)
- [Tools Documentation](https://microsoft.github.io/autogen/stable//user-guide/core-user-guide/components/tools.html)
- [Mastering Retry Logic Agents](https://sparkco.ai/blog/mastering-retry-logic-agents-a-deep-dive-into-2025-best-practices)
- [Managing State](https://microsoft.github.io/autogen/stable//user-guide/agentchat-user-guide/tutorial/state.html)
- [State Management Discussions](https://github.com/microsoft/autogen/discussions/6005)
- [Memory Management in AutoGen](https://medium.com/@shmilysyg/memory-management-within-autogen-1-2-1e6303ba5d7a)
- [Transform Messages for Non-OpenAI Models](https://microsoft.github.io/autogen/0.2/docs/topics/non-openai-models/transforms-for-nonopenai-models/)
- [Roadmap for Context Overflow](https://github.com/microsoft/autogen/issues/156)
- [AutoGen v0.4 Crash Course](https://www.cohorte.co/blog/autogen-v0-4-ag2-crash-course-build-event-driven-observable-ai-agents-that-scale)
- [AgentChat Base Classes](https://microsoft.github.io/autogen/stable//reference/python/autogen_agentchat.base.html)
- [Open Telemetry Documentation](https://microsoft.github.io/autogen/stable//user-guide/core-user-guide/framework/telemetry.html)
- [Tracing and Observability](https://microsoft.github.io/autogen/stable//user-guide/agentchat-user-guide/tracing.html)
- [AutoGen Observability with SigNoz](https://signoz.io/docs/autogen-observability/)
- [AI Agent Observability Standards](https://opentelemetry.io/blog/2025/ai-agent-observability/)
- [Termination Conditions](https://microsoft.github.io/autogen/stable//user-guide/agentchat-user-guide/tutorial/termination.html)
- [CancellationToken Discussions](https://github.com/microsoft/autogen/discussions/5937)
- [AutoGen FAQ](https://microsoft.github.io/autogen/0.2/docs/FAQ/)
- [Error Handling in Tools](https://github.com/microsoft/autogen/issues/5274)
- [Getting Started with AutoGen](https://singhrajeev.com/2025/02/08/getting-started-with-autogen-a-framework-for-building-multi-agent-generative-ai-applications/)
- [MCP Tools Reference](https://microsoft.github.io/autogen/stable//reference/python/autogen_ext.tools.mcp.html)
- [Workbench and MCP](https://microsoft.github.io/autogen/stable//user-guide/core-user-guide/components/workbench.html)
- [How to Use MCP Tools with AutoGen](https://newsletter.victordibia.com/p/how-to-use-mcp-anthropic-mcp-tools)
- [AutoGen and MCP: Building Multi-Agent Systems](https://llmmultiagents.com/en/blogs/autogen_mcp_blog)
- [Distributed Agent Runtime](https://microsoft.github.io/autogen/stable//user-guide/core-user-guide/framework/distributed-agent-runtime.html)
- [Understanding AutoGen's Distributed Runtime](https://www.prasanna.dev/posts/distributed-runtime-autogen)
- [Usage Tracking with AG2](https://docs.ag2.ai/latest/docs/use-cases/notebooks/notebooks/agentchat_cost_token_tracking/)
- [Agent Monitoring with AgentOps](https://microsoft.github.io/autogen/0.2/docs/ecosystem/agentops/)
- [Custom Agents](https://microsoft.github.io/autogen/stable//user-guide/agentchat-user-guide/custom-agents.html)
- [Model Clients](https://microsoft.github.io/autogen/stable//user-guide/core-user-guide/components/model-clients.html)
- [Messages Documentation](https://microsoft.github.io/autogen/stable//user-guide/agentchat-user-guide/tutorial/messages.html)
