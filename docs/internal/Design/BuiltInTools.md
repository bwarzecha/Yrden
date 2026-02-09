# Design: Built-in Tools (Shell, ReadFile, WriteFile)

## Problem

An AI agent without tools is just a chatbot. To perform real work — running builds, reading code, writing files — the agent needs tools. Today, every Yrden user must build these from scratch using the `TypedTool` protocol. This means every user independently solves the same hard problems: shell process management, output truncation, file size limits, environment setup. Most will get it wrong in ways that waste tokens or break silently.

The goal is to ship three built-in tools that are **immediately useful for coding agents**: shell execution, file reading, and file writing. These must be production-quality, meaning they handle the edge cases that actually break agent workflows in practice.

### Why these three?

- **Shell** — runs builds, tests, git commands, installs dependencies. The universal escape hatch.
- **ReadFile** — provides code context. An agent that can't read files can't reason about code.
- **WriteFile** — produces output. An agent that can't write files can't create or modify code.

This is the minimum viable set. EditFile, Glob, and Grep are natural follow-ups but not required for a functional agent.

---

## Research: Build vs Reuse

Before designing custom tools, we evaluated whether existing implementations could be used instead.

**MCP filesystem servers** (official Anthropic, safurrier/Python, mark3labs/Go): Available today and Yrden already supports MCP tools via `MCPToolProxy`. However, no MCP server provides the token efficiency features we need — character-level truncation for long lines, offset+limit combined reads, output spillover. The best one ([safurrier/mcp-filesystem](https://github.com/safurrier/mcp-filesystem)) has offset/limit but requires Python and still misses per-line truncation. All require Node.js or Python as runtime dependencies, which is unacceptable for a Swift library.

**Anthropic bash/text_editor tools** (`bash_20250124`, `text_editor_20250728`): These are *specifications*, not components. Claude knows how to generate calls for them, but the execution is 100% client-implemented. There is nothing reusable — you build the runner yourself.

**Claude Agent SDK** (Python/TypeScript): Has exactly the tools we want (Read, Write, Edit, Bash, Glob, Grep), but they're compiled into the Claude Code binary. Available only through Python/TypeScript wrappers that spawn Claude Code as a subprocess. No Swift path exists.

**Swift-native packages**: No Swift AI framework ships built-in file or shell tools. SwiftAgents, SwiftAgent, AgentSDK-Swift — all focus on agent loops and provider integration, none provide tool implementations.

| Criterion | In-Process Swift | MCP Official FS | MCP safurrier | Anthropic Tools | Claude Agent SDK |
|-----------|-----------------|-----------------|---------------|-----------------|------------------|
| Token efficiency | Full control | Minimal | Good (offset/limit) | Client-implemented | Locked in binary |
| Dependencies | None (pure Swift) | Node.js | Python + ripgrep | N/A | Claude Code CLI |
| Latency | 0ms overhead | ~1-5ms/call | ~1-5ms/call | N/A | Subprocess spawn |
| Char truncation | Yes | No | No | Client-implemented | Not extractable |
| Output spillover | Yes | No | No | No | Not extractable |
| Setup | `swift package resolve` | `npm install` | `pip install` | N/A | Install Claude Code |

**Decision: Build our own.** The token efficiency layer is the hard part and no existing tool implements it. The I/O itself is straightforward Foundation calls. Users who want MCP tools can already plug them in via Yrden's existing MCP support — our built-in tools are the zero-dependency, token-optimized default.

---

## Research: What Breaks in Practice

We studied Claude Code, OpenAI Codex CLI, Cursor, Windsurf, Anthropic's API tools, PydanticAI, LangChain, CrewAI, and AutoGen. We reviewed GitHub issues, user complaints, security research, and internal architecture documents. Below are the four critical problems that every existing tool either handles poorly or ignores entirely.

### 1. Truncated Shell Output Is Permanently Lost

Every tool truncates large command output. None of them preserve the full output for later retrieval.

**Claude Code**: Hard-truncates at 30,000 characters (`BASH_MAX_OUTPUT_LENGTH`). The truncated portion is permanently lost. If the agent runs `swift test` and the output is 100K chars, it sees the beginning but not the test failures at the end. The only workaround is `run_in_background` + `TaskOutput`, but this requires the agent to know in advance that output will be large.

**OpenAI Codex**: Hard-truncates at 10 KiB (later relaxed). Users report needing ~50 sequential tool calls to read a 1,500-line API spec ([Issue #7906](https://github.com/openai/codex/issues/7906)). JSON/XML gets truncated mid-structure, making it unparseable ([Issue #9504](https://github.com/openai/codex/issues/9504)). Critical error messages lost ([Issue #9502](https://github.com/openai/codex/issues/9502)).

**Cursor**: The agent scrapes terminal output via terminal integration, which is inherently unreliable. Output visibility is intermittently lost mid-session. Defaults to `tail 20` (only last 20 lines). Users must manually copy/paste terminal output into chat. ([Cursor Forum #58317](https://forum.cursor.com/t/terminal-output-handling-issues-in-agent-mode/58317), [#133248](https://forum.cursor.com/t/agent-loses-terminal-output/133248))

**Windsurf**: Terminal commands execute but output is not relayed to the AI. The agent sees exit code 0 but empty stdout/stderr. ([Codeium Issue #258](https://github.com/Exafunction/codeium/issues/258))

**LangChain ShellTool**: No truncation at all. Large outputs flood the context window.

The "spillover to temp file" pattern — write full output to a file, return truncated output with the file path — would solve this. No existing tool implements it.

### 2. Line-Based File Limits Fail on Real Files

A "max 2000 lines" limit is meaningless when the file has everything on one line.

| File Type | Typical Size | Lines | Line Length | What Happens with Line Limits |
|-----------|-------------|-------|-------------|-------------------------------|
| Minified JS (`react.min.js`) | 152 KB | 1 | 155,648 chars | "2000 lines" reads entire 152KB file |
| Minified JSON (no pretty-print) | 1KB–35MB | 1 | Entire file | Line limit provides zero protection |
| JSONL logs | Variable | Variable | 5–50KB/line | 2K char/line truncation corrupts every JSON entry |
| `package-lock.json` | 200KB–50MB | 10K–500K+ | 50–200 chars | Lines short but file huge (45K+ lines) |
| CSV with many columns | Variable | Variable | 1–100KB+ | Header line alone can be 50KB |
| SQL dumps | 1MB–10GB | Variable | 1–10MB/line | Single INSERT with thousands of rows |
| Source maps (`.map`) | 100KB–50MB | 1–5 | Entire file | JSON with massive mappings string |
| SVG (generated) | 10KB–10MB | Often 1 | Entire file | Tool-generated, often minified |

Claude Code applies three simultaneous limits (2000 lines, 2000 chars/line, 25K token cap), which handles most cases but still lets pathological files through. Codex tried line-only limits (256 lines OR 10KB) and users complained constantly about truncated reads. Roo Code uses dynamic token budgets but no per-line limits.

The correct approach is **defense in depth**: multiple independent limits that all apply simultaneously (total character cap + per-line truncation + line count), combined with streaming reads so memory usage stays constant regardless of file size.

### 3. Shell Can't Find the User's Tools

When a Swift process spawns a child, it inherits the parent's environment. This works when launched from a terminal. It breaks when launched from Xcode, Finder, or launchd — the PATH is minimal: `/usr/bin:/bin:/usr/sbin:/sbin`.

Tools installed via Homebrew (`/opt/homebrew/bin`), nvm (`~/.nvm/versions/node/vXX/bin`), pyenv (`~/.pyenv/shims`), rbenv, cargo (`~/.cargo/bin`), and Go (`~/go/bin`) are all added by shell initialization scripts (`.zshrc`, `.bashrc`). These scripts run for **interactive login shells only** — not for child processes spawned by a Swift app.

On macOS, the problem is worse because:
- `/usr/libexec/path_helper` (called by `/etc/zprofile`) reorders PATH entries, pushing custom paths to the end
- Homebrew on Apple Silicon lives at `/opt/homebrew/bin`, which is NOT in the default launchd PATH
- The bundled `/bin/bash` is version 3.2 from 2007 (GPLv3 licensing issue)

Claude Code spawns separate "shell detection subprocesses" at startup to capture the environment, which [caused a bug](https://github.com/anthropics/claude-code/issues/12507) where those subprocesses consumed stdin. Cursor forces `/bin/bash` with a custom init file, which [breaks for zsh users](https://forum.cursor.com/t/agent-mode-terminal-ignores-zsh-profile-setting-and-forces-bash/68663). Codex [clears the environment entirely](https://developers.openai.com/codex/config-advanced/) and rebuilds it from scratch.

The [ChimeHQ ProcessEnv](https://github.com/ChimeHQ/ProcessEnv) library solves this for Swift: spawn a login interactive shell once, run `env`, parse the output, cache it.

### 4. Working Directory Doesn't Persist Between Calls

If the agent runs `cd /some/project` in one tool call, the next call starts in the original directory. This breaks multi-step workflows where the agent expects to stay in a directory.

Claude Code claims a "persistent bash session" but testing reveals that **environment variables don't persist between calls** ([Issue #2508](https://github.com/anthropics/claude-code/issues/2508)). CWD does persist. This strongly suggests fresh-process-per-command with CWD tracking (not an actual persistent shell).

---

## Research: Security Landscape

Shell execution is the #1 security risk for AI agents. Research from [arxiv](https://arxiv.org/html/2509.22040v1) demonstrated:

- **83.4% attack success rate** against Cursor in Auto mode
- **41–52% success rate** against GitHub Copilot
- Attack vectors: poisoned `.cursorrules`/`CLAUDE.md` files, malicious MCP server responses, crafted git histories
- Framing attacks ("For debugging purposes...MANDATORY FIRST STEP...") significantly increase agent compliance

The [IDEsaster disclosure](https://thehackernews.com/2025/12/researchers-uncover-30-flaws-in-ai.html) (December 2025) found 30+ vulnerabilities across Cursor, Windsurf, Copilot, Zed, Roo Code, and Cline:

- Prompt injection triggering `read_file` to access `.env`, SSH keys
- JSON `$schema` exfiltration (writes JSON with schema URL pointing to attacker domain)
- Configuration file RCE (edits `.vscode/settings.json` to point executable paths to malicious binaries)

Every major framework uses a layered defense: OS-level sandboxing (Seatbelt/Landlock) + filesystem isolation + command approval + audit logging. [NVIDIA's guidance](https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk/) emphasizes: approvals should never be cached, and both filesystem AND network isolation are essential.

For v1, we rely on approval + application-level path validation. OS-level enforcement (Seatbelt) is the follow-up.

### 5. Directory Restriction — How AI Tools Scope Filesystem Access

We researched every viable approach to restricting which directories the tools can touch.

**Approaches evaluated:**

| Approach | Security | Complexity | Platform | Works for Libraries | Used By |
|----------|----------|------------|----------|---------------------|---------|
| **Seatbelt / `sandbox-exec`** | Kernel-enforced | Medium-High | macOS | Yes | Claude Code, Codex, Gemini CLI, Cursor |
| **Landlock** | Kernel-enforced | Medium | Linux | Yes | Codex (Linux) |
| **Application-level path validation** | Bypassable (TOCTOU) | Low | Cross-platform | Yes | MCP filesystem server |
| **App Sandbox (entitlements)** | Kernel-enforced | Low | macOS | No (`.app` bundles only) | App Store apps |
| **chroot** | Moderate | High | macOS/Linux | No (requires root) | Legacy |
| **EndpointSecurity** | Kernel-enforced | Very High | macOS | No (Apple approval + root) | Security products |
| **posix_spawn file actions** | None | N/A | N/A | N/A | Wrong mechanism (FD inheritance only) |

**Seatbelt** is the industry standard for AI coding tools on macOS. Claude Code, Codex, Gemini CLI, and Cursor all generate SBPL profiles that restrict child processes to specific directories. The profile wraps commands via `sandbox-exec -p '<profile>' /bin/sh -c 'command'`. It's technically deprecated since ~2016 but still works on macOS 15, is used heavily by Apple internally, and every major AI tool depends on it.

**Application-level path validation** resolves paths via `realpath()` and checks against allowed prefixes. The [MCP filesystem server](https://github.com/modelcontextprotocol/servers) uses this pattern. It prevents accidental access and provides useful error messages, but is fundamentally bypassable via TOCTOU races (another process swaps a directory for a symlink between check and use). Known vulnerabilities: [MCP symlink bypass](https://github.com/modelcontextprotocol/servers/security/advisories/GHSA-q66q-fx2p-7w4m), [Gemini CLI symlink bypass](https://github.com/google-gemini/gemini-cli/issues/1121).

**Why both layers matter:**
- `ReadFileTool` / `WriteFileTool`: We control the file operations directly. Application-level validation is sufficient — the tool opens exactly the file it validated. TOCTOU is a theoretical risk but requires a cooperating attacker process on the same machine.
- `ShellTool`: The LLM generates arbitrary shell commands. Application-level validation is meaningless because the shell command can do anything (`ln -s / /allowed/dir/escape`). Only OS-level enforcement (Seatbelt) works here.

---

## Research: Token Efficiency Across Frameworks

| Tool | Truncation | Line Numbers | Output Format |
|------|-----------|-------------|---------------|
| Claude Code | 30K chars bash, 2K lines + 2K chars/line + 25K token read | `cat -n` (~70% overhead) | Plain text |
| Anthropic API text_editor | Optional `max_characters` | `N: content` (~30–40% overhead) | Plain text |
| OpenAI Codex | 10KB (was 256 lines) | Not documented | Plain text |
| Roo Code | Dynamic token budget | `N \| content` (~30–40% overhead) | Plain text |
| Cursor | 250 lines (750 max mode) | Not documented | Terminal scrape |
| LangChain | None | None | Plain string |
| PydanticAI | None (developer responsibility) | N/A | ToolReturn (value + metadata) |

Key findings:
- Claude Code's `cat -n` format wastes ~70% of tokens on whitespace padding. A 6-file read measured at 31K raw tokens consumed 54K actual tokens ([Issue #20223](https://github.com/anthropics/claude-code/issues/20223)).
- Compact `N: content` format (used by Anthropic API) costs ~30-40% overhead — half of `cat -n`.
- Codex is [considering switching](https://github.com/openai/codex/issues/6426) from line-based to token-based limits (~25K tokens) because line counts don't correlate with token consumption.
- Cursor's approach of writing long outputs to files (letting the agent read selectively) reduced tokens by 46.9% in A/B testing.

---

## Design Decisions

### Decision 1: Shell Process Model — Fresh Process + CWD Tracking

Spawn a new process per command. Track working directory across calls via a sentinel.

| | Fresh Process + CWD Tracking | Persistent Shell Process |
|---|---|---|
| **CWD persistence** | Yes (via sentinel parsing) | Yes (natural) |
| **Env var persistence** | No | Yes (natural) |
| **Timeout/kill** | Simple: kill the process | Must kill command without killing the shell |
| **Pipe deadlock risk** | Low: clean lifecycle per command | Higher: long-lived pipes can clog |
| **Concurrency safety** | Safe: independent processes | Unsafe: single sequential stdin |
| **If command hangs** | Kill it, next command unaffected | Whole shell is stuck, need restart |
| **Swift Sendable** | Easy: no long-lived mutable state | Hard: Process + Pipes across async boundaries |
| **What Claude Code does** | This (actual behavior per Issue #2508) | This (claimed API design) |

**Why fresh process wins**: The main downside — env vars don't persist between calls — rarely matters. Agent workflows use `export FOO=bar && use_foo` in a single command string, not across separate tool calls. CWD is the one that matters, and we track that.

**CWD tracking mechanism**: Wrap every command:
```
{command}; __yrden_exit=$?; echo "\n__YRDEN_CWD__:$(pwd)"; exit $__yrden_exit
```
Parse the sentinel from output, strip it before returning to the agent, store the new CWD in an actor for the next call.

**Tradeoff**: If a user needs env var persistence (e.g., `source .env` in one call, use the vars in the next), they must combine commands in a single string. This is a documentation problem, not a design flaw. A persistent shell can be added later as an opt-in mode.

### Decision 2: Shell Environment — Capture at Init

At `ShellTool.init()`, spawn the user's actual shell with `-l -i -c "env"` to capture the full environment.

**Shell detection chain**:
1. `ProcessInfo.processInfo.environment["SHELL"]`
2. `String(cString: getpwuid(getuid())!.pointee.pw_shell)`
3. Fallback: `/bin/zsh` on macOS, `/bin/bash` on Linux

**Fish shell**: If the detected shell is fish, use `/bin/zsh` for command execution. Fish syntax is POSIX-incompatible; commands like `export FOO=bar && echo $FOO` don't work.

**Environment parsing**: Pipe stdout of the login shell, suppress stderr (where shell motd/prompts go). Parse `KEY=VALUE\n` lines. Multi-line values are rare but possible — handle by looking for lines that don't contain `=` and appending to the previous value.

**Three modes** for maximum flexibility:
- `ShellEnvironment.captureUserEnvironment()` — recommended, spawns shell once (~50–200ms)
- `ShellEnvironment.inherited()` — uses parent process env (works from terminal, breaks from Xcode)
- `ShellEnvironment.explicit([String: String])` — caller provides everything

**Tradeoff**: The async init adds ~50–200ms of startup latency. This is acceptable because it runs once and the alternative (broken PATH) is much worse. Users who need instant startup can use `.inherited()`.

### Decision 3: Output Spillover — Full Output to Temp File

When shell output exceeds `maxOutputLength`, write the **full** output to a temp file and include the path in the truncated result.

```
[first 18K chars of output]

[...truncated 85,432 of 115,432 total characters. Full output: /tmp/yrden/abc123/cmd-1.output]

[last 12K chars of output]
```

The agent can then: `read_file(path: "/tmp/yrden/abc123/cmd-1.output", offset: 450, limit: 50)` to inspect any section.

**No existing tool does this.** Claude Code hard-truncates (lost forever). Codex hard-truncates (lost forever). Cursor often can't even read its own terminal output. This is the single biggest usability improvement we can make.

**Spillover directory**: Default `/tmp/yrden/{session-uuid}/`, configurable at init. Files named `cmd-{uuid}.output`.

**Tradeoff**: Extra disk I/O on truncation. Disk is cheap, lost build output is not. The agent must know to use `read_file` on the spillover path — this is handled by the tool description telling the agent about the mechanism.

### Decision 4: Output Truncation — Head + Tail (60/40)

Keep first 60% and last 40% of the character budget, with a marker between them.

**Why 60/40 (not 80/20)**: Build errors, test failures, and stack traces typically appear at the end of output. The last 40% catches these. The first 60% provides context (what was being built/tested).

**Why not head-only** (Claude Code's approach): Loses error output. The agent sees "building..." but not "error: cannot find 'foo' in scope" at the end.

**Why not 50/50**: The beginning of output usually provides more context (command echoing, progress). 60/40 balances context vs error visibility.

### Decision 5: ReadFile — Three-Layer Defense

Four independent limits, all applied simultaneously:

| Layer | Default | What It Prevents |
|-------|---------|-----------------|
| ~~File size safeguard~~ | Removed | Not needed: streaming line reading (`URL.lines`) uses constant memory regardless of file size. The other three layers handle truncation. |
| **Line count limit** | 500 lines | Sensible default for code. Adjustable via offset/limit |
| **Per-line char truncation** | 4,000 chars | Prevents one minified line from eating the whole budget |
| **Total character cap** | 100,000 chars | Hard ceiling (~25K tokens). No read can exceed this |

**Order of application**:
1. Open file for streaming line reading (`URL.lines`) — constant memory regardless of file size
2. Read first 8KB to check for binary content (null bytes) → error if binary
3. Stream lines, applying offset (skip lines) then limit (take N lines, default 500)
4. Truncate each line to 4,000 chars (with `[...+N chars]` indicator)
5. Add line numbers, accumulate result with running character count
6. If accumulated result > 100,000 chars, stop reading and apply head+tail truncation to what's been collected

No file size safeguard needed. `URL.lines` reads line-by-line with constant memory (~60MB peak) regardless of whether the file is 1KB or 10GB. The three remaining layers handle all bounding.

**What this means in practice**:

| File | Behavior |
|------|----------|
| 200-line Swift file (15KB) | Full content, no truncation |
| 800-line Swift file (60KB) | First 500 lines. Agent pages with offset/limit |
| `react.min.js` (152KB, 1 line) | 1 line streamed, truncated to 4K chars. Constant memory. |
| `package-lock.json` (2.5MB, 45K lines) | First 500 lines streamed. Agent pages further with offset/limit. |
| JSONL log (50KB/line, 1K lines) | 500 lines streamed, each truncated to 4K. Total capped at 100K. |
| 35MB minified JSON (1 line) | 1 line streamed, truncated to 4K chars. Constant memory. |

**Tradeoff**: Streaming (`URL.lines`) is slightly more complex than `String(contentsOfFile:)`, but eliminates any need for file size limits. There's no scenario where the tool OOMs or rejects a valid text file that the agent wants to read.

### Decision 6: Line Number Format — Compact `N: content`

Use `1: content` (Anthropic API style), not Claude Code's `cat -n` style (`     1\tcontent`).

**Token savings**: ~40% less overhead than `cat -n`. For a 500-line file, this saves ~2,000 tokens per read. Over a multi-step agent session with 10+ reads, that's 20K+ tokens saved.

### Decision 7: Shell Requires Approval by Default

`requiresApproval = true` by default, overridable at init.

Based on: 83.4% attack success rate against auto-execute agents, IDEsaster's 30+ CVEs, NVIDIA's "never cache approvals" guidance. The existing `ApprovalRequired<T>` wrapper and `beforeTools` approval flow in the agent loop handle this transparently.

### Decision 8: Use swift-subprocess (Swift 6.1)

Foundation's `Process` with `Pipe` has a well-documented deadlock: if the child writes >64KB to stdout/stderr, the pipe buffer fills, the child blocks on write, and the parent (waiting on `waitUntilExit()`) blocks forever. The workaround (reading pipes on detached tasks) is fragile and verbose.

**Solution**: Use [swift-subprocess](https://github.com/swiftlang/swift-subprocess) (`swiftlang/swift-subprocess`), the official replacement for Foundation's `Process`. Requires Swift 6.1, which we will adopt (bumping `swift-tools-version: 6.1` in Package.swift).

swift-subprocess eliminates the pipe deadlock entirely and provides:

- **Native async/await** — no pipe management, no `Task.detached` workarounds
- **Built-in output collection with size limits** — `.string(limit: 1 << 20)` caps output at 1MB
- **Graceful teardown sequences** — `.gracefulShutDown(allowedDurationToNextStep:)` then `.terminate`
- **PATH resolution** — `.name("git")` resolves via $PATH automatically
- **Environment modification** — `.inherit.updating(["KEY": "value"])` without rebuilding the whole dict
- **Task cancellation integration** — parent task cancellation triggers teardown sequence

```swift
import Subprocess

// Simple: collect output
let result = try await run(
    .name("swift"), arguments: ["test"],
    output: .string, error: .string
)
let output = result.standardOutput  // String
let exitCode = result.terminationStatus.exitCode

// With timeout via structured concurrency
try await withThrowingTaskGroup(of: String.self) { group in
    group.addTask {
        let r = try await run(.path("/bin/sh"), arguments: ["-c", command],
                              output: .string, error: .string)
        return r.standardOutput + r.standardError
    }
    group.addTask {
        try await Task.sleep(for: timeout)
        throw ShellTimeoutError()
    }
    let result = try await group.next()!
    group.cancelAll()  // cancellation triggers teardown on the subprocess
    return result
}
```

**Platform compatibility**: swift-subprocess supports macOS 15+ and Linux. Our current Package.swift targets macOS 14 — we will need to bump to macOS 15. This is acceptable since macOS 15 (Sequoia) shipped June 2024 and Xcode 16+ (required for Swift 6.1) targets it by default.

### Decision 9: Two-Phase Shell Termination

On timeout: SIGTERM first (gives process 5 seconds to clean up), then SIGKILL.

swift-subprocess provides this natively via `TeardownStep`:

```swift
// Configured on the subprocess at creation time
let result = try await run(
    .path(shellPath), arguments: ["-c", command],
    output: .string, error: .string,
    // On cancellation: SIGTERM → wait 5s → SIGKILL
    teardownSequence: [
        .gracefulShutDown(allowedDurationToNextStep: .seconds(5)),
        .kill
    ]
)
```

When the parent task is cancelled (e.g., timeout via `withThrowingTaskGroup`), swift-subprocess automatically executes the teardown sequence. No manual signal handling needed. Industry standard: Claude Code, Codex, and Docker all use SIGTERM-then-SIGKILL.

### Decision 10: Directory Restriction — Two-Layer Defense

Restrict tools to specific directories using application-level path validation (v1) with OS-level Seatbelt sandboxing for shell commands (v2).

#### Layer 1: PathValidator (v1 — all tools)

Application-level check applied before every file operation and available for shell command sandboxing.

```swift
public struct PathValidator: Sendable {
    public let allowedReadDirectories: [String]   // Default: ["/"] (unrestricted)
    public let allowedWriteDirectories: [String]  // Default: [workingDirectory]
    public let deniedReadDirectories: [String]    // Default: ["~/.ssh", "~/.aws", "~/.gnupg"]

    /// Resolve and validate a path for reading.
    /// 1. Resolve to absolute via URL(fileURLWithPath:).standardizedFileURL
    /// 2. Resolve symlinks via realpath(3)
    /// 3. Normalize macOS aliases (/var → /private/var)
    /// 4. Check against denied directories first (deny wins over allow)
    /// 5. Check against allowed directories (path == dir || path.hasPrefix(dir + "/"))
    public func validateRead(_ path: String) throws -> String

    /// Resolve and validate a path for writing. Same steps, checks allowedWriteDirectories.
    public func validateWrite(_ path: String) throws -> String
}
```

**Path prefix checking** must append `/` to prevent `/allowed/data` matching `/allowed/data-archived`:
```swift
private func isWithin(_ path: String, directories: [String]) -> Bool {
    directories.contains { dir in
        path == dir || path.hasPrefix(dir + "/")
    }
}
```

**Security guarantees**: Prevents accidental access and honest LLM mistakes. Not resistant to TOCTOU attacks (requires a cooperating attacker process on the same machine). Sufficient for ReadFileTool and WriteFileTool where we control the file operations directly.

#### Layer 2: Seatbelt Sandbox (v2 — ShellTool only)

For shell commands, application-level validation is meaningless — the LLM can run `ln -s / /allowed/escape`. OS-level enforcement is required.

We studied the actual SBPL profiles from Claude Code ([anthropic-experimental/sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime)), Codex ([openai/codex](https://github.com/openai/codex) `codex-rs/core/src/seatbelt_base_policy.sbpl`), Gemini CLI ([google-gemini/gemini-cli](https://github.com/google-gemini/gemini-cli) `packages/cli/src/utils/sandbox-macos-*.sb`), and Chromium ([chromium common.sb](https://chromium.googlesource.com/chromium/src/+/HEAD/sandbox/policy/mac/common.sb)).

**Industry approaches compared:**

| Tool | Profile Style | Default Posture | Write Scope | Network | Profile Size |
|------|--------------|-----------------|-------------|---------|-------------|
| Claude Code | Dynamic (TypeScript generates SBPL) | deny default | Explicit allow list | Proxy-based filtering | ~200 lines |
| Codex | Static template + Rust params | deny default | Writable roots via `-D` params | Separate policy file | ~120 lines base |
| Gemini CLI | 6 static `.sb` files | permissive: allow default; restrictive: deny default | TARGET_DIR + INCLUDE_DIR_0..4 | open/closed/proxied variants | ~30-80 lines each |
| Chromium | Static with runtime params | deny default | N/A (browser) | N/A | ~500 lines (common.sb) |

**Essential SBPL building blocks** (intersection of all profiles):

Every profile needs these for basic shell command execution:
```scheme
;; Process lifecycle
(allow process-exec)                    ; run executables
(allow process-fork)                    ; fork child processes
(allow signal (target same-sandbox))    ; signal own processes
(allow process-info* (target same-sandbox))

;; Mach IPC — minimum for CLI tools
(allow mach-lookup
  (global-name "com.apple.system.opendirectoryd.libinfo")  ; user/group lookups
  (global-name "com.apple.logd")                            ; system logging
  (global-name "com.apple.system.logger")                   ; syslog
  (global-name "com.apple.bsd.dirhelper")                   ; confstr()
  (global-name "com.apple.system.opendirectoryd.membership"); group membership
  (global-name "com.apple.PowerManagement.control")         ; sleep prevention
)

;; Mach IPC — additional for network operations (TLS, DNS, etc.)
(allow mach-lookup
  (global-name "com.apple.SecurityServer")
  (global-name "com.apple.securityd.xpc")
  (global-name "com.apple.networkd")
  (global-name "com.apple.ocspd")
  (global-name "com.apple.trustd.agent")
  (global-name "com.apple.SystemConfiguration.DNSConfiguration")
  (global-name "com.apple.SystemConfiguration.configd")
)

;; Device files
(allow file-read-data (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom"))
(allow file-write-data (require-all (path "/dev/null") (vnode-type CHARACTER-DEVICE)))

;; PTY support (interactive shell commands need this)
(allow pseudo-tty)
(allow file-read* file-write* file-ioctl (literal "/dev/ptmx"))
(allow file-read* file-write* (regex #"^/dev/ttys[0-9]+"))
(allow file-ioctl (regex #"^/dev/ttys[0-9]+"))

;; IPC
(allow ipc-posix-shm)                  ; shared memory
(allow ipc-posix-sem)                  ; semaphores (Python multiprocessing)

;; User preferences
(allow user-preference-read)

;; IOKit
(allow iokit-open (iokit-registry-entry-class "RootDomainUserClient"))
(allow iokit-get-properties)

;; sysctl — hardware and kernel info (all tools share this set, derived from Chromium)
(allow sysctl-read
  (sysctl-name "hw.activecpu") (sysctl-name "hw.memsize") (sysctl-name "hw.ncpu")
  (sysctl-name "hw.pagesize") (sysctl-name "hw.physicalcpu") (sysctl-name "hw.logicalcpu_max")
  (sysctl-name "hw.cputype") (sysctl-name "hw.cpufamily") (sysctl-name "hw.machine")
  (sysctl-name "kern.hostname") (sysctl-name "kern.osversion") (sysctl-name "kern.osrelease")
  (sysctl-name "kern.ostype") (sysctl-name "kern.version") (sysctl-name "kern.argmax")
  (sysctl-name "kern.maxfilesperproc") (sysctl-name "kern.maxproc")
  (sysctl-name-prefix "hw.optional.arm.") (sysctl-name-prefix "hw.perflevel")
  (sysctl-name-prefix "kern.proc.pid.") (sysctl-name-prefix "net.routetable.")
  ;; ~20 more entries shared across Claude Code, Codex, and Chromium
)
```

**Yrden's profile template** (Gemini-style parameterized, Codex-style deny-default):

```scheme
(version 1)
(deny default (with message "YRDEN_SANDBOX"))

;; --- Process lifecycle ---
(allow process-exec)
(allow process-fork)
(allow signal (target same-sandbox))
(allow process-info* (target same-sandbox))

;; --- File reads: allow all, deny sensitive paths ---
(allow file-read*)
(allow file-read-metadata (subpath "/"))  ;; needed for realpath(), stat()
(deny file-read*
  (subpath (param "DENIED_READ_0"))       ;; e.g. ~/.ssh
  (subpath (param "DENIED_READ_1"))       ;; e.g. ~/.aws
  (subpath (param "DENIED_READ_2"))       ;; e.g. ~/.gnupg
  (with message "YRDEN_SANDBOX"))

;; --- File writes: only to allowed directories ---
(allow file-write*
  (subpath (param "WRITABLE_0"))          ;; workspace directory
  (subpath (param "WRITABLE_1"))          ;; spillover/temp directory
  (subpath (param "TMPDIR"))              ;; system TMPDIR
  (literal "/dev/null")
  (literal "/dev/ptmx")
  (regex #"^/dev/ttys[0-9]+")
)

;; Protect .git/hooks even within writable directories
(deny file-write*
  (regex #".*/\.git/hooks.*")
  (with message "YRDEN_SANDBOX"))

;; --- Mach IPC, sysctl, IOKit, PTY, IPC ---
;; [essential building blocks from above]

;; --- Network: allow all by default (v2 can restrict) ---
(allow network*)
```

**Invocation from Swift:**

```swift
public struct SeatbeltProfile: Sendable {
    let writableDirectories: [String]
    let deniedReadDirectories: [String]
    let tmpdir: String

    /// Generate the SBPL profile string with parameters baked in.
    /// We use string interpolation (like Claude Code) rather than -D params
    /// because it's simpler and we control all inputs.
    func generate() -> String { ... }
}

// In ShellTool, wrap the command:
let profile = SeatbeltProfile(
    writableDirectories: pathValidator.allowedWriteDirectories,
    deniedReadDirectories: pathValidator.deniedReadDirectories,
    tmpdir: spilloverDirectory
)
let args = ["/usr/bin/sandbox-exec", "-p", profile.generate(),
            shellPath, "-c", wrappedCommand]
```

**Known pitfalls** (learned from studying all four implementations):
- **`/var` vs `/private/var`**: macOS symlinks `/var` → `/private/var`. Canonicalize all paths with `realpath()` before injecting into profiles. Both Codex and Claude Code were bitten by this.
- **`file-read-metadata`**: `(deny default)` blocks `stat()` and `realpath()`. Must explicitly `(allow file-read-metadata (subpath "/"))` or symlink traversal breaks.
- **PTY extensions**: PTYs created before entering the sandbox may lack Apple's `com.apple.sandbox.pty` extension. The `file-ioctl` fallback rule handles this (Codex pattern).
- **Mach services are OS-version-dependent**: New macOS releases may require new service allowances. Start permissive on Mach, tighten over time.
- **`sandbox-exec` path**: Always use absolute `/usr/bin/sandbox-exec` to prevent PATH injection.

**Tradeoff**: Seatbelt is macOS-only and technically deprecated (works on macOS 15, used by Apple internally, relied on by every AI tool). On Linux, the equivalent is Landlock (future work). On platforms without OS-level sandboxing, PathValidator alone provides the safety net.

#### How the layers compose

| Tool | Layer 1 (PathValidator) | Layer 2 (Seatbelt) |
|------|------------------------|---------------------|
| **ReadFileTool** | Validates path before `URL.lines` | Not needed (we control the operation) |
| **WriteFileTool** | Validates path before write | Not needed (we control the operation) |
| **ShellTool** | Validates `workingDirectory` arg | Wraps command in `sandbox-exec` profile |

#### Configuration: BuiltInTools Factory

Creating tools individually and passing PathValidator to each is verbose and error-prone (forget one tool = security gap). Instead, provide a factory that creates all tools with shared configuration:

```swift
public struct BuiltInTools: Sendable {
    public let shell: ShellTool
    public let readFile: ReadFileTool
    public let writeFile: WriteFileTool

    /// All tools as an array, ready to pass to Agent.
    public var all: [any Tool] { [shell, readFile, writeFile] }

    public init(
        workingDirectory: String,
        allowedWriteDirectories: [String]? = nil,  // Default: [workingDirectory]
        deniedReadDirectories: [String]? = nil,     // Default: ["~/.ssh", "~/.aws", "~/.gnupg"]
        environment: ShellEnvironment? = nil,       // Default: .captureUserEnvironment()
        shellApprovalRequired: Bool = true
    ) async throws
}
```

**Usage — simple:**
```swift
let tools = try await BuiltInTools(workingDirectory: "/Users/alice/project")
let agent = Agent(model: model, tools: tools.all)
```

**Usage — restricted:**
```swift
let tools = try await BuiltInTools(
    workingDirectory: "/Users/alice/project",
    allowedWriteDirectories: ["/Users/alice/project", "/tmp"],
    deniedReadDirectories: ["~/.ssh", "~/.aws", "~/.gnupg", "~/.config/secrets"]
)
let agent = Agent(model: model, tools: tools.all)
```

**Usage — individual tools with custom config:**
```swift
// Factory creates with shared PathValidator, but tools are also usable standalone
let read = ReadFileTool(
    pathValidator: PathValidator(allowedWriteDirectories: ["/"]),
    totalCharacterLimit: 50_000  // tighter limit
)
let agent = Agent(model: model, tools: [tools.shell, read, tools.writeFile])
```

**What the factory does internally:**
1. Creates `PathValidator` from the directory parameters
2. Creates `ShellEnvironment` (async — captures user shell, ~50-200ms)
3. Creates `ShellTool` with the environment, PathValidator, and default spillover directory
4. Creates `ReadFileTool` and `WriteFileTool` with the same PathValidator
5. All tools share the same directory restriction policy — no way to accidentally misconfigure one

When no directory restrictions are specified, defaults to unrestricted reads (except `~/.ssh`, `~/.aws`, `~/.gnupg`) and writes limited to the working directory.

---

## Tool Specifications

### OutputTruncation (shared utility)

```swift
public enum OutputTruncation {
    /// Truncate text using head+tail strategy (60% head, 40% tail).
    /// Returns original text if within limit.
    static func truncate(_ text: String, maxLength: Int) -> String

    /// Truncate with metadata about what happened.
    static func truncateWithInfo(
        _ text: String,
        maxLength: Int
    ) -> (text: String, wasTruncated: Bool, totalLength: Int)
}
```

- Marker: `\n\n[...truncated {omitted} of {total} total characters...]\n\n`
- Head/tail split at line boundaries when possible (don't cut mid-line)
- Marker length counted against the budget

### ShellEnvironment

```swift
public struct ShellEnvironment: Sendable {
    public let variables: [String: String]
    public let shellPath: String

    /// Capture user's interactive login shell environment.
    /// Spawns $SHELL -l -i -c "env" once, parses output, caches.
    public static func captureUserEnvironment() async throws -> ShellEnvironment

    /// Use current process environment as-is.
    public static func inherited() -> ShellEnvironment

    /// Use caller-provided environment.
    public static func explicit(_ variables: [String: String]) -> ShellEnvironment
}
```

### ShellTool

**LLM-controlled arguments** (`@Schema`):
```swift
@Schema(description: "Execute a shell command")
public struct ShellToolArgs {
    let command: String
    let workingDirectory: String?  // Uses tracked CWD if omitted
    let timeout: Int?              // Seconds. Default: 120, max: 600
}
```

**Developer configuration** (init-time):
```swift
public struct ShellTool: TypedTool {
    public let maxOutputLength: Int          // Default: 30,000
    public let spilloverDirectory: String    // Default: /tmp/yrden/{uuid}/
    public let defaultTimeout: Duration      // Default: 120s
    public let maxTimeout: Duration          // Default: 600s
    public let environment: ShellEnvironment
    public var requiresApproval: Bool        // Default: true

    // Actor-isolated mutable state
    private let state: ShellToolState  // tracks CWD
}
```

**Execution flow**:
1. Resolve CWD: `args.workingDirectory ?? state.getCWD()`
2. Clamp timeout: `min(args.timeout ?? defaultTimeout, maxTimeout)`
3. Wrap command with CWD sentinel
4. Run via swift-subprocess: `.path(shellPath)`, arguments `["-c", wrappedCommand]`, environment from `ShellEnvironment`, workingDirectory from step 1
5. Collect stdout + stderr as strings (subprocess handles pipe buffering)
6. Apply timeout via structured concurrency (`withThrowingTaskGroup` + `Task.sleep` race)
7. Merge stdout + stderr
8. Parse and strip CWD sentinel, update state
9. If output > maxOutputLength: write full to spillover file, truncate with head+tail, append spillover path
10. Format: exit 0 → output only; non-zero → "Exit code: N\n{output}"; timeout → "Command timed out..."

**LLM-facing description**:
> Execute a shell command and return its output. The user's shell environment is available (Homebrew, nvm, pyenv, etc.). Working directory persists between calls. Output is truncated to 30,000 characters with head+tail preservation; when truncated, full output is saved to a file whose path is shown — use read_file with offset/limit to inspect specific sections. Do not use for interactive commands (vim, less, password prompts) or file reading/writing (use read_file/write_file instead).

### ReadFileTool

**LLM-controlled arguments** (`@Schema`):
```swift
@Schema(description: "Read a file's contents with optional line range")
public struct ReadFileArgs {
    let path: String    // Absolute path
    let offset: Int?    // Starting line (1-based). Default: 1
    let limit: Int?     // Max lines. Default: 500
}
```

**Developer configuration** (init-time):
```swift
public struct ReadFileTool: TypedTool {
    public let totalCharacterLimit: Int     // Default: 100,000
    public let perLineCharacterLimit: Int   // Default: 4,000
    public let defaultLineLimit: Int        // Default: 500
}
```

**Execution flow**:
1. Check exists → error if missing
2. Open for streaming line reading (`URL.lines`) — constant memory regardless of file size
3. Read first 8KB to check for binary content (null bytes) → error if binary
4. Stream lines as UTF-8 → error if decode fails
5. Apply offset (skip lines) then limit (take N lines, default 500)
6. Per-line truncation: lines > 4K chars get `{first4K} [...+{N} chars]`
7. Add compact line numbers: `{N}: {content}`
8. Accumulate with running character count; if > 100K chars, stop and apply head+tail truncation
9. Prepend header: `[File: {path} | Lines {start}-{end} of {total} | {size}]`

**Output examples**:

Normal file:
```
[File: /src/Agent.swift | Lines 1-200 of 200 | 8.5 KB]
1: import Foundation
2: import Yrden
3:
4: public actor Agent<Output: SchemaType> {
...
200: }
```

Minified file:
```
[File: /dist/bundle.min.js | Lines 1-1 of 1 | 152.3 KB]
1: !function(e,t){"object"==typeof exports&&"undefin [...+151648 chars]
```

Binary file:
```
Error: /assets/image.png appears to be a binary file (null bytes detected in first 8KB).
```

**LLM-facing description**:
> Read a file's contents with line numbers. Returns at most 500 lines starting from offset. Individual lines longer than 4,000 characters are truncated. Total output capped at 100,000 characters. Uses streaming reads so any text file can be opened regardless of size. Use offset and limit to paginate through large files.

### WriteFileTool

**LLM-controlled arguments** (`@Schema`):
```swift
@Schema(description: "Write content to a file, creating it if it doesn't exist")
public struct WriteFileArgs {
    let path: String     // Absolute path
    let content: String  // File content
}
```

**Developer configuration** (init-time):
```swift
public struct WriteFileTool: TypedTool {
    public let createDirectories: Bool  // Default: true
    public let maxWriteSize: Int        // Default: 10,000,000 (10 MB)
}
```

**Execution flow**:
1. Size check: `content.utf8.count > maxWriteSize` → error
2. Create parent directories if needed (`withIntermediateDirectories: true`)
3. Write atomically: `content.write(toFile:atomically:true, encoding:.utf8)`
4. Return: `"Wrote {N} bytes to {path}"`

**LLM-facing description**:
> Write content to a file. Creates parent directories if they don't exist. Overwrites existing files atomically (no partial writes). Maximum size: 10 MB.

---

## File Layout

```
Sources/Yrden/Tools/
├── BuiltInTools.swift           # Factory: creates all tools with shared config
├── OutputTruncation.swift       # Shared head+tail truncation
├── PathValidator.swift          # Path resolution + directory restriction
├── ShellEnvironment.swift       # Environment capture + shell detection
├── ShellTool.swift              # Shell execution + CWD tracking + spillover
├── ReadFileTool.swift           # Three-layer defense file reading
└── WriteFileTool.swift          # Atomic file writing

Tests/YrdenTests/Unit/Tools/
├── BuiltInToolsTests.swift
├── OutputTruncationTests.swift
├── PathValidatorTests.swift
├── ShellEnvironmentTests.swift
├── ShellToolTests.swift
├── ReadFileToolTests.swift
└── WriteFileToolTests.swift
```

No existing files modified. All tools plug into the existing `[any Tool]` system via `TypedTool` conformance.

---

## Test Strategy

### BuiltInTools
- `BuiltInTools(workingDirectory:)` creates shell, readFile, writeFile
- `.all` returns `[any Tool]` with all three
- PathValidator shared: write restriction applies to all tools equally
- Default denied reads: `~/.ssh`, `~/.aws`, `~/.gnupg`
- Custom write directories respected by all tools
- Individual tools accessible via `.shell`, `.readFile`, `.writeFile`

### OutputTruncation
- Under limit → unchanged
- At exact limit → unchanged
- Over limit → head present, tail present, marker present, correct counts
- Split ratio approximately 60/40
- Empty string
- maxLength smaller than marker (edge case)

### PathValidator
- Path within allowed directory → resolved path returned
- Path outside allowed directory → error with denied path
- Symlink inside allowed dir pointing outside → error (resolved path checked)
- `../` traversal → normalized before check, denied if escapes allowed dir
- Prefix confusion: `/allowed/data` must not match `/allowed/data-archived`
- macOS `/var` → `/private/var` normalization
- Denied read directories take priority over allowed
- Default config: reads unrestricted, writes to working directory only
- Denied defaults: `~/.ssh`, `~/.aws`, `~/.gnupg` blocked for reads

### ShellEnvironment
- `inherited()` returns current process env
- `explicit()` returns exactly what was passed
- `captureUserEnvironment()` returns PATH with expected entries (homebrew, etc.)
- Shell detection finds valid path
- Fish fallback to zsh

### ShellTool
- `echo hello` → `"hello\n"`
- `exit 1` → starts with `"Exit code: 1"`
- Working directory respected (`pwd` in specific dir)
- CWD tracking: `cd /tmp`, then next call's `pwd` → `/tmp`
- CWD sentinel stripped from visible output
- Exit code preserved through sentinel wrapper
- Timeout: `sleep 999` with 1s timeout → process killed, timeout message
- Large output: generate >30K chars → truncated + spillover file written
- Spillover file contains full output, readable via ReadFileTool
- `requiresApproval` defaults to `true`
- Tool definition schema is valid JSON

### ReadFileTool
- Small file → full content with compact line numbers
- Offset (1-based) skips lines
- Limit caps output at N lines
- Long line (10K chars) → truncated to 4K + overflow indicator
- Minified file (1 line, 50K chars) → line truncated, within total cap
- Total char cap: file producing >100K chars after formatting → head+tail truncated
- File not found → error
- Binary file (null bytes) → error
- Empty file → header with "Lines 0-0 of 0"
- Non-UTF-8 → error
- Header metadata correct (line range, total lines, file size)
- Streaming: large file (>1MB) reads without loading into memory

### WriteFileTool
- New file → created with correct content
- Existing file → overwritten
- Nested parent directories → created
- Content matches exactly (atomic write)
- Over size limit → error
- Multi-byte UTF-8 → byte count correct
- Path with spaces → works

---

## Future Work

- **Seatbelt sandbox for ShellTool**: Generate SBPL profiles wrapping shell commands via `sandbox-exec`. Kernel-enforced directory restriction. This is what Claude Code, Codex, Gemini CLI, and Cursor all use for shell execution.
- **Landlock sandbox for Linux**: Equivalent of Seatbelt using Linux Landlock LSM (5.13+). Syscall-based, no root required.
- **EditFile tool**: Exact string replacement (like Claude Code's Edit). Eliminates read-then-write for modifications.
- **Glob/Grep tools**: Structured file search. Much more token-efficient than shell `find`/`grep`.
- **Persistent shell mode**: Opt-in long-running shell process for workflows requiring env var persistence.
- **Background execution**: `run_in_background` with incremental output retrieval (like Claude Code's `TaskOutput`).
- **Token-based limits**: Replace character limits with actual token counting (model-specific).

---

## References

### Shell Execution
- [Anthropic Bash Tool Docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/bash-tool)
- [Claude Code Sandboxing](https://www.anthropic.com/engineering/claude-code-sandboxing)
- [Codex Security Docs](https://developers.openai.com/codex/security/)
- [Codex Deep Dive on Sandboxes](https://pierce.dev/notes/a-deep-dive-on-agent-sandboxes)
- [Cursor Terminal Docs](https://cursor.com/docs/agent/terminal)
- [Swift Subprocess Proposal (SF-0007)](https://github.com/swiftlang/swift-foundation/blob/main/Proposals/0007-swift-subprocess.md)
- [Swift Process Async Handling](https://forums.swift.org/t/right-way-to-asynchronously-wait-for-a-process-to-terminate/64036)
- [ChimeHQ ProcessEnv](https://github.com/ChimeHQ/ProcessEnv)
- [macOS path_helper analysis](https://gist.github.com/Linerre/f11ad4a6a934dcf01ee8415c9457e7b2)

### File Tools
- [Anthropic Text Editor Tool](https://platform.claude.com/docs/en/docs/build-with-claude/tool-use/text-editor-tool)
- [Claude Code Token Overhead (Issue #20223)](https://github.com/anthropics/claude-code/issues/20223)
- [Codex Token-Based Truncation Proposal (Issue #6426)](https://github.com/openai/codex/issues/6426)
- [Roo Code read_file Docs](https://docs.roocode.com/advanced-usage/available-tools/read-file)
- [Cursor Dynamic Context Discovery](https://cursor.com/blog/dynamic-context-discovery)

### Security & Sandboxing
- [Prompt Injection on AI Coding Editors (arxiv)](https://arxiv.org/html/2509.22040v1)
- [IDEsaster Vulnerabilities (The Hacker News)](https://thehackernews.com/2025/12/researchers-uncover-30-flaws-in-ai.html)
- [NVIDIA Sandboxing Guidance](https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk/)
- [OWASP Top 10 for Agentic AI](https://genai.owasp.org/2025/12/09/owasp-genai-security-project-releases-top-10-risks-and-mitigations-for-agentic-ai-security/)
- [Claude Code Sandboxing (Anthropic Engineering)](https://www.anthropic.com/engineering/claude-code-sandboxing)
- [Deep Dive on Agent Sandboxes (Pierce Freeman)](https://pierce.dev/notes/a-deep-dive-on-agent-sandboxes)
- [sandbox-exec: macOS Command-Line Sandboxing](https://igorstechnoclub.com/sandbox-exec/)
- [MCP Filesystem Server Symlink Bypass (CVE)](https://github.com/modelcontextprotocol/servers/security/advisories/GHSA-q66q-fx2p-7w4m)
- [Gemini CLI Symlink Bypass](https://github.com/google-gemini/gemini-cli/issues/1121)
- [Cursor Sandboxing Leaks Secrets](https://luca-becker.me/blog/cursor-sandboxing-leaks-secrets/)
- [Landlock: Unprivileged Access Control (Linux Kernel Docs)](https://docs.kernel.org/userspace-api/landlock.html)
- [Chromium macOS Sandbox V2 Design](https://chromium.googlesource.com/chromium/src/+/HEAD/sandbox/mac/seatbelt_sandbox_design.md)

### Seatbelt Profile Sources (studied for Decision 10)
- [Anthropic sandbox-runtime — SBPL generation](https://github.com/anthropic-experimental/sandbox-runtime) (`src/sandbox/macos-sandbox-utils.ts`)
- [Codex — Seatbelt base policy](https://github.com/openai/codex) (`codex-rs/core/src/seatbelt_base_policy.sbpl`)
- [Codex — Seatbelt Rust integration](https://github.com/openai/codex) (`codex-rs/core/src/seatbelt.rs`)
- [Gemini CLI — Static sandbox profiles](https://github.com/google-gemini/gemini-cli) (`packages/cli/src/utils/sandbox-macos-*.sb`)
- [Chromium — common.sb](https://chromium.googlesource.com/chromium/src/+/HEAD/sandbox/policy/mac/common.sb)
- [Chromium — Mac Sandbox README](https://chromium.googlesource.com/chromium/src/+/HEAD/sandbox/mac/README.md)
- [Apple Sandbox Guide v1.0 (Reverse Engineering)](https://reverse.put.as/wp-content/uploads/2011/09/Apple-Sandbox-Guide-v1.0.pdf)
- [Antigravity AI IDE Sandbox PoC](https://github.com/jdaln/osx-antigravity-ai-ide-sandbox)

### Build vs Reuse (evaluated alternatives)
- [MCP Official Filesystem Server](https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem)
- [safurrier/mcp-filesystem (token-efficient)](https://github.com/safurrier/mcp-filesystem)
- [tumf/mcp-shell-server](https://github.com/tumf/mcp-shell-server)
- [Anthropic Bash Tool Spec](https://platform.claude.com/docs/en/agents-and-tools/tool-use/bash-tool)
- [Anthropic Text Editor Tool Spec](https://platform.claude.com/docs/en/agents-and-tools/computer-use)
- [Claude Agent SDK Overview](https://platform.claude.com/docs/en/agent-sdk/overview)
- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)

### Framework Comparisons
- [OpenAI Agents SDK](https://github.com/openai/openai-agents-python)
- [PydanticAI Tools](https://ai.pydantic.dev/tools/)
- [LangChain ShellTool](https://reference.langchain.com/v0.3/python/community/tools/langchain_community.tools.shell.tool.ShellTool.html)
- [CrewAI Tools](https://docs.crewai.com/en/concepts/tools)
- [AutoGen Tools](https://microsoft.github.io/autogen/stable//user-guide/core-user-guide/components/tools.html)
- [Claude Code System Prompts](https://github.com/Piebald-AI/claude-code-system-prompts)
- [How Claude Code is Built (Pragmatic Engineer)](https://newsletter.pragmaticengineer.com/p/how-claude-code-is-built)
