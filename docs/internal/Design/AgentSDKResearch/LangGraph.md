## Research Complete: LangGraph API Surface

I've completed a comprehensive analysis of LangGraph's architecture and API design. Here's what I've documented:

## Key Findings

### 1. **Core Architecture**
- **StateGraph**: Graph-based execution with nodes (computation) and edges (flow control)
- **State Management**: TypedDict schemas with reducers (`add_messages`, custom functions)
- **Execution Model**: Pregel-inspired "supersteps" with transactional semantics
- Nodes execute in parallel within supersteps, with all-or-nothing state updates

### 2. **Execution & Streaming**
- **Methods**: `invoke()`, `stream()`, `astream()`, `astream_events()`
- **Stream Modes**: values, updates, messages, custom, debug
- **Custom Streaming**: `get_stream_writer()` for user-defined data
- All methods support both sync and async

### 3. **State Management Patterns**
- **Reducers**: Control how updates merge (accumulate vs overwrite)
- **State Injection**: `InjectedState` and `InjectedStore` for tool context
- **Memory**: Thread-scoped (checkpointing) vs cross-thread (stores)
- Built-in support for Postgres, MongoDB, Redis backends

### 4. **Tool/Node Execution**
- **ToolNode**: Prebuilt node for parallel tool execution
- **Error Handling**: Configurable strategies (catch-all, specific types, custom)
- **tools_condition**: Routing utility based on tool_calls presence
- ReAct loop pattern: agent → tools → agent (repeat until no tool calls)

### 5. **Interruption & Resume**
- **`interrupt()`**: Pause execution, collect user input, resume with `Command(resume=...)`
- **Checkpointing Required**: Must persist state for resume functionality
- **interrupt_before/after**: Compile-time pause points
- Agent pattern: Pseudo-tool (AskHuman) for requesting human input mid-execution

### 6. **Context Engineering**
- **trim_messages**: Manage context window with strategies (keep last N tokens)
- **RemoveMessage**: Delete specific messages from state
- **Summarization**: Replace old messages with LLM-generated summaries
- **Direct Modification**: Edit messages in state within nodes

### 7. **Agent Prebuilts**
- **create_react_agent**: High-level ReAct agent builder
- **Dynamic Models**: Runtime model selection based on state
- **Dynamic Prompts**: Context-aware system prompts
- **Hooks**: pre_model_hook, post_model_hook for message management and validation
- **Note**: Moving from `langgraph.prebuilt` to `langchain.agents` in v1.0 (Oct 2025)

### 8. **Advanced Features**

**Command API**:
- Combines state updates + routing in single return
- Routing logic inside node functions
- Can navigate to parent graph from subgraphs

**Send API (Map-Reduce)**:
- Dynamic parallel execution with runtime-determined task count
- Each Send has independent state
- Use `defer=True` on aggregators for synchronization

**Deferred Execution**:
- Delay node execution until all parallel branches complete
- Critical for uneven branch lengths (map-reduce flows)

### 9. **Multi-Agent Systems**
- **Handoffs**: Agent-to-agent control transfer via Command
- **Subgraphs**: Nested graphs with independent state
- **Patterns**: Supervisor (centralized), Swarm (decentralized), Hierarchical Teams
- Parent graph checkpointers auto-propagate to subgraphs

### 10. **Production Deployment**
- **LangSmith Deployment** (formerly LangGraph Platform)
- **Options**: Cloud SaaS, Hybrid BYOC, Self-hosted, Self-hosted Lite
- **Features**: One-click GitHub deploy, observability, scaling, auth
- **Local Dev**: `langgraph up` for local API server + Studio UI

### 11. **Limitations & Criticisms**

**Steep Learning Curve**:
- Requires graph theory, state machines, distributed systems knowledge
- High boilerplate for simple workflows
- Overkill for linear chains

**Debugging Challenges**:
- Hard to track state across distributed nodes
- Transactional failures roll back entire superstep
- Visualization struggles with complex graphs

**Not "True" Agentic**:
- Developer controls graph structure, not AI
- Functions as workflow orchestration, not autonomous agent
- Agency lies with developer, not system

**High TCO**:
- Platform costs, infrastructure requirements
- Specialized monitoring/debugging tools
- Developer time for learning and maintenance

## Key Insights for Yrden

### Patterns to Adopt:
1. **Explicit state management** with structured schemas
2. **Multiple execution modes** (invoke vs stream vs iterate)
3. **Checkpointing as first-class** feature
4. **Human-in-the-loop** with interrupt/resume patterns
5. **Dynamic routing** (Command-style) alongside static edges

### Swift Translation Opportunities:
1. **Type safety**: Compile-time types > runtime TypedDict
2. **Performance**: Actors + structured concurrency > asyncio
3. **Simplicity**: Avoid supersteps complexity initially
4. **Apple ecosystem**: First-class macOS/iOS support
5. **MCP + Sandbox**: LangGraph doesn't have these built-in

### Simplifications for v1:
1. Skip supersteps (use sequential + explicit parallel)
2. Skip graph visualization
3. Limit streaming modes (values + messages only)
4. Single checkpointer (SQLite first)
5. No deployment platform (just library)

The complete research document (14 sections, ~11,000 words) is ready to be added to `/Users/bartosz/dev/Yrden/docs/Design/LangGraphResearch.md` when you approve file creation.

## Sources Referenced:
- [LangGraph Documentation](https://docs.langchain.com/oss/python/langgraph/)
- [Graph API Overview](https://docs.langchain.com/oss/python/langgraph/graph-api)
- [Streaming Documentation](https://docs.langchain.com/oss/python/langgraph/streaming)
- [Memory Management](https://docs.langchain.com/oss/python/langgraph/add-memory)
- [Interrupts Documentation](https://docs.langchain.com/oss/python/langgraph/interrupts)
- [Human-in-the-Loop Guide](https://langchain-ai.github.io/langgraph/how-tos/human_in_the_loop/wait-user-input/)
- [LangGraph Agents Reference](https://reference.langchain.com/python/langgraph/agents/)
- [Send API Tutorial](https://dev.to/sreeni5018/leveraging-langgraphs-send-api-for-dynamic-and-parallel-workflow-execution-4pgd)
- [Command API Tutorial](https://dev.to/aiengineering/a-beginners-guide-to-dynamic-routing-in-langgraph-with-command-2c5l)
- [LangGraph Platform GA](https://www.blog.langchain.com/langgraph-platform-ga/)
- [Context Engineering Blog](https://www.blog.langchain.com/context-engineering-for-agents/)
- [LangGraph Limitations 2025](https://community.latenode.com/t/current-limitations-of-langchain-and-langgraph-frameworks-in-2025/30994)
- [Best AI Agent Frameworks 2025](https://langwatch.ai/blog/best-ai-agent-frameworks-in-2025-comparing-langgraph-dspy-crewai-agno-and-more)
