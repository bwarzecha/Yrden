# Appendix: CrewAI API Research

## Overview

CrewAI is a Python framework for building multi-agent AI systems. It emphasizes a high-level, declarative approach where agents with defined roles collaborate to accomplish tasks. The framework positions itself as "lean and lightning-fast" without dependencies on LangChain or similar tools.

**Key Design Philosophy:**
- Role-based agent design (role, goal, backstory)
- Task-centric execution model
- Crew orchestration for multi-agent collaboration
- Event-driven Flows for complex workflows
- YAML configuration as the recommended approach

---

## 1. Core Concepts & Types

### Agent Class

The Agent is CrewAI's fundamental unit - an autonomous entity that performs tasks, makes decisions, uses tools, and collaborates with other agents.

**Required Attributes:**
```python
from crewai import Agent

researcher = Agent(
    role="AI Technology Researcher",        # Function/expertise
    goal="Research the latest AI developments",  # Objective guiding decisions
    backstory="You're a seasoned researcher with 10 years of experience..."
)
```

**Execution Control Parameters:**

| Parameter | Type | Default | Purpose |
|-----------|------|---------|---------|
| `max_iter` | int | 20 | Maximum iterations before best answer |
| `max_rpm` | Optional[int] | None | Rate limiting for API requests |
| `max_execution_time` | Optional[int] | None | Timeout in seconds |
| `max_retry_limit` | int | 2 | Retry attempts on errors |
| `verbose` | bool | False | Enable detailed execution logs |
| `cache` | bool | True | Cache tool usage results |

**Advanced Features:**
```python
agent = Agent(
    role="Analyst",
    goal="Analyze data",
    backstory="...",
    
    # LLM configuration
    llm="gpt-4o",                          # Model selection
    function_calling_llm="gpt-4o-mini",    # Separate model for tools
    use_system_prompt=True,                # Model compatibility flag
    
    # Memory and knowledge
    memory=True,                           # Enable conversation history
    respect_context_window=True,           # Auto-summarize on overflow
    knowledge_sources=[pdf_source],        # Domain knowledge
    
    # Collaboration
    allow_delegation=False,                # Can delegate to other agents
    
    # Execution
    allow_code_execution=True,             # Execute Python code
    code_execution_mode="safe",            # "safe" (Docker) or "unsafe"
    
    # Reasoning
    reasoning=True,                        # Enable reflection before tasks
    max_reasoning_attempts=None,           # Unlimited planning iterations
    
    # Multimodal
    multimodal=True,                       # Process images
    
    # Templates (low-level control)
    system_template="...",                 # Core behavioral instructions
    prompt_template="...",                 # Input format structure
    response_template="...",               # Response format
    
    # Callbacks
    step_callback=my_callback_fn           # Function after each step
)
```

### Task Class

Tasks represent specific assignments completed by agents.

**Core Configuration:**
```python
from crewai import Task
from pydantic import BaseModel

class BlogPost(BaseModel):
    title: str
    content: str

research_task = Task(
    description="Research the latest AI developments in {topic}",
    expected_output="A comprehensive report with 10 key findings",
    agent=researcher,                      # Responsible agent
    
    # Output handling
    output_pydantic=BlogPost,              # Structured output
    output_file="report.md",               # Save to file
    markdown=True,                         # Markdown formatting
    
    # Dependencies
    context=[prior_task],                  # Tasks whose outputs feed in
    
    # Execution
    async_execution=False,                 # Enable parallel execution
    human_input=False,                     # Require human review
    
    # Validation
    guardrail=validate_length,             # Single validation function
    guardrails=[validate_length, "Must be under 500 words"],  # Multiple
    guardrail_max_retries=3,               # Retry limit
    
    # Callbacks
    callback=task_callback_fn              # Post-completion action
)
```

**Guardrail Pattern:**
```python
from typing import Tuple, Any
from crewai import TaskOutput

def validate_word_count(result: TaskOutput) -> Tuple[bool, Any]:
    """Return (is_valid, transformed_result_or_error_message)"""
    word_count = len(result.raw.split())
    if word_count > 200:
        return (False, "Exceeds 200-word limit. Condense the response.")
    return (True, result.raw.strip())

# LLM-based guardrails use string descriptions
task = Task(
    description="Write content",
    guardrail="Output must be engaging and suitable for general audience"
)
```

### Crew Class

Crews orchestrate agents working together on tasks.

```python
from crewai import Crew, Process

crew = Crew(
    agents=[researcher, writer],
    tasks=[research_task, write_task],
    
    # Process type
    process=Process.sequential,            # or Process.hierarchical
    
    # For hierarchical process
    manager_llm="gpt-4o",                  # Required for hierarchical
    # OR
    manager_agent=custom_manager,          # Custom coordinator
    
    # Execution
    verbose=True,
    max_rpm=10,                            # Rate limiting
    
    # Memory
    memory=True,                           # Enable all memory types
    embedder={
        "provider": "openai",
        "config": {"model": "text-embedding-3-small"}
    },
    
    # Knowledge
    knowledge_sources=[pdf_source],        # Shared across agents
    
    # Caching
    cache=True,                            # Tool result caching
    
    # Planning
    planning=True,                         # Pre-execution task planning
    planning_llm="gpt-4o",
    
    # Logging
    output_log_file="execution.json",
    
    # Callbacks
    step_callback=step_fn,
    task_callback=task_fn,
    
    # Streaming
    stream=True                            # Real-time output
)
```

---

## 2. Execution Model

### crew.kickoff() Pattern

```python
# Simple execution
result = crew.kickoff(inputs={"topic": "AI Agents"})

# Access results
print(result.raw)                          # Plain text
print(result.pydantic)                     # Structured output
print(result.json_dict)                    # Dictionary
print(result.tasks_output)                 # Individual task results
print(result.token_usage)                  # Token consumption

# Batch execution
results = crew.kickoff_for_each(inputs=[
    {"topic": "AI"},
    {"topic": "ML"}
])
```

**Async Variants:**
```python
# Native async (recommended for high concurrency)
result = await crew.akickoff(inputs={"topic": "AI"})
results = await crew.akickoff_for_each(inputs=[...])

# Thread-wrapped async
result = await crew.kickoff_async(inputs={"topic": "AI"})
```

