## Appendix: Claude Agent SDK (Python) API Research

*Research conducted: February 2026*
*SDK Version: 0.1.29*

### 1. Core Concepts and Types

#### 1.1 Primary Interfaces

The SDK provides two distinct interfaces for interacting with Claude:

| Interface | Purpose | Session Behavior | Key Features |
|-----------|---------|------------------|--------------|
| `query()` | One-off requests | Creates new session each call | Simple, stateless |
| `ClaudeSDKClient` | Interactive conversations | Maintains single session | Multi-turn, hooks, interrupts |

**Critical distinction**: `query()` is stateless (new session per call), while `ClaudeSDKClient` maintains conversation context across multiple `query()` calls within the same client instance.

#### 1.2 Message Types

```python
# Union of all message types
Message = UserMessage | AssistantMessage | SystemMessage | ResultMessage | StreamEvent

# Content within messages
ContentBlock = TextBlock | ThinkingBlock | ToolUseBlock | ToolResultBlock
```

**Message flow**:
1. `SystemMessage` (subtype="init") - Contains session_id, loaded tools, agents
2. `AssistantMessage` - Claude's responses with content blocks
3. `ResultMessage` - Final message with usage/cost data

#### 1.3 Configuration: `ClaudeAgentOptions`

Key configuration fields (selected):

```python
@dataclass
class ClaudeAgentOptions:
    # Tools
    tools: list[str] | ToolsPreset | None = None
    allowed_tools: list[str] = field(default_factory=list)
    disallowed_tools: list[str] = field(default_factory=list)
    
    # Session management
    resume: str | None = None           # Session ID to resume
    fork_session: bool = False          # Fork vs continue when resuming
    continue_conversation: bool = False # Continue most recent conversation
    
    # Execution limits
    max_turns: int | None = None
    max_budget_usd: float | None = None
    
    # Prompts
    system_prompt: str | SystemPromptPreset | None = None
    
    # Advanced
    hooks: dict[HookEvent, list[HookMatcher]] | None = None
    can_use_tool: CanUseTool | None = None
    mcp_servers: dict[str, McpServerConfig] | str | Path = field(default_factory=dict)
    agents: dict[str, AgentDefinition] | None = None
    
    # Streaming
    include_partial_messages: bool = False
```

---

### 2. Execution Model

#### 2.1 Agent Loop

The SDK operates as a request-response cycle:
1. User sends prompt
2. Claude generates response (text and/or tool calls)
3. Tools execute if requested
4. Loop continues until completion or limit reached

**This is NOT an iterator-based loop**. The execution is abstracted behind async iteration over messages. You cannot step through individual loop iterations - you receive messages as they complete.

#### 2.2 Streaming Behavior

Two levels of streaming:
1. **Message-level** (default): Complete messages emitted as they finish
2. **Partial messages** (opt-in): Token-level streaming with `StreamEvent`

```python
# Enable partial message streaming
options = ClaudeAgentOptions(include_partial_messages=True)

async for message in client.receive_response():
    if isinstance(message, StreamEvent):
        # Real-time token updates
        event_data = message.event
```

#### 2.3 Interruption

Only available with `ClaudeSDKClient`:

```python
async with ClaudeSDKClient(options) as client:
    await client.query("Long running task...")
    await asyncio.sleep(2)
    await client.interrupt()  # Stop current execution
    await client.query("New task")  # Continue in same session
```

---

### 3. Hook System

#### 3.1 Available Hooks

| Hook Event | Trigger Point | Can Modify? | Can Block? |
|------------|---------------|-------------|------------|
| `PreToolUse` | Before tool execution | Yes (input) | Yes |
| `PostToolUse` | After tool execution | No | No |
| `UserPromptSubmit` | When user submits prompt | Yes (prompt) | No |
| `Stop` | When execution stops | No | No |
| `SubagentStop` | When subagent stops | No | No |
| `PreCompact` | Before message compaction | No | No |

