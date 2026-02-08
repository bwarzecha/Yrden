# Built-in Tools

Yrden ships with three built-in tools for file system and shell operations: `ShellTool`, `ReadFileTool`, and `WriteFileTool`. These tools share a `PathValidator` for consistent security boundaries and integrate directly with the agent system via the `Tool` protocol.

## Quick Start

```swift
let tools = try await BuiltInTools(
    workingDirectory: "/Users/alice/project",
    allowedWriteDirectories: ["/Users/alice/project"],
    deniedReadDirectories: ["~/.ssh", "~/.aws", "~/.gnupg"],
    shellApprovalRequired: true
)

let agent = try Agent<String>(model: model, tools: tools.all)
let result = try await agent.run("List the Swift files in the project")
```

---

## BuiltInTools Factory

The `BuiltInTools` struct creates all three tools with shared configuration and a shared `PathValidator`.

```swift
public struct BuiltInTools: Sendable {
    public let shell: ShellTool
    public let readFile: ReadFileTool
    public let writeFile: WriteFileTool

    public var all: [any Tool] { [shell, readFile, writeFile] }
}
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `workingDirectory` | `String` | (required) | Initial CWD for shell commands and default write directory |
| `allowedWriteDirectories` | `[String]?` | `[workingDirectory]` | Directories where `WriteFileTool` can write |
| `deniedReadDirectories` | `[String]?` | `["~/.ssh", "~/.aws", "~/.gnupg"]` | Directories blocked from reading |
| `environment` | `ShellEnvironment?` | Auto-captured | Shell environment for command execution |
| `shellApprovalRequired` | `Bool` | `true` | Whether `ShellTool` requires human approval |

### Shell Environment

By default, `BuiltInTools` captures the user's interactive login shell environment using `ShellEnvironment.captureUserEnvironment()`. This spawns `$SHELL -l -i -c "env"` once and parses the output, ensuring tools like Homebrew, nvm, pyenv, and cargo are available even when launched from Xcode or Finder.

You can override this behavior:

```swift
// Use the current process environment as-is (works from terminal)
let env = ShellEnvironment.inherited()

// Provide explicit environment
let env = ShellEnvironment.explicit(
    ["PATH": "/usr/bin:/bin", "HOME": "/Users/alice"],
    shellPath: "/bin/zsh"
)

let tools = try await BuiltInTools(
    workingDirectory: "/tmp",
    environment: env
)
```

---

## ShellTool

Executes shell commands with working directory tracking, output truncation, and timeout enforcement.

### Tool Definition

- **Name:** `shell`
- **Requires approval:** `true` (by default)
- **Arguments:** `command` (required), `workingDirectory` (optional), `timeout` (optional)

```swift
@Schema(description: "Execute a shell command")
public struct ShellToolArgs {
    @Guide(description: "Shell command to execute")
    public let command: String

    @Guide(description: "Working directory for the command")
    public let workingDirectory: String?

