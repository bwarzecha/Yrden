# Design: Complete Tool Set

> Redesigned to match Claude Code's tool architecture. Based on comparative analysis of Claude Code, OpenAI Codex CLI, Google Gemini CLI, Cursor, Windsurf, and Aider.

## Scope

This document covers:

1. **Refinements to existing tools** — Shell (add `description`, `run_in_background`), ReadFile (no changes needed), WriteFile (no changes needed)
2. **Three new core tools** — EditFile, Glob, Grep
3. **Background execution system** — `run_in_background` flag on Shell + TaskOutput + TaskStop tools
4. **Subagent tool** (stretch) — Task tool for spawning isolated sub-agents

**Dropped**: ListDirectory — Claude Code doesn't have one and gets by with Glob + Shell `ls`. Not worth a dedicated tool.

---

## Design Principles

Six principles from cross-agent analysis (Claude Code, Codex, Gemini CLI, Cursor, Aider):

1. **Context window is the scarce resource** — Tools default to minimal output. Grep returns paths only. Glob returns paths only. The agent fetches details via ReadFile.
2. **Content-based matching, not positional** — Edits use string matching, not line numbers. Line numbers drift after each edit.
3. **Tools do one thing well** — Glob finds files. Grep searches content. Read retrieves. Edit modifies. No overlap. Agent composes: Glob → Read → Edit.
4. **Errors are information, not termination** — Tool errors feed back to the LLM for self-correction.
5. **Safety through constraints** — Uniqueness enforcement on edits, PathValidator on all file ops, approval tiers by category.
6. **Simplicity over sophistication** — Regex over vector embeddings. String matching over AST. Foundation over ripgrep.

---

## Complete Tool Catalog

### Overview

| # | Tool | Status | Approval | Category |
|---|------|--------|----------|----------|
| 1 | `read_file` | Exists | Auto | File read |
| 2 | `write_file` | Exists | Auto | File write |
| 3 | `shell` | **Refined** | Required | Execution |
| 4 | `edit_file` | **New** | Auto | File write |
| 5 | `glob` | **New** | Auto | Search |
| 6 | `grep` | **New** | Auto | Search |
| 7 | `task_output` | **New** | Auto | Background |
| 8 | `task_stop` | **New** | Auto | Background |
| 9 | `task` | **New (stretch)** | Auto | Orchestration |

---

## Tool 1: ReadFile (No Changes)

The existing ReadFileTool is well-designed. No modifications needed.

**Current spec**: 500 lines default, 4K per-line truncation, 100K total character cap, compact `N: content` format, streaming via `URL.lines`, binary detection, file header metadata.

**Comparison to Claude Code**: Claude Code uses 2,000 lines/2,000 chars per line with `cat -n` format. Yrden's approach is actually better — more conservative defaults save tokens, compact format saves ~40% overhead, and the file header (`[File: path | Lines X-Y of Z | size]`) gives the agent metadata Claude Code lacks.

**Future consideration**: PDF and image support are possible additions but depend on the LLM being multimodal. Not blocking.

---

## Tool 2: WriteFile (No Changes)

The existing WriteFileTool is well-designed. No modifications needed.

**Current spec**: Atomic writes, parent directory creation, 10MB max, PathValidator.

**Comparison to Claude Code**: Claude Code enforces "must read before write" — the tool fails if the file exists but hasn't been read. This prevents blind overwrites. However, this is an **agent-loop concern** (tracking which files have been read), not a tool-level feature. If we add it later, it goes in the execution engine, not the tool.

---

## Tool 3: Shell (Refined)

Two additions to the existing ShellTool: `description` parameter and `run_in_background` flag.

### Changes to ShellToolArgs

```swift
@Schema(description: "Execute a shell command")
public struct ShellToolArgs {
    @Guide(description: "Shell command to execute")
    public let command: String

    @Guide(description: "Working directory for the command")
    public let workingDirectory: String?

    @Guide(description: "Timeout in seconds (default: 120, max: 600)")
    public let timeout: Int?

    // NEW
    @Guide(description: "Brief description of what this command does")
    public let description: String?

    // NEW
    @Guide(description: "Run in background and return a task ID. Use task_output to check results later")
    public let run_in_background: Bool?
}
```