**Note**: Python SDK does NOT support `SessionStart`, `SessionEnd`, or `Notification` hooks due to setup limitations.

#### 3.2 Hook Callback Signature

```python
async def hook_callback(
    input_data: dict[str, Any],  # Hook-specific input (PreToolUseHookInput, etc.)
    tool_use_id: str | None,      # For tool-related hooks
    context: HookContext          # Additional context
) -> dict[str, Any]:              # HookJSONOutput
```

#### 3.3 Hook Capabilities

**PreToolUse can**:
- **Allow** execution with optional input modification
- **Deny** execution with reason
- **Add system messages** for user feedback

```python
async def security_hook(input_data, tool_use_id, context):
    if "rm -rf" in input_data.get("tool_input", {}).get("command", ""):
        return {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": "Dangerous command blocked"
            }
        }
    return {}  # Allow
```

**PostToolUse can**:
- Add additional context for Claude
- Log/audit tool results
- Cannot modify or block

**Control fields available**:
- `continue_`: Boolean to continue/stop execution
- `stopReason`: Message when stopping
- `systemMessage`: User-visible feedback
- `additionalContext`: Extra info for Claude

#### 3.4 Limitations

- Hooks run **synchronously** in the execution flow (though async Python functions)
- Cannot modify messages already in transcript
- Cannot inject new tool calls
- Limited to predefined hook points

---

### 4. Tool Execution

#### 4.1 Tool Definition with `@tool` Decorator

```python
from claude_agent_sdk import tool, create_sdk_mcp_server

@tool("greet", "Greet a user", {"name": str})
async def greet_user(args: dict[str, Any]) -> dict[str, Any]:
    return {
        "content": [{"type": "text", "text": f"Hello, {args['name']}!"}]
    }

# Error handling
@tool("divide", "Divide two numbers", {"a": float, "b": float})
async def divide(args):
    if args["b"] == 0:
        return {
            "content": [{"type": "text", "text": "Cannot divide by zero"}],
            "is_error": True  # Marks as error
        }
    return {"content": [{"type": "text", "text": str(args["a"] / args["b"])}]}
```

#### 4.2 Tool Registration via MCP

```python
# Create in-process MCP server
server = create_sdk_mcp_server(
    name="my-tools",
    version="1.0.0",
    tools=[greet_user, divide]
)

# Configure agent
options = ClaudeAgentOptions(
    mcp_servers={"tools": server},
    allowed_tools=["mcp__tools__greet", "mcp__tools__divide"]
)
```

Tool naming convention: `mcp__<server_name>__<tool_name>`

#### 4.3 Tool Permission Callback

For fine-grained control beyond hooks:

```python
async def permission_handler(
    tool_name: str,
    input_data: dict,
    context: ToolPermissionContext
) -> PermissionResultAllow | PermissionResultDeny:
    
    # Auto-approve safe tools
    if tool_name in ["Read", "Grep"]:
        return PermissionResultAllow(updated_input=input_data)
    
    # Redirect sensitive operations
    if tool_name == "Write" and "config" in input_data.get("file_path", ""):
        safe_path = f"./sandbox/{input_data['file_path']}"
        return PermissionResultAllow(
            updated_input={**input_data, "file_path": safe_path}
        )
    
    # Block dangerous operations
    if tool_name == "Bash" and "rm -rf" in input_data.get("command", ""):
        return PermissionResultDeny(
            message="Dangerous command blocked",
            interrupt=True  # Stop execution entirely
        )
    
    return PermissionResultAllow(updated_input=input_data)

options = ClaudeAgentOptions(can_use_tool=permission_handler)
```

**Key difference from hooks**: Permission callback can modify tool inputs and deny with optional interrupt, while hooks have more structured output but less direct control.

---

### 5. Continuation/Resume Patterns

#### 5.1 Session Persistence

Sessions are automatically persisted to disk (`~/.claude/projects/`). Session ID is available in the init message:

```python
async for message in query(prompt="Start task", options=options):
    if hasattr(message, 'subtype') and message.subtype == 'init':
        session_id = message.data.get('session_id')
        # Save session_id for later
```

