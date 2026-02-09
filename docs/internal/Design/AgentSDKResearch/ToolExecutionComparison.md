# Tool Execution Patterns: Comprehensive SDK Comparison

**Analysis Date:** February 2026
**Purpose:** Detailed comparison of tool definition, execution, error handling, and approval patterns across 8 agent frameworks to inform Yrden's Swift implementation.

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Tool Definition Patterns](#tool-definition-patterns)
3. [Schema Generation](#schema-generation)
4. [Execution Control](#execution-control)
5. [Error Handling Deep Dive](#error-handling-deep-dive)
6. [Approval Mechanisms](#approval-mechanisms)
7. [Context Access Patterns](#context-access-patterns)
8. [Result Handling](#result-handling)
9. [Timeout & Resource Management](#timeout--resource-management)
10. [Complete Tool Implementation Examples](#complete-tool-implementation-examples)
11. [Best Practices & Anti-Patterns](#best-practices--anti-patterns)
12. [Yrden Design Recommendations](#yrden-design-recommendations)

---

## Executive Summary

After analyzing 8 agent frameworks (PydanticAI, LangGraph, AutoGen, CrewAI, Claude Agent SDK, OpenAI Agents SDK, Vercel AI SDK, Cloudflare Agents), three dominant architectural patterns emerged:

### Pattern 1: Decorator-Based (Python)
**Used by:** PydanticAI, CrewAI, AutoGen
**Strength:** Minimal boilerplate, automatic schema generation
**Weakness:** Runtime type checking only

```python
@agent.tool(retries=3)
async def search(ctx: RunContext[Deps], query: str, limit: int = 10) -> str:
    """Search the knowledge base."""
    return await ctx.deps.search_client.search(query, limit)
```

### Pattern 2: Class-Based with Schema Objects (TypeScript)
**Used by:** Vercel AI SDK, Cloudflare Agents
**Strength:** Explicit schemas, strong TypeScript integration
**Weakness:** More verbose, separate schema definition

```typescript
const searchTool = tool({
  description: 'Search the knowledge base',
  parameters: z.object({
    query: z.string(),
    limit: z.number().optional()
  }),
  execute: async ({ query, limit = 10 }) => { ... }
});
```

### Pattern 3: Graph-Based with Node Abstraction (Python)
**Used by:** LangGraph
**Strength:** Complex workflow orchestration, parallel execution
**Weakness:** Steep learning curve, overkill for simple agents

```python
tool_node = ToolNode(tools, handle_tool_errors=True)
graph.add_conditional_edges("agent", tools_condition)
```

### Recommended Pattern for Yrden: Protocol-Based with Macros

```swift
protocol Tool<Context> {
    associatedtype Arguments: SchemaType
    associatedtype Output

    var name: String { get }
    var description: String { get }

    func call(context: Context, arguments: Arguments) async throws -> Output
}

@Schema
struct SearchArguments {
    @Guide(description: "Natural language search query")
    let query: String

    @Guide(description: "Maximum results", .range(1...100))
    let limit: Int
}

struct SearchTool: Tool {
    typealias Arguments = SearchArguments
    typealias Output = String

    let name = "search"
    let description = "Search the knowledge base"

    func call(context: RunContext<Deps>, arguments: SearchArguments) async throws -> String {
        return try await context.deps.searchClient.search(arguments.query, limit: arguments.limit)
    }
}
```

**Why this pattern:**
- Compile-time type safety via Swift macros
- Idiomatic Swift (protocols, not decorators)
- Explicit dependencies via `RunContext<Deps>`
- Full control over execution flow

---

## Tool Definition Patterns

### 1. PydanticAI: Decorator-Based with Type Inference

**Core Pattern:**
```python
from pydantic_ai import Agent, RunContext
from pydantic import BaseModel

class SearchDeps:
    def __init__(self, api_key: str):
        self.search_client = SearchClient(api_key)

agent = Agent[SearchDeps, str]('anthropic:claude-sonnet')

@agent.tool(retries=3)
async def search(ctx: RunContext[SearchDeps], query: str, limit: int = 10) -> str:
    """Search the knowledge base with natural language queries.

    Args:
        query: The search query
        limit: Maximum number of results
    """
    results = await ctx.deps.search_client.search(query, limit)
    return format_results(results)

@agent.tool
async def calculate(ctx: RunContext[SearchDeps], expression: str) -> float:
    """Evaluate a mathematical expression safely."""
    # Safe eval implementation
    return safe_eval(expression)
```

**Key Features:**
- **Automatic schema generation** from type hints
- **Dependency injection** via `RunContext[DepsType]`
- **Docstring becomes tool description**
- **Retry configuration** at tool level
- **Async/sync support** (framework handles both)

**Schema Generation:**
PydanticAI introspects the function signature:
```python
# From this:
async def search(ctx: RunContext[SearchDeps], query: str, limit: int = 10) -> str:

# Generates:
{
  "type": "object",
  "properties": {
    "query": {"type": "string"},
    "limit": {"type": "integer", "default": 10}
  },
  "required": ["query"]
}
```

**Strengths:**
- Minimal boilerplate
- Type-safe at runtime (Pydantic validates)
- Clear separation of logic and schema
- Excellent for iterative development

**Weaknesses:**
- Runtime type checking only
- No compile-time guarantees
- Magic via decorators (less explicit)

---

### 2. LangGraph: Node-Based Tool Execution

**Core Pattern:**
```python
from langgraph.prebuilt import ToolNode
from langchain_core.tools import tool

@tool
def search(query: str, limit: int = 10) -> str:
    """Search the knowledge base."""
    return search_client.search(query, limit)

@tool
def calculate(expression: str) -> float:
    """Evaluate a mathematical expression."""
    return safe_eval(expression)

# Create tool node for parallel execution
tools = [search, calculate]
tool_node = ToolNode(tools, handle_tool_errors=True)

# Add to graph with conditional routing
graph.add_conditional_edges(
    "agent",
    tools_condition,  # Routes to tools if tool_calls present
    {
        "tools": "tools_node",
        "end": END
    }
)
```

**Error Handling Configuration:**
```python
# Option 1: Catch all errors
tool_node = ToolNode(tools, handle_tool_errors=True)

# Option 2: Catch specific errors
tool_node = ToolNode(
    tools,
    handle_tool_errors=[ValueError, KeyError],
    fallback_message="Tool execution failed, please retry with different parameters."
)

# Option 3: Custom error handler
def custom_error_handler(error: Exception, tool_input: dict) -> str:
    logger.error(f"Tool failed: {error}")
    return f"Error: {error}. Suggested action: {suggest_fix(error)}"

tool_node = ToolNode(tools, handle_tool_errors=custom_error_handler)
```

**Parallel Execution:**
```python
# ToolNode automatically executes all tool_calls in parallel
# If LLM returns:
# tool_calls = [
#     {"name": "search", "args": {"query": "Python"}},
#     {"name": "search", "args": {"query": "Swift"}},
#     {"name": "calculate", "args": {"expression": "2+2"}}
# ]
# All 3 execute concurrently via asyncio.gather()
```

**Strengths:**
- Built-in parallel execution
- Flexible error handling strategies
- Integrates with graph-based flow control
- Supports tool call reflection (LLM sees error messages)

**Weaknesses:**
- Requires understanding graphs, nodes, edges
- High boilerplate for simple agents
- Tool definition separate from agent definition
- Less control over individual tool execution

---

### 3. AutoGen: FunctionTool Wrapper with Code Execution

**Core Pattern:**
```python
from autogen import FunctionTool, ConversableAgent, CodeExecutorConfig

# Standard function tools
search_tool = FunctionTool(
    name="search",
    description="Search the knowledge base",
    func=lambda query, limit=10: search_client.search(query, limit)
)

# Code execution tool (Docker-based for safety)
code_executor_config = CodeExecutorConfig(
    executor=DockerCommandLineCodeExecutor(
        image="python:3-slim",
        timeout=30,
        work_dir="workspace"
    )
)

agent = ConversableAgent(
    name="assistant",
    llm_config=llm_config,
    tools=[search_tool],
    code_execution_config=code_executor_config
)
```

**Reflection Pattern:**
```python
# AutoGen's unique "reflection" mechanism
# When a tool fails, the agent automatically receives feedback

def risky_operation(file_path: str) -> str:
    """Delete a file."""
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"File {file_path} does not exist")
    os.remove(file_path)
    return f"Deleted {file_path}"

risky_tool = FunctionTool(
    name="delete_file",
    description="Delete a file by path",
    func=risky_operation
)

# On error, AutoGen:
# 1. Catches the exception
# 2. Sends error message back to LLM
# 3. LLM can retry with corrected parameters
# Example conversation:
# LLM: {"name": "delete_file", "args": {"file_path": "/nonexistent"}}
# Tool: Error: File /nonexistent does not exist
# LLM: Let me check the file path first...
```

**Code Execution Safety:**
```python
# Docker isolation prevents malicious code
code_executor = DockerCommandLineCodeExecutor(
    image="python:3-slim",
    timeout=30,  # Kill after 30 seconds
    work_dir="workspace",  # Isolated filesystem
    bind_dir="/tmp/autogen_workdir"  # Host directory mapping
)

# Example malicious code that's safely contained:
# ```python
# import os
# os.system("rm -rf /")  # Only affects Docker container
# ```
```

**Strengths:**
- Safe code execution via Docker
- Automatic reflection (error feedback to LLM)
- Simple function-to-tool conversion
- Multi-agent communication built-in

**Weaknesses:**
- Docker dependency for code execution
- Limited schema control
- No fine-grained retry configuration
- Less type-safe than Pydantic-based approaches

---

### 4. CrewAI: Decorator and Class-Based Hybrid

**Core Pattern:**
```python
from crewai import Agent, Task, Crew
from crewai.tools import tool, BaseTool
from pydantic import BaseModel, Field

# Pattern 1: Decorator-based (simple)
@tool("Search Tool")
def search(query: str, limit: int = 10) -> str:
    """Search the knowledge base."""
    return search_client.search(query, limit)

# Pattern 2: Class-based (advanced)
class SearchInput(BaseModel):
    query: str = Field(description="Search query")
    limit: int = Field(default=10, ge=1, le=100, description="Max results")

class SearchTool(BaseTool):
    name: str = "search"
    description: str = "Search the knowledge base"
    args_schema: type[BaseModel] = SearchInput

    def _run(self, query: str, limit: int = 10) -> str:
        """Synchronous execution."""
        return search_client.search(query, limit)

    async def _arun(self, query: str, limit: int = 10) -> str:
        """Asynchronous execution (optional)."""
        return await search_client.async_search(query, limit)
```

**Guardrails Integration:**
```python
from crewai import Agent, Guardrail

def validate_search_query(query: str) -> str:
    """Ensure query is safe and reasonable."""
    if len(query) < 3:
        raise ValueError("Query too short, must be at least 3 characters")
    if any(blocked in query.lower() for blocked in BLOCKED_TERMS):
        raise ValueError("Query contains blocked terms")
    return query

search_guardrail = Guardrail(
    name="search_validation",
    description="Validates search queries",
    validation_fn=validate_search_query
)

agent = Agent(
    role="researcher",
    tools=[search_tool],
    guardrails=[search_guardrail]  # Applied before tool execution
)
```

**Tool Collaboration:**
```python
# CrewAI's unique feature: tools can use other agents
researcher = Agent(
    role="researcher",
    tools=[search_tool, web_scraper_tool]
)

writer = Agent(
    role="writer",
    tools=[format_tool, spell_check_tool]
)

# Task dependencies create tool chains
research_task = Task(
    description="Research Python frameworks",
    agent=researcher,
    expected_output="Comprehensive research report"
)

writing_task = Task(
    description="Write blog post based on research",
    agent=writer,
    context=[research_task],  # Can access research_task's output as input
    expected_output="Polished blog post"
)

crew = Crew(agents=[researcher, writer], tasks=[research_task, writing_task])
```

**Strengths:**
- Dual definition style (simple decorator or rich class)
- Built-in guardrails for validation
- Sync/async variants
- Multi-agent collaboration patterns

**Weaknesses:**
- Two competing patterns can be confusing
- Guardrails are separate from tools (not integrated)
- Less control over retry logic
- Pydantic schemas required for class-based tools

---

### 5. Claude Agent SDK: Minimal with MCP Integration

**Core Pattern:**
```python
from claude_agent_sdk import Agent, tool
from mcp import MCPClient

# Local tool definition
@tool
async def search(query: str, limit: int = 10) -> str:
    """Search the knowledge base."""
    return await search_client.search(query, limit)

# MCP tool discovery
mcp_client = await MCPClient.connect(
    transport=StdioTransport(
        command="uvx",
        args=["mcp-server-filesystem", "/Users/me/documents"]
    )
)

mcp_tools = await mcp_client.list_tools()

# Combine local and MCP tools
agent = Agent(
    api_key="...",
    tools=[search] + mcp_tools
)
```

**Permission Callbacks:**
```python
from claude_agent_sdk import PermissionResultAllow, PermissionResultDeny

async def permission_handler(tool_name: str, input_data: dict, context: dict) -> PermissionResult:
    """Fine-grained control over tool execution."""

    if tool_name == "delete_file":
        # Require human approval for destructive actions
        approved = await request_human_approval(f"Delete {input_data['path']}?")
        if not approved:
            return PermissionResultDeny(reason="User denied deletion")

    if tool_name == "search":
        # Inject additional constraints
        input_data["limit"] = min(input_data.get("limit", 10), 20)  # Cap at 20
        return PermissionResultAllow(updated_input=input_data)

    return PermissionResultAllow()

agent = Agent(
    api_key="...",
    tools=[search, delete_file],
    permission_callback=permission_handler
)
```

**MCP Tool Types:**
```python
# MCP tools are dynamically discovered, not statically defined
# Example from mcp-server-filesystem:
# {
#   "name": "read_file",
#   "description": "Read contents of a file",
#   "inputSchema": {
#     "type": "object",
#     "properties": {
#       "path": {"type": "string"}
#     },
#     "required": ["path"]
#   }
# }

# Claude Agent SDK automatically converts these to callable tools
response = await agent.run("Read the contents of README.md")
# Internally calls mcp_client.call_tool("read_file", {"path": "README.md"})
```

**Strengths:**
- Seamless MCP integration (dynamic tool discovery)
- Simple permission callback pattern
- Minimal boilerplate for basic tools
- Anthropic-native (optimized for Claude models)

**Weaknesses:**
- Limited retry control
- No built-in validation
- MCP dependency for advanced features
- Less mature than other frameworks

---

### 6. OpenAI Agents SDK: Approval-First with State Management

**Core Pattern:**
```python
from openai_agents import Agent, function_tool, RunContext

@function_tool(needs_approval=True)
async def delete_file(ctx: RunContext, path: str) -> str:
    """Delete a file permanently."""
    os.remove(path)
    return f"Deleted {path}"

@function_tool
async def search(ctx: RunContext, query: str) -> str:
    """Search the knowledge base."""
    return await ctx.deps.search_client.search(query)

agent = Agent(
    model="gpt-4o",
    tools=[search, delete_file]
)
```

**Interruption and State Management:**
```python
from openai_agents import Agent, Interruption

# Run until interruption
run = await agent.run("Delete old log files", stream=False)

if run.status == "interrupted":
    # Get pending tool calls
    pending = run.interruptions[0]
    print(f"Tool: {pending.tool_name}")
    print(f"Args: {pending.arguments}")

    # User reviews and approves
    approved = input("Approve? (y/n): ") == "y"

    if approved:
        # Resume execution
        run = await agent.resume(run.id, approved=True)
    else:
        # Cancel and provide feedback
        run = await agent.resume(
            run.id,
            approved=False,
            feedback="User denied file deletion. Please suggest safer alternatives."
        )

# Serialize state for later resumption
state = run.to_dict()
# Save to database...

# Resume from state later (even after restart)
restored_run = Agent.from_dict(state)
run = await agent.resume(restored_run.id, approved=True)
```

**Typed Context:**
```python
from dataclasses import dataclass

@dataclass
class AgentDeps:
    user_id: str
    search_client: SearchClient
    auth_token: str

@function_tool
async def search(ctx: RunContext[AgentDeps], query: str) -> str:
    """Search with user context."""
    # Type-safe access to dependencies
    results = await ctx.deps.search_client.search(
        query=query,
        user=ctx.deps.user_id,
        auth=ctx.deps.auth_token
    )
    return results

# Agent run with typed deps
deps = AgentDeps(
    user_id="user_123",
    search_client=SearchClient(),
    auth_token="..."
)
run = await agent.run("Search for Python", deps=deps)
```

**Strengths:**
- Built-in approval workflow (no custom logic needed)
- State serialization for persistence
- Typed context access
- Simple interruption model

**Weaknesses:**
- OpenAI-specific (no multi-provider support)
- Requires async/await everywhere
- Limited retry customization
- No parallel tool execution

---

### 7. Vercel AI SDK: Zod Schemas with Step Callbacks

**Core Pattern:**
```typescript
import { tool } from 'ai';
import { z } from 'zod';

const searchTool = tool({
  description: 'Search the knowledge base',
  parameters: z.object({
    query: z.string().describe('Natural language search query'),
    limit: z.number().min(1).max(100).optional().default(10)
  }),
  execute: async ({ query, limit }) => {
    const results = await searchClient.search(query, limit);
    return { results, count: results.length };
  }
});

const agent = createAgent({
  model: anthropic('claude-sonnet-4'),
  tools: { search: searchTool },
  maxSteps: 10
});
```

**Dynamic Tool Phasing:**
```typescript
const agent = createAgent({
  model: anthropic('claude-sonnet-4'),
  tools: {
    search: searchTool,
    calculate: calculateTool,
    delete: deleteTool
  },
  prepareStep: async ({ stepNumber, tools }) => {
    // Phase 1: Research (steps 1-5)
    if (stepNumber <= 5) {
      return {
        activeTools: ['search', 'calculate']  // Exclude 'delete'
      };
    }

    // Phase 2: Action (steps 6+)
    return {
      activeTools: Object.keys(tools)  // All tools available
    };
  }
});
```

**Approval Integration:**
```typescript
const deleteTool = tool({
  description: 'Delete a file',
  parameters: z.object({
    path: z.string()
  }),
  execute: async ({ path }, { needsApproval }) => {
    if (needsApproval) {
      const approved = await requestUserApproval(`Delete ${path}?`);
      if (!approved) {
        throw new Error('User denied deletion');
      }
    }
    fs.unlinkSync(path);
    return { deleted: path };
  }
});

const agent = createAgent({
  model: anthropic('claude-sonnet-4'),
  tools: { delete: deleteTool },
  experimental_needsApproval: (tool) => tool.name === 'delete'
});
```

**Streaming Tool Results:**
```typescript
const result = await streamAgent({
  model: anthropic('claude-sonnet-4'),
  tools: { search: searchTool },
  prompt: 'Search for Python frameworks'
});

for await (const part of result.fullStream) {
  switch (part.type) {
    case 'tool-call':
      console.log(`Calling ${part.toolName} with`, part.args);
      break;
    case 'tool-result':
      console.log(`Result from ${part.toolName}:`, part.result);
      break;
    case 'text-delta':
      process.stdout.write(part.textDelta);
      break;
  }
}
```

**Strengths:**
- Excellent Zod integration (runtime + TypeScript types)
- Dynamic tool phasing (`prepareStep` callback)
- Built-in streaming with typed events
- `needsApproval` flag for selective approval

**Weaknesses:**
- TypeScript-only
- Limited retry customization (global `maxSteps` only)
- No dependency injection pattern
- Approval is per-tool, not per-call

---

### 8. Cloudflare Agents: Durable Objects with State Sync

**Core Pattern:**
```typescript
import { Agent, Tool } from '@cloudflare/agents';

class SearchTool extends Tool {
  name = 'search';
  description = 'Search the knowledge base';

  parameters = {
    type: 'object',
    properties: {
      query: { type: 'string' },
      limit: { type: 'number', default: 10 }
    },
    required: ['query']
  } as const;

  async execute(args: { query: string; limit: number }, state: AgentState) {
    const results = await this.env.SEARCH_INDEX.search(args.query, args.limit);
    return results;
  }
}

class MyAgent extends Agent<Env, AgentState> {
  initialState = {
    conversationHistory: [],
    toolCallCount: 0
  };

  tools = [new SearchTool()];
}
```

**WebSocket State Synchronization:**
```typescript
// Cloudflare's unique feature: real-time state sync via WebSockets
// Client (browser)
const ws = new WebSocket('wss://agent.example.com/session/123');

ws.onmessage = (event) => {
  const update = JSON.parse(event.data);
  if (update.type === 'state') {
    // Agent state changed (tool call, new message, etc.)
    console.log('Agent state:', update.state);
  }
  if (update.type === 'tool_call') {
    // Request human approval
    const approved = confirm(`Approve ${update.tool}?`);
    ws.send(JSON.stringify({ type: 'approval', approved }));
  }
};

// Server (Durable Object)
class MyAgent extends Agent<Env, AgentState> {
  async handleWebSocket(ws: WebSocket) {
    ws.accept();

    // Send state updates automatically
    this.on('state-change', (newState) => {
      ws.send(JSON.stringify({ type: 'state', state: newState }));
    });

    // Request approval for destructive tools
    this.on('before-tool-call', async (call) => {
      if (call.tool === 'delete') {
        ws.send(JSON.stringify({ type: 'tool_call', tool: call.tool, args: call.args }));
        const approval = await this.waitForMessage(ws, 'approval');
        if (!approval.approved) {
          throw new Error('User denied tool execution');
        }
      }
    });
  }
}
```

**Persistent State:**
```typescript
class MyAgent extends Agent<Env, AgentState> {
  initialState = { count: 0 };

  async handleToolCall(call: ToolCall) {
    // State persists across requests (Durable Object storage)
    this.state.count++;

    // Execute tool
    const result = await this.executeTool(call);

    // State automatically saved
    return result;
  }
}

// Agent state persists across:
// - Multiple requests
// - Server restarts
// - Long-running conversations
```

**Strengths:**
- Built-in state persistence (Durable Objects)
- Real-time WebSocket synchronization
- Edge deployment (low latency)
- Automatic state management

**Weaknesses:**
- Cloudflare-specific (vendor lock-in)
- Limited to Cloudflare Workers runtime
- No multi-provider support
- Manual JSON schema definition

---

## Schema Generation

| Framework | Method | Type Safety | Validation |
|-----------|--------|-------------|------------|
| **PydanticAI** | Automatic from type hints | Runtime (Pydantic) | ✅ Rich constraints |
| **LangGraph** | Automatic from type hints | Runtime (Pydantic) | ✅ Rich constraints |
| **AutoGen** | Inferred from function signature | ❌ Weak | ❌ Minimal |
| **CrewAI** | Decorator (basic) or Pydantic (class) | Runtime (Pydantic) | ✅ Rich constraints |
| **Claude SDK** | Automatic from type hints | ❌ Weak | ❌ Minimal |
| **OpenAI SDK** | Automatic from type hints | Runtime (via typing) | ⚠️ Limited |
| **Vercel AI** | Zod schemas | Compile-time (TypeScript) + Runtime | ✅ Rich constraints |
| **Cloudflare** | Manual JSON Schema | Compile-time (TypeScript) | ⚠️ Manual validation |

### Schema Generation Examples

**PydanticAI (Automatic, Pydantic-based):**
```python
from pydantic import BaseModel, Field

class SearchArgs(BaseModel):
    query: str = Field(description="Search query")
    limit: int = Field(default=10, ge=1, le=100)
    category: Literal["docs", "code", "all"] = "all"

@agent.tool
async def search(ctx: RunContext[Deps], args: SearchArgs) -> str:
    # Schema automatically generated:
    # {
    #   "type": "object",
    #   "properties": {
    #     "query": {"type": "string", "description": "Search query"},
    #     "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 10},
    #     "category": {"type": "string", "enum": ["docs", "code", "all"], "default": "all"}
    #   },
    #   "required": ["query"]
    # }
    return await ctx.deps.search(args.query, args.limit, args.category)
```

**Vercel AI SDK (Zod-based):**
```typescript
import { z } from 'zod';

const searchSchema = z.object({
  query: z.string().describe('Search query'),
  limit: z.number().int().min(1).max(100).default(10),
  category: z.enum(['docs', 'code', 'all']).default('all')
});

const searchTool = tool({
  description: 'Search the knowledge base',
  parameters: searchSchema,
  execute: async ({ query, limit, category }) => {
    // TypeScript infers: { query: string, limit: number, category: 'docs' | 'code' | 'all' }
    return await search(query, limit, category);
  }
});
```

**Cloudflare Agents (Manual JSON Schema):**
```typescript
class SearchTool extends Tool {
  parameters = {
    type: 'object',
    properties: {
      query: {
        type: 'string',
        description: 'Search query'
      },
      limit: {
        type: 'number',
        minimum: 1,
        maximum: 100,
        default: 10
      },
      category: {
        type: 'string',
        enum: ['docs', 'code', 'all'],
        default: 'all'
      }
    },
    required: ['query']
  } as const;

  async execute(args: { query: string; limit: number; category: string }) {
    // Manual type annotation required
    return await search(args.query, args.limit, args.category);
  }
}
```

### Validation Approaches

**1. Provider-Side Validation (All Frameworks)**
LLM provider enforces schema before calling tool:
```json
// Request to Anthropic
{
  "tool_choice": {"type": "tool", "name": "search"},
  "tools": [{
    "name": "search",
    "input_schema": {
      "type": "object",
      "properties": {
        "limit": {"type": "integer", "minimum": 1, "maximum": 100}
      }
    }
  }]
}

// Provider validates: limit must be integer in [1, 100]
// If LLM returns limit=200, provider rejects before framework sees it
```

**2. Framework-Side Validation**

**PydanticAI (Strict):**
```python
class SearchArgs(BaseModel):
    query: str = Field(min_length=3, max_length=200)
    limit: int = Field(ge=1, le=100)

    @field_validator('query')
    def validate_query(cls, v):
        if any(blocked in v.lower() for blocked in BLOCKED_TERMS):
            raise ValueError('Query contains blocked terms')
        return v

# Validation happens AFTER provider, BEFORE execution
# If invalid, raises ValidationError → sent back to LLM as feedback
```

**Vercel AI SDK (Zod Runtime):**
```typescript
const searchSchema = z.object({
  query: z.string().min(3).max(200).refine(
    (val) => !BLOCKED_TERMS.some(term => val.toLowerCase().includes(term)),
    { message: 'Query contains blocked terms' }
  ),
  limit: z.number().int().min(1).max(100)
});

// Validation happens automatically, errors thrown if invalid
```

**3. Custom Validation (LangGraph):**
```python
def validate_tool_input(tool_input: dict) -> dict:
    """Pre-execution validation."""
    if tool_input.get("limit", 0) > 100:
        raise ValueError("Limit too high, maximum is 100")
    return tool_input

tool_node = ToolNode(
    tools,
    handle_tool_errors=True,
    pre_execute=validate_tool_input  # Custom hook
)
```

---

## Execution Control

### Sequential vs Parallel Execution

| Framework | Default | Configurable | Notes |
|-----------|---------|--------------|-------|
| **PydanticAI** | Sequential | ❌ | Tools called one-by-one in `.iter()` loop |
| **LangGraph** | Parallel | ✅ | `ToolNode` executes all tool_calls concurrently |
| **AutoGen** | Sequential | ⚠️ Limited | Multi-agent flows can be parallel |
| **CrewAI** | Sequential | ✅ | Task-level parallelism via `async=True` |
| **Claude SDK** | Sequential | ❌ | One tool at a time |
| **OpenAI SDK** | Sequential | ❌ | One tool at a time |
| **Vercel AI** | Sequential | ❌ | One tool at a time |
| **Cloudflare** | Sequential | ✅ | Can use `Promise.all()` in custom logic |

### Parallel Execution Example: LangGraph

```python
from langgraph.prebuilt import ToolNode
import asyncio

# LLM returns multiple tool calls:
# [
#   {"name": "search", "id": "call_1", "args": {"query": "Python"}},
#   {"name": "search", "id": "call_2", "args": {"query": "Swift"}},
#   {"name": "calculate", "id": "call_3", "args": {"expr": "2+2"}}
# ]

tool_node = ToolNode(tools)

# ToolNode implementation (simplified):
async def execute_tools(tool_calls: list[ToolCall]) -> list[ToolResult]:
    # Create tasks for all tool calls
    tasks = [execute_single_tool(call) for call in tool_calls]

    # Execute in parallel
    results = await asyncio.gather(*tasks, return_exceptions=True)

    # Handle errors
    for i, result in enumerate(results):
        if isinstance(result, Exception):
            results[i] = ToolResult(
                tool_call_id=tool_calls[i].id,
                error=str(result)
            )

    return results
```

**Advantages:**
- Faster execution (3 tools in time of slowest, not sum)
- Better for I/O-bound tools (API calls, database queries)

**Disadvantages:**
- Harder to debug (race conditions, unclear order)
- Tools must be independent (no shared state)
- Error handling complexity (partial failures)

### Conditional Execution: LangGraph Tools Condition

```python
from langgraph.prebuilt import tools_condition

# Automatically route based on LLM output
graph.add_conditional_edges(
    "agent",
    tools_condition,  # Checks if tool_calls present in state
    {
        "tools": "tools_node",  # Route to tools if tool_calls exist
        "end": END              # End if no tool_calls
    }
)

# Custom routing logic
def should_use_tools(state: State) -> str:
    messages = state["messages"]
    last_message = messages[-1]

    # Only use tools if confidence is low
    if hasattr(last_message, "confidence") and last_message.confidence < 0.7:
        return "tools"

    # Skip tools if we've used them 5+ times
    if state.get("tool_call_count", 0) >= 5:
        return "end"

    return "tools" if last_message.tool_calls else "end"

graph.add_conditional_edges("agent", should_use_tools, {"tools": "tools_node", "end": END})
```

### Retry Logic

**1. PydanticAI: Per-Tool Retry with ModelRetry**
```python
from pydantic_ai import ModelRetry

@agent.tool(retries=3)
async def flaky_api(ctx: RunContext[Deps], query: str) -> str:
    """Call an unreliable API."""
    try:
        result = await ctx.deps.api_client.call(query)
        if not result.is_valid():
            # Tell LLM to retry with better input
            raise ModelRetry("API returned invalid result. Try rephrasing your query.")
        return result.data
    except APIError as e:
        if e.retryable:
            # Framework retries automatically
            raise ModelRetry(f"API error: {e}. Retrying...")
        else:
            # Don't retry, fail permanently
            raise

# Execution flow:
# Attempt 1: LLM calls with query="vague input"
# → API returns invalid
# → ModelRetry raised → LLM sees error message
# Attempt 2: LLM calls with query="more specific input"
# → API returns valid
# → Success
```

**2. LangGraph: Global Error Handling**
```python
# All tools use same retry strategy
tool_node = ToolNode(tools, handle_tool_errors=True)

# Or custom per-error-type:
def retry_on_timeout(error: Exception, tool_input: dict) -> str:
    if isinstance(error, TimeoutError):
        return "Tool timed out. Please try again with smaller input."
    return f"Error: {error}"

tool_node = ToolNode(tools, handle_tool_errors=retry_on_timeout)
```

**3. Vercel AI SDK: Global maxSteps**
```typescript
const agent = createAgent({
  model: anthropic('claude-sonnet-4'),
  tools: { search: searchTool },
  maxSteps: 5  // Maximum tool calls across entire conversation
});

// No per-tool retry control
// If tool throws, error is sent to LLM, counts as 1 step
```

**4. CrewAI: Task-Level Retries**
```python
task = Task(
    description="Search for information",
    agent=researcher,
    tools=[search_tool],
    max_retries=3  # Retry entire task on failure
)
```

### Loop Control: Full Iteration

**PydanticAI: Best-in-Class Loop Control**
```python
async with agent.iter(prompt, deps=deps) as run:
    async for node in run:
        match node:
            case ToolCall(name="delete_file", args=args):
                # Inspect before execution
                if not await confirm_deletion(args["path"]):
                    # Skip this tool call
                    continue

            case TextChunk(content=text):
                # Stream partial responses
                print(text, end="")

            case ToolResult(name=name, result=result):
                # Post-process tool output
                log_tool_execution(name, result)

# Full control: can break, continue, modify, inject between steps
```

**OpenAI Agents: Interruption-Based**
```python
run = await agent.run("Delete old files")

while run.status == "interrupted":
    # Handle approval
    pending = run.interruptions[0]
    approved = await request_approval(pending)
    run = await agent.resume(run.id, approved=approved)

# Less granular: can only approve/deny, not modify
```

**Vercel AI SDK: Callback-Based**
```typescript
const agent = createAgent({
  model: anthropic('claude-sonnet-4'),
  tools: { search: searchTool },
  prepareStep: async ({ stepNumber, tools }) => {
    // Executed BEFORE each step
    if (stepNumber > 5) {
      return { stopWhen: true };  // Abort execution
    }
    return { activeTools: Object.keys(tools) };
  }
});

// Less control: callback runs before step, can't modify in-flight
```

---

## Error Handling Deep Dive

### Error Types

| Error Type | Description | Frameworks |
|------------|-------------|------------|
| **Validation Error** | Tool arguments invalid | All (provider-enforced) |
| **Execution Error** | Tool code throws exception | All |
| **Timeout Error** | Tool exceeds time limit | AutoGen, CrewAI, Cloudflare |
| **Retry Signal** | Request LLM retry with feedback | PydanticAI, LangGraph, OpenAI |
| **Permission Denied** | User/system blocks execution | Claude SDK, OpenAI, Vercel AI |

### Error Handling Patterns

**1. PydanticAI: ModelRetry Exception**
```python
from pydantic_ai import ModelRetry

@agent.tool
async def search(ctx: RunContext[Deps], query: str, limit: int) -> str:
    # Validation error (caught by Pydantic before execution)
    # if limit > 100: ValidationError raised automatically

    # Execution error with retry
    try:
        results = await ctx.deps.search_client.search(query, limit)
    except SearchError as e:
        if e.code == "RATE_LIMIT":
            # Ask LLM to retry with smaller limit
            raise ModelRetry(f"Rate limited. Try with limit < {limit}.")
        else:
            # Permanent failure
            raise

    # Validation of result
    if not results:
        raise ModelRetry(f"No results for '{query}'. Try different keywords.")

    return format_results(results)

# ModelRetry flow:
# 1. Exception raised during tool execution
# 2. Framework catches it
# 3. Error message sent back to LLM as tool result
# 4. LLM sees: "Tool 'search' returned: Rate limited. Try with limit < 50."
# 5. LLM retries with corrected parameters
# 6. Counts against tool's retry limit (retries=N)
```

**2. LangGraph: Error Handling Strategies**
```python
# Strategy 1: Catch all errors, send to LLM
tool_node = ToolNode(tools, handle_tool_errors=True)

# Strategy 2: Catch specific errors
tool_node = ToolNode(
    tools,
    handle_tool_errors=[ValueError, KeyError, HTTPError]
)

# Strategy 3: Custom error messages
def format_error(error: Exception, tool_input: dict) -> str:
    if isinstance(error, HTTPError):
        return f"API request failed: {error.response.status_code}. Try again later."
    if isinstance(error, ValueError):
        return f"Invalid input: {error}. Check your parameters."
    return f"Unexpected error: {error}"

tool_node = ToolNode(tools, handle_tool_errors=format_error)

# Strategy 4: Fail fast (raise to graph level)
tool_node = ToolNode(tools, handle_tool_errors=False)
# Any error propagates → graph execution stops → can be caught at graph level
```

**3. AutoGen: Automatic Reflection**
```python
from autogen import FunctionTool

def search(query: str) -> str:
    if len(query) < 3:
        raise ValueError("Query must be at least 3 characters")
    return search_client.search(query)

search_tool = FunctionTool(name="search", func=search)

# Execution trace:
# Agent: Let's search with {"query": "ab"}
# Tool: ValueError: Query must be at least 3 characters
# Agent: Let me try with a longer query {"query": "abstract"}
# Tool: [Results for "abstract"]

# AutoGen automatically sends error back to agent, no configuration needed
```

**4. CrewAI: Guardrails for Pre-Validation**
```python
from crewai import Guardrail

def validate_file_path(path: str) -> str:
    """Prevent access to sensitive files."""
    if path.startswith("/etc") or path.startswith("/sys"):
        raise ValueError("Cannot access system files")
    if not os.path.exists(path):
        raise ValueError(f"File does not exist: {path}")
    return path

file_guardrail = Guardrail(
    name="file_validation",
    validation_fn=validate_file_path
)

agent = Agent(
    role="file_manager",
    tools=[read_file_tool, write_file_tool],
    guardrails=[file_guardrail]  # Applied BEFORE tool execution
)

# Flow:
# 1. LLM calls tool with path="/etc/passwd"
# 2. Guardrail validates → raises ValueError
# 3. Error sent to LLM: "Cannot access system files"
# 4. Tool never executes
```

**5. Vercel AI SDK: Throw and Retry**
```typescript
const searchTool = tool({
  description: 'Search the knowledge base',
  parameters: z.object({
    query: z.string(),
    limit: z.number().int().min(1).max(100)
  }),
  execute: async ({ query, limit }) => {
    const results = await search(query, limit);

    if (results.length === 0) {
      // Error sent to LLM automatically
      throw new Error(`No results for "${query}". Try different keywords.`);
    }

    return results;
  }
});

// LLM sees error message and can retry
// Global retry limit: maxSteps
```

**6. OpenAI Agents: String Return for Errors**
```python
@function_tool
async def search(ctx: RunContext, query: str) -> str:
    """Search the knowledge base."""
    try:
        results = await ctx.deps.search_client.search(query)
        if not results:
            # Return error as string (not exception)
            return f"No results found for '{query}'. Try different keywords."
        return format_results(results)
    except SearchError as e:
        return f"Search failed: {e}. Please try again."

# No exception handling needed at framework level
# Tool returns error message as regular string
# LLM interprets it as feedback
```

### Error Handling Best Practices

**1. Differentiate Transient vs Permanent Errors**
```python
@agent.tool(retries=3)
async def api_call(ctx: RunContext[Deps], endpoint: str) -> str:
    try:
        return await ctx.deps.api.get(endpoint)
    except RateLimitError as e:
        # Transient: retry with backoff
        raise ModelRetry(f"Rate limited. Wait {e.retry_after}s and try again.")
    except AuthenticationError as e:
        # Permanent: don't retry
        raise ValueError(f"Authentication failed: {e}. Check your API key.")
```

**2. Provide Actionable Feedback**
```python
# ❌ Bad: Generic error
raise ModelRetry("Search failed")

# ✅ Good: Specific, actionable
raise ModelRetry("Search failed: Query too broad. Try adding more specific terms like 'Python web frameworks 2026'.")
```

**3. Use Guardrails for Security**
```python
# Don't rely on LLM to avoid dangerous operations
# Use guardrails to enforce constraints

def validate_sql_query(query: str) -> str:
    forbidden = ["DROP", "DELETE", "UPDATE", "INSERT", "ALTER"]
    if any(keyword in query.upper() for keyword in forbidden):
        raise ValueError("Only SELECT queries allowed")
    return query

sql_guardrail = Guardrail(name="sql_safety", validation_fn=validate_sql_query)
```

**4. Log Errors for Debugging**
```python
@agent.tool
async def search(ctx: RunContext[Deps], query: str) -> str:
    try:
        return await ctx.deps.search_client.search(query)
    except Exception as e:
        # Log full error for debugging
        logger.error(f"Search failed: {e}", exc_info=True, extra={"query": query})
        # Return simplified message to LLM
        raise ModelRetry(f"Search temporarily unavailable. Try again in a moment.")
```

---

## Approval Mechanisms

### Approval Patterns Comparison

| Framework | Pattern | Granularity | State Persistence | UI Integration |
|-----------|---------|-------------|-------------------|----------------|
| **PydanticAI** | Manual in `.iter()` | Per tool call | ❌ Manual | ❌ Manual |
| **OpenAI Agents** | Interruptions + resume | Per tool call | ✅ Built-in | ✅ Easy |
| **Vercel AI SDK** | `needsApproval` flag | Per tool type | ❌ None | ⚠️ Via callback |
| **Claude SDK** | Permission callback | Per tool call | ❌ None | ⚠️ Via callback |
| **LangGraph** | Manual in graph | Per node | ✅ Checkpointing | ❌ Manual |
| **CrewAI** | ❌ Not built-in | N/A | N/A | N/A |
| **AutoGen** | ❌ Not built-in | N/A | N/A | N/A |
| **Cloudflare** | WebSocket pattern | Per tool call | ✅ Durable Objects | ✅ Real-time |

### 1. PydanticAI: Manual Loop Control

```python
async with agent.iter(prompt, deps=deps) as run:
    async for node in run:
        match node:
            case ToolCall(name="delete_file", args=args):
                # Full control: can inspect, modify, skip
                print(f"Agent wants to delete: {args['path']}")
                approved = input("Approve? (y/n): ") == "y"

                if not approved:
                    # Skip execution
                    continue

                # Or modify arguments
                if args["path"].endswith(".log"):
                    print("Redirecting to archive instead of delete")
                    args["path"] = f"/archive/{args['path']}"

            case ToolResult(name=name, result=result):
                print(f"Tool {name} completed: {result}")

# Advantages:
# - Full control (inspect, modify, skip, inject)
# - Can add custom logic (approval rules, logging, metrics)
# - Pythonic (async for loop)

# Disadvantages:
# - No built-in persistence (must implement yourself)
# - No UI integration (manual prompts or custom webhook)
# - Must handle state manually if pausing between runs
```

### 2. OpenAI Agents: Interruption + Resume

```python
from openai_agents import Agent, function_tool

@function_tool(needs_approval=True)
async def delete_file(ctx: RunContext, path: str) -> str:
    """Delete a file permanently."""
    os.remove(path)
    return f"Deleted {path}"

agent = Agent(model="gpt-4o", tools=[delete_file])

# Run until interruption
run = await agent.run("Clean up old logs", stream=False)

if run.status == "interrupted":
    # Get pending tool calls
    for interruption in run.interruptions:
        print(f"Tool: {interruption.tool_name}")
        print(f"Args: {interruption.arguments}")

        # Request human approval (via UI, webhook, etc.)
        approved = await request_approval_from_ui(interruption)

        if approved:
            # Resume with approval
            run = await agent.resume(run.id, approved=True)
        else:
            # Provide feedback
            run = await agent.resume(
                run.id,
                approved=False,
                feedback="User denied deletion. Please suggest safer alternatives like archiving."
            )

# State persistence (critical for long-running or async approvals)
state_dict = run.to_dict()
await db.save("run_123", state_dict)

# Later (even after server restart):
state_dict = await db.load("run_123")
restored_run = Agent.from_dict(state_dict)
run = await agent.resume(restored_run.id, approved=True)

# Advantages:
# - Built-in state serialization (can pause indefinitely)
# - Clear approval semantics (needs_approval flag)
# - Easy UI integration (webhook endpoint → approve/deny)

# Disadvantages:
# - OpenAI-specific (no multi-provider)
# - Approval is per-tool-type, not per-invocation (all delete_file calls require approval)
# - Can't modify arguments during approval
```

### 3. Vercel AI SDK: needsApproval Flag

```typescript
const deleteTool = tool({
  description: 'Delete a file',
  parameters: z.object({ path: z.string() }),
  execute: async ({ path }, { needsApproval }) => {
    if (needsApproval) {
      // Custom approval logic (not built-in)
      const approved = await requestApproval({
        action: 'delete',
        target: path
      });

      if (!approved) {
        throw new Error('User denied deletion');
      }
    }

    fs.unlinkSync(path);
    return { deleted: path };
  }
});

const agent = createAgent({
  model: anthropic('claude-sonnet-4'),
  tools: { delete: deleteTool },
  experimental_needsApproval: (tool) => {
    // Determine which tools need approval
    return tool.name === 'delete' || tool.name === 'execute_code';
  }
});

// Advantages:
// - Simple flag-based approach
// - TypeScript type safety

// Disadvantages:
// - No built-in approval mechanism (must implement requestApproval yourself)
// - No state persistence
// - Approval callback is synchronous (blocks execution)
```

### 4. Claude SDK: Permission Callback

```python
from claude_agent_sdk import Agent, PermissionResultAllow, PermissionResultDeny

async def permission_handler(tool_name: str, input_data: dict, context: dict) -> PermissionResult:
    """Executed BEFORE every tool call."""

    if tool_name == "delete_file":
        # Request approval from external system
        approved = await approval_service.request(
            action="delete",
            path=input_data["path"],
            user_id=context["user_id"]
        )

        if not approved:
            return PermissionResultDeny(
                reason="User denied file deletion"
            )

    if tool_name == "search":
        # Modify input (e.g., add rate limits)
        input_data["limit"] = min(input_data.get("limit", 10), 20)
        return PermissionResultAllow(updated_input=input_data)

    return PermissionResultAllow()

agent = Agent(
    api_key="...",
    tools=[search_tool, delete_file_tool],
    permission_callback=permission_handler
)

# Advantages:
# - Per-call granularity (can approve/deny individual invocations)
# - Can modify input during approval
# - Simple callback pattern

# Disadvantages:
# - No state persistence (callback must be synchronous or handle async itself)
# - No built-in UI integration
# - Anthropic-specific
```

### 5. LangGraph: Interrupt Before/After

```python
from langgraph.graph import StateGraph, interrupt

def agent_node(state: State):
    # Agent generates tool calls
    response = llm.invoke(state["messages"])
    return {"messages": [response]}

def approval_node(state: State):
    # Manual approval step
    last_message = state["messages"][-1]
    tool_calls = last_message.tool_calls

    for call in tool_calls:
        if call["name"] == "delete_file":
            # Interrupt execution, wait for human input
            approved = interrupt(f"Approve deletion of {call['args']['path']}?")
            if not approved:
                return {"messages": [{"role": "system", "content": "User denied deletion"}]}

    return state

def tools_node(state: State):
    # Execute approved tools
    results = execute_tools(state["messages"][-1].tool_calls)
    return {"messages": results}

# Build graph with approval node
graph = StateGraph(State)
graph.add_node("agent", agent_node)
graph.add_node("approval", approval_node)
graph.add_node("tools", tools_node)
graph.add_edge("agent", "approval")
graph.add_edge("approval", "tools")
graph.add_edge("tools", "agent")

# Compile with checkpointer for state persistence
from langgraph.checkpoint.memory import MemorySaver
app = graph.compile(checkpointer=MemorySaver())

# Execution
config = {"configurable": {"thread_id": "1"}}
for chunk in app.stream({"messages": [{"role": "user", "content": "Delete old logs"}]}, config):
    print(chunk)
    if "__interrupt__" in chunk:
        # Human approval needed
        approved = input("Approve? (y/n): ") == "y"
        # Resume with approval
        app.update_state(config, {"approved": approved})

# Advantages:
# - Full control via graph structure
# - State persistence via checkpointers
# - Can add complex approval logic (multi-step, conditional)

# Disadvantages:
# - Requires understanding graphs (steep learning curve)
# - More boilerplate than other approaches
# - Manual interrupt/resume handling
```

### 6. Cloudflare: WebSocket Real-Time Approval

```typescript
import { Agent } from '@cloudflare/agents';

class MyAgent extends Agent<Env, State> {
  async handleWebSocket(ws: WebSocket) {
    ws.accept();

    // Before tool execution, request approval via WebSocket
    this.on('before-tool-call', async (call) => {
      if (call.tool === 'delete' || call.tool === 'execute_code') {
        // Send approval request to client
        ws.send(JSON.stringify({
          type: 'approval_request',
          tool: call.tool,
          args: call.args,
          id: call.id
        }));

        // Wait for client response
        const approval = await new Promise((resolve) => {
          const handler = (msg: MessageEvent) => {
            const data = JSON.parse(msg.data);
            if (data.type === 'approval_response' && data.id === call.id) {
              ws.removeEventListener('message', handler);
              resolve(data.approved);
            }
          };
          ws.addEventListener('message', handler);

          // Timeout after 60 seconds
          setTimeout(() => resolve(false), 60000);
        });

        if (!approval) {
          throw new Error('User denied tool execution');
        }
      }
    });

    // Send state updates to client
    this.on('state-change', (newState) => {
      ws.send(JSON.stringify({ type: 'state', state: newState }));
    });
  }
}

// Client (browser):
const ws = new WebSocket('wss://agent.example.com/session/123');

ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);

  if (msg.type === 'approval_request') {
    // Show UI modal
    const approved = confirm(`Approve ${msg.tool} with args: ${JSON.stringify(msg.args)}?`);

    // Send response
    ws.send(JSON.stringify({
      type: 'approval_response',
      id: msg.id,
      approved: approved
    }));
  }
};

// Advantages:
// - Real-time communication (low latency)
// - Rich UI integration (send full context to browser)
// - State persisted via Durable Objects (survives disconnects)

// Disadvantages:
// - Requires WebSocket infrastructure
// - Cloudflare-specific (vendor lock-in)
// - More complex client implementation
```

### Approval Best Practices

**1. Default Deny for Destructive Actions**
```python
DANGEROUS_TOOLS = {"delete_file", "execute_code", "drop_database"}

async def permission_handler(tool_name: str, args: dict) -> bool:
    if tool_name in DANGEROUS_TOOLS:
        # Always require explicit approval
        return await request_human_approval(tool_name, args)
    return True  # Auto-approve safe tools
```

**2. Provide Context in Approval Requests**
```python
# ❌ Bad: No context
approved = input("Approve deletion? (y/n): ")

# ✅ Good: Full context
print(f"""
Approval Request:
- Action: Delete file
- Path: {args['path']}
- Size: {os.path.getsize(args['path'])} bytes
- Last modified: {os.path.getmtime(args['path'])}
- Reason: {context['reason']}
""")
approved = input("Approve? (y/n): ") == "y"
```

**3. Implement Approval Timeout**
```python
async def request_approval_with_timeout(tool_name: str, args: dict, timeout: int = 60) -> bool:
    try:
        approved = await asyncio.wait_for(
            request_approval_from_ui(tool_name, args),
            timeout=timeout
        )
        return approved
    except asyncio.TimeoutError:
        logger.warning(f"Approval timeout for {tool_name}")
        return False  # Default deny on timeout
```

**4. Audit Trail**
```python
async def permission_handler(tool_name: str, args: dict, context: dict) -> bool:
    approved = await request_approval(tool_name, args)

    # Log approval decision
    await audit_log.record({
        "timestamp": datetime.now(),
        "user": context["user_id"],
        "tool": tool_name,
        "args": args,
        "approved": approved,
        "approver": context.get("approver", "system")
    })

    return approved
```

---

## Context Access Patterns

### Dependency Injection Approaches

| Framework | Pattern | Type Safety | Mutability | Scope |
|-----------|---------|-------------|------------|-------|
| **PydanticAI** | `RunContext[DepsType]` | ✅ Generic | ❌ Immutable | Per run |
| **OpenAI Agents** | `RunContext[DepsType]` | ✅ Generic | ❌ Immutable | Per run |
| **LangGraph** | State dictionary | ❌ Runtime | ✅ Mutable | Per thread |
| **CrewAI** | Agent attributes | ❌ Runtime | ✅ Mutable | Per agent |
| **Claude SDK** | Context parameter | ❌ Runtime | ❌ Read-only | Per call |
| **Vercel AI** | Closure capture | ⚠️ TypeScript | ❌ Immutable | Per tool |
| **AutoGen** | Agent attributes | ❌ Runtime | ✅ Mutable | Per agent |
| **Cloudflare** | `this.env` + state | ⚠️ TypeScript | ✅ Mutable | Per Durable Object |

### 1. PydanticAI: Typed RunContext

```python
from dataclasses import dataclass
from pydantic_ai import Agent, RunContext

@dataclass
class SearchDeps:
    """Dependencies available to all tools."""
    user_id: str
    search_client: SearchClient
    db: Database
    auth_token: str
    config: Config

agent = Agent[SearchDeps, str]('anthropic:claude-sonnet')

@agent.tool
async def search(ctx: RunContext[SearchDeps], query: str) -> str:
    """Search with user context."""
    # Type-safe access to dependencies
    results = await ctx.deps.search_client.search(
        query=query,
        user_id=ctx.deps.user_id,  # IDE autocomplete works
        auth=ctx.deps.auth_token
    )

    # Access run metadata
    logger.info(f"Search executed", extra={
        "run_id": ctx.run_id,
        "user": ctx.deps.user_id,
        "query": query
    })

    return format_results(results)

# Usage
deps = SearchDeps(
    user_id="user_123",
    search_client=SearchClient(api_key="..."),
    db=Database(url="..."),
    auth_token="...",
    config=load_config()
)

result = await agent.run("Search for Python frameworks", deps=deps)

# Advantages:
# - Compile-time type checking (mypy, pyright)
# - Immutable (prevents accidental state mutation)
# - Clear dependency declaration
# - Easy testing (mock deps object)

# Disadvantages:
# - Requires dataclass definition
# - Can't modify deps during execution
# - Must pass deps on every run() call
```

### 2. LangGraph: Mutable State Dictionary

```python
from typing import TypedDict
from langgraph.graph import StateGraph

class State(TypedDict):
    messages: list
    user_id: str
    search_results: list
    iteration_count: int

def agent_node(state: State):
    # Access state
    user_id = state["user_id"]
    messages = state["messages"]

    # Modify state
    state["iteration_count"] += 1

    # Call LLM
    response = llm.invoke(messages)

    # Return updates (merged into state)
    return {"messages": [response]}

def search_node(state: State):
    # Tools can access and modify state
    query = extract_query(state["messages"][-1])
    results = search_client.search(query, user_id=state["user_id"])

    # Update state with results
    return {
        "search_results": results,
        "messages": [format_results(results)]
    }

graph = StateGraph(State)
graph.add_node("agent", agent_node)
graph.add_node("search", search_node)
graph.add_edge("agent", "search")
graph.add_edge("search", "agent")

# Run with initial state
app = graph.compile()
result = app.invoke({
    "messages": [{"role": "user", "content": "Search for Python"}],
    "user_id": "user_123",
    "search_results": [],
    "iteration_count": 0
})

# Advantages:
# - Mutable (nodes can update state directly)
# - Shared across all nodes
# - Persisted via checkpointers
# - Can accumulate data across iterations

# Disadvantages:
# - No type safety (runtime only)
# - Easy to introduce bugs (mutation confusion)
# - Must manually define State schema
```

### 3. Vercel AI SDK: Closure Capture

```typescript
// Dependencies captured in closure
const searchClient = new SearchClient(apiKey);
const userId = 'user_123';

const searchTool = tool({
  description: 'Search the knowledge base',
  parameters: z.object({ query: z.string() }),
  execute: async ({ query }) => {
    // Access captured dependencies
    const results = await searchClient.search(query, userId);
    return results;
  }
});

// Or pass context via factory function
function createTools(userId: string, searchClient: SearchClient) {
  return {
    search: tool({
      description: 'Search the knowledge base',
      parameters: z.object({ query: z.string() }),
      execute: async ({ query }) => {
        return await searchClient.search(query, userId);
      }
    })
  };
}

const tools = createTools('user_123', searchClient);
const agent = createAgent({ model: anthropic('claude-sonnet-4'), tools });

// Advantages:
// - Simple (no explicit context passing)
// - TypeScript type safety

// Disadvantages:
// - Less explicit (hard to see what tools depend on)
// - Can't change context between runs
// - Testing requires mocking captured variables
```

### 4. CrewAI: Agent Attributes

```python
from crewai import Agent, Task

class SearchAgent(Agent):
    def __init__(self, user_id: str, search_client: SearchClient):
        super().__init__(
            role="researcher",
            tools=[self.search_tool]
        )
        # Store as instance attributes
        self.user_id = user_id
        self.search_client = search_client

    def search_tool(self, query: str) -> str:
        # Access via self
        results = self.search_client.search(query, self.user_id)
        return format_results(results)

# Usage
agent = SearchAgent(user_id="user_123", search_client=SearchClient())
task = Task(description="Search for Python frameworks", agent=agent)

# Advantages:
# - Object-oriented (familiar pattern)
# - Mutable (can update attributes)

# Disadvantages:
# - No type safety
# - Harder to test (must instantiate entire agent)
# - State tied to agent instance
```

### 5. Cloudflare: Durable Object Environment + State

```typescript
import { Agent } from '@cloudflare/agents';

interface Env {
  SEARCH_API_KEY: string;
  DATABASE: D1Database;
}

interface State {
  userId: string;
  conversationHistory: Message[];
  searchCache: Record<string, any>;
}

class MyAgent extends Agent<Env, State> {
  initialState: State = {
    userId: '',
    conversationHistory: [],
    searchCache: {}
  };

  tools = [
    {
      name: 'search',
      execute: async (args: { query: string }) => {
        // Access environment (immutable, bound at creation)
        const apiKey = this.env.SEARCH_API_KEY;

        // Access state (mutable, persisted across requests)
        const userId = this.state.userId;
        const cached = this.state.searchCache[args.query];

        if (cached) {
          return cached;
        }

        // Perform search
        const results = await search(args.query, { userId, apiKey });

        // Update state (automatically persisted)
        this.state.searchCache[args.query] = results;

        return results;
      }
    }
  ];
}

// Durable Object bindings provide env
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const id = env.AGENT_DURABLE_OBJECT.idFromName('session_123');
    const stub = env.AGENT_DURABLE_OBJECT.get(id);
    return stub.fetch(request);
  }
};

// Advantages:
// - Environment secrets (API keys) separated from state
// - State persisted automatically (Durable Objects storage)
// - Works across requests (long-lived conversations)

// Disadvantages:
// - Cloudflare-specific
// - Must understand Durable Objects model
// - Limited to Cloudflare Workers runtime
```

### Context Access Best Practices

**1. Separate Configuration from State**
```python
# ✅ Good: Config immutable, state mutable
@dataclass
class Deps:
    config: Config  # Immutable: API keys, timeouts
    user_id: str    # Immutable: user identity

class State(TypedDict):
    messages: list       # Mutable: conversation history
    search_results: list # Mutable: accumulated results
```

**2. Use Type-Safe Dependencies**
```python
# ❌ Bad: Untyped dict
ctx.deps["search_client"].search(query)  # No autocomplete, no type checking

# ✅ Good: Typed dataclass
ctx.deps.search_client.search(query)  # IDE autocomplete, mypy validates
```

**3. Avoid Global State**
```python
# ❌ Bad: Global mutable state
SEARCH_CACHE = {}

@agent.tool
async def search(ctx: RunContext[Deps], query: str) -> str:
    if query in SEARCH_CACHE:  # Shared across all users!
        return SEARCH_CACHE[query]
    ...

# ✅ Good: State in deps or context
@agent.tool
async def search(ctx: RunContext[Deps], query: str) -> str:
    if query in ctx.deps.cache:  # Per-user cache
        return ctx.deps.cache[query]
    ...
```

**4. Make Dependencies Explicit**
```python
# ❌ Bad: Hidden dependencies
def search(query: str) -> str:
    return global_client.search(query)  # Where does global_client come from?

# ✅ Good: Explicit dependencies
@agent.tool
async def search(ctx: RunContext[Deps], query: str) -> str:
    return await ctx.deps.search_client.search(query)  # Clear dependency
```

---

## Result Handling

### Success, Failure, Partial Results

**1. PydanticAI: Typed Return Values**
```python
from typing import Literal
from pydantic import BaseModel

class SearchResult(BaseModel):
    status: Literal["success", "partial", "failed"]
    results: list[str]
    error_message: str | None = None
    total_found: int

@agent.tool
async def search(ctx: RunContext[Deps], query: str) -> SearchResult:
    try:
        results = await ctx.deps.search_client.search(query)
        return SearchResult(
            status="success",
            results=results,
            total_found=len(results)
        )
    except PartialResultsError as e:
        # Return partial results with error context
        return SearchResult(
            status="partial",
            results=e.partial_results,
            error_message=str(e),
            total_found=len(e.partial_results)
        )
    except SearchError as e:
        # Complete failure
        return SearchResult(
            status="failed",
            results=[],
            error_message=str(e),
            total_found=0
        )

# LLM receives structured result:
# {
#   "status": "partial",
#   "results": ["result1", "result2"],
#   "error_message": "Database timeout, returning cached results",
#   "total_found": 2
# }
```

**2. LangGraph: State Accumulation**
```python
class State(TypedDict):
    messages: list
    search_results: list[dict]
    failed_searches: list[str]

def search_node(state: State):
    query = extract_query(state["messages"][-1])

    try:
        results = search_client.search(query)
        # Accumulate successful results
        state["search_results"].extend(results)
        return {"messages": [format_success(results)]}
    except SearchError as e:
        # Track failures
        state["failed_searches"].append(query)
        return {"messages": [f"Search for '{query}' failed: {e}"]}

# After multiple searches, state contains:
# search_results: [result1, result2, result3]  # All successful results
# failed_searches: ["bad query 1"]             # Failed queries
```

**3. Streaming Tool Results**

**Vercel AI SDK (Built-in):**
```typescript
const searchTool = tool({
  description: 'Search the knowledge base',
  parameters: z.object({ query: z.string() }),
  execute: async function* ({ query }) {
    // Stream partial results
    const stream = searchClient.searchStream(query);

    for await (const result of stream) {
      yield { type: 'partial', data: result };
    }

    yield { type: 'complete', total: stream.totalCount };
  }
});

// Consumer receives incremental updates:
for await (const part of agent.streamText({ prompt: 'Search for Python' })) {
  if (part.type === 'tool-result') {
    console.log('Partial result:', part.result);
  }
}
```

**PydanticAI (Manual via Context):**
```python
from dataclasses import dataclass

@dataclass
class StreamingDeps:
    search_client: SearchClient
    result_callback: Callable[[str], None]  # Callback for streaming

@agent.tool
async def search(ctx: RunContext[StreamingDeps], query: str) -> str:
    results = []
    async for result in ctx.deps.search_client.search_stream(query):
        # Send partial result to callback
        ctx.deps.result_callback(f"Found: {result.title}")
        results.append(result)

    return format_results(results)

# Usage
def handle_partial_result(msg: str):
    print(f"[STREAMING] {msg}")

deps = StreamingDeps(
    search_client=SearchClient(),
    result_callback=handle_partial_result
)

result = await agent.run("Search for Python", deps=deps)
# Output:
# [STREAMING] Found: Python 3.11 Release
# [STREAMING] Found: Python Tutorial
# [STREAMING] Found: Python Best Practices
# [Final result]
```

---

## Timeout & Resource Management

| Framework | Timeout Support | Memory Limits | Concurrency Control | Cost Tracking |
|-----------|----------------|---------------|---------------------|---------------|
| **PydanticAI** | ❌ Manual | ❌ Manual | ❌ Manual | ✅ Usage metadata |
| **LangGraph** | ⚠️ Via asyncio | ❌ Manual | ✅ Parallel nodes | ❌ Manual |
| **AutoGen** | ✅ Docker timeout | ✅ Docker memory | ⚠️ Limited | ❌ Manual |
| **CrewAI** | ✅ Task timeout | ❌ Manual | ✅ Async tasks | ❌ Manual |
| **Claude SDK** | ❌ Manual | ❌ Manual | ❌ Manual | ❌ Manual |
| **OpenAI SDK** | ❌ Manual | ❌ Manual | ❌ Manual | ❌ Manual |
| **Vercel AI** | ❌ Manual | ❌ Manual | ❌ Sequential only | ✅ Token tracking |
| **Cloudflare** | ✅ CPU timeout | ✅ Memory limit | ✅ Via Workers | ❌ Manual |

### Timeout Patterns

**1. AutoGen: Docker-Based Timeout**
```python
from autogen import CodeExecutorConfig, DockerCommandLineCodeExecutor

code_executor = DockerCommandLineCodeExecutor(
    image="python:3-slim",
    timeout=30,  # Kill after 30 seconds
    work_dir="workspace"
)

config = CodeExecutorConfig(executor=code_executor)

# If code runs longer than 30s, Docker kills the container
# Agent receives: TimeoutError: Code execution exceeded 30 seconds
```

**2. CrewAI: Task-Level Timeout**
```python
from crewai import Task

task = Task(
    description="Search and analyze 100 documents",
    agent=researcher,
    timeout_seconds=300,  # 5 minutes max
    expected_output="Analysis report"
)

# If task exceeds timeout, CrewAI raises TaskTimeoutError
# Can be caught and handled at crew level
```

**3. Manual Timeout (PydanticAI, LangGraph)**
```python
import asyncio

@agent.tool
async def slow_search(ctx: RunContext[Deps], query: str) -> str:
    try:
        return await asyncio.wait_for(
            ctx.deps.search_client.search(query),
            timeout=10.0  # 10 seconds max
        )
    except asyncio.TimeoutError:
        raise ModelRetry("Search timed out. Try a more specific query.")
```

**4. Cloudflare: CPU Time Limit**
```typescript
// Cloudflare Workers have 50ms CPU time limit (standard)
// Durable Objects have 30s wall clock limit

class MyAgent extends Agent<Env, State> {
  async handleRequest(request: Request): Promise<Response> {
    // If execution exceeds 30s, Cloudflare throws Error
    // Must design for incremental execution
    const result = await this.run(request.text());
    return new Response(result);
  }
}
```

### Resource Limits

**1. Token Limits (Vercel AI SDK)**
```typescript
const agent = createAgent({
  model: anthropic('claude-sonnet-4'),
  tools: { search: searchTool },
  maxTokens: 4000,  // Limit output tokens
  experimental_maxInputTokens: 100000  // Limit total context
});

// Automatically truncates conversation history to fit limits
```

**2. Iteration Limits (PydanticAI)**
```python
# Max tool call iterations
result = await agent.run(
    prompt,
    deps=deps,
    max_iterations=5  # Stop after 5 tool→LLM cycles
)

# If limit reached, raises MaxIterationsError
```

**3. Cost Tracking (PydanticAI)**
```python
result = await agent.run(prompt, deps=deps)

# Access usage metadata
print(f"Tokens: {result.usage().total_tokens}")
print(f"Cost: ${result.usage().cost()}")
print(f"Requests: {result.usage().request_count}")
```

---

## Complete Tool Implementation Examples

### Example 1: Search Tool (All Frameworks)

**PydanticAI:**
```python
from pydantic_ai import Agent, RunContext, ModelRetry
from pydantic import BaseModel, Field

class SearchArgs(BaseModel):
    query: str = Field(description="Natural language search query")
    limit: int = Field(default=10, ge=1, le=100)

@dataclass
class Deps:
    search_client: SearchClient

agent = Agent[Deps, str]('anthropic:claude-sonnet')

@agent.tool(retries=3)
async def search(ctx: RunContext[Deps], args: SearchArgs) -> str:
    """Search the knowledge base with natural language queries."""
    try:
        results = await ctx.deps.search_client.search(args.query, args.limit)
        if not results:
            raise ModelRetry(f"No results for '{args.query}'. Try different keywords.")
        return format_results(results)
    except SearchError as e:
        raise ModelRetry(f"Search failed: {e}. Please try again.")
```

**LangGraph:**
```python
from langchain_core.tools import tool
from langgraph.prebuilt import ToolNode

@tool
def search(query: str, limit: int = 10) -> str:
    """Search the knowledge base.

    Args:
        query: Natural language search query
        limit: Maximum results (1-100)
    """
    if not (1 <= limit <= 100):
        raise ValueError("Limit must be between 1 and 100")

    results = search_client.search(query, limit)
    if not results:
        return f"No results found for '{query}'. Try different keywords."
    return format_results(results)

tool_node = ToolNode([search], handle_tool_errors=True)
```

**CrewAI:**
```python
from crewai.tools import BaseTool
from pydantic import BaseModel, Field

class SearchInput(BaseModel):
    query: str = Field(description="Search query")
    limit: int = Field(default=10, ge=1, le=100)

class SearchTool(BaseTool):
    name: str = "search"
    description: str = "Search the knowledge base"
    args_schema: type[BaseModel] = SearchInput

    async def _arun(self, query: str, limit: int = 10) -> str:
        results = await search_client.search(query, limit)
        return format_results(results) if results else f"No results for '{query}'"
```

**Vercel AI SDK:**
```typescript
import { tool } from 'ai';
import { z } from 'zod';

const searchTool = tool({
  description: 'Search the knowledge base',
  parameters: z.object({
    query: z.string().describe('Natural language search query'),
    limit: z.number().int().min(1).max(100).default(10)
  }),
  execute: async ({ query, limit }) => {
    const results = await searchClient.search(query, limit);
    if (results.length === 0) {
      throw new Error(`No results for "${query}". Try different keywords.`);
    }
    return formatResults(results);
  }
});
```

---

## Best Practices & Anti-Patterns

### Best Practices

**1. Type-Safe Tool Definitions**
```python
# ✅ Use Pydantic/Zod for argument schemas
class SearchArgs(BaseModel):
    query: str = Field(min_length=1, max_length=200)
    limit: int = Field(ge=1, le=100)

# ❌ Avoid untyped functions
def search(query, limit=10):  # No validation
    ...
```

**2. Descriptive Tool Docstrings**
```python
# ✅ Detailed description
@agent.tool
async def search(ctx: RunContext[Deps], query: str) -> str:
    """Search the knowledge base with natural language queries.

    Returns relevant documents ranked by relevance. Use specific keywords
    for better results. Maximum 100 results per query.
    """
    ...

# ❌ Generic or missing description
@agent.tool
async def search(ctx: RunContext[Deps], query: str) -> str:
    """Search."""  # Too vague
    ...
```

**3. Provide Actionable Error Messages**
```python
# ✅ Specific, actionable feedback
raise ModelRetry("Rate limited. Try with limit < 50 or wait 60 seconds.")

# ❌ Generic error
raise ModelRetry("Search failed")
```

**4. Validate Inputs Early**
```python
# ✅ Fail fast with clear message
if len(query) < 3:
    raise ValueError("Query must be at least 3 characters")

# ❌ Let it fail deep in execution
results = search_client.search(query)  # May fail cryptically
```

**5. Separate Concerns**
```python
# ✅ Tool logic separate from framework code
class SearchService:
    async def search(self, query: str, limit: int) -> list:
        # Pure business logic
        ...

@agent.tool
async def search_tool(ctx: RunContext[Deps], query: str) -> str:
    # Thin wrapper, delegates to service
    results = await ctx.deps.search_service.search(query, 10)
    return format_results(results)

# ❌ Mix framework and business logic
@agent.tool
async def search_tool(ctx: RunContext[Deps], query: str) -> str:
    # Business logic embedded in tool
    conn = await ctx.deps.db.connect()
    results = await conn.execute("SELECT ...")
    ...
```

### Anti-Patterns

**1. Tools with Side Effects Without Approval**
```python
# ❌ Dangerous: Auto-deletes without confirmation
@agent.tool
async def delete_file(ctx: RunContext[Deps], path: str) -> str:
    os.remove(path)
    return f"Deleted {path}"

# ✅ Safe: Require approval
@agent.tool
async def delete_file(ctx: RunContext[Deps], path: str) -> str:
    # In manual loop, check for approval before execution
    # Or use needs_approval flag (OpenAI Agents)
    os.remove(path)
    return f"Deleted {path}"
```

**2. Overly Broad Tool Descriptions**
```python
# ❌ Too broad
@agent.tool
async def do_thing(ctx: RunContext[Deps], action: str, target: str) -> str:
    """Do various things with targets."""
    ...

# ✅ Specific tools
@agent.tool
async def search_documents(ctx: RunContext[Deps], query: str) -> str:
    """Search document collection."""
    ...

@agent.tool
async def delete_document(ctx: RunContext[Deps], doc_id: str) -> str:
    """Delete a specific document by ID."""
    ...
```

**3. Ignoring Partial Failures**
```python
# ❌ All-or-nothing
results = [await api.call(item) for item in items]  # Fails if any item fails

# ✅ Graceful degradation
results = []
errors = []
for item in items:
    try:
        results.append(await api.call(item))
    except Exception as e:
        errors.append((item, str(e)))

return {
    "results": results,
    "errors": errors,
    "success_rate": len(results) / len(items)
}
```

**4. No Timeout on External Calls**
```python
# ❌ Can hang indefinitely
response = await api_client.call(query)

# ✅ Always timeout external calls
try:
    response = await asyncio.wait_for(
        api_client.call(query),
        timeout=10.0
    )
except asyncio.TimeoutError:
    raise ModelRetry("API timed out. Try a simpler query.")
```

**5. Returning Large Unstructured Text**
```python
# ❌ Dumps entire result (floods context window)
@agent.tool
async def search(ctx: RunContext[Deps], query: str) -> str:
    results = await ctx.deps.search(query)
    return "\n".join(str(r) for r in results)  # Could be 100KB+

# ✅ Summarize or structure
@agent.tool
async def search(ctx: RunContext[Deps], query: str) -> str:
    results = await ctx.deps.search(query)
    # Return top 5 with summaries
    return "\n".join(
        f"{i+1}. {r.title}: {r.summary[:100]}"
        for i, r in enumerate(results[:5])
    )
```

---

## Yrden Design Recommendations

Based on the comprehensive analysis of 8 agent frameworks, here are the recommended patterns for Yrden:

### 1. Tool Definition: Protocol-Based

```swift
protocol Tool<Context> {
    associatedtype Arguments: SchemaType
    associatedtype Output

    var name: String { get }
    var description: String { get }

    func call(context: Context, arguments: Arguments) async throws -> Output
}

// Usage
struct SearchTool: Tool {
    typealias Arguments = SearchArguments
    typealias Output = String

    let name = "search"
    let description = "Search the knowledge base with natural language queries"

    func call(context: RunContext<Deps>, arguments: SearchArguments) async throws -> String {
        let results = try await context.deps.searchClient.search(arguments.query, limit: arguments.limit)
        return formatResults(results)
    }
}
```

**Why:** Protocol-based is idiomatic Swift, provides compile-time type safety, and avoids Python's decorator magic.

### 2. Schema Generation: @Schema Macro

```swift
@Schema(description: "Search parameters")
struct SearchArguments {
    @Guide(description: "Natural language search query")
    let query: String

    @Guide(description: "Maximum results to return", .range(1...100))
    let limit: Int
}

// Macro generates:
// - static var jsonSchema: JSONValue
// - static var constraints: SchemaConstraints
// - extension SearchArguments: SchemaType, Codable
```

**Why:** Compile-time schema generation (no runtime reflection), constraints embedded in descriptions for universal provider support.

### 3. Execution Control: AsyncSequence Iteration

```swift
for try await node in agent.iter(prompt, deps: deps) {
    switch node {
    case .toolCall(let calls):
        // Full control: inspect, approve, modify, skip
        if needsApproval(calls[0]) {
            let approved = await requestApproval(calls[0])
            if !approved { continue }
        }

    case .toolResult(let result):
        // Post-process results
        logToolExecution(result)

    case .contentDelta(let text):
        // Stream partial responses
        print(text, terminator: "")
    }
}
```

**Why:** Follows PydanticAI's best-in-class pattern, native Swift concurrency, structured concurrency safety.

### 4. Error Handling: Typed ToolError

```swift
enum ToolError: Error {
    case retry(String)  // Signal LLM to retry
    case failure(Error) // Permanent failure
}

// Usage in tool
func call(context: RunContext<Deps>, arguments: Args) async throws -> String {
    do {
        return try await search(arguments.query)
    } catch let error as RateLimitError {
        throw ToolError.retry("Rate limited. Try with limit < \(arguments.limit).")
    } catch {
        throw ToolError.failure(error)
    }
}
```

**Why:** Type-safe alternative to Python's `ModelRetry` exception, clear semantics, Swift error handling idioms.

### 5. Approval: Interruption-Based

```swift
// Mark tools requiring approval
struct DeleteFileTool: Tool {
    let requiresApproval = true
    // ...
}

// Execution with approval
let run = try await agent.run(prompt, deps: deps)

while run.status == .interrupted {
    let pending = run.pendingApprovals[0]
    let approved = await requestApproval(pending)
    run = try await agent.resume(run.id, approved: approved)
}
```

**Why:** Follows OpenAI Agents SDK pattern with state serialization, enables async approval workflows.

### 6. Context Access: Generic RunContext

```swift
struct RunContext<Deps: Sendable> {
    let runId: UUID
    let deps: Deps
    let metadata: [String: String]
}

// Type-safe dependencies
struct AgentDeps: Sendable {
    let searchClient: SearchClient
    let userId: String
    let authToken: String
}

// Tool receives typed context
func call(context: RunContext<AgentDeps>, arguments: Args) async throws -> String {
    // Compile-time checked access
    return try await context.deps.searchClient.search(
        arguments.query,
        userId: context.deps.userId
    )
}
```

**Why:** Matches PydanticAI's `RunContext[DepsType]` pattern, compile-time type safety, Swift generics, Sendable for concurrency safety.

### 7. Result Handling: Structured Output

```swift
@Schema
struct SearchResult {
    @Guide(description: "Search status")
    let status: SearchStatus

    let results: [String]
    let errorMessage: String?
    let totalFound: Int
}

enum SearchStatus: String, Codable {
    case success
    case partial
    case failed
}
```

**Why:** Structured results give LLM clear context, enables partial failure handling, type-safe.

### Summary Matrix

| Feature | Pattern | Inspiration |
|---------|---------|-------------|
| **Tool Definition** | Protocol-based | Swift idioms |
| **Schema Generation** | `@Schema` macro | SwiftAI + Yrden original |
| **Execution Control** | `AsyncSequence.iter()` | PydanticAI |
| **Error Handling** | `ToolError.retry()` | PydanticAI `ModelRetry` |
| **Approval** | Interruption + state | OpenAI Agents SDK |
| **Context Access** | `RunContext<Deps>` | PydanticAI |
| **Result Handling** | Structured output | Vercel AI SDK + PydanticAI |
| **Retry Logic** | Per-tool retries | PydanticAI |
| **State Persistence** | Checkpointing | LangGraph + OpenAI |

---

## Conclusion

After analyzing tool execution patterns across 8 agent frameworks, the following insights emerge:

**Top Patterns to Adopt:**
1. **PydanticAI's `.iter()` pattern** - Best-in-class loop control
2. **OpenAI Agents' interruption model** - Clean approval with state serialization
3. **Vercel AI SDK's Zod schemas** - Excellent type safety pattern (adapt to Swift macros)
4. **LangGraph's ToolNode** - Parallel execution when needed
5. **CrewAI's guardrails** - Pre-validation layer

**Patterns to Avoid:**
1. Graph-based complexity (LangGraph) unless truly needed
2. Runtime-only type checking (weak validation)
3. Global configuration without per-tool control
4. Unstructured error messages
5. All-or-nothing approval (no granularity)

**Yrden's Unique Position:**
- **Compile-time type safety** via Swift macros (better than Pydantic/Zod runtime validation)
- **Protocol-based tools** (more idiomatic than Python decorators)
- **Structured concurrency** (safer than Python asyncio)
- **MCP + Sandbox** (no other framework has both built-in)
- **Skills system** (Anthropic-style, not in other SDKs)

The recommendations above provide a clear path forward for implementing Yrden's tool execution system with the best patterns from existing frameworks, adapted to Swift's strengths.
