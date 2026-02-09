# Design: Expanded Tool Set (EditFile, Glob, Grep, ListDirectory)

## Problem

Yrden ships three built-in tools: Shell, ReadFile, WriteFile. These are the minimum viable set for a coding agent. But "minimum viable" means the agent has to use Shell as a crutch for operations that deserve dedicated tools — and Shell is both the most dangerous and least token-efficient option for structured operations.

Today, an agent that needs to:
- **Edit a file** must read the file, construct the full new content, and call WriteFile. This wastes tokens (sending the entire file back) and risks data loss (if the agent's reconstruction misses lines).
- **Find files** must run `find . -name "*.swift"` via Shell. The output is unstructured text, not sorted by relevance, and the command requires approval.
- **Search code** must run `grep -r "pattern" .` via Shell. Output floods the context window with every matching line, no pagination, no output modes.
- **Explore a directory** must run `ls -la` or `tree` via Shell. No depth control, no consistent format.

Every major AI coding agent has converged on the same solution: dedicated tools for these four operations, each with domain-specific parameters that reduce token consumption and improve accuracy. This document designs Yrden's versions.

### Why these four?

Agents that have all seven tools (Shell, Read, Write, Edit, Glob, Grep, ListDir) can execute the full spectrum of Agent Skills. From our research on Anthropic's production skills (see AgentSkills.md):
- 88% need ReadFile
- 75% need WriteFile
- 69% need Shell
- **38% need EditFile** — the most common "missing" tool
- Glob and Grep are used implicitly (via Shell) in nearly every skill that searches code

The tools below eliminate Shell-as-crutch for structured operations.

---

## Research: Industry Convergence

We studied Claude Code, OpenAI Codex CLI, Google Gemini CLI, Cursor, Windsurf, and Aider. Below are the universal patterns.

### Every agent uses the same edit paradigm

| Agent | Edit Method | Line Numbers? | Match Strategy |
|-------|-------------|---------------|----------------|
| Claude Code | `old_string` → `new_string` | No | Exact unique string |
| Gemini CLI | `old_string` → `new_string` | No | Exact → flexible → LLM correction |
| Codex CLI | `apply_patch` (custom format) | No (`@@` scope markers) | Function/class context + 3 lines |
| Cursor | Semantic diff (`// ... existing code ...`) | No | Apply model interprets sketch |
| Aider | `SEARCH` → `REPLACE` blocks | No | Exact → whitespace → indent → fuzzy |
| Windsurf | Direct edit | Yes (exception) | Line-range targeting |

**No agent uses line numbers for edits** (except Windsurf, which is the least capable). The reason: line numbers drift after each edit. If an agent plans edits at lines 10, 25, and 40, after the first edit the other positions may have shifted. Content-based matching is position-independent.

### Every agent has structured search tools

| Agent | File Search | Content Search | Default Output |
|-------|------------|----------------|----------------|
| Claude Code | Glob (patterns) | Grep (ripgrep) | File paths only |
| Gemini CLI | `glob` (patterns) | `grep_search` (git grep) | File paths only |
| Codex CLI | `list_dir` (recursive) | `grep_files` (ripgrep) | Matches with limit |
| Cursor | `file_search` (fuzzy) | `grep_search` (ripgrep) | Matches with explanation |
| Windsurf | `find_by_name` | `grep_search` | Matches |

Universal pattern: **search tools default to minimal output** (file paths, not content) to conserve the context window. Content is fetched selectively via ReadFile.

### How each agent handles directory listing

| Agent | Tool | Depth Control | Pagination |
|-------|------|---------------|------------|
| Claude Code | Bash `ls` (no dedicated tool) | No | No |
| Codex CLI | `list_dir` | `depth` param (default 2) | `offset` + `limit` |
| Gemini CLI | `list_directory` | Not documented | Not documented |
| Cursor | `list_dir` | Yes | No |
| Windsurf | `list_dir` | Yes | No |

---

## Research: Design Principles from Cross-Agent Analysis

Six principles emerged from studying all implementations:

### 1. Context Window is the Scarce Resource

Every design decision must account for token consumption. Tools should default to the minimum useful output. Grep returns file paths (not matching lines) by default. Glob returns paths (not file contents). The agent can always fetch more with ReadFile.

### 2. Content-Based Matching, Not Positional

Edits use string matching, not line numbers. This is robust to sequential edits, more natural for LLMs (which reason about code as text), and enables uniqueness enforcement (a safety feature).

### 3. Tools Do One Thing Well (Unix Philosophy)

Each tool has a single responsibility. Glob finds files. Grep searches content. Read retrieves file content. Edit modifies files. No overlap. The agent composes: **Glob → Read → Edit** or **Grep → Read → Edit**.

### 4. Errors Are Information, Not Termination

Tool errors are sent back to the LLM as structured messages, enabling self-correction in the next loop iteration. An Edit with ambiguous match returns "Found 3 matches; include more context" — the agent learns and retries.

### 5. Safety Through Constraints, Not Trust

Multiple layers work together: read-before-write requirements, uniqueness enforcement on edits, PathValidator on all file operations, approval tiers by tool category.

### 6. Simplicity Over Sophistication

Regex search over vector embeddings. String matching over AST manipulation. Plain text over structured databases. This makes the system debuggable, predictable, and fast.

---

## Design Decisions

### Decision 1: EditFile — Search/Replace with Uniqueness Enforcement

The edit tool uses `old_string` → `new_string` replacement with exact string matching, following the paradigm established by Anthropic's `str_replace_based_edit_tool` and used by Claude Code, Gemini CLI, and Aider.

**Why not unified diff format?** Aider benchmarked unified diff against search/replace across multiple models. Search/replace produced fewer errors and was less prone to "laziness" (the model skipping content). The format is simpler for models to produce correctly.

**Why not line-based editing?** Line numbers drift after each edit. In a multi-edit sequence, the agent would need to recalculate positions after every change. String matching is position-independent.

**Why require unique matches?** If `old_string` matches multiple locations, which one should be replaced? Guessing is dangerous — the agent could modify the wrong code. Requiring uniqueness forces the agent to include enough surrounding context to identify exactly one location. This is safer than Aider's "replace first occurrence" or Codex's "use scope markers" approaches.

**Why not LLM self-correction (like Gemini CLI)?** Gemini CLI calls a secondary LLM to fix failed edits. This adds latency, cost, and complexity. The simpler approach — return a clear error and let the agent's main loop retry — achieves the same result with less machinery. The agent already knows the file content from a prior read.

**Tradeoff**: Insertions at a specific location require finding a unique anchor string nearby and including it in `old_string` with the new content appended/prepended. This is slightly less ergonomic than a dedicated `insert_at_line` operation, but more robust and doesn't require a separate tool.

### Decision 2: EditFile — `replace_all` for Bulk Operations

A `replace_all: Bool` parameter (default `false`) enables replacing all occurrences of `old_string`. This handles the common case of renaming a variable or updating an import path across a file without requiring multiple tool calls.

When `replace_all` is false, the tool fails if multiple matches exist (requiring more context). When true, all occurrences are replaced (useful for rename operations).

### Decision 3: EditFile — No MultiEdit (v1)

Claude Code provides a `MultiEdit` tool for atomic multi-edit operations. We defer this to v2 for three reasons:
1. Most edits are single replacements. Multi-edit is an optimization.
2. The agent can achieve the same result with sequential Edit calls.
3. Adding atomic multi-edit significantly complicates the implementation (sequential application with rollback).

If benchmarks show agents frequently need 3+ edits to the same file in succession, we'll add MultiEdit as a wrapper (like RetryingTool).

### Decision 4: Glob — Sort by Modification Time

File results sorted by **most recently modified first**. This is the heuristic used by Claude Code and Gemini CLI. Recently modified files are more likely relevant to the current task. This saves the agent from sorting or filtering results.

### Decision 5: Grep — Three Output Modes

Following Claude Code's design:
- `files_with_matches` (default): Return only file paths. Most context-efficient.
- `content`: Return matching lines with optional context (`-A`, `-B`, `-C`).
- `count`: Return match counts per file.

The default being `files_with_matches` is deliberate. The agent often just needs to know *which* files contain something before deciding to Read them. Returning full content by default would flood the context.

### Decision 6: Grep — Use Foundation Regex (Not ripgrep)

Claude Code and Codex both shell out to `ripgrep` for search. This adds a binary dependency. Yrden is a pure Swift library with zero external dependencies beyond SwiftSyntax and swift-subprocess.

We use Foundation's built-in regex support (`Regex<AnyRegexOutput>`) combined with `URL.lines` for streaming. This means:
- No binary dependency
- No Shell approval needed (Grep is a read-only tool)
- Cross-platform (macOS + Linux)
- Same streaming performance as ReadFile

**Tradeoff**: Foundation regex is ~5–10x slower than ripgrep on very large codebases (100K+ files). For most projects (<10K files), the difference is negligible. Users who need ripgrep-speed search on massive codebases can use Shell or an MCP tool.

### Decision 7: Grep — Respect .gitignore

By default, Grep skips files that match `.gitignore` patterns. This prevents searching `node_modules/`, `.build/`, `Pods/`, and other generated directories that waste time and tokens.

Implementation: parse `.gitignore` at the search root and apply patterns during file enumeration. If not in a git repo, no filtering is applied.

### Decision 8: ListDirectory — Depth-Limited Tree

ListDirectory returns a tree-like output with configurable depth (default 2). This provides the agent with project structure without overwhelming the context window.

```
src/
  Agent/
    Agent.swift
    AgentTool.swift
    AgentTypes.swift
  Tools/
    BuiltInTools.swift
    EditFileTool.swift
    ...
  Providers/
    Anthropic/
    OpenAI/
```

**Why not just `ls` via Shell?** Shell requires approval. ListDirectory is read-only and auto-approved. The structured output with depth control is also more token-efficient than raw `ls -laR`.

### Decision 9: Approval Tiers

Following the universal pattern across all agents:

| Tool | Default Approval | Rationale |
|------|-----------------|-----------|
| Shell | Required | Arbitrary code execution |
| WriteFile | Not required | Creates/overwrites files (reversible) |
| **EditFile** | **Not required** | Modifies existing files (reversible via git) |
| ReadFile | Not required | Read-only |
| **Glob** | **Not required** | Read-only (file listing) |
| **Grep** | **Not required** | Read-only (content search) |
| **ListDirectory** | **Not required** | Read-only (directory listing) |

All tools can have approval overridden via `.requireApproval()`.

---

## Tool Specifications

### EditFileTool

**LLM-controlled arguments** (`@Schema`):

```swift
@Schema(description: "Make an exact text replacement in a file")
public struct EditFileArgs {
    @Guide(description: "Absolute path to the file to edit")
    public let path: String

    @Guide(description: "The exact text to find in the file")
    public let old_string: String

    @Guide(description: "The text to replace it with (must differ from old_string)")
    public let new_string: String

    @Guide(description: "Replace all occurrences (default: false). When false, fails if old_string matches more than once")
    public let replace_all: Bool?
}
```

**Developer configuration** (init-time):

```swift
public struct EditFileTool: TypedTool {
    public typealias Args = EditFileArgs

    public let name = "edit_file"
    public let description = """
        Make an exact text replacement in a file. Finds old_string and replaces it \
        with new_string. The old_string must be unique in the file (unless replace_all \
        is true). Include enough surrounding context in old_string to uniquely identify \
        the location. To insert text, include surrounding context in old_string with \
        the new text added at the desired position in new_string. To delete text, set \
        new_string to the surrounding context without the deleted portion.
        """

    public let pathValidator: PathValidator
    public let maxFileSize: Int  // Default: 10_000_000 (10 MB)
}
```

**Execution flow**:

1. Validate path via `pathValidator.validateWrite(path)`
2. Check file exists → error if missing
3. Check file size ≤ `maxFileSize` → error if too large
4. Read full file content as String
5. Validate `old_string` ≠ `new_string` → error if identical
6. Validate `old_string` is not empty → error if empty (use WriteFile for new files)
7. Count occurrences of `old_string` in file content
8. If `replace_all` is false (default):
   - 0 matches → error: "No match found for the specified text"
   - 1 match → replace
   - N matches → error: "Found {N} matches. Include more surrounding context to uniquely identify the location, or set replace_all to true"
9. If `replace_all` is true:
   - 0 matches → error: "No match found for the specified text"
   - N matches → replace all
10. Write modified content atomically
11. Return summary: "Replaced {N} occurrence(s) in {path}"

**Error messages** (designed for LLM self-correction):

| Scenario | Error Message |
|----------|---------------|
| File not found | `"File not found: {path}"` |
| No match | `"No match found for the specified text in {path}. The file may have been modified since you last read it."` |
| Ambiguous match | `"Found {N} matches for the specified text in {path}. Include more surrounding context in old_string to uniquely identify the location, or set replace_all to true."` |
| Same strings | `"old_string and new_string are identical. No changes needed."` |
| Empty old_string | `"old_string cannot be empty. To create a new file, use write_file."` |
| File too large | `"File is {size} which exceeds the {limit} limit for editing."` |
| Path denied | `"Path {path} is outside allowed directories: ..."` |

**LLM-facing description** (the `description` property above is sufficient).

### GlobTool

**LLM-controlled arguments** (`@Schema`):

```swift
@Schema(description: "Find files matching a glob pattern")
public struct GlobArgs {
    @Guide(description: "Glob pattern to match (e.g., '**/*.swift', 'src/**/*.ts', '*.json')")
    public let pattern: String

    @Guide(description: "Directory to search in. Defaults to working directory if omitted")
    public let path: String?
}
```

**Developer configuration** (init-time):

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
}
```

**Execution flow**:

1. Resolve `path` (or use `workingDirectory`) via `pathValidator.validateRead`
2. Enumerate files matching `pattern` using `FileManager` + `fnmatch(3)`
3. If `respectGitignore`: parse `.gitignore` at search root, filter matches
4. Sort results by modification time (newest first) using file attributes
5. Truncate to `maxResults`
6. Return paths as newline-separated list
7. If truncated, append: `"[...showing {maxResults} of {total} matches]"`

**Glob pattern support** (standard `fnmatch` + `**`):

| Pattern | Matches |
|---------|---------|
| `*.swift` | All `.swift` files in the search directory (not recursive) |
| `**/*.swift` | All `.swift` files recursively |
| `src/**/*.{ts,tsx}` | TypeScript files under `src/` |
| `test_*.py` | Python test files in current directory |
| `[A-Z]*.swift` | Swift files starting with uppercase |

**Implementation approach**: Recursive directory enumeration with `FileManager.enumerator(at:includingPropertiesForKeys:)`. Apply `fnmatch(3)` to each relative path. This handles `**` via the recursive enumeration itself.

**Output example**:

```
Sources/Yrden/Agent/Agent.swift
Sources/Yrden/Agent/AgentTool.swift
Sources/Yrden/Agent/AgentTypes.swift
Sources/Yrden/Tools/EditFileTool.swift
Sources/Yrden/Tools/GlobTool.swift
Tests/YrdenTests/Unit/Tools/EditFileToolTests.swift
[...showing 200 of 847 matches]
```

### GrepTool

**LLM-controlled arguments** (`@Schema`):

```swift
@Schema(description: "Search file contents using a regex pattern")
public struct GrepArgs {
    @Guide(description: "Regular expression pattern to search for")
    public let pattern: String