#### 5.2 Resuming a Session

```python
# Resume existing session
options = ClaudeAgentOptions(
    resume="session-xyz",  # Previously saved session_id
)

async for message in query(
    prompt="Continue where we left off",
    options=options
):
    print(message)
```

#### 5.3 Forking Sessions

Fork creates a new branch from the resume point without modifying the original:

```python
options = ClaudeAgentOptions(
    resume="session-xyz",
    fork_session=True,  # Creates new session ID, preserves original
)
```

| Behavior | `fork_session=False` (default) | `fork_session=True` |
|----------|-------------------------------|---------------------|
| Session ID | Same as original | New ID generated |
| History | Appends to original | Creates branch |
| Original | Modified | Preserved |
| Use Case | Continue linear work | Explore alternatives |

#### 5.4 Cross-Session State

The SDK does NOT provide:
- Automatic state serialization beyond session transcript
- Cross-process session sharing
- Custom state injection on resume

What IS preserved:
- Full conversation transcript
- Tool execution history
- File changes (with checkpointing if enabled)

---

### 6. Limitations and Tradeoffs

#### 6.1 Architectural Constraints

1. **CLI Dependency**: SDK wraps Claude Code CLI - not a direct API client
   - Pros: Same capabilities as CLI, bundled automatically
   - Cons: Process overhead, limited to CLI's feature set

2. **No Iterator-Based Loop Control**: Cannot step through individual agent loop iterations
   - You receive messages as they complete
   - Cannot pause/resume mid-turn
   - Cannot inject messages during execution (only via hooks)

3. **Hook Limitations**:
   - Python SDK lacks `SessionStart`, `SessionEnd`, `Notification` hooks
   - Hooks are callbacks, not coroutines that yield control
   - Cannot modify past messages or inject new tool calls

4. **Session Persistence is Local**:
   - Sessions stored on filesystem only
   - No built-in cloud/remote session storage
   - No session transfer between machines

#### 6.2 What You CAN'T Do

| Desired Behavior | Status | Workaround |
|------------------|--------|------------|
| Step through loop iterations | Not supported | Use hooks for observation |
| Modify messages during execution | Not supported | Use `can_use_tool` for inputs |
| Custom output types (beyond JSON) | Not supported | Post-process JSON output |
| Run without CLI | Not supported | None - CLI is required |
| Share sessions across processes | Not supported | Manual transcript transfer |
| Cancel mid-tool-execution | Not supported | Can only interrupt between turns |
| Add custom message types | Not supported | Use system messages |

#### 6.3 Design Decisions

1. **Hook-based over iterator-based**: Simpler mental model but less flexible
2. **MCP for custom tools**: Standard protocol but adds complexity
3. **Session persistence by default**: Good for resumption, privacy concerns
4. **Permission callbacks separate from hooks**: Cleaner separation but two systems to learn

#### 6.4 Known Issues/Pain Points

1. **Budget checking is post-hoc**: "Budget checking happens after each API call completes, so the final cost may slightly exceed the specified budget."

2. **Asyncio cleanup with `break`**: "When iterating over messages, avoid using `break` to exit early as this can cause asyncio cleanup issues."

3. **No thinking block streaming**: Thinking blocks arrive complete, not streamed

4. **Tool input schema limitations**: Simple type mapping or full JSON Schema, nothing in between

---

### 7. Comparison with Yrden Design Goals

| Feature | Claude Agent SDK | Yrden Goal |
|---------|-----------------|------------|
| Loop control | Hooks only | Iterator-based (`.iter()`) |
| Tool definition | `@tool` decorator + MCP | Protocol conformance |
| Typed outputs | JSON Schema | `@Schema` macro |
| Provider support | Claude only (via CLI) | Multi-provider |
| Dependency injection | None | `RunContext[Deps]` |
| Retry signals | None | `ToolRejection` / `ModelRetry` |
| Skills system | Plugins/Agents | First-class Skills |
| Streaming | Message + partial | Full event streaming |