### `description` Parameter

**What**: A human-readable, 5–15 word description of what the command does. Examples: "Run Swift tests", "Install npm dependencies", "Check git status".

**Why**: This is not sent to the LLM — it's for the **approval UI**. When the user sees a shell command like `find . -name "*.tmp" -exec rm {} \;`, the description "Delete all .tmp files recursively" helps them decide faster. Claude Code has this; it's a UX feature.

**Implementation**: Store in `ToolCallResult` metadata. Pass through `AgentStreamEvent.toolCallStart` for UI display. No execution impact.

### `run_in_background` Parameter

**What**: When `true`, the shell command starts executing but the tool returns immediately with a task ID. The agent can continue working and check results later via `task_output`.

**Why**: Long-running commands (builds, test suites, installations) block the agent loop. Background execution lets the agent do other work while waiting.

**Implementation**: See "Background Execution Architecture" section below.

**Return format** when `run_in_background: true`:
```
Background task started: task_abc123
Command: swift test
Use task_output to check results.
```

### No Other Changes

The existing Shell implementation (CWD tracking, spillover, head+tail truncation, environment capture, timeout, PathValidator) is already better than Claude Code's in key ways (spillover files, head+tail vs head-only truncation). No changes needed.

---

## Tool 4: EditFile (New)

### Design Rationale

Every major agent uses content-based search/replace for file editing. This is the format Anthropic's models are specifically trained on (`str_replace_based_edit_tool`). It's safer than line-based editing (line numbers drift) and simpler than diff formats (fewer model errors).

### Args

```swift
@Schema(description: "Make an exact text replacement in a file")
public struct EditFileArgs {
    @Guide(description: "Absolute path to the file to edit")
    public let path: String

    @Guide(description: "The exact text to find in the file")
    public let old_string: String

    @Guide(description: "The replacement text (must differ from old_string)")
    public let new_string: String

    @Guide(description: "Replace all occurrences. Default false — fails if old_string matches more than once")
    public let replace_all: Bool?
}
```

### Configuration

```swift
public struct EditFileTool: TypedTool {
    public typealias Args = EditFileArgs

    public let name = "edit_file"
    public let description = """
        Make an exact text replacement in a file. The old_string must match exactly \
        (including whitespace and indentation). When replace_all is false (default), \
        old_string must be unique in the file — include enough surrounding context \
        to identify exactly one location. To insert text, include surrounding lines \
        in old_string and add the new text in the appropriate position in new_string. \
        To delete text, omit it from new_string.
        """

    public let pathValidator: PathValidator
    public let maxFileSize: Int  // Default: 10_000_000 (10 MB)

    public init(
        pathValidator: PathValidator,
        maxFileSize: Int = 10_000_000
    )
}
```

### Execution Flow

1. `pathValidator.validateWrite(path)` → resolved path
2. File exists? → error if not
3. File size ≤ `maxFileSize`? → error if not
4. Read full content as String
5. `old_string` is not empty? → error: "use write_file for new files"
6. `old_string` ≠ `new_string`? → error: "no changes needed"
7. Count occurrences of `old_string` in content
8. If `replace_all ?? false`:
   - 0 matches → error
   - N matches → replace all
9. Else (single replacement mode):
   - 0 matches → error: "No match found. The file may have changed since you last read it."
   - 1 match → replace
   - N matches → error: "Found {N} matches. Include more surrounding context in old_string to uniquely identify the location, or set replace_all to true."
10. Write modified content atomically
11. Return: "Replaced {N} occurrence(s) in {path}"

### Error Messages

Designed to enable LLM self-correction:

| Scenario | Message |
|----------|---------|
| Not found | `"File not found: {path}"` |
| No match | `"No match found for the specified text in {path}. The file may have been modified since you last read it."` |
| Ambiguous | `"Found {N} matches for the specified text in {path}. Include more surrounding context in old_string to uniquely identify the location, or set replace_all to true."` |
| Same strings | `"old_string and new_string are identical. No changes needed."` |
| Empty old_string | `"old_string cannot be empty. To create a new file, use write_file."` |
| File too large | `"File is {size} which exceeds the {limit} limit."` |

---

## Tool 5: Glob (New)

### Args

```swift
@Schema(description: "Find files matching a glob pattern")
public struct GlobArgs {
    @Guide(description: "Glob pattern (e.g., '**/*.swift', 'src/**/*.ts', '*.json')")
    public let pattern: String

    @Guide(description: "Directory to search in. Defaults to working directory")
    public let path: String?
}
```

### Configuration

```swift
public struct GlobTool: TypedTool {
    public typealias Args = GlobArgs

    public let name = "glob"
    public let description = """
        Find files matching a glob pattern. Returns file paths sorted by most \
        recently modified first. Supports *, **, ?, {a,b}, [abc] patterns. \
        Use this to find files by name or extension before reading them.
        """

    public let pathValidator: PathValidator
    public let workingDirectory: String
    public let maxResults: Int         // Default: 200
    public let respectGitignore: Bool  // Default: true

    public init(
        pathValidator: PathValidator,
        workingDirectory: String,
        maxResults: Int = 200,
        respectGitignore: Bool = true
    )
}
```

### Execution Flow

1. Resolve `path` (or `workingDirectory`) via `pathValidator.validateRead`
2. Enumerate files via `FileManager.enumerator(at:includingPropertiesForKeys:)`
3. Match each relative path against `pattern` using `fnmatch(3)` with `FNM_PATHNAME`
4. Filter against `.gitignore` if `respectGitignore` and in a git repo
5. Collect `(path, modificationDate)` tuples
6. Sort by modification date descending (newest first)
7. Take first `maxResults`
8. Return relative paths, newline-separated
9. If truncated: append `"[...showing {maxResults} of {total} matches]"`

### Output Example

```
Sources/Yrden/Agent/Agent.swift
Sources/Yrden/Agent/AgentTool.swift
Sources/Yrden/Tools/EditFileTool.swift
Tests/YrdenTests/Unit/Tools/EditFileToolTests.swift
[...showing 200 of 847 matches]
```

---

## Tool 6: Grep (New)

### Args

```swift
@Schema(description: "Search file contents using a regex pattern")
public struct GrepArgs {
    @Guide(description: "Regular expression pattern to search for")
    public let pattern: String

    @Guide(description: "File or directory to search in. Defaults to working directory")
    public let path: String?

    @Guide(description: "Output: 'files' (default, paths only), 'content' (matching lines), 'count' (match counts per file)")
    public let output_mode: String?

    @Guide(description: "Glob pattern to filter files (e.g., '*.swift')")
    public let glob: String?

    @Guide(description: "Case-insensitive search")
    public let case_insensitive: Bool?

    @Guide(description: "Lines of context before each match (content mode only)")
    public let context_before: Int?

    @Guide(description: "Lines of context after each match (content mode only)")
    public let context_after: Int?

    @Guide(description: "Maximum number of results to return")
    public let max_results: Int?
}
```

### Configuration

```swift
public struct GrepTool: TypedTool {
    public typealias Args = GrepArgs

    public let name = "grep"
    public let description = """
        Search file contents using a regex pattern. Returns file paths by default \
        (most context-efficient). Use output_mode 'content' to see matching lines \
        with optional context, or 'count' for match counts. Respects .gitignore. \
        Use glob to filter by file type (e.g., '*.swift').
        """

    public let pathValidator: PathValidator
    public let workingDirectory: String
    public let defaultMaxResults: Int   // Default: 100
    public let respectGitignore: Bool   // Default: true
    public let totalCharacterLimit: Int // Default: 100_000

    public init(
        pathValidator: PathValidator,
        workingDirectory: String,
        defaultMaxResults: Int = 100,
        respectGitignore: Bool = true,
        totalCharacterLimit: Int = 100_000
    )
}
```

