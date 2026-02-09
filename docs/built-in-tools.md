# Built-in Tools

Yrden ships with eight built-in tools for file system, search, and shell operations. These tools share a `PathValidator` for consistent security boundaries and integrate directly with the agent system via the `Tool` protocol.

## Quick Start

```swift
let tools = try await BuiltInTools(workingDirectory: "/Users/alice/project")
let agent = try Agent<String>(
    model: model,
    tools: tools.all,
    backgroundTaskRegistry: tools.registry  // Enables background task notifications
)
let result = try await agent.run("Find and fix the bug in main.swift")
```

For read-only access (safe for untrusted prompts):

```swift
let safeAgent = try Agent<String>(model: model, tools: tools.readOnly)
```

---

## BuiltInTools Factory

The `BuiltInTools` struct creates all eight tools with shared configuration, a shared `PathValidator`, and a shared `BackgroundTaskRegistry`.

```swift
public struct BuiltInTools: Sendable {
    public let shell: ShellTool
    public let readFile: ReadFileTool
    public let writeFile: WriteFileTool
    public let editFile: EditFileTool
    public let glob: GlobTool
    public let grep: GrepTool
    public let taskOutput: TaskOutputTool
    public let taskStop: TaskStopTool
    public let registry: BackgroundTaskRegistry

    public var all: [any Tool]      // All 8 tools
    public var core: [any Tool]     // 6 tools (no background task management)
    public var readOnly: [any Tool] // 3 tools (read_file, glob, grep)
}
```

### Tool Collections

| Collection | Tools | Use Case |
|------------|-------|----------|
| `all` (8) | shell, read_file, write_file, edit_file, glob, grep, task_output, task_stop | Full agent capabilities |
| `core` (6) | shell, read_file, write_file, edit_file, glob, grep | No background task management |
| `readOnly` (3) | read_file, glob, grep | Safe for untrusted contexts |

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `workingDirectory` | `String` | (required) | Initial CWD for shell commands, default search directory for glob/grep |
| `allowedWriteDirectories` | `[String]?` | `[workingDirectory]` | Directories where write_file and edit_file can operate |
| `deniedReadDirectories` | `[String]?` | `["~/.ssh", "~/.aws", "~/.gnupg"]` | Directories blocked from reading |
| `environment` | `ShellEnvironment?` | Auto-captured | Shell environment for command execution |
| `shellApprovalRequired` | `Bool` | `true` | Whether shell requires human approval |

### Shell Environment

By default, `BuiltInTools` captures the user's interactive login shell environment using `ShellEnvironment.captureUserEnvironment()`. This spawns `$SHELL -l -i -c "env"` once and parses the output, ensuring tools like Homebrew, nvm, pyenv, and cargo are available even when launched from Xcode or Finder.

```swift
// Use the current process environment as-is (works from terminal)
let env = ShellEnvironment.inherited()

// Provide explicit environment
let env = ShellEnvironment.explicit(
    ["PATH": "/usr/bin:/bin", "HOME": "/Users/alice"],
    shellPath: "/bin/zsh"
)

let tools = try await BuiltInTools(workingDirectory: "/tmp", environment: env)
```

---

## ShellTool

Executes shell commands with working directory tracking, output truncation, timeout enforcement, and background execution support.

### Tool Definition

- **Name:** `shell`
- **Requires approval:** `true` (by default)

```swift
@Schema(description: "Execute a shell command")
public struct ShellToolArgs {
    @Guide(description: "Shell command to execute")
    public let command: String

    @Guide(description: "Working directory for the command")
    public let workingDirectory: String?

    @Guide(description: "Timeout in seconds (default: 120, max: 600)")
    public let timeout: Int?

    @Guide(description: "Run the command in the background and return immediately with a task ID")
    public let runInBackground: Bool?

    @Guide(description: "Description of what this background task does")
    public let description: String?
}
```

### Features

**Working directory persistence:** The tool tracks the current working directory across calls. If a command changes directory (e.g., `cd /tmp`), subsequent commands will execute from `/tmp`. Background commands do not affect CWD tracking.

**Output truncation:** Output exceeding `maxOutputLength` (default: 30,000 characters) is truncated using head+tail preservation (60% head, 40% tail). Full output is saved to a spillover file.