**Key insight for Yrden**: The Claude Agent SDK prioritizes simplicity and integration with Claude Code CLI over flexibility. For Yrden, the PydanticAI-style iterator approach (`for await node in agent.iter()`) provides more control at the cost of complexity.

---

### 8. Code Patterns Summary

#### Basic Query
```python
async for message in query(prompt="Hello", options=ClaudeAgentOptions()):
    if isinstance(message, AssistantMessage):
        print(message.content)
```

#### Multi-Turn with Context
```python
async with ClaudeSDKClient() as client:
    await client.query("First question")
    async for msg in client.receive_response(): pass
    
    await client.query("Follow up")  # Remembers context
    async for msg in client.receive_response(): pass
```

#### Custom Tool + Hook
```python
@tool("search", "Search docs", {"query": str})
async def search(args): ...

async def audit_hook(input_data, tool_use_id, ctx):
    print(f"Tool: {input_data['tool_name']}")
    return {}

options = ClaudeAgentOptions(
    mcp_servers={"s": create_sdk_mcp_server("s", tools=[search])},
    allowed_tools=["mcp__s__search"],
    hooks={"PreToolUse": [HookMatcher(hooks=[audit_hook])]}
)
```

#### Resume with Fork
```python
# Original session
async for msg in query(prompt="Start", options=ClaudeAgentOptions()):
    if msg.subtype == 'init': session_id = msg.data['session_id']

# Fork to explore alternative
async for msg in query(
    prompt="Try different approach",
    options=ClaudeAgentOptions(resume=session_id, fork_session=True)
): pass
```

---

### Sources