### Output Modes

**`files` (default)** — one path per line:
```
Sources/Yrden/Agent/Agent.swift
Sources/Yrden/Agent/AgentTool.swift
```

**`content`** — matching lines with file:line:content:
```
Sources/Yrden/Agent/Agent.swift
  42:     public let tools: [any Tool]
  68:     func executeTool(_ call: ToolCall) async throws -> AnyToolResult {

Sources/Yrden/Agent/AgentTool.swift
  39: public protocol Tool: Sendable {
```

**`count`** — match count per file:
```
Sources/Yrden/Agent/Agent.swift: 5
Sources/Yrden/Agent/AgentTool.swift: 12
```

### Execution Flow

1. Resolve `path` (or `workingDirectory`) via `pathValidator.validateRead`
2. Compile regex with `case_insensitive` flag
3. Enumerate files recursively
4. Filter by `glob` pattern if provided
5. Filter by `.gitignore` if `respectGitignore`
6. Skip binary files (null-byte check in first 8KB)
7. For each file: stream lines via `URL.lines`, apply regex
8. Collect results per `output_mode`
9. Truncate at `max_results` (default 100)
10. Apply `totalCharacterLimit` via `OutputTruncation`

### Implementation: Foundation Regex

Use Swift `Regex<AnyRegexOutput>` — no ripgrep dependency. Slower on 100K+ file codebases but keeps Yrden dependency-free. Users who need ripgrep can use Shell or MCP.

---

## Background Execution Architecture

### Problem

Long-running shell commands (builds, test suites, installations) block the agent loop. The agent sits idle for 30+ seconds waiting for `swift test` to finish. During this time, it could be reading files, making edits, or running other commands.

### How Claude Code Solves This

Three tools work together:

1. **Bash** with `run_in_background: true` → returns task ID immediately
2. **TaskOutput** with `task_id` → retrieves output (blocking or non-blocking)
3. **TaskStop** with `task_id` → cancels a running task

The agent gets **automatic notifications** when tasks complete, injected into the next tool result as system messages.

### How Yrden Implements This

Yrden already has the building blocks:
- `AnyToolResult.deferred(DeferredToolCall)` — a result type for "not done yet"
- `DeferralKind.external` — defined but unused, perfect for background tasks
- `AgentStreamEvent` — event system for real-time updates
- `ToolContext.runID` — unique run identifier for tracking
- Actor isolation on Agent — thread-safe task tracking

### Tool 7: TaskOutput (New)

```swift
@Schema(description: "Get output from a background task")
public struct TaskOutputArgs {
    @Guide(description: "The task ID returned by the background command")
    public let task_id: String

    @Guide(description: "Wait for completion (true) or return current output immediately (false). Default: true")
    public let block: Bool?

    @Guide(description: "Maximum time to wait in seconds (when block is true). Default: 30")
    public let timeout: Int?
}

public struct TaskOutputTool: TypedTool {
    public typealias Args = TaskOutputArgs

    public let name = "task_output"
    public let description = """
        Get output from a background task. Use block=true (default) to wait for \
        completion, or block=false to check current status without waiting. \
        Returns the task status and any output produced since the last check.
        """

    // Reference to the background task registry (shared with ShellTool)
    let taskRegistry: BackgroundTaskRegistry
}
```

**Return format**:

When task is still running (`block: false`):
```
Status: running
Output since last check:
Building for testing...
Compiling Agent.swift (12/47)
```

When task is complete:
```
Status: completed (exit code: 0)
Output:
Test Suite 'All tests' passed.
  42 tests, 0 failures
```

When task failed:
```
Status: completed (exit code: 1)
Output:
error: type 'Agent' has no member 'foo'
```

### Tool 8: TaskStop (New)