### Task Execution Flow

**Sequential Process:**
```
Task 1 → Output → Task 2 (receives Task 1 output as context) → Output → Task 3 → ...
```

**Hierarchical Process:**
```
Manager Agent
    ├── Analyzes all tasks
    ├── Delegates to appropriate agents based on capabilities
    ├── Validates outputs
    └── Coordinates until all tasks complete
```

### Agent Collaboration

Agents collaborate through two built-in tools (when `allow_delegation=True`):

1. **Delegation Tool**: Assign tasks to teammates
   ```
   "Delegate work to coworker(task: str, context: str, coworker: str)"
   ```

2. **Question Tool**: Gather information from colleagues
   ```
   "Ask question to coworker(question: str, context: str, coworker: str)"
   ```

**Collaboration Patterns:**

```python
# Sequential Pipeline: Research → Write → Edit
research_task = Task(description="Research...", agent=researcher)
write_task = Task(description="Write...", agent=writer, context=[research_task])
edit_task = Task(description="Edit...", agent=editor, context=[write_task])

# Hierarchical with specialist agents
manager = Agent(role="Manager", allow_delegation=True)
specialist = Agent(role="Specialist", allow_delegation=False)  # No re-delegation
```

---

## 3. Tool Definition

### @tool Decorator (Simple)

```python
from crewai.tools import tool

@tool("Search Web")
def search_web(query: str) -> str:
    """Search the web for information. Use this to find current data."""
    # Docstring is critical - agents use it to understand when to use the tool
    return search_api.search(query)
```

### BaseTool Class (Complex)

```python
from crewai.tools import BaseTool
from pydantic import BaseModel, Field
from typing import Type

class SearchInput(BaseModel):
    query: str = Field(..., description="The search query")
    max_results: int = Field(default=5, description="Maximum results to return")

class WebSearchTool(BaseTool):
    name: str = "web_search"
    description: str = "Search the web for current information"
    args_schema: Type[BaseModel] = SearchInput
    
    def _run(self, query: str, max_results: int = 5) -> str:
        return search_api.search(query, max_results)
    
    async def _arun(self, query: str, max_results: int = 5) -> str:
        return await search_api.async_search(query, max_results)
```

### Tool Caching

```python
def cache_even_results(args, result):
    """Only cache even-numbered results"""
    return int(result) % 2 == 0

my_tool.cache_function = cache_even_results
```

### Tool Assignment

```python
# Agent-level tools (available for all tasks)
agent = Agent(tools=[search_tool, calc_tool])

# Task-level tools (override agent defaults)
task = Task(
    description="...",
    agent=agent,
    tools=[specialized_tool]  # Only this tool available
)
```

### Built-in Tool Categories

- Web scraping: Firecrawl, Browserbase
- Document search: PDF, DOCX, JSON, CSV
- Code execution: CodeInterpreter
- Image generation: DALL-E
- Database: PostgreSQL queries

---

## 4. State & Memory

### Memory System

CrewAI provides four integrated memory types:

| Type | Storage | Purpose |
|------|---------|---------|
| **Short-Term** | ChromaDB (RAG) | Recent interactions and outcomes |
| **Long-Term** | SQLite3 | Insights/learnings across sessions |
| **Entity** | ChromaDB (RAG) | People, places, concepts encountered |
| **Contextual** | Combined | Maintains coherence across tasks |

**Basic Usage:**
```python
crew = Crew(
    agents=[...],
    tasks=[...],
    memory=True  # Enables all memory types
)
```

**Custom Storage:**
```python
import os
os.environ["CREWAI_STORAGE_DIR"] = "./my_project_storage"

crew = Crew(
    agents=[...],
    tasks=[...],
    memory=True,
    embedder={
        "provider": "ollama",
        "config": {"model": "mxbai-embed-large"}
    }
)
```

### Knowledge System

