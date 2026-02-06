# Agent SDK Research

Comprehensive research on popular agent frameworks and SDKs, conducted to inform the design of Yrden's agent execution API.

## Purpose

This research analyzes how different agent SDKs handle:
- Agent execution models and control flow
- State management and continuation patterns
- Tool execution and approval mechanisms
- Context engineering and message modification
- Streaming and real-time updates
- Multi-agent patterns and handoffs
- Limitations and design tradeoffs

## SDK Research Files

Detailed analysis of each framework's API:

| SDK | File | Focus | Size |
|-----|------|-------|------|
| **OpenAI Agents SDK** | [OpenAI.md](OpenAI.md) | Run state, max turns, guardrails, handoffs | 53KB |
| **CrewAI** | [CrewAI.md](CrewAI.md) | Multi-agent orchestration, task delegation | 49KB |
| **Microsoft AutoGen** | [AutoGen.md](AutoGen.md) | Conversational agents, group chat patterns | 52KB |
| **Cloudflare Agents** | [Cloudflare.md](Cloudflare.md) | Durable Objects, edge deployment, state | 39KB |
| **Vercel AI SDK** | [VercelAI.md](VercelAI.md) | generateText/streamText, maxSteps, tools | 39KB |
| **PydanticAI** | [PydanticAI.md](PydanticAI.md) | Dependency injection, iter(), usage limits | 36KB |
| **Claude Agent SDK** | [ClaudeSDK.md](ClaudeSDK.md) | Hook system, lifecycle management | 32KB |
| **LangGraph** | [LangGraph.md](LangGraph.md) | StateGraph, checkpointing, interrupts | 6.5KB |

## Cross-SDK Comparison Documents

Synthesized analysis across all frameworks:

| Document | What It Covers | Key Insights |
|----------|----------------|--------------|
| [StateManagementComparison.md](StateManagementComparison.md) | State representation, checkpointing, persistence | LangGraph & Cloudflare lead in persistence; Most SDKs lack cross-session support |
| [ContextEngineeringComparison.md](ContextEngineeringComparison.md) | Message modification, hooks, token management | LangGraph & Cloudflare allow full mutation; Most use read-only hooks |
| [PauseResumeComparison.md](PauseResumeComparison.md) | Pause triggers, state preservation, resume patterns | Exception-based patterns lose state; Return-based preserves state |
| [ToolExecutionComparison.md](ToolExecutionComparison.md) | Tool definition, execution control, error handling | PydanticAI's `ModelRetry` pattern is cleanest; Most lack retry mechanisms |
| [CustomerPainPoints.md](CustomerPainPoints.md) | Real-world issues, GitHub complaints, pain points | Top issues: State loss, breaking changes, poor errors, steep learning curves |
| [TradeoffMatrix.md](TradeoffMatrix.md) | Complexity vs control, DX, performance, type safety | Yrden should target mid-level (PydanticAI position) with Swift compile-time advantages |

## Key Findings

### Execution Models

- **Hook-based** (Claude SDK): Lifecycle hooks for observation/modification
- **Iterator-based** (PydanticAI, OpenAI): Step-by-step execution control with `iter()`
- **Graph-based** (LangGraph): State machines with conditional edges
- **Orchestrator-based** (CrewAI, AutoGen): High-level delegation patterns

### State Management Approaches

- **Explicit checkpointing** (LangGraph): MemorySaver, SqliteSaver for persistence
- **Run objects** (OpenAI, Claude): Serializable state containers
- **Message history** (Vercel AI, PydanticAI): Raw message arrays
- **Durable Objects** (Cloudflare): Distributed state at the edge

### Context Engineering

- **Full control** (LangGraph): Direct state mutation via reducers
- **Hook-based** (Claude SDK): Limited modification via lifecycle hooks
- **No mutation** (PydanticAI, OpenAI): Read-only access during execution
- **Post-processing** (Vercel AI): Transform after completion

### Pause/Resume Patterns

- **Exception-based** (PydanticAI): `UsageLimitExceeded` throws, loses state
- **Return-based** (OpenAI): Returns `AgentRun` with pause reason
- **Interrupt nodes** (LangGraph): `interrupt_before`/`interrupt_after` markers
- **Human-in-the-loop modes** (AutoGen): `ALWAYS`, `NEVER`, `TERMINATE`

## Research Methodology

Each SDK was researched by:
1. Exploring official documentation and examples
2. Reading source code for implementation details
3. Analyzing API patterns and design decisions
4. Identifying tradeoffs and limitations
5. Extracting code examples demonstrating key features

## Related Design Documents

- [AgentExecutionAPI.md](../AgentExecutionAPI.md) - Our unified API design influenced by this research
- [CLAUDE.md](../../../CLAUDE.md) - Project vision and architecture

## Date

Research conducted: February 4, 2026