```swift
@Schema(description: "Stop a running background task")
public struct TaskStopArgs {
    @Guide(description: "The task ID to stop")
    public let task_id: String
}

public struct TaskStopTool: TypedTool {
    public typealias Args = TaskStopArgs

    public let name = "task_stop"
    public let description = "Stop a running background task. Sends SIGTERM, then SIGKILL after 5 seconds."

    let taskRegistry: BackgroundTaskRegistry
}
```

**Return format**:
```
Task task_abc123 stopped.
```

### BackgroundTaskRegistry

The central coordinator that ShellTool, TaskOutputTool, and TaskStopTool all share:

```swift
public actor BackgroundTaskRegistry {
    private var tasks: [String: BackgroundTask] = [:]

    /// Launch a command in the background. Returns task ID.
    func launch(
        command: String,
        workingDirectory: String,
        environment: ShellEnvironment,
        timeout: Duration
    ) async -> String

    /// Get current status and new output since last check.
    func getOutput(taskId: String, block: Bool, timeout: Duration) async throws -> TaskSnapshot

    /// Stop a running task.
    func stop(taskId: String) async throws

    /// Check for any completed tasks (for notifications).
    func completedSince(lastCheck: Date) -> [TaskCompletion]
}

struct BackgroundTask: Sendable {
    let id: String
    let command: String
    let startTime: Date
    let process: Process  // or swift-subprocess handle
    var outputBuffer: String
    var lastReadOffset: Int  // For incremental output
    var status: TaskStatus
}

enum TaskStatus: Sendable {
    case running
    case completed(exitCode: Int32)
    case failed(Error)
    case stopped
}

struct TaskSnapshot: Sendable {
    let status: TaskStatus
    let newOutput: String      // Only output since last check
    let totalOutputLength: Int
}

struct TaskCompletion: Sendable {
    let taskId: String
    let command: String
    let exitCode: Int32
}
```

### Notification Mechanism

How the agent learns that a background task finished:

1. **BackgroundTaskRegistry** tracks all running tasks
2. **Before each agent loop iteration**, the execution engine calls `registry.completedSince(lastCheck:)`
3. Any completions are **injected as system messages** into the conversation:
   ```
   [Background task task_abc123 completed (exit code: 0). Use task_output to see results.]
   ```
4. The agent sees this in its next context and can call `task_output` to get the full output

**Integration point**: This happens in the agent's iteration loop, between the "afterTools" and "beforeModel" phases. The check is cheap (actor method call, no I/O).

### Incremental Output

TaskOutput returns **only new output since the last check**, not the entire history. This prevents context window explosion from repeatedly polling a verbose build.

```
Call 1: "Building module 1/10..."
Call 2: "Building module 2/10...\nBuilding module 3/10..."
Call 3: "All modules built.\nRunning tests..."
```

The `BackgroundTask.lastReadOffset` tracks where the last read stopped.

### How Shell + TaskOutput + TaskStop Compose

```
Agent loop iteration 1:
  Agent: shell(command: "swift test", run_in_background: true)
  Shell: launches process, returns "Background task started: task_abc123"
  Agent: continues to next action

Agent loop iteration 2:
  Agent: edit_file(path: "src/Bug.swift", old_string: "...", new_string: "...")
  [System injects: "Background task task_abc123 completed (exit code: 1)"]
  Agent: sees notification

Agent loop iteration 3:
  Agent: task_output(task_id: "task_abc123")
  TaskOutput: returns test failure output
  Agent: reads error, makes fix, runs tests again
```

---

## Tool 9: Task / Subagent (Stretch)

### What Claude Code Does

The `Task` tool spawns isolated sub-agents with their own context windows. Each agent type has restricted tool access:

| Type | Tools | Model | Purpose |
|------|-------|-------|---------|
| Explore | Read, Glob, Grep | Fast/cheap | Codebase exploration |
| Plan | Read, Glob, Grep, WebSearch | Balanced | Architecture planning |
| General | All tools | Full | Complex multi-step work |
| Bash | Shell only | Full | Terminal operations |

Key constraints:
- Subagents **cannot spawn other subagents** (prevents infinite nesting)
- Each gets its own **isolated context window**
- Returns a **single final result** to the parent
- Can run in the background