Knowledge provides static, pre-loaded domain information (vs. memory's interaction history).

```python
from crewai.knowledge.source import PDFKnowledgeSource

pdf_source = PDFKnowledgeSource(
    file_paths=["manual.pdf"],
    chunk_size=500,
    chunk_overlap=50
)

# Crew-level (shared across all agents)
crew = Crew(
    agents=[...],
    knowledge_sources=[pdf_source]
)

# Agent-level (isolated per agent)
agent = Agent(
    role="Expert",
    knowledge_sources=[specialized_source]
)
```

**Knowledge vs Memory:**
- **Knowledge**: Static reference material (PDFs, CSVs, docs)
- **Memory**: Dynamic interaction history and learnings

---

## 5. Human-in-the-Loop

### Task-Level Human Input

```python
task = Task(
    description="Write the final report",
    agent=writer,
    human_input=True  # Pause for human review
)
```

When `human_input=True`, execution pauses after task completion for human review. The crew sends a webhook notification with execution ID, task ID, and output.

### Flow-Based Human Feedback

```python
from crewai.flow.flow import Flow
from crewai.flow.human_feedback import human_feedback

class ReviewFlow(Flow):
    @start()
    @human_feedback(
        message="Do you approve this content?",
        emit=["approved", "rejected"],
        llm="gpt-4o-mini"
    )
    def review_step(self):
        return "content to review"
    
    @listen("approved")
    def on_approval(self, result):
        # Access result.feedback for human comments
        pass
    
    @listen("rejected")
    def on_rejection(self, result):
        # Retry with feedback
        pass
```

### Approval Workflow (Production)

```python
# Resume after human review
response = resume_endpoint(
    execution_id="...",
    task_id="...",
    human_feedback="Please add more detail about...",
    is_approve=False,  # Will retry with feedback
    webhook_urls=original_webhook_urls  # Must match kickoff
)
```

**Important**: Webhook URLs must be provided again in resume calls - they don't carry over automatically.

---

## 6. Flow Control (CrewAI Flows)

Flows provide event-driven workflow orchestration with state management.

### Basic Flow Structure

```python
from crewai.flow.flow import Flow, start, listen, router
from pydantic import BaseModel

class ArticleState(BaseModel):
    topic: str = ""
    research: str = ""
    article: str = ""

class ArticleFlow(Flow[ArticleState]):
    @start()
    def set_topic(self):
        self.state.topic = "AI Agents"
        return self.state.topic
    
    @listen(set_topic)
    def research(self, topic):
        # Receives output from set_topic
        self.state.research = do_research(topic)
        return self.state.research
    
    @listen(research)
    def write(self, research_results):
        self.state.article = write_article(research_results)
        return self.state.article

# Execute
flow = ArticleFlow()
result = flow.kickoff()
print(flow.state.article)
```

### Conditional Logic

```python
from crewai.flow.flow import or_, and_

class ConditionalFlow(Flow):
    @start()
    def start_a(self):
        return "A"
    
    @start()
    def start_b(self):
        return "B"
    
    # OR: Execute when ANY completes
    @listen(or_(start_a, start_b))
    def process_any(self, result):
        pass
    
    # AND: Execute when ALL complete
    @listen(and_(start_a, start_b))
    def process_all(self):
        pass
```

### Router Pattern

```python
class RouterFlow(Flow):
    @start()
    def analyze(self):
        return {"success": True, "data": "..."}
    
    @router(analyze)
    def route_decision(self, result):
        if result["success"]:
            return "success_path"
        return "failure_path"
    
    @listen("success_path")
    def handle_success(self):
        pass
    
    @listen("failure_path")
    def handle_failure(self):
        pass
```

### State Persistence

```python
from crewai.flow.persistence import persist

@persist  # Class-level: persist all state changes
class PersistentFlow(Flow[MyState]):
    @start()
    def begin(self):
        self.state.counter = 1  # Auto-saved to SQLite
```

### Crews Within Flows

```python
class CrewFlow(Flow):
    @start()
    def get_inputs(self):
        return {"topic": "AI"}
    
    @listen(get_inputs)
    def run_research_crew(self, inputs):
        result = ResearchCrew().crew().kickoff(inputs=inputs)
        self.state.research = result.raw
        return result
    
    @listen(run_research_crew)
    def run_writing_crew(self, research_result):
        return WritingCrew().crew().kickoff(
            inputs={"research": research_result.raw}
        )
```

---

## 7. Context Engineering

### Modifying Messages via Hooks

```python
from crewai.hooks import before_llm_call, after_llm_call, LLMCallHookContext

@before_llm_call
def add_context(context: LLMCallHookContext):
    # IMPORTANT: Modify in-place, don't replace
    context.messages.append({
        "role": "system",
        "content": "Always cite your sources."
    })

@before_llm_call
def validate_and_block(context: LLMCallHookContext):
    if "dangerous" in str(context.messages):
        return False  # Block execution
    return None  # Allow

@after_llm_call
def sanitize_response(context: LLMCallHookContext):
    if context.response and "SECRET" in context.response:
        return context.response.replace("SECRET", "[REDACTED]")
    return None  # Keep original
```

### Custom Prompt Templates

```python
agent = Agent(
    role="Assistant",
    goal="Help users",
    backstory="...",
    
    # Override default system prompt
    system_template="""
    You are a helpful assistant. 
    Always be concise and factual.
    Never make up information.
    """,
    
    # Custom input format (for model-specific needs)
    prompt_template="""
    <|start_header_id|>user<|end_header_id|>
    {input}
    <|eot_id|>
    """,
    
    # Disable system prompt separation (for o1-like models)
    use_system_prompt=False
)
```

### Token Management

CrewAI automatically handles token counting and context window management:

```python
agent = Agent(
    role="...",
    respect_context_window=True  # Auto-summarize when exceeding limits
)
```

### Verbose/Debug Modes

```python
# Agent-level
agent = Agent(verbose=True)

# Crew-level
crew = Crew(verbose=True)

# Inspect generated prompts
from crewai.utilities.prompts import Prompts
prompts = Prompts(agent)
# Examine what reaches the LLM
```

---

## 8. Event System

### Event Categories

CrewAI emits events across multiple domains:

- **Crew Events**: kickoff started/completed/failed
- **Agent Events**: execution started/completed, errors
- **Task Events**: started, completed, failed, evaluation
- **Tool Events**: started, finished, various error types
- **LLM Events**: call lifecycle, streaming chunks
- **Memory Events**: query, save, retrieval operations
- **Flow Events**: creation, execution, method events

### Custom Event Listener

```python
from crewai.utilities.events import BaseEventListener, crewai_event_bus
from crewai.utilities.events.base_event import BaseEvent

class MonitoringListener(BaseEventListener):
    def setup_listeners(self, crewai_event_bus):
        @crewai_event_bus.on("task_completed")
        def on_task_complete(source, event):
            print(f"Task completed: {event.task_id}")
            log_to_monitoring_system(event)
        
        @crewai_event_bus.on("tool_error")
        def on_tool_error(source, event):
            alert_on_call_team(event)

# Instantiate to register
listener = MonitoringListener()
```

### Scoped Event Handling (Testing)

```python
with crewai_event_bus.scoped_handlers():
    # Handlers registered here are auto-removed on exit
    @crewai_event_bus.on("task_completed")
    def temporary_handler(source, event):
        pass
    
    crew.kickoff()
# Handlers cleaned up
```

---

## 9. Testing

### CLI Testing

```bash
# Basic test (2 iterations, gpt-4o-mini)
crewai test

# Custom iterations and model
crewai test --n_iterations 5 --model gpt-4o
crewai test -n 5 -m gpt-4o
```

**Output metrics:**
- Task scores (1-10 scale)
- Agent attribution
- Run comparisons
- Execution time

### Training for Consistency

```bash
# Train with human feedback
crewai train -n 3  # 3 iterations
```

Training flow:
1. Agent produces output
2. Human provides feedback
3. Agent generates improved response
4. Feedback consolidated to `trained_agents_data.pkl`
5. Future runs apply learned suggestions

---

## 10. Limitations & Tradeoffs

### What CrewAI CANNOT Do

1. **No Low-Level Loop Control**
   - Cannot iterate through individual agent reasoning steps
   - Cannot pause mid-thought for inspection
   - No equivalent to PydanticAI's `.iter()` / `.next()`

2. **No Direct Message Manipulation**
   - Cannot directly access/modify the message history
   - Must use hooks to inject content
   - Cannot remove or reorder messages

3. **Limited Streaming Granularity**
   - Streams final output, not intermediate reasoning
   - No token-by-token streaming during tool calls

4. **Process Constraints**
   - Sequential: Strict ordering, no parallelism
   - Hierarchical: Requires manager overhead
   - No fine-grained inter-task parallelism

5. **Memory Limitations**
   - No cross-crew memory sharing (except external providers)
   - No selective memory clearing
   - No memory prioritization

6. **Testing Constraints**
   - CLI testing only supports OpenAI
   - No built-in mock/stub system
   - No deterministic replay

### Abstraction Level

CrewAI is **high-level by design**:

| Feature | CrewAI Approach | Low-Level Alternative |
|---------|-----------------|----------------------|
| Agent execution | Role/goal/backstory | Direct prompt control |
| Task dependencies | `context` parameter | Manual message passing |
| Collaboration | `allow_delegation` | Explicit agent calls |
| Memory | `memory=True` | Custom RAG implementation |
| Validation | Guardrails | Manual output checking |

### Design Constraints

1. **YAML-First Philosophy**: Code-based config supported but not recommended
2. **Pydantic Dependency**: All structured outputs require Pydantic models
3. **No Recursive Agents**: Agents cannot spawn sub-agents dynamically
4. **Single Manager**: Hierarchical process has one manager, not nested hierarchies
5. **Task Granularity**: Tasks are atomic - no sub-task decomposition

### When to Use CrewAI

**Good fit:**
- Multi-agent collaboration with defined roles
- Sequential or manager-delegated workflows
- YAML-configurable, production deployments
- Need memory/knowledge out of the box

**Poor fit:**
- Fine-grained execution control requirements
- Single-agent with complex tool orchestration
- Need to inspect/modify individual reasoning steps
- Custom streaming requirements

---

## Summary Comparison: CrewAI vs PydanticAI Patterns

| Feature | PydanticAI | CrewAI |
|---------|------------|--------|
| Loop control | `.iter()` / `.next()` | None (kickoff only) |
| Tool definition | `@agent.tool` decorator | `@tool` or `BaseTool` class |
| Structured output | Return type annotation | `output_pydantic` parameter |
| Retry signaling | `raise ModelRetry(msg)` | Guardrail return `(False, msg)` |
| Dependency injection | `RunContext[DepsType]` | Agent backstory + task context |
| Multi-agent | Agent calling agents | Crew with process type |
| Message access | Direct in context | Hooks only |
| Streaming | Full control | Output only |
| State management | Manual | Flow state (Pydantic) |

---

## Code Examples Summary

### Minimal Crew

```python
from crewai import Agent, Task, Crew

agent = Agent(
    role="Writer",
    goal="Write engaging content",
    backstory="Expert content creator"
)

task = Task(
    description="Write about {topic}",
    expected_output="A short article",
    agent=agent
)

crew = Crew(agents=[agent], tasks=[task])
result = crew.kickoff(inputs={"topic": "AI"})
print(result.raw)
```

### Production Crew with Features

```python
from crewai import Agent, Task, Crew, Process
from crewai.tools import tool
from pydantic import BaseModel

class Report(BaseModel):
    title: str
    findings: list[str]
    recommendation: str

@tool("Search")
def search(query: str) -> str:
    """Search for information"""
    return search_api(query)

researcher = Agent(
    role="Researcher",
    goal="Find accurate information",
    backstory="Senior research analyst",
    tools=[search],
    memory=True,
    verbose=True
)

analyst = Agent(
    role="Analyst", 
    goal="Synthesize findings",
    backstory="Expert data analyst"
)

research_task = Task(
    description="Research {topic}",
    expected_output="Key findings",
    agent=researcher
)

analysis_task = Task(
    description="Analyze and recommend",
    expected_output="Structured report",
    agent=analyst,
    context=[research_task],
    output_pydantic=Report,
    guardrail="Report must have at least 3 findings"
)

crew = Crew(
    agents=[researcher, analyst],
    tasks=[research_task, analysis_task],
    process=Process.sequential,
    memory=True,
    verbose=True
)

result = crew.kickoff(inputs={"topic": "AI agents in 2025"})
print(result.pydantic.recommendation)
```
Now let me compile the comprehensive continuation of the CrewAI research document based on all the information gathered.

---

# Appendix: CrewAI API Research (Continued)

## 11. Agent Deep Dive

### Complete Agent Configuration Reference

```python
from crewai import Agent

agent = Agent(
    # === CORE IDENTITY ===
    role="Senior Data Analyst",              # Required: Function/expertise
    goal="Extract insights from data",       # Required: Objective
    backstory="15 years of experience...",   # Required: Context/personality
    
    # === LLM CONFIGURATION ===
    llm="gpt-4o",                           # Primary model (default: gpt-4)
    function_calling_llm="gpt-4o-mini",     # Separate model for tools
    use_system_prompt=True,                 # Model compatibility (o1: False)
    
    # === EXECUTION CONTROL ===
    max_iter=20,                            # Max attempts before final answer
    max_rpm=None,                           # Rate limiting for API calls
    max_execution_time=None,                # Timeout in seconds
    max_retry_limit=2,                      # Retries on error
    verbose=False,                          # Detailed execution logs
    
    # === CODE EXECUTION ===
    allow_code_execution=False,             # Enable Python execution
    code_execution_mode="safe",             # "safe" (Docker) or "unsafe"
    
    # === REASONING & PLANNING ===
    reasoning=False,                        # Enable reflection/planning
    max_reasoning_attempts=None,            # None = unlimited planning
    
    # === MULTIMODAL ===
    multimodal=False,                       # Process images + text
    
    # === COLLABORATION ===
    allow_delegation=False,                 # Can delegate to other agents
    
    # === MEMORY & KNOWLEDGE ===
    memory=False,                           # Conversation history
    respect_context_window=True,            # Auto-summarize on overflow
    knowledge_sources=[],                   # Domain knowledge bases
    embedder={                              # Custom embeddings
        "provider": "openai",
        "config": {"model": "text-embedding-3-small"}
    },
    
    # === TOOLS ===
    tools=[search_tool, calc_tool],         # Available capabilities
    cache=True,                             # Cache tool results
    
    # === TEMPLATES (LOW-LEVEL CONTROL) ===
    system_template=None,                   # Override system prompt
    prompt_template=None,                   # Custom input format
    response_template=None,                 # Custom output format
    
    # === TIME AWARENESS ===
    inject_date=False,                      # Add current date to tasks
    date_format="%Y-%m-%d",                 # Date format string
    
    # === CALLBACKS ===
    step_callback=None                      # Function after each step
)
```

### Code Execution Modes

**Safe Mode (Docker-based):**
- Recommended for production
- Isolates execution environment
- Prevents system access
- Requires Docker installation

**Unsafe Mode:**
- Direct Python execution
- Full system access
- Only for trusted code
- Development/testing only

### Reasoning Capabilities

When `reasoning=True`, agents:
1. Reflect on the task before acting
2. Create detailed execution plans
3. Break down complex challenges
4. Iterate on strategy (up to `max_reasoning_attempts`)

**Use cases:**
- Complex multi-step problems
- Strategic decision-making
- Tasks requiring careful planning

### Multimodal Support

```python
analyst = Agent(
    role="Visual Data Analyst",
    goal="Analyze charts and graphs",
    backstory="Expert in visual analytics",
    multimodal=True  # Can process images
)

task = Task(
    description="Analyze this chart: [image URL]",
    agent=analyst
)
```

---

## 12. Crew Deep Dive

### Complete Crew Configuration

```python
from crewai import Crew, Process

crew = Crew(
    # === CORE COMPONENTS ===
    agents=[researcher, analyst, writer],
    tasks=[research_task, analysis_task, write_task],
    
    # === PROCESS TYPE ===
    process=Process.sequential,            # or Process.hierarchical
    
    # === HIERARCHICAL PROCESS (required if hierarchical) ===
    manager_llm="gpt-4o",                  # LLM for manager
    # OR
    manager_agent=custom_manager,          # Custom manager agent
    
    # === EXECUTION ===
    verbose=True,                          # Detailed logging
    max_rpm=None,                          # Rate limiting override
    
    # === PLANNING ===
    planning=False,                        # Enable pre-execution planning
    planning_llm="gpt-4o-mini",           # LLM for AgentPlanner
    
    # === MEMORY ===
    memory=False,                          # Enable all memory types
    embedder={                             # Memory embeddings
        "provider": "openai",
        "config": {"model": "text-embedding-3-small"}
    },
    
    # === KNOWLEDGE ===
    knowledge_sources=[],                  # Shared knowledge
    
    # === TOOL CONFIGURATION ===
    function_calling_llm=None,             # LLM for all agents' tools
    cache=True,                            # Tool result caching
    
    # === CALLBACKS ===
    step_callback=None,                    # After each agent step
    task_callback=None,                    # After each task
    
    # === STREAMING ===
    stream=False,                          # Real-time output
    
    # === LOGGING ===
    output_log_file=None,                  # Save as .txt or .json
    
    # === TELEMETRY ===
    share_crew=False                       # Anonymous usage data
)
```

### Process Types Comparison

| Aspect | Sequential | Hierarchical |
|--------|-----------|--------------|
| **Task order** | Predefined, fixed | Dynamic, manager decides |
| **Agent assignment** | Pre-assigned per task | Manager delegates based on capability |
| **Best for** | Linear workflows | Complex coordination needs |
| **Overhead** | Minimal | Manager adds latency |
| **Configuration** | Tasks only | Requires manager_llm or manager_agent |

### Planning Feature

```python
crew = Crew(
    agents=[...],
    tasks=[...],
    planning=True,                # Enable planning
    planning_llm="gpt-4o"        # Custom planner model
)
```

**How it works:**
1. Before execution, crew data sent to `AgentPlanner`
2. Planner creates step-by-step execution strategy
3. Plan added to each task description
4. Agents execute with enhanced guidance

**Default:** Uses `gpt-4o-mini` (requires OpenAI API key)

**Tradeoff:** Adds planning latency and OpenAI dependency

---

## 13. Memory System Deep Dive

### Memory Types Detailed

| Memory Type | Storage | Lifecycle | Purpose |
|-------------|---------|-----------|---------|
| **Short-Term** | ChromaDB (RAG) | Single execution | Recent interactions, current context |
| **Long-Term** | SQLite3 | Persistent | Learnings across sessions |
| **Entity** | ChromaDB (RAG) | Persistent | People, places, concepts |
| **Contextual** | Combined | Dynamic | Maintains coherence |

### Storage Architecture

**Default locations:**
```
macOS:   ~/Library/Application Support/CrewAI/{project}/
Linux:   ~/.local/share/CrewAI/{project}/
Windows: C:\Users\{user}\AppData\Local\CrewAI\{project}/
```

**Directory structure:**
```
{project}/
├── knowledge/          # Knowledge sources
├── short_term/         # Short-term memory (ChromaDB)
├── long_term/          # Long-term memory (SQLite)
├── entities/           # Entity memory (ChromaDB)
└── memory.db          # Main database
```

### Configuration Examples

**Custom storage location:**
```python
import os
os.environ["CREWAI_STORAGE_DIR"] = "./my_storage"
```

**Ollama embeddings (local/private):**
```python
crew = Crew(
    agents=[...],
    tasks=[...],
    memory=True,
    embedder={
        "provider": "ollama",
        "config": {"model": "mxbai-embed-large"}
    }
)
```

**Azure OpenAI embeddings:**
```python
embedder={
    "provider": "azure_openai",
    "config": {
        "model": "text-embedding-ada-002",
        "deployment_name": "my-embedding-deployment"
    }
}
```

### Memory Management

**Reset specific memory types:**
```python
crew.reset_memories(command_type='short')      # Clear short-term
crew.reset_memories(command_type='long')       # Clear long-term
crew.reset_memories(command_type='entity')     # Clear entities
crew.reset_memories(command_type='knowledge')  # Clear knowledge
```

**Monitor memory operations:**
```python
from crewai.utilities.events import BaseEventListener
from crewai.utilities.events.base_event import MemoryQueryCompletedEvent

class MemoryMonitor(BaseEventListener):
    def setup_listeners(self, crewai_event_bus):
        @crewai_event_bus.on(MemoryQueryCompletedEvent)
        def on_query(source, event):
            print(f"Query: {event.query}")
            print(f"Time: {event.query_time_ms}ms")
            print(f"Results: {len(event.results)}")

monitor = MemoryMonitor()
```

---

## 14. LLM Integration Deep Dive

### Supported Providers (25+)

| Provider | Models | Context | Special Features |
|----------|--------|---------|------------------|
| **OpenAI** | GPT-4o, o1, o3 | 128K | Function calling, vision |
| **Anthropic** | Claude 3.5 Sonnet/Opus | 200K | Extended Thinking, caching |
| **Google** | Gemini 1.5 Pro/Flash | 2M | Massive context |
| **AWS Bedrock** | Various | Varies | AWS integration |
| **Azure OpenAI** | GPT models | Varies | Enterprise features |
| **Ollama** | Local models | Varies | Privacy, no API costs |

### Configuration Methods

**1. Environment Variables (.env):**
```bash
MODEL=openai/gpt-4o
OPENAI_API_KEY=sk-...
```

**2. YAML Configuration:**
```yaml
agents:
  - role: Researcher
    llm: anthropic/claude-3-5-sonnet-20241022
```

**3. Python LLM Class:**
```python
from crewai import LLM

llm = LLM(
    model="anthropic/claude-3-5-sonnet-20241022",
    api_key="sk-ant-...",
    temperature=0.7,
    max_tokens=4000,
    timeout=30,
    seed=42  # For reproducibility
)

agent = Agent(
    role="Analyst",
    goal="...",
    backstory="...",
    llm=llm
)
```

### Provider-Specific Requirements

**Anthropic:**
- `max_tokens` is **required** (no default)
- Uses `stop_sequences` instead of `stop`
- Extended Thinking available for Sonnet 4+

**Google Gemini:**
- Requires `GOOGLE_API_KEY` OR `GOOGLE_CLOUD_PROJECT`
- Supports both API and Vertex AI
- 2M token context window

**AWS Bedrock:**
- Uses Converse API
- Requires `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
- Region configuration needed

**Ollama (Local):**
```python
llm = LLM(
    model="ollama/llama3.2",
    base_url="http://localhost:11434"
)
```

### Advanced Features

**Structured Outputs:**
```python
from pydantic import BaseModel

class Analysis(BaseModel):
    summary: str
    key_points: list[str]
    confidence: float

llm = LLM(
    model="openai/gpt-4o",
    response_format=Analysis
)
```

**Streaming:**
```python
llm = LLM(
    model="openai/gpt-4o",
    stream=True
)

crew = Crew(agents=[...], tasks=[...], stream=True)
for chunk in crew.kickoff():
    print(chunk.content, end="", flush=True)
```

**Async Operations:**
```python
result = await crew.akickoff(inputs={...})
```

---

## 15. Task Replay System

### How Replay Works

CrewAI automatically stores task outputs from the most recent `kickoff()` execution, allowing selective re-execution without re-fetching data or re-running earlier tasks.

**Key benefits:**
- Faster iteration on failing tasks
- Test modifications without full re-run
- Agents retain context from previous execution

### CLI Usage

**1. View available tasks:**
```bash
crewai log-tasks-outputs
```

**Output example:**
```
Task ID: abc123 - Research latest AI trends
Task ID: def456 - Write blog post
Task ID: ghi789 - Edit final draft
```

**2. Replay from specific task:**
```bash
crewai replay -t def456
```

This re-executes `def456` and all subsequent tasks.

### Programmatic Usage

```python
from crewai import Crew

crew = Crew(agents=[...], tasks=[...])

# Initial run
result = crew.kickoff(inputs={"topic": "AI"})

# Replay from specific task
try:
    replay_result = crew.replay(
        task_id="def456",
        inputs={"topic": "Machine Learning"}  # Optional: new inputs
    )
except Exception as e:
    print(f"Replay failed: {e}")
```

### Limitations

1. **Only latest kickoff**: Replay uses the most recent execution
2. **kickoff_for_each restriction**: Only last crew run is replayable
3. **Requires prior kickoff**: Must execute `kickoff()` before replay available
4. **Task ID dependency**: Must know exact task ID (use `log-tasks-outputs`)

### Known Issues

- Some users report replays executing multiple tasks instead of starting from specified task ([GitHub Issue #1776](https://github.com/crewAIInc/crewAI/issues/1776))
- Replay may not work correctly with `human_input=True` ([GitHub Issue #1774](https://github.com/crewAIInc/crewAI/issues/1774))

---

## 16. Built-in Tools Ecosystem

### Tool Categories

**File Operations:**
- `FileReadTool` - Read individual files
- `DirectoryReadTool` - List directory contents
- `DirectorySearchTool` - Search within directories

**Web & Search:**
- `SerperDevTool` - Google search via Serper API
- `ScrapeWebsiteTool` - Extract content from URLs
- `WebsiteSearchTool` - Search within websites
- `FirecrawlScrapeWebsiteTool` - Advanced scraping

**Document Processing:**
- `PDFSearchTool` - Search PDF documents
- `DOCXSearchTool` - Search Word documents
- `TXTSearchTool` - Search text files
- `MDXSearchTool` - Search Markdown files

**Structured Data:**
- `CSVSearchTool` - Query CSV files
- `JSONSearchTool` - Query JSON files
- `XMLSearchTool` - Query XML files

**Development:**
- `CodeInterpreterTool` - Execute Python code
- `CodeDocsSearchTool` - Search code documentation

**Image Generation:**
- `DallETool` - Generate images via DALL-E

**Database:**
- `PGSearchTool` - Query PostgreSQL databases

### SerperDevTool Example

**Installation:**
```bash
pip install 'crewai[tools]'
```

**Setup:**
1. Get API key from [serper.dev](https://serper.dev) (2,500 free searches/month)
2. Set environment variable:
```bash
export SERPER_API_KEY=your_key_here
```

**Usage:**
```python
from crewai_tools import SerperDevTool

search_tool = SerperDevTool(
    n=10,                    # Number of results
    country="us",            # Search region
    location="California"    # Specific location
)

researcher = Agent(
    role="Researcher",
    goal="Find current information",
    tools=[search_tool]
)
```

### Custom Tool with Caching

```python
from crewai.tools import tool

@tool("complex_calculation")
def calculate(input_data: str) -> str:
    """Perform complex calculations"""
    result = expensive_computation(input_data)
    return str(result)

# Add custom caching logic
def cache_only_even_results(args, result):
    return int(result) % 2 == 0

calculate.cache_function = cache_only_even_results
```

---

## 17. Testing & Training

### Testing

**Purpose:** Evaluate crew performance across multiple runs

**CLI Usage:**
```bash
# Basic test (2 iterations, gpt-4o-mini)
crewai test

# Custom configuration
crewai test -n 5 -m gpt-4o
```

**Output:**
- Task scores (1-10 scale)
- Average scores per task
- Overall crew performance
- Execution time
- Agent attribution

**Limitations:**
- Currently OpenAI models only
- No mock/stub system built-in

### Training

**Purpose:** Improve agents through human feedback

**Workflow:**
1. Agent produces initial output
2. Human provides feedback
3. Agent generates improved response
4. System consolidates learnings
5. Future runs apply feedback automatically

**CLI Usage:**
```bash
crewai train -n 3  # 3 training iterations
```

**Programmatic:**
```python
crew.train(
    n_iterations=3,
    inputs={"topic": "AI"},
    filename="trained_data.pkl"  # Optional
)
```

**Data Files:**

| File | Purpose | Lifecycle |
|------|---------|-----------|
| `training_data.pkl` | Raw feedback per iteration | Temporary (session-specific) |
| `trained_agents_data.pkl` | Consolidated suggestions | Persistent (applied to future runs) |

**Structure of `trained_agents_data.pkl`:**
```python
{
    "agent_role": {
        "suggestions": ["Always cite sources", "Use bullet points"],
        "quality_score": 8.5,
        "action_summary": "Improved factual accuracy"
    }
}
```

**How trained data is applied:**
Agents automatically load suggestions and append them to task prompts as mandatory instructions.

**Recommendation:** Use models with ≥7B parameters for reliable training (smaller models struggle with structured outputs).

---

## 18. CLI Reference

### Complete Command List

```bash
# === PROJECT MANAGEMENT ===
crewai create crew [NAME]           # Create new crew project
crewai create flow [NAME]           # Create new flow project

# === EXECUTION ===
crewai run                          # Execute crew or flow (auto-detect)
crewai chat                         # Interactive chat session (requires chat_llm)

# === TESTING & TRAINING ===
crewai test -n [ITER] -m [MODEL]   # Test crew performance
crewai train -n [ITER] -f [FILE]   # Train with human feedback

# === MEMORY MANAGEMENT ===
crewai reset-memories [OPTIONS]    # Clear memory
  --long                            # Clear long-term memory
  --short                           # Clear short-term memory
  --entities                        # Clear entity memory
  --kickoff-outputs                 # Clear kickoff outputs
  --knowledge                       # Clear knowledge storage

# === EXECUTION HISTORY ===
crewai log-tasks-outputs            # Show recent task results
crewai replay -t [TASK_ID]          # Replay from specific task

# === DEPLOYMENT (CrewAI AMP) ===
crewai login                        # Authenticate via device code
crewai deploy create                # Prepare deployment
crewai deploy push                  # Upload to cloud
crewai deploy status                # Check deployment status
crewai deploy logs                  # View execution logs
crewai deploy list                  # List deployments
crewai deploy remove                # Delete deployment

# === ORGANIZATION MANAGEMENT ===
crewai org list                     # List organizations
crewai org current                  # Show current org
crewai org switch [ID]              # Switch organization

# === CONFIGURATION ===
crewai config [COMMAND]             # Manage settings
  # Settings stored in ~/.config/crewai/settings.json

# === OBSERVABILITY ===
crewai traces [enable|disable|status]  # Control telemetry

# === UTILITY ===
crewai version                      # Show version
crewai version --tools              # Show tools version
```

---

## 19. Advanced Patterns

### Hierarchical Manager Customization

```python
from crewai import Agent, Crew, Process

# Option 1: Manager LLM
crew = Crew(
    agents=[specialist1, specialist2],
    tasks=[task1, task2],
    process=Process.hierarchical,
    manager_llm="gpt-4o"
)

# Option 2: Custom Manager Agent
manager = Agent(
    role="Project Manager",
    goal="Coordinate team efficiently",
    backstory="10 years managing AI projects",
    allow_delegation=True,  # Must be True
    verbose=True
)

crew = Crew(
    agents=[specialist1, specialist2],
    tasks=[task1, task2],
    process=Process.hierarchical,
    manager_agent=manager
)
```

**Best practices:**
- Manager should have `allow_delegation=True`
- Specialists should have `allow_delegation=False` (prevent re-delegation)
- Clear role differentiation prevents confusion

### Flow with Multiple Crews

```python
from crewai.flow.flow import Flow, start, listen

class MultiCrewFlow(Flow):
    @start()
    def gather_requirements(self):
        # Initial data collection
        return {"requirements": "Build AI dashboard"}
    
    @listen(gather_requirements)
    def research_phase(self, inputs):
        research_crew = ResearchCrew()
        result = research_crew.crew().kickoff(inputs=inputs)
        self.state.research = result.raw
        return result
    
    @listen(research_phase)
    def development_phase(self, research_result):
        dev_crew = DevelopmentCrew()
        result = dev_crew.crew().kickoff(
            inputs={"research": research_result.raw}
        )
        self.state.code = result.raw
        return result
    
    @listen(development_phase)
    def testing_phase(self, dev_result):
        qa_crew = QACrew()
        result = qa_crew.crew().kickoff(
            inputs={"code": dev_result.raw}
        )
        self.state.test_results = result.raw
        return result

# Execute
flow = MultiCrewFlow()
final_result = flow.kickoff()
```

### Event-Driven Monitoring

```python
from crewai.utilities.events import BaseEventListener, crewai_event_bus

class ProductionMonitor(BaseEventListener):
    def setup_listeners(self, crewai_event_bus):
        @crewai_event_bus.on("crew_kickoff_started")
        def on_start(source, event):
            log_to_monitoring(f"Crew {event.crew_id} started")
        
        @crewai_event_bus.on("task_completed")
        def on_task_complete(source, event):
            metrics.record("task_completion", {
                "task_id": event.task_id,
                "duration": event.duration_ms
            })
        
        @crewai_event_bus.on("tool_error")
        def on_tool_error(source, event):
            alert_team(f"Tool {event.tool_name} failed: {event.error}")
        
        @crewai_event_bus.on("llm_call_completed")
        def on_llm_call(source, event):
            track_token_usage(event.token_count)

monitor = ProductionMonitor()
```

### Fingerprinting for Audit Trails

```python
crew = Crew(agents=[...], tasks=[...])

# Access component fingerprints
for agent in crew.agents:
    fp = agent.security_config.fingerprint
    print(f"Agent: {agent.role}")
    print(f"  UUID: {fp.uuid}")
    print(f"  Created: {fp.created_at}")
    
    # Add metadata
    fp.metadata = {
        "version": "2.0",
        "owner": "data-science-team",
        "compliance": "SOC2"
    }

# Deterministic fingerprints
from crewai.utilities.fingerprint import Fingerprint
fp = Fingerprint.generate(seed="my-consistent-seed")
```

---

## 20. Limitations & Design Constraints Summary

### What CrewAI Cannot Do

| Limitation | Impact | Workaround |
|------------|--------|------------|
| **No mid-execution pause** | Can't inspect reasoning steps | Use hooks to observe LLM calls |
| **No message history access** | Can't directly view/modify messages | Use `@before_llm_call` hooks |
| **No token-level streaming** | Can't stream tool execution | Only final outputs stream |
| **No fine-grained parallelism** | Tasks run sequentially or via manager | Use async flows |
| **No cross-crew memory** | Crews have isolated memory | Use external_memory with shared provider |
| **No sub-task decomposition** | Tasks are atomic | Break into multiple tasks |
| **No recursive agents** | Agents can't spawn sub-agents | Use hierarchical process |

### Design Philosophy

CrewAI is **intentionally high-level**:

| Design Choice | Rationale |
|---------------|-----------|
| YAML-first configuration | Team collaboration, reproducibility |
| Role-based agents | Clear responsibility boundaries |
| Crew orchestration | Multi-agent focus (not single-agent optimization) |
| Built-in memory/knowledge | Batteries-included production readiness |
| Sequential/Hierarchical only | Predictable execution patterns |

### When NOT to Use CrewAI

**Poor fit scenarios:**
- Need low-level control over every LLM interaction
- Single-agent with complex branching logic
- Custom streaming requirements
- Direct message history manipulation
- Real-time token-by-token processing

**Better alternatives:**
- **LangChain/LangGraph**: Low-level control, graph-based workflows
- **PydanticAI**: Fine-grained iteration, single-agent focus
- **Raw LLM SDKs**: Maximum control, minimal abstraction

---

## Sources

- [CrewAI Tasks Documentation](https://docs.crewai.com/concepts/tasks)
- [CrewAI Flows Documentation](https://docs.crewai.com/concepts/flows)
- [CrewAI Knowledge System](https://docs.crewai.com/concepts/knowledge)
- [CrewAI Execution Hooks](https://docs.crewai.com/en/learn/execution-hooks)
- [CrewAI LLM Call Hooks](https://docs.crewai.com/en/learn/llm-hooks)
- [CrewAI Tool Call Hooks](https://docs.crewai.com/en/learn/tool-hooks)
- [CrewAI Prompt Customization](https://docs.crewai.com/en/guides/advanced/customizing-prompts)
- [CrewAI GitHub Repository](https://github.com/crewAIInc/crewAI)
- [CrewAI Agents Documentation](https://docs.crewai.com/concepts/agents)
- [CrewAI Crews Documentation](https://docs.crewai.com/concepts/crews)
- [CrewAI Memory System](https://docs.crewai.com/concepts/memory)
- [CrewAI Processes Documentation](https://docs.crewai.com/concepts/processes)
- [CrewAI Tools Documentation](https://docs.crewai.com/concepts/tools)
- [CrewAI Collaboration](https://docs.crewai.com/concepts/collaboration)
- [CrewAI Human-in-the-Loop](https://docs.crewai.com/en/learn/human-in-the-loop)
- [CrewAI Testing](https://docs.crewai.com/en/concepts/testing)
- [CrewAI Training](https://docs.crewai.com/en/concepts/training)
- [CrewAI LLM Configuration](https://docs.crewai.com/en/concepts/llms)
- [CrewAI Planning Feature](https://docs.crewai.com/concepts/planning)
- [CrewAI CLI Documentation](https://docs.crewai.com/en/concepts/cli)
- [CrewAI Fingerprinting](https://docs.crewai.com/en/guides/advanced/fingerprinting)
- [CrewAI Hallucination Guardrail](https://docs.crewai.com/en/enterprise/features/hallucination-guardrail)
- [CrewAI Task Replay](https://docs.crewai.com/en/learn/replay-tasks-from-latest-crew-kickoff)
- [Replay Tasks Feature - CrewAI](https://docs.crewai.com/en/learn/replay-tasks-from-latest-crew-kickoff)
- [CrewAI Tools - GeeksforGeeks](https://www.geeksforgeeks.org/artificial-intelligence/crewai-tools/)
- [Google Serper Search Tool](https://docs.crewai.com/tools/SerperDevTool/)

---

This completes the comprehensive research on the CrewAI API surface. The document covers all major aspects of the framework from core concepts through advanced patterns, testing, deployment, and known limitations.