**Timeout enforcement:** Commands are terminated after the timeout period (default: 120 seconds, max: 600 seconds). SIGTERM is sent first, followed by SIGKILL if the process does not exit.

**Background execution:** When `run_in_background` is `true`, the command starts immediately and returns a task ID. Use `task_output` and `task_stop` to interact with the running task.

**Process group kills:** All process termination uses `kill(-pgid, signal)` to kill the entire process group, preventing orphan child processes.

### Example Output

```
[first 18,000 characters of output...]

[...truncated 45000 of 93000 total characters...]

[last 12,000 characters of output...]

[Full output saved to: /tmp/yrden-shell-ABC123/shell-output-DEF456.txt]
```

---

## ReadFileTool

Reads file contents with line numbers, pagination, and three layers of protection against token waste.

### Tool Definition

- **Name:** `read_file`
- **Requires approval:** `false`

```swift
@Schema(description: "Read a file's contents with optional line range")
public struct ReadFileArgs {
    @Guide(description: "Absolute path to the file")
    public let path: String

    @Guide(description: "Starting line number (1-based)")
    public let offset: Int?

    @Guide(description: "Maximum number of lines to read")
    public let limit: Int?
}
```

### Three-Layer Defense

1. **Line count limit** (default: 500 lines) -- stops reading after the limit
2. **Per-line character truncation** (default: 4,000 characters) -- truncates long lines with `[...+N chars]`
3. **Total character cap** (default: 100,000 characters) -- head+tail truncation via `OutputTruncation`

### Features

**Binary detection:** Reads the first 8KB and checks for null bytes. Binary files are rejected.

**Streaming line reads:** Uses Swift's `URL.lines` async sequence for memory-efficient reading.

**Path validation:** Denied directories (e.g., `~/.ssh`) are blocked.

---

## WriteFileTool

Writes content to files with atomic writes and size limits.

### Tool Definition

- **Name:** `write_file`
- **Requires approval:** `false`

```swift
@Schema(description: "Write content to a file, creating it if it doesn't exist")
public struct WriteFileArgs {
    @Guide(description: "Absolute path to the file")
    public let path: String

    @Guide(description: "Content to write to the file")
    public let content: String
}
```

### Features

**Atomic writes:** Files are written atomically to prevent partial writes.

**Directory creation:** Parent directories are created automatically.

**Size limit:** Maximum write size is 10 MB by default.

**Path validation:** Only allowed write directories are permitted.

---

## EditFileTool

Edits files by replacing exact string matches. Designed for LLM self-correction -- error messages tell the model exactly what went wrong.

### Tool Definition

- **Name:** `edit_file`
- **Requires approval:** `false`

```swift
@Schema(description: "Edit a file by replacing exact string matches")
public struct EditFileArgs {
    @Guide(description: "Absolute path to the file to edit")
    public let path: String

    @Guide(description: "The exact text to find in the file")
    public let oldString: String

    @Guide(description: "The text to replace it with")
    public let newString: String

    @Guide(description: "Replace all occurrences (default: false, requires unique match)")
    public let replaceAll: Bool
}
```

### Features

**Uniqueness enforcement:** When `replace_all` is `false`, the `old_string` must match exactly once. If it matches zero times, the error message says "not found". If it matches multiple times, the error reports the count, prompting the model to provide more context or use `replace_all`.

**Atomic writes:** Edits are written atomically.

**No line numbers needed:** Content-based matching means line number drift from prior edits doesn't cause failures.

### Example Error Messages

```
No match found for old_string in /path/to/file.txt. Make sure the text matches exactly.

Found 3 matches for old_string in /path/to/file.txt. Provide more context to make the match unique, or set replace_all to true.
```

---

## GlobTool

Finds files matching a glob pattern, sorted by modification time (newest first).

### Tool Definition

- **Name:** `glob`
- **Requires approval:** `false`

```swift
@Schema(description: "Find files matching a glob pattern")
public struct GlobToolArgs {
    @Guide(description: "Glob pattern to match (e.g. '**/*.swift')")
    public let pattern: String

    @Guide(description: "Directory to search in (defaults to working directory)")
    public let path: String?
}
```

### Features

**Glob patterns:** Supports `*`, `**`, `?`, `[abc]`, and `{a,b}` patterns.

**Gitignore support:** Respects `.gitignore` files by default. Always excludes `.git/` and `.DS_Store`.