### Yrden Design

```swift
@Schema(description: "Launch a sub-agent to handle a complex task")
public struct TaskArgs {
    @Guide(description: "Detailed instructions for the sub-agent")
    public let prompt: String

    @Guide(description: "Short description (3-5 words)")
    public let description: String

    @Guide(description: "Agent profile: 'explore' (read-only), 'plan' (read + search), 'general' (all tools)")
    public let profile: String?

    @Guide(description: "Run in background and return task ID")
    public let run_in_background: Bool?
}

public struct TaskTool: TypedTool {
    public typealias Args = TaskArgs

    public let name = "task"
    public let description = """
        Launch a sub-agent to handle a complex task independently. The sub-agent \
        gets its own context and tools. Use 'explore' profile for read-only research, \
        'plan' for architecture decisions, or 'general' for full capabilities. \
        Sub-agents cannot launch other sub-agents.
        """

    let agentFactory: SubAgentFactory
    let taskRegistry: BackgroundTaskRegistry  // Shared with shell background tasks
}
```

### SubAgentFactory

```swift
public struct SubAgentFactory: Sendable {
    let model: any Model
    let tools: [any Tool]  // Full tool set from parent

    /// Create a sub-agent with the specified profile.
    func createAgent(
        profile: SubAgentProfile,
        prompt: String
    ) throws -> Agent<StringOutput>
}

public enum SubAgentProfile: String, Sendable {
    case explore   // Read, Glob, Grep only
    case plan      // Read, Glob, Grep + no writes
    case general   // All parent tools except Task (no nesting)
}
```

### Execution Flow

1. Parse `profile` (default: `general`)
2. Create sub-agent via `SubAgentFactory` with filtered tools
3. If `run_in_background`:
   - Launch in background task
   - Register with `BackgroundTaskRegistry`
   - Return task ID immediately
4. Else:
   - Run sub-agent synchronously
   - Return final output string

### Integration with BackgroundTaskRegistry

Background sub-agents share the same registry as background shell commands. The `TaskOutputTool` and `TaskStopTool` work for both. A background sub-agent is just another task with a different execution type.

```swift
// In BackgroundTaskRegistry
enum TaskKind {
    case shell(command: String, process: Process)
    case subAgent(agent: Agent<StringOutput>, task: Task<String, Error>)
}
```

### Why This Is a Stretch Goal

1. Requires `Agent` to be re-entrant (can be created inside tool execution)
2. Sub-agent context isolation needs careful design (what messages does it start with?)
3. The "no nesting" constraint needs enforcement at the tool level
4. Cost management — sub-agents consume their own tokens

---

## Changes to Existing Files

### BuiltInTools.swift — Updated Factory

```swift
public struct BuiltInTools: Sendable {
    // Existing
    public let shell: ShellTool
    public let readFile: ReadFileTool
    public let writeFile: WriteFileTool

    // New core tools
    public let editFile: EditFileTool
    public let glob: GlobTool
    public let grep: GrepTool

    // New background tools
    public let taskOutput: TaskOutputTool
    public let taskStop: TaskStopTool

    /// Core tools (no background management).
    public var core: [any Tool] {
        [shell, readFile, writeFile, editFile, glob, grep]
    }

    /// All tools including background task management.
    public var all: [any Tool] {
        core + [taskOutput, taskStop]
    }

    /// Read-only tools (for explore/plan profiles).
    public var readOnly: [any Tool] {
        [readFile, glob, grep]
    }

    public init(
        workingDirectory: String,
        allowedWriteDirectories: [String]? = nil,
        deniedReadDirectories: [String]? = nil,
        environment: ShellEnvironment? = nil,
        shellApprovalRequired: Bool = true
    ) async throws
}
```

### ShellToolArgs — Two New Fields

Add `description: String?` and `run_in_background: Bool?` to the existing `@Schema` struct. No other changes to ShellTool.

### AgentStreamEvent — New Event