    @Guide(description: "Timeout in seconds (default: 120, max: 600)")
    public let timeout: Int?
}
```

### Features

**Working directory persistence:** The tool tracks the current working directory across calls using a sentinel marker (`__YRDEN_CWD__`) appended to each command. If a command changes directory (e.g., `cd /tmp`), subsequent commands will execute from `/tmp`.

**Output truncation:** Output exceeding `maxOutputLength` (default: 30,000 characters) is truncated using head+tail preservation (60% head, 40% tail). Full output is saved to a spillover file whose path is included in the response.

**Timeout enforcement:** Commands are terminated after the timeout period (default: 120 seconds, max: 600 seconds). SIGTERM is sent first, followed by SIGKILL if the process does not exit within 1 second.

**Memory safety:** Pipe reads are capped at `2 * maxOutputLength` to prevent unbounded memory usage from runaway processes. Remaining data is drained without storing.

**Path validation:** Requested working directories are validated against the `PathValidator` before execution.

### Configuration

```swift
let shell = ShellTool(
    environment: env,
    pathValidator: validator,
    workingDirectory: "/Users/alice/project",
    maxOutputLength: 30_000,         // Character limit before truncation
    spilloverDirectory: "/tmp/yrden", // Where full output is saved
    defaultTimeout: .seconds(120),
    maxTimeout: .seconds(600),
    requiresApproval: true
)
```

### Example Output

For a command that produces large output:

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
- **Arguments:** `path` (required), `offset` (optional), `limit` (optional)

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

1. **Line count limit** (default: 500 lines) -- stops reading after the limit, does not iterate the entire file
2. **Per-line character truncation** (default: 4,000 characters) -- truncates individual long lines with a `[...+N chars]` suffix
3. **Total character cap** (default: 100,000 characters) -- applies head+tail truncation via `OutputTruncation`

### Features

**Binary detection:** Reads the first 8KB and checks for null bytes. Binary files are rejected with an error message.

**Streaming line reads:** Uses Swift's `URL.lines` async sequence for memory-efficient reading. Stops early after the line limit without reading the rest of the file.

**Path validation:** Paths are validated against the `PathValidator` -- denied directories (e.g., `~/.ssh`) are blocked.

### Configuration

```swift
let readFile = ReadFileTool(
    pathValidator: validator,
    totalCharacterLimit: 100_000,
    perLineCharacterLimit: 4_000,
    defaultLineLimit: 500
)
```

### Example Output

```
[File: /Users/alice/project/main.swift | Lines 1-50 of 200 | 4.2 KB]
1: import Foundation
2: import Yrden
3:
4: @main
5: struct App {
...
50:     }
```

For large files that exceed the line limit, the header indicates there are more lines:

```
[File: /Users/alice/project/data.json | Lines 1-500 of 500+ | 1.2 MB]
```

---

## WriteFileTool

Writes content to files with atomic writes and size limits.

### Tool Definition

- **Name:** `write_file`
- **Requires approval:** `false`
- **Arguments:** `path` (required), `content` (required)

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

**Atomic writes:** Files are written atomically to prevent partial writes on crash or interruption.

**Directory creation:** Parent directories are created automatically if they do not exist.

**Size limit:** Maximum write size is 10 MB by default, preventing accidental multi-GB writes from LLM output.

**Path validation:** Paths are validated against the `PathValidator` -- only allowed write directories are permitted.

### Configuration

```swift
let writeFile = WriteFileTool(
    pathValidator: validator,
    createDirectories: true,    // Auto-create parent directories
    maxWriteSize: 10_000_000    // 10 MB limit
)
```

### Example Output

```
Wrote 1234 bytes to /Users/alice/project/output.txt
```

---

## PathValidator

Shared security boundary for all file tools. Resolves paths to absolute, resolves symlinks via `realpath(3)`, normalizes macOS aliases (`/var` to `/private/var`), then checks against allowed and denied directory lists.

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

This prevents symlink-based escapes. For example, `/tmp/link-to-ssh` pointing to `~/.ssh` will be resolved to the real path and blocked.

### Validation Methods

```swift
// For reading -- checks denied list, then allowed list
let resolved = try validator.validateRead("/Users/alice/project/file.txt")

// For writing -- checks allowed write directories only
let resolved = try validator.validateWrite("/Users/alice/project/output.txt")
```

### Errors

```swift
public enum PathValidationError: Error, Sendable {
    case pathDenied(path: String, reason: String)
    case pathOutsideAllowed(path: String, allowedDirectories: [String])
}
```

---

## OutputTruncation

Utility for truncating large text outputs using a head+tail preservation strategy.

When text exceeds the character budget:
- 60% is kept from the head
- 40% is kept from the tail
- A marker shows how much was omitted
- Splits at line boundaries when possible (within a 200-character window)

```swift
let truncated = OutputTruncation.truncate(largeText, maxLength: 30_000)
// Returns: [first ~18,000 chars]\n\n[...truncated N of M total characters...]\n\n[last ~12,000 chars]

// With metadata
let (text, wasTruncated, totalLength) = OutputTruncation.truncateWithInfo(
    largeText,
    maxLength: 30_000
)
```

---

## Approval System

The `ShellTool` requires human approval by default (`requiresApproval: true`). This integrates with the agent's tool approval mechanism.

You can also mark any tool as requiring approval:

```swift
// Using the wrapper
let approvedReadTool = readFileTool.requireApproval()

// Or configure at construction
let shell = ShellTool(
    environment: env,
    pathValidator: validator,
    workingDirectory: "/tmp",
    requiresApproval: false  // Disable for automated pipelines
)
```

---

## Using Individual Tools

While `BuiltInTools` is the recommended factory, you can create tools individually for more control:

```swift
let validator = PathValidator(
    allowedWriteDirectories: ["/Users/alice/project"],
    deniedReadDirectories: ["~/.ssh", "~/.aws"]
)

let env = try await ShellEnvironment.captureUserEnvironment()

// Create individually
let shell = ShellTool(
    environment: env,
    pathValidator: validator,
    workingDirectory: "/Users/alice/project"
)

let reader = ReadFileTool(pathValidator: validator)
let writer = WriteFileTool(pathValidator: validator)

// Mix with other tools
let agent = try Agent<String>(
    model: model,
    tools: [shell, reader, mcpSearchTool]  // Combine built-in and MCP tools
)
```