**Modification time sorting:** Results are sorted newest-first, helping the model focus on recently changed files.

**Result limit:** Caps output at `maxResults` (default: 1000) with a truncation message.

---

## GrepTool

Searches file contents using [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`). Requires `rg` to be installed (`brew install ripgrep`).

### Tool Definition

- **Name:** `grep`
- **Requires approval:** `false`

```swift
@Schema(description: "Search file contents using ripgrep")
public struct GrepToolArgs {
    @Guide(description: "The regex pattern to search for")
    public let pattern: String

    @Guide(description: "Directory to search in (defaults to working directory)")
    public let path: String?

    @Guide(description: "Glob pattern to filter files (e.g. '*.swift')")
    public let glob: String?

    @Guide(description: "Output mode: 'files', 'content', or 'count'")
    public let outputMode: String?

    @Guide(description: "Whether to search case-insensitively")
    public let caseInsensitive: Bool?

    @Guide(description: "Number of context lines around matches")
    public let contextLines: Int?

    @Guide(description: "Maximum number of results to return")
    public let maxResults: Int?
}
```

### Output Modes

| Mode | Description | Example |
|------|-------------|---------|
| `files` (default) | File paths containing matches | `src/main.swift` |
| `content` | Matching lines with file path and line number | `src/main.swift:10: func calculate()` |
| `count` | Match count per file | `src/main.swift: 3` |

### Features

**Ripgrep-backed:** Uses `rg --json` for fast, reliable searching. Natively handles gitignore, binary file skipping, and glob filtering.

**Path validation:** Search directory is validated against the `PathValidator`.

**Output truncation:** Large results are truncated via `OutputTruncation`.

---

## Background Execution

The shell tool supports running commands in the background. Background tasks are managed by a shared `BackgroundTaskRegistry` and can be monitored via `task_output` and stopped via `task_stop`.

### TaskOutputTool

- **Name:** `task_output`
- **Requires approval:** `false`

```swift
@Schema(description: "Get output from a background task")
public struct TaskOutputArgs {
    @Guide(description: "The task ID returned by the shell tool")
    public let taskId: String

    @Guide(description: "Whether to wait for the task to complete")
    public let block: Bool?

    @Guide(description: "Maximum seconds to wait when blocking")
    public let timeout: Int?
}
```

### TaskStopTool

- **Name:** `task_stop`
- **Requires approval:** `false`

```swift
@Schema(description: "Stop a running background task")
public struct TaskStopArgs {
    @Guide(description: "The task ID to stop")
    public let taskId: String
}
```

### Background Task Workflow

```
1. Agent calls shell with run_in_background: true
   → Returns task ID (e.g., "bg_1_a3f2c1d0")

2. Agent calls task_output with block: false
   → Returns current output + "running" status

3. Agent calls task_output with block: true
   → Waits for completion, returns full output + exit code

4. (Optional) Agent calls task_stop to terminate early
   → SIGTERM → wait → SIGKILL if needed
```

### Lifecycle and Cleanup

Background tasks are owned by the `BackgroundTaskRegistry`, not by individual `run()` calls. This means:

- **Tasks outlive `run()`:** A background task started during `agent.run()` continues running after the run completes. You can start another `run()` and the task will still be there.
- **Registry deinit kills all:** When the registry (or `BuiltInTools`) goes out of scope, all running processes are killed immediately via `kill(-pgid, SIGKILL)`.
- **Explicit cleanup:** Call `registry.cancelAll()` for graceful shutdown (SIGTERM, then SIGKILL).

```swift
let tools = try await BuiltInTools(workingDirectory: "/project")
let agent = try Agent<String>(
    model: model,
    tools: tools.all,
    backgroundTaskRegistry: tools.registry
)

let result = try await agent.run("Start the dev server")
// Background tasks may still be running after run() returns

// Option 1: Wait for all background tasks
try await tools.registry.waitForAll(timeout: .seconds(30))

// Option 2: Kill all background tasks
await tools.registry.cancelAll()

// Option 3: Let tools go out of scope (deinit kills everything)
```

### BackgroundTaskRegistry Public API

```swift
public final class BackgroundTaskRegistry: @unchecked Sendable {
    /// Gracefully stop all running tasks (SIGTERM → wait → SIGKILL).
    public func cancelAll() async

    /// Stop a specific task.
    public func stop(taskId: String) async throws

    /// Wait for all tasks to complete, with optional timeout.
    public func waitForAll(timeout: Duration? = nil) async throws

    /// Poll for tasks completed since a given date.
    public func completedSince(_ date: Date) async -> [TaskCompletion]

    /// List currently running tasks.
    public func activeTasks() async -> [TaskInfo]

    /// Quick check if any tasks are still running.
    public func hasRunningTasks() async -> Bool
}
```

---

## Agent Integration

Pass `backgroundTaskRegistry` to `Agent.init()` to enable automatic background task completion notifications.

### Notification Models

| Mode | Notifications | Who Controls |
|------|--------------|-------------|
| `agent.run()` | Auto-injected as system messages between iterations | Library |
| `agent.runStream()` | Emitted as `.backgroundTaskCompleted` stream events | Library |
| `agent.iter()` | Customer calls `registry.completedSince()` manually | Customer |

For `run()` and `runStream()`, the agent loop checks `registry.completedSince()` between iterations and automatically injects notifications. For `iter()`, the customer has full control and can poll the registry between iterations.

```swift
// run() mode: library handles everything
let tools = try await BuiltInTools(workingDirectory: "/project")
let agent = try Agent<String>(
    model: model,
    tools: tools.all,
    backgroundTaskRegistry: tools.registry
)
let result = try await agent.run("Start a server and test it")

// iter() mode: customer controls notifications
let iterator = agent.iter("Start a server")
var lastCheck = Date()
for try await step in iterator {
    // Check for background completions between iterations
    let completions = await tools.registry.completedSince(lastCheck)
    lastCheck = Date()
    for completion in completions {
        print("Task \(completion.taskId) finished (exit \(completion.exitCode))")
    }
}
```

---

## PathValidator

Shared security boundary for all tools. Resolves paths to absolute, resolves symlinks via `realpath(3)`, normalizes macOS aliases (`/var` to `/private/var`), then checks against allowed and denied directory lists.

**Denied directories take priority over allowed directories.**

```swift
let validator = PathValidator(
    allowedReadDirectories: ["/"],                            // Default: read anywhere
    allowedWriteDirectories: ["/Users/alice/project"],        // Only write here
    deniedReadDirectories: ["~/.ssh", "~/.aws", "~/.gnupg"]  // Block sensitive dirs
)
```

### Path Resolution

1. Tilde expansion (`~/.ssh` to `/Users/alice/.ssh`)
2. URL normalization (resolves `.` and `..`)
3. Symlink resolution via `realpath(3)` (if path exists)
4. Ancestor resolution for non-existent paths (walks up to nearest existing ancestor, resolves it, appends remaining components)

This prevents symlink-based escapes.

---

## OutputTruncation

Utility for truncating large text outputs using a head+tail preservation strategy.

When text exceeds the character budget:
- 60% is kept from the head
- 40% is kept from the tail
- A marker shows how much was omitted
- Splits at line boundaries when possible

```swift
let truncated = OutputTruncation.truncate(largeText, maxLength: 30_000)
```

---

## Approval System

The `ShellTool` requires human approval by default. This integrates with the agent's tool approval mechanism.

```swift
// Disable approval for automated pipelines
let tools = try await BuiltInTools(
    workingDirectory: "/project",
    shellApprovalRequired: false
)

// Or wrap any tool to require approval
let approvedReadTool = readFileTool.requireApproval()
```

---

## Using Individual Tools

While `BuiltInTools` is the recommended factory, you can create tools individually:

```swift
let validator = PathValidator(
    allowedWriteDirectories: ["/Users/alice/project"],
    deniedReadDirectories: ["~/.ssh", "~/.aws"]
)
let env = try await ShellEnvironment.captureUserEnvironment()
let registry = BackgroundTaskRegistry()

let shell = ShellTool(
    environment: env,
    pathValidator: validator,
    workingDirectory: "/Users/alice/project",
    backgroundTaskRegistry: registry,
    requiresApproval: false
)
let reader = ReadFileTool(pathValidator: validator)
let glob = GlobTool(pathValidator: validator, workingDirectory: "/Users/alice/project")

// Mix built-in and custom tools
let agent = try Agent<String>(
    model: model,
    tools: [shell, reader, glob, myCustomTool],
    backgroundTaskRegistry: registry
)
```