- [Claude Agent SDK GitHub](https://github.com/anthropics/claude-agent-sdk-python)
- [Agent SDK Python Reference](https://platform.claude.com/docs/en/agent-sdk/python)
- [Session Management Documentation](https://platform.claude.com/docs/en/agent-sdk/sessions)
- [PyPI Package](https://pypi.org/project/claude-agent-sdk/)
Now let me compile the additional research findings into an extended section.

---

## Appendix: Claude Agent SDK (Python) API Research (Continued)

### 9. Structured Outputs

#### 9.1 Core Concept

Structured outputs enforce schema validation on agent responses. The agent can use any tools needed to complete a task, then returns validated JSON matching your schema. This bridges the gap between free-form agent execution and typed application integration.

**Key workflow**:
1. Define JSON Schema (or generate via Pydantic/Zod)
2. Pass via `output_format` in options
3. Agent runs normally (multi-turn, tool use)
4. Final response includes `structured_output` field with validated data

#### 9.2 Configuration

```python
from pydantic import BaseModel

class Report(BaseModel):
    company_name: str
    founded_year: int
    headquarters: str

schema = Report.model_json_schema()

options = ClaudeAgentOptions(
    output_format={
        "type": "json_schema",
        "schema": schema
    }
)

async for message in query(prompt="Research Anthropic", options=options):
    if isinstance(message, ResultMessage) and message.structured_output:
        # Validate with Pydantic
        report = Report.model_validate(message.structured_output)
        print(f"Founded: {report.founded_year}")
```

#### 9.3 Error Handling

| Subtype | Meaning |
|---------|---------|
| `success` | Output generated and validated |
| `error_max_structured_output_retries` | Agent couldn't produce valid output after retries |

```python
if message.subtype == "success" and message.structured_output:
    data = MySchema.model_validate(message.structured_output)
elif message.subtype == "error_max_structured_output_retries":
    # Fallback: simplify schema, retry with clearer prompt
```

#### 9.4 Best Practices

1. **Keep schemas focused**: Deeply nested schemas are harder to satisfy
2. **Make fields optional if data might not exist**: Don't require fields the task can't always provide
3. **Use clear prompts**: Ambiguity makes schema satisfaction harder
4. **Validate runtime**: Always use `model_validate()` even though SDK validates

---

### 10. File Checkpointing

#### 10.1 How It Works

File checkpointing tracks modifications made through `Write`, `Edit`, and `NotebookEdit` tools. Each user message gets a UUID that serves as a restore point.

**What's tracked**:
- Files created during session
- Files modified during session
- Original content of modified files

**What's NOT tracked**:
- Changes via Bash commands (`echo >`, `sed -i`)
- Directory operations (mkdir, rmdir)
- Network/remote files

#### 10.2 Setup Requirements

1. **Environment variable**: `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=1`
2. **Enable in options**: `enable_file_checkpointing=True`
3. **Get checkpoint UUIDs**: `extra_args={"replay-user-messages": None}`

```python
import os

options = ClaudeAgentOptions(
    enable_file_checkpointing=True,
    permission_mode="acceptEdits",  # Auto-approve edits
    extra_args={"replay-user-messages": None},
    env={**os.environ, "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING": "1"}
)
```

#### 10.3 Capture and Rewind Pattern

```python
checkpoint_id = None
session_id = None

async with ClaudeSDKClient(options) as client:
    await client.query("Refactor auth module")
    
    async for message in client.receive_response():
        # Capture checkpoint on each user message
        if isinstance(message, UserMessage) and message.uuid:
            checkpoint_id = message.uuid
        # Capture session ID for later resume
        if isinstance(message, ResultMessage):
            session_id = message.session_id

# Later: rewind by resuming session
async with ClaudeSDKClient(ClaudeAgentOptions(
    enable_file_checkpointing=True,
    resume=session_id
)) as client:
    await client.query("")  # Empty prompt to open connection
    async for message in client.receive_response():
        await client.rewind_files(checkpoint_id)
        break
```

#### 10.4 Common Patterns

**Latest checkpoint only** (overwrite pattern):
```python
safe_checkpoint = None

async for message in client.receive_response():
    if isinstance(message, UserMessage) and message.uuid:
        safe_checkpoint = message.uuid  # Keep overwriting
    
    if error_detected and safe_checkpoint:
        await client.rewind_files(safe_checkpoint)
        break
```

**Multiple checkpoints** (branching pattern):
```python
@dataclass
class Checkpoint:
    id: str
    description: str
    timestamp: datetime

checkpoints = []

async for message in client.receive_response():
    if isinstance(message, UserMessage) and message.uuid:
        checkpoints.append(Checkpoint(
            id=message.uuid,
            description=f"After turn {len(checkpoints) + 1}",
            timestamp=datetime.now()
        ))

# Later: rewind to any checkpoint
target = checkpoints[0]  # Or let user choose
await client.rewind_files(target.id)
```

#### 10.5 Limitations

- File content only (not directories)
- Bash changes not tracked
- Session-specific (can't rewind across sessions)
- Local files only

---

### 11. Permission System Deep Dive

#### 11.1 Evaluation Order

Permissions are evaluated in strict order (first match wins):

1. **Hooks** (`PreToolUse`) - Can allow/deny/continue
2. **Permission rules** (from settings.json) - Deny → Allow → Ask
3. **Permission mode** (`bypassPermissions`, `acceptEdits`, etc.)
4. **`can_use_tool` callback** - Final decision

![Permission flow](conceptual visualization: Hooks → Rules → Mode → Callback → Tool Execution)

#### 11.2 Permission Modes Detailed

| Mode | Auto-Approves | Blocks | Use Case |
|------|---------------|--------|----------|
| `default` | Nothing | Nothing | Human approves everything |
| `acceptEdits` | File ops (`Write`, `Edit`, `mkdir`, `rm`, `mv`, `cp`) | Other tools | Prototype/code changes |
| `bypassPermissions` | Everything | Nothing | Trusted env only |
| `plan` | Nothing | All tool execution | Review before execution |

**Dynamic mode switching**:
```python
# Start restrictive
q = query(prompt="...", options=ClaudeAgentOptions(permission_mode="default"))

# After reviewing initial approach, allow edits
await q.set_permission_mode("acceptEdits")

async for message in q:
    # Messages processed with new mode
```

#### 11.3 Tool Permission Callback Return Types

```python
# Allow (unchanged)
PermissionResultAllow(updated_input=input_data)

# Allow (modified)
PermissionResultAllow(
    updated_input={**input_data, "file_path": "./sandbox/safe.txt"}
)

# Deny with reason (Claude sees this)
PermissionResultDeny(
    message="Cannot write to system directories",
    interrupt=False  # Continue execution
)

# Deny and stop execution
PermissionResultDeny(
    message="Critical security violation",
    interrupt=True  # Stop everything
)
```

#### 11.4 `AskUserQuestion` Tool

Claude calls this tool to ask clarifying questions (not arbitrary tool approval).

**Input structure**:
```python
{
    "questions": [
        {
            "question": "How should I format the output?",
            "header": "Format",  # Max 12 chars
            "options": [
                {"label": "Summary", "description": "Brief overview"},
                {"label": "Detailed", "description": "Full explanation"}
            ],
            "multiSelect": False
        }
    ]
}
```

**Response structure**:
```python
{
    "questions": [...],  # Pass through original
    "answers": {
        "How should I format the output?": "Summary",
        "Which sections to include?": "Intro, Conclusion"  # Multi-select
    }
}
```

**Key points**:
- 1-4 questions per call
- 2-4 options per question
- 60-second timeout for callback
- Not available in subagents
- Requires `AskUserQuestion` in `allowed_tools` if you specify tools

---

### 12. Budget and Limits

#### 12.1 Budget Control

```python
options = ClaudeAgentOptions(max_budget_usd=0.10)

async for message in query(prompt="...", options=options):
    if hasattr(message, 'subtype') and message.subtype == "error_max_budget_usd":
        print("Budget exceeded!")
        # Final cost may slightly exceed budget
```

**Important**: Budget checking happens AFTER each API call completes, so the final cost may exceed the limit by one call's cost.

#### 12.2 Turn Limits

```python
options = ClaudeAgentOptions(max_turns=5)
```

Limits total number of conversation turns (user + assistant pairs).

#### 12.3 Usage Tracking

```python
async for message in query(...):
    if isinstance(message, ResultMessage):
        print(f"Cost: ${message.total_cost_usd}")
        print(f"Turns: {message.num_turns}")
        print(f"Duration: {message.duration_ms}ms")
        print(f"API time: {message.duration_api_ms}ms")
        if message.usage:
            print(f"Tokens: {message.usage}")
```

---

### 13. Plugins

#### 13.1 Loading Plugins

```python
options = ClaudeAgentOptions(
    plugins=[
        {"type": "local", "path": "./my-plugin"},
        {"type": "local", "path": "/absolute/path/plugin"}
    ]
)
```

**Discovery pattern**:
```python
async for message in query(prompt="...", options=options):
    if hasattr(message, 'subtype') and message.subtype == 'init':
        plugins = message.data.get("plugins", [])
        for plugin in plugins:
            print(f"Loaded: {plugin.get('name')}")
```

#### 13.2 Plugin Capabilities

Plugins can provide:
- Custom commands (slash commands)
- Custom agents
- Custom skills
- Custom hooks

**Note**: Only local plugins are currently supported.

---

### 14. Debugging with stderr

```python
stderr_messages = []

def stderr_callback(line: str):
    if "[ERROR]" in line:
        stderr_messages.append(line)
        print(f"Debug: {line}")

options = ClaudeAgentOptions(
    stderr=stderr_callback,
    extra_args={"debug-to-stderr": None}  # Enable CLI debug output
)

async for message in query(prompt="...", options=options):
    pass

# After execution, review stderr_messages
```

---

### 15. Comparison: Hook vs Permission Callback

| Aspect | Hooks | Permission Callback |
|--------|-------|---------------------|
| **Trigger** | Specific events (PreToolUse, PostToolUse) | Unresolved permission decisions |
| **Runs** | Always (for matched tools) | Only if rules/modes don't resolve |
| **Can modify input?** | Yes (via hookSpecificOutput) | Yes (via updated_input) |
| **Can deny?** | Yes (permissionDecision: "deny") | Yes (PermissionResultDeny) |
| **Can interrupt?** | Yes (continue_: False) | Yes (interrupt=True) |
| **Can add context?** | Yes (additionalContext) | Via message field |
| **Async?** | Yes (async function) | Yes (async function) |
| **Timeout** | Configurable per matcher | 60 seconds (fixed) |
| **User prompt?** | No (deterministic) | Yes (can prompt user) |

**When to use each**:
- **Hooks**: Deterministic security policies, logging, validation
- **Permission callback**: User approval flows, interactive decisions

---

### 16. Settings Sources

#### 16.1 Available Sources

```python
SettingSource = Literal["user", "project", "local"]
```

| Source | Location | Version Controlled |
|--------|----------|-------------------|
| `user` | `~/.claude/settings.json` | No (global) |
| `project` | `.claude/settings.json` | Yes (shared) |
| `local` | `.claude/settings.local.json` | No (gitignored) |

#### 16.2 Default Behavior

**When `setting_sources` is omitted or `None`**: No filesystem settings are loaded (isolated environment).

**Why this matters**: The SDK isolates itself from file-based config by default, unlike the CLI. You must explicitly opt-in to load settings.

#### 16.3 Loading CLAUDE.md

```python
options = ClaudeAgentOptions(
    setting_sources=["project"],  # Required to load CLAUDE.md
    system_prompt={
        "type": "preset",
        "preset": "claude_code"  # Use default system prompt
    }
)
```

Without `setting_sources=["project"]`, CLAUDE.md files are ignored.

#### 16.4 Precedence

When multiple sources are loaded:
1. Local settings (highest priority)
2. Project settings
3. User settings (lowest priority)

Programmatic options always override filesystem settings.

---

### 17. Sandbox Settings

#### 17.1 Configuration

```python
from claude_agent_sdk import SandboxSettings

sandbox: SandboxSettings = {
    "enabled": True,
    "autoAllowBashIfSandboxed": True,
    "excludedCommands": ["docker"],  # Always bypass sandbox
    "allowUnsandboxedCommands": False,  # Model can't request escape
    "network": {
        "allowLocalBinding": True,  # Dev servers
        "allowUnixSockets": ["/var/run/docker.sock"],  # Specific sockets
        "httpProxyPort": 8080,
        "socksProxyPort": 1080
    },
    "ignoreViolations": {
        "file": ["/tmp/*"],
        "network": ["localhost"]
    }
}

options = ClaudeAgentOptions(sandbox=sandbox)
```

#### 17.2 Key Distinction

**Filesystem/network restrictions**: NOT in sandbox settings. They come from permission rules (Read/Edit/WebFetch deny rules).

**Sandbox settings**: For command execution sandboxing only.

#### 17.3 Unsandboxed Command Flow

When `allowUnsandboxedCommands=True`:
1. Model sets `dangerouslyDisableSandbox: True` in tool input
2. Request falls back to permission system
3. Your `can_use_tool` callback is invoked
4. You authorize or deny

```python
async def can_use_tool(tool_name, input_data, context):
    if tool_name == "Bash" and input_data.get("dangerouslyDisableSandbox"):
        # Model requesting to escape sandbox
        if is_authorized(input_data["command"]):
            return PermissionResultAllow(updated_input=input_data)
        return PermissionResultDeny(message="Unauthorized unsandboxed command")
    return PermissionResultAllow(updated_input=input_data)
```

---

### 18. Subagents and Multi-Agent Patterns

#### 18.1 Programmatic Agents

```python
from claude_agent_sdk import AgentDefinition

options = ClaudeAgentOptions(
    agents={
        "code_reviewer": AgentDefinition(
            description="Reviews code for bugs and style issues",
            prompt="You are a thorough code reviewer. Check for security, performance, and style.",
            tools=["Read", "Grep", "Glob"],
            model="sonnet"  # or "opus", "haiku", "inherit"
        ),
        "test_writer": AgentDefinition(
            description="Writes unit and integration tests",
            prompt="You write comprehensive test suites.",
            tools=["Read", "Write", "Bash"],
            model="inherit"  # Use parent's model
        )
    }
)
```

#### 18.2 Agent Invocation

Claude autonomously selects which agent to use based on descriptions. Alternatively, you can invoke explicitly via the `Task` tool (if exposed).

**Task tool input**:
```python
{
    "description": "Review auth module",  # Short 3-5 word description
    "prompt": "Review the authentication code for security issues",
    "subagent_type": "code_reviewer"
}
```

**Task tool output**:
```python
{
    "result": "Found 3 issues...",
    "usage": {...},
    "total_cost_usd": 0.05,
    "duration_ms": 15000
}
```

#### 18.3 Subagent Limitations

- `AskUserQuestion` not available in subagents
- Subagents inherit `bypassPermissions` mode (cannot be overridden)
- Hooks may not cover all subagent events (Python SDK limitations)

---

### 19. Key Architectural Insights for Yrden

After comprehensive research, here are the critical takeaways:

#### 19.1 What Works Well

1. **Hook system for observability**: Clean separation between deterministic logic (hooks) and interactive approval (callbacks)
2. **Session persistence**: Automatic save/resume is convenient for long-running workflows
3. **Structured outputs**: Bridging free-form execution with typed results is elegant
4. **File checkpointing**: Unique feature not found elsewhere
5. **MCP integration**: Standard protocol for tool definition

#### 19.2 What Doesn't Work Well

1. **No iterator-based loop control**: You observe via hooks, can't step through iterations
2. **CLI dependency**: Process overhead, limited to CLI capabilities
3. **Python hook limitations**: Missing SessionStart, SessionEnd, Notification hooks
4. **60-second timeout on callbacks**: Hard limit, no extension
5. **Post-hoc budget checking**: Can exceed budget by one API call
6. **No cross-process session sharing**: Sessions are local only

#### 19.3 Design Philosophy Differences

| Aspect | Claude Agent SDK | PydanticAI (Reference) | Yrden Goal |
|--------|-----------------|------------------------|------------|
| **Control model** | Hooks (observe) | Iterators (control) | Iterator-based |
| **State management** | Automatic persistence | Manual | Flexible |
| **Provider** | Claude only | Multi-provider | Multi-provider |
| **Dependency injection** | None | `RunContext[Deps]` | `RunContext[Deps]` |
| **Retry signals** | None | `ModelRetry` | `ToolRejection` |
| **Type safety** | Runtime JSON Schema | Pydantic (compile-time) | `@Schema` macro |

#### 19.4 Patterns to Adopt for Yrden

1. **Structured outputs**: The `output_format` approach is clean
2. **Permission modes**: Simple presets for common cases
3. **File checkpointing concept**: Unique and useful
4. **Hook + callback separation**: Deterministic vs interactive is good separation

#### 19.5 Patterns to Avoid for Yrden

1. **Hook-only observation**: Provide iterator-based loop control
2. **Automatic session persistence**: Make it opt-in
3. **Single-provider lock-in**: Abstract providers cleanly
4. **CLI wrapper pattern**: Build as direct API client

---

### Sources (Continued)

- [Structured Outputs Documentation](https://platform.claude.com/docs/en/agent-sdk/structured-outputs)
- [File Checkpointing Documentation](https://platform.claude.com/docs/en/agent-sdk/file-checkpointing)
- [Permissions Documentation](https://platform.claude.com/docs/en/agent-sdk/permissions)
- [User Input Documentation](https://platform.claude.com/docs/en/agent-sdk/user-input)
- [GitHub Examples Directory](https://github.com/anthropics/claude-agent-sdk-python/tree/main/examples)