```swift
public enum AgentStreamEvent<Output: SchemaType>: Sendable {
    // ... existing cases ...

    /// A background task completed.
    case backgroundTaskCompleted(id: String, summary: String)
}
```

---

## Test Strategy

### Principles

- **Real filesystem operations** — create temp directories, write real files, verify real changes
- **No mocking of tools** — tools are the thing being tested
- **Temp directory per test** — isolated, cleaned up in teardown
- **Test the error messages** — LLM self-correction depends on clear errors

### EditFileTool Tests

```swift
// Core behavior
func test_singleMatch_replacesCorrectly()
func test_noMatch_returnsHelpfulError()
func test_multipleMatches_replaceAllFalse_failsWithCount()
func test_multipleMatches_replaceAllTrue_replacesAll()
func test_sameStrings_returnsError()
func test_emptyOldString_returnsError()
func test_fileNotFound_returnsError()

// Edge cases
func test_whitespacePreserved_tabsAndSpaces()
func test_multilineOldString_matchesAcrossLines()
func test_unicodeContent_preservedExactly()
func test_emptyNewString_deletesOldString()
func test_newlineInStrings_handledCorrectly()

// Safety
func test_atomicWrite_contentCorrectEvenIfLarge()
func test_pathOutsideAllowed_denied()
func test_fileTooLarge_rejected()

// Sequential edits (the whole point of content-based matching)
func test_twoSequentialEdits_sameFile_bothSucceed()
func test_editAfterEdit_lineNumbersDontMatter()
```

### GlobTool Tests

```swift
// Pattern matching
func test_starPattern_matchesInCurrentDirOnly()
func test_doubleStarPattern_matchesRecursively()
func test_braceAlternation_matchesBothOptions()
func test_characterClass_matchesRange()
func test_questionMark_matchesSingleChar()

// Behavior
func test_resultsSortedByModificationTime()
func test_maxResults_truncatesWithMessage()
func test_emptyResults_noError()
func test_respectsGitignore_skipsNodeModules()
func test_noGitignore_noFiltering()
func test_relativePaths_relativeToSearchDir()

// Validation
func test_pathOutsideAllowed_denied()
func test_nonexistentDirectory_error()
```

### GrepTool Tests

```swift
// Output modes
func test_filesMode_returnsPathsOnly()
func test_contentMode_returnsMatchingLines()
func test_contentMode_withContext_showsSurroundingLines()
func test_countMode_returnsCountPerFile()

// Search behavior
func test_literalPattern_findsExactMatch()
func test_regexPattern_findsPatternMatch()
func test_caseInsensitive_matchesRegardlessOfCase()
func test_globFilter_onlySearchesMatchingFiles()
func test_respectsGitignore()
func test_skipsBinaryFiles()

// Limits
func test_maxResults_truncates()
func test_totalCharacterLimit_appliesTruncation()
func test_emptyResults_noError()
func test_invalidRegex_returnsError()
```

### Shell Background Execution Tests

```swift
// Background launch
func test_runInBackground_returnsImmediately()
func test_runInBackground_returnsTaskId()
func test_backgroundTask_continuesRunning()

// TaskOutput
func test_taskOutput_blockTrue_waitsForCompletion()
func test_taskOutput_blockFalse_returnsCurrentOutput()
func test_taskOutput_incrementalOutput_onlyNewSinceLastCheck()
func test_taskOutput_completedTask_returnsFullOutput()
func test_taskOutput_unknownTaskId_returnsError()
func test_taskOutput_timeout_returnsPartialOutput()

// TaskStop
func test_taskStop_terminatesRunningTask()
func test_taskStop_alreadyCompleted_noError()
func test_taskStop_unknownTaskId_returnsError()

// Notifications
func test_completedTasks_reportedByRegistry()
func test_multipleBackgroundTasks_trackedIndependently()

// Integration
func test_backgroundShell_thenTaskOutput_fullWorkflow()
func test_backgroundShell_spillover_worksWithTaskOutput()
```

### BackgroundTaskRegistry Tests