    @Guide(description: "File or directory to search in. Defaults to working directory")
    public let path: String?

    @Guide(description: "Output mode: 'files' (default, paths only), 'content' (matching lines), 'count' (match counts)")
    public let output_mode: String?

    @Guide(description: "Glob pattern to filter files (e.g., '*.swift', '*.{ts,tsx}')")
    public let glob: String?

    @Guide(description: "Case-insensitive search")
    public let case_insensitive: Bool?

    @Guide(description: "Number of context lines before each match (content mode only)")
    public let context_before: Int?

    @Guide(description: "Number of context lines after each match (content mode only)")
    public let context_after: Int?

    @Guide(description: "Maximum number of results to return")
    public let max_results: Int?
}
```

**Developer configuration** (init-time):

```swift
public struct GrepTool: TypedTool {
    public typealias Args = GrepArgs

    public let name = "grep"
    public let description = """
        Search file contents using a regex pattern. Returns matching file paths \
        by default (most context-efficient). Use output_mode 'content' to see \
        matching lines with optional context, or 'count' for match counts per file. \
        Respects .gitignore by default. Use glob parameter to filter by file type.
        """

    public let pathValidator: PathValidator
    public let workingDirectory: String
    public let defaultMaxResults: Int   // Default: 100
    public let respectGitignore: Bool   // Default: true
    public let totalCharacterLimit: Int // Default: 100_000
}
```

**Output modes**:

**`files` (default)** — paths only, one per line:
```
Sources/Yrden/Agent/Agent.swift
Sources/Yrden/Agent/AgentTool.swift
Sources/Yrden/Tools/ShellTool.swift
```

**`content`** — matching lines with file paths and line numbers:
```
Sources/Yrden/Agent/Agent.swift
  42:     public let tools: [any Tool]
  68:     func executeTool(_ call: ToolCall) async throws -> AnyToolResult {

Sources/Yrden/Agent/AgentTool.swift
  39: public protocol Tool: Sendable {
  79: public protocol TypedTool: Tool {
```

With context (`context_before: 1, context_after: 1`):
```
Sources/Yrden/Agent/Agent.swift
  41:     public let systemPrompt: String
  42:     public let tools: [any Tool]
  43:     public let maxIterations: Int
```

**`count`** — match count per file:
```
Sources/Yrden/Agent/Agent.swift: 5
Sources/Yrden/Agent/AgentTool.swift: 12
Sources/Yrden/Tools/ShellTool.swift: 3
```

**Execution flow**:

1. Resolve `path` (or use `workingDirectory`) via `pathValidator.validateRead`
2. Compile regex pattern (with `case_insensitive` flag if set)
3. Enumerate files recursively from path
4. If `glob`: filter filenames via `fnmatch(3)`
5. If `respectGitignore`: filter against `.gitignore` patterns
6. For each file, stream lines via `URL.lines` and apply regex
7. Collect results according to `output_mode`
8. Truncate at `max_results` (default 100) entries
9. Apply `totalCharacterLimit` via OutputTruncation
10. Return formatted output

**Regex**: Use Swift's `Regex<AnyRegexOutput>` from `_StringProcessing`. Falls back to `NSRegularExpression` for patterns that Foundation's `Regex` doesn't support.

### ListDirectoryTool

**LLM-controlled arguments** (`@Schema`):

```swift
@Schema(description: "List directory contents in a tree format")
public struct ListDirectoryArgs {
    @Guide(description: "Directory path to list. Defaults to working directory")
    public let path: String?

    @Guide(description: "Maximum depth to recurse (default: 2)")
    public let depth: Int?
}
```

**Developer configuration** (init-time):

```swift
public struct ListDirectoryTool: TypedTool {
    public typealias Args = ListDirectoryArgs

    public let name = "list_directory"
    public let description = """
        List directory contents in a tree format with configurable depth. \
        Shows files and subdirectories. Use depth to control how deep to recurse \
        (default: 2). Useful for understanding project structure.
        """

    public let pathValidator: PathValidator
    public let workingDirectory: String
    public let defaultDepth: Int     // Default: 2
    public let maxDepth: Int         // Default: 5
    public let maxEntries: Int       // Default: 500
}
```

**Execution flow**:

1. Resolve `path` (or use `workingDirectory`) via `pathValidator.validateRead`
2. Clamp depth: `min(args.depth ?? defaultDepth, maxDepth)`
3. Enumerate directory contents recursively up to depth
4. Build tree output with indentation (2 spaces per level)
5. Directories show trailing `/`
6. Hidden files (`.`-prefix) are included but `.git/` contents are skipped
7. Truncate at `maxEntries` with `"[...{N} more entries]"` marker
8. Sort entries: directories first, then files, alphabetically within each group

**Output example** (depth: 2):

```
Sources/
  Yrden/
    Agent/
    Providers/
    Tools/
  YrdenMacros/
Tests/
  YrdenTests/
  YrdenTestSupport/
Package.swift
README.md
```

**Output example** (depth: 3, specific path):

```
Sources/Yrden/Tools/
  BuiltInTools.swift
  EditFileTool.swift
  GlobTool.swift
  GrepTool.swift
  ListDirectoryTool.swift
  OutputTruncation.swift
  PathValidator.swift
  ReadFileTool.swift
  ShellEnvironment.swift
  ShellTool.swift
  WriteFileTool.swift
```

---

## Shared Utilities

### GitignoreFilter

A shared utility for Glob and Grep to filter files against `.gitignore` patterns.

```swift
struct GitignoreFilter: Sendable {
    let patterns: [GitignorePattern]

    /// Parse .gitignore at the given root directory.
    /// Returns nil if not in a git repo or .gitignore doesn't exist.
    static func load(from root: String) -> GitignoreFilter?

    /// Check if a relative path should be ignored.
    func isIgnored(_ relativePath: String) -> Bool
}
```

**Implementation**: Parse `.gitignore` line by line, convert to `fnmatch` patterns. Support negation (`!pattern`), directory-only patterns (`dir/`), and anchored vs unanchored patterns. This is a subset of git's full matching — sufficient for 95% of real `.gitignore` files.

**Why not shell out to `git check-ignore`?** It requires Shell (approval), is slow for batch operations, and doesn't work outside git repos.

### FileEnumerator

A shared utility for recursive file enumeration used by Glob, Grep, and ListDirectory.

```swift
struct FileEnumerator {
    /// Enumerate files recursively from a directory.
    /// Applies gitignore filtering if available.
    static func enumerate(
        directory: String,
        maxDepth: Int? = nil,
        gitignoreFilter: GitignoreFilter? = nil
    ) -> AsyncStream<FileEntry>
}

struct FileEntry: Sendable {
    let path: String           // Absolute path
    let relativePath: String   // Relative to enumeration root
    let isDirectory: Bool
    let modificationDate: Date
    let depth: Int
}
```

---

## Integration with BuiltInTools

The `BuiltInTools` factory expands to include all seven tools:

```swift
public struct BuiltInTools: Sendable {
    public let shell: ShellTool
    public let readFile: ReadFileTool
    public let writeFile: WriteFileTool
    public let editFile: EditFileTool
    public let glob: GlobTool
    public let grep: GrepTool
    public let listDirectory: ListDirectoryTool

    /// All tools as an array, ready to pass to Agent.
    public var all: [any Tool] {
        [shell, readFile, writeFile, editFile, glob, grep, listDirectory]
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

**Usage is unchanged** — `tools.all` returns all tools. Users who want a subset can pick individual tools:

```swift
// All tools (default)
let tools = try await BuiltInTools(workingDirectory: projectPath)
let agent = Agent(model: model, tools: tools.all)

// Read-only subset (for an "explore" agent)
let agent = Agent(model: model, tools: [tools.readFile, tools.glob, tools.grep, tools.listDirectory])

// Write-capable but no shell
let agent = Agent(model: model, tools: [tools.readFile, tools.writeFile, tools.editFile, tools.glob, tools.grep])
```

---

## How These Tools Enable Skills

Agent Skills (see AgentSkills.md) are prompt instructions that use built-in tools to perform structured tasks. The expanded tool set unlocks higher-tier skills:

| Skill Tier | Tools Required | Example |
|------------|---------------|---------|
| Tier 1: File generation | ReadFile, WriteFile | Generate config files |
| Tier 2: Code modification | ReadFile, WriteFile, **EditFile** | Refactor, fix bugs |
| Tier 3: Codebase exploration | ReadFile, **Glob**, **Grep**, **ListDirectory** | Code review, dependency analysis |
| Tier 4: Build & test | Shell, ReadFile, WriteFile, **EditFile** | Test, lint, fix, rebuild |
| Tier 5: Full autonomy | All 7 tools | Multi-file refactoring, feature implementation |

Without EditFile, Tier 2 skills require reading the full file and writing the full file — wasteful and error-prone. Without Glob/Grep, Tier 3 skills require Shell for searching — requiring approval for every search operation.

---

## File Layout

```
Sources/Yrden/Tools/
├── BuiltInTools.swift           # Factory: creates all 7 tools with shared config
├── OutputTruncation.swift       # Shared head+tail truncation
├── PathValidator.swift          # Path resolution + directory restriction
├── ShellEnvironment.swift       # Environment capture + shell detection
├── ShellTool.swift              # Shell execution + CWD tracking + spillover
├── ReadFileTool.swift           # Three-layer defense file reading
├── WriteFileTool.swift          # Atomic file writing
├── EditFileTool.swift           # Search/replace with uniqueness enforcement   [NEW]
├── GlobTool.swift               # File pattern matching                        [NEW]
├── GrepTool.swift               # Content search with output modes             [NEW]
├── ListDirectoryTool.swift      # Depth-limited tree listing                   [NEW]
├── GitignoreFilter.swift        # .gitignore pattern parsing                   [NEW]
└── FileEnumerator.swift         # Shared recursive file enumeration            [NEW]

Tests/YrdenTests/Unit/Tools/
├── ... (existing tests)
├── EditFileToolTests.swift                                                     [NEW]
├── GlobToolTests.swift                                                         [NEW]
├── GrepToolTests.swift                                                         [NEW]
├── ListDirectoryToolTests.swift                                                [NEW]
├── GitignoreFilterTests.swift                                                  [NEW]
└── FileEnumeratorTests.swift                                                   [NEW]
```

---

## Test Strategy

### EditFileTool

- Single match → replaced, correct content written
- No match → error with helpful message
- Multiple matches + `replace_all: false` → error with count
- Multiple matches + `replace_all: true` → all replaced, count returned
- `old_string` == `new_string` → error
- Empty `old_string` → error
- File not found → error
- File too large → error
- Path outside allowed directories → error
- Preserves file permissions after edit
- Atomic write (no partial state on crash)
- Multi-byte UTF-8 content preserved exactly
- Whitespace (tabs, spaces, newlines) in old_string matched exactly
- Adjacent edits: edit at line 5, then edit at line 6 (both succeed)

### GlobTool

- `*.swift` matches `.swift` files in root only
- `**/*.swift` matches recursively
- `{a,b}` alternation works
- `[A-Z]*` character class works
- Results sorted by modification time (newest first)
- Max results truncation with message
- Empty results → empty output (no error)
- Invalid pattern → error
- Respects .gitignore (node_modules skipped)
- Relative paths in output (relative to search directory)
- Path validation applied to search directory

### GrepTool

- Simple literal pattern finds matches
- Regex pattern (`\bclass\b`) works
- `files` mode → paths only
- `content` mode → file:line:content format
- `count` mode → file:count format
- `case_insensitive` → matches regardless of case
- `context_before` and `context_after` in content mode
- `glob` filter → only searches matching files
- Respects .gitignore
- `max_results` truncation
- Total character limit truncation
- Empty results → empty output
- Invalid regex → error with message
- Binary files skipped (same null-byte check as ReadFile)
- Path validation applied

### ListDirectoryTool

- Depth 1 → top-level only
- Depth 2 (default) → one level of nesting
- Depth 5 (max) → deep nesting
- Directories show trailing `/`
- Sorted: directories first, then files, alphabetical
- `.git/` contents skipped (but `.git/` itself shown)
- Max entries truncation
- Empty directory → empty output
- Non-existent directory → error
- Path validation applied

### GitignoreFilter

- Simple patterns: `*.log` ignores `.log` files
- Directory patterns: `build/` ignores only directories
- Negation: `!important.log` un-ignores
- Nested `.gitignore` patterns
- Anchored vs unanchored patterns
- Comments and blank lines ignored
- Non-git directory → returns nil (no filtering)

---

## Future Work

- **MultiEdit**: Atomic multi-replacement in a single file (like Claude Code's MultiEdit)
- **Ripgrep integration**: Optional dependency for large codebase search performance
- **Semantic search**: Vector-based code search (like Cursor's `codebase_search`)
- **WebFetch/WebSearch**: HTTP fetch and web search tools (lower priority — these are easily added via MCP)
- **NotebookEdit**: Jupyter notebook cell manipulation
- **Background shell**: Long-running processes with incremental output retrieval
- **Token-based limits**: Replace character limits with actual token counting

---

## References

### Edit Tool Design
- [Anthropic Text Editor Tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/text-editor-tool)
- [Claude Code Edit Tool System Prompt](https://gist.github.com/wong2/e0f34aac66caf890a332f7b6f9e2ba8f)
- [Aider Edit Formats](https://aider.chat/docs/more/edit-formats.html)
- [How Cursor AI IDE Works](https://blog.sshh.io/p/how-cursor-ai-ide-works)
- [OpenAI Codex apply_patch](https://github.com/openai/codex/blob/main/codex-rs/apply-patch/apply_patch_tool_instructions.md)
- [Gemini CLI Replace Tool](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/tools)
- [Code Surgery: How AI Assistants Make Precise Edits](https://fabianhertwig.com/blog/coding-assistants-file-edits/)

### Search Tool Design
- [Claude Code Grep/Glob Tools](https://www.vtrivedy.com/posts/claudecode-tools-reference)
- [Codex CLI grep_files](https://github.com/openai/codex/tree/main/codex-rs/core/src/tools/handlers)
- [Gemini CLI grep_search/glob](https://geminicli.com/docs/tools/)

### Cross-Agent Analysis
- [AI Coding Agent Architecture Comparison](https://www.zenml.io/llmops-database/claude-code-agent-architecture-single-threaded-master-loop-for-autonomous-coding)
- [Claude Code Behind the Scenes (PromptLayer)](https://blog.promptlayer.com/claude-code-behind-the-scenes-of-the-master-agent-loop/)
- [Anthropic Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)
- [Anthropic Principles for Effective Tool Design](https://platform.claude.com/docs/en/agents-and-tools/tool-use/best-practices)

### Yrden Design Documents
- [BuiltInTools.md](BuiltInTools.md) — Shell, ReadFile, WriteFile design
- [AgentSkills.md](AgentSkills.md) — Skills system and tool requirements
- [UnifiedToolProtocol.md](UnifiedToolProtocol.md) — Tool/TypedTool protocol hierarchy
- [Research-SwiftToolProtocols.md](Research-SwiftToolProtocols.md) — Ecosystem comparison