```swift
func test_launch_returnsUniqueId()
func test_getOutput_runningTask_returnsPartial()
func test_getOutput_completedTask_returnsFull()
func test_getOutput_incremental_noRepeat()
func test_stop_sendsTermThenKill()
func test_completedSince_returnsNewCompletions()
func test_concurrentAccess_actorIsolated()
```

---

## File Layout

```
Sources/Yrden/Tools/
├── BuiltInTools.swift           # Factory: creates all tools          [MODIFIED]
├── OutputTruncation.swift       # Shared head+tail truncation
├── PathValidator.swift          # Path resolution + directory restriction
├── ShellEnvironment.swift       # Environment capture
├── ShellTool.swift              # Shell execution + CWD + spillover   [MODIFIED: add description, run_in_background]
├── ReadFileTool.swift           # Three-layer defense file reading
├── WriteFileTool.swift          # Atomic file writing
├── EditFileTool.swift           # Search/replace                      [NEW]
├── GlobTool.swift               # File pattern matching               [NEW]
├── GrepTool.swift               # Content search                      [NEW]
├── GitignoreFilter.swift        # .gitignore parsing                  [NEW]
├── FileEnumerator.swift         # Shared recursive enumeration        [NEW]
├── BackgroundTaskRegistry.swift # Background task coordination        [NEW]
├── TaskOutputTool.swift         # Retrieve background task output     [NEW]
└── TaskStopTool.swift           # Stop background tasks               [NEW]

Sources/Yrden/Agent/
├── AgentTypes.swift             # [MODIFIED: add backgroundTaskCompleted event]
└── ... (no other changes)

Tests/YrdenTests/Unit/Tools/
├── EditFileToolTests.swift                                            [NEW]
├── GlobToolTests.swift                                                [NEW]
├── GrepToolTests.swift                                                [NEW]
├── GitignoreFilterTests.swift                                         [NEW]
├── FileEnumeratorTests.swift                                          [NEW]
├── BackgroundTaskRegistryTests.swift                                  [NEW]
├── TaskOutputToolTests.swift                                          [NEW]
├── TaskStopToolTests.swift                                            [NEW]
└── ShellBackgroundTests.swift   # Integration: shell + taskoutput     [NEW]
```

---

## Implementation Order

1. **EditFileTool** — highest value, simplest to implement
2. **GitignoreFilter + FileEnumerator** — shared utilities needed by Glob and Grep
3. **GlobTool** — depends on FileEnumerator
4. **GrepTool** — depends on FileEnumerator
5. **BackgroundTaskRegistry** — core infrastructure for background execution
6. **Shell `run_in_background`** — modify ShellTool to use registry
7. **TaskOutputTool + TaskStopTool** — thin wrappers around registry
8. **Agent loop notification** — inject completion events between iterations
9. **Task tool** (stretch) — subagent spawning

---

## References

### Claude Code Tool Architecture
- [Claude Code Tools Reference](https://www.vtrivedy.com/posts/claudecode-tools-reference)
- [Claude Code System Prompts](https://gist.github.com/wong2/e0f34aac66caf890a332f7b6f9e2ba8f)
- [Anthropic Text Editor Tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/text-editor-tool)
- [Claude Code Behind the Scenes](https://blog.promptlayer.com/claude-code-behind-the-scenes-of-the-master-agent-loop/)

### Cross-Agent Analysis
- [Aider Edit Formats](https://aider.chat/docs/more/edit-formats.html)
- [How Cursor AI IDE Works](https://blog.sshh.io/p/how-cursor-ai-ide-works)
- [OpenAI Codex CLI](https://github.com/openai/codex)
- [Google Gemini CLI](https://github.com/google-gemini/gemini-cli)

### Yrden Design Documents
- [BuiltInTools.md](BuiltInTools.md) — Shell, ReadFile, WriteFile design
- [AgentSkills.md](AgentSkills.md) — Skills system and tool requirements
- [UnifiedToolProtocol.md](UnifiedToolProtocol.md) — Tool/TypedTool protocol hierarchy
