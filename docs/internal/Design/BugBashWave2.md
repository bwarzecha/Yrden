# Bug Bash Wave 2: Harder Scenarios

## Context

Wave 1 has 20 scenarios covering basic single-tool ops, simple multi-tool combos (grep+edit, grep+write), background tasks, bulk rename, and architecture exploration. Both cloud and local models pass most of them. The scenarios are effective at catching regressions but don't stress-test agent decision-making, error recovery, or tool efficiency.

Wave 2 should find **inefficiencies** (agent picks wrong tool, wastes iterations) and **subtle failures** (agent hallucinates instead of admitting uncertainty, edits blindly instead of checking first).

---

## New Scenario Categories

### 1. Error Recovery / Ambiguous Edits

Test what happens when the obvious approach fails and the agent must adapt.

**Example:** Plant a file with two identical code blocks via `extra_files`. Ask the agent to edit only the second occurrence. The `edit_file` tool will fail on ambiguous `old_string` — the agent must provide more surrounding context or use `replace_all` strategically.

**Framework support:** Already works. Use `extra_files` + `file_contains`.

### 2. Tool Selection Efficiency

Measure whether the agent picks the right tool, not just whether it gets the right answer.

**Example:** "Find which functions call `validateRead` and add a logging statement before each call." Efficient path: `grep` to find call sites, then targeted `edit_file`. Inefficient: `shell` with `grep`, or reading every file with `read_file`.

**Framework support:** Needs new postconditions (see below).

### 3. Multi-Step Ordered Edits

Edits that depend on each other across multiple files and must be consistent.

**Example:** "Add a new `timeout` parameter to ShellTool — update the struct, the args, the JSON schema, and all call sites." Requires coordinated edits across 3-4 locations.

**Framework support:** Already works. Multiple `file_contains` checks across files.

### 4. Misleading / Impossible Tasks

Tasks where the correct answer is "this doesn't exist" — tests whether the agent hallucinates.

**Example:** "The `SearchTool` has a bug in its regex handling — fix it." There is no `SearchTool`. The agent should discover this and report it, not fabricate a fix.

**Framework support:** Needs `completed: false` and `output_contains` postconditions.

### 5. Large Output / Pagination Stress

Test graceful handling of truncated tool output.

**Example:** Generate a 5000-line data file via `extra_files`. Ask the agent to find and extract specific records matching a pattern, then produce a summary. Tests whether the agent handles `maxOutputLength` truncation.

**Framework support:** Already works. Use `extra_files` for the large file + `file_contains` for results.

### 6. Debugging a Real Bug

"Something is broken, figure out what and fix it" — no hints about where or what.

**Example:** Inject a Python script via `extra_files` that fails due to an off-by-one error. Task: "This script fails when run. Diagnose and fix it." Forces: run, read error output, reason, edit, verify.

**Framework support:** Would benefit from `shell_output_contains` to verify the agent actually ran the fixed script. Otherwise works with `file_contains`.

### 7. Concurrent Background Task Coordination

Harder version of existing background scenarios (15, 19).

**Example:** "Run `server.py` in background, then run `client.py` that talks to it. Capture the client output, stop the server, and save both logs to `report.txt`."

**Framework support:** Already works. May need higher `maxIterations`.

### 8. Idempotency / "Already Done" Detection

Pre-apply the requested change. The agent should check first and report it's done, not blindly edit.

**Example:** Pre-apply a change via `extra_files`. Task: "Make sure X is set to Y." Correct behavior: verify and report. Wrong behavior: edit the file (potentially breaking it by double-applying).

**Framework support:** Needs `file_unchanged` postcondition.

---

## Required Framework Changes

### Priority 1: Trivial

**`completed: false` postcondition**

Currently `checkPostconditions()` only checks when `completed == true`. Add the `false` branch to assert the agent correctly recognized an impossible/invalid task.

```swift
if let completed = spec.completed {
    if completed && run.status != .completed {
        failures.append("expected completed but got \(run.status)")
    }
    if !completed && run.status == .completed {
        failures.append("expected agent to NOT complete")
    }
}
```

### Priority 2: Small

**Efficiency postconditions: `max_tool_calls`, `max_iterations`**

The data is already in `AgentRun` — just add checks to `checkPostconditions()`.

```swift
let max_tool_calls: Int?    // total tool invocations must be ≤ this
let max_iterations: Int?    // iterations to completion must be ≤ this (stricter than scenario limit)
```

This is different from the scenario's `maxIterations` field (which is a hard stop). These postconditions assert the agent was *efficient* — it finished but took too many steps.

**Tool usage postconditions: `tool_used`, `tool_not_used`**

Assert which tools appeared (or didn't) in the trace.

```swift
let tool_used: [String]?       // these tool names MUST appear in trace
let tool_not_used: [String]?   // these tool names must NOT appear
```

Example: `"tool_not_used": ["shell"]` to enforce the agent uses `grep` tool instead of shelling out to `grep`.

### Priority 3: Small-Medium

**`output_contains` / `output_not_contains`**

Check the agent's text responses (not tool results). Concatenate all `.text` content from model responses, then substring-match.

```swift
let output_contains: [String]?
let output_not_contains: [String]?
```

Needed for: "agent should say SearchTool doesn't exist" or "agent should say the change is already applied."

**`file_unchanged`**

Hash specified files after `extra_files` are written but before agent starts. After agent finishes, hash again and compare.

```swift
let file_unchanged: [String]?  // these files must not be modified
```

Needed for: idempotency scenarios.

**`shell_output_contains`**

Scan tool results in the trace for shell tool calls, check their stdout.

```swift
let shell_output_contains: [String]?  // at least one shell result must contain these
```

Needed for: "agent ran the fixed script and got correct output" verification.

---

## Implementation Order

| Step | What | Unlocks |
|------|------|---------|
| 1 | `completed: false` | Misleading/impossible task scenarios |
| 2 | `max_tool_calls`, `max_iterations` | Efficiency measurement scenarios |
| 3 | `tool_used`, `tool_not_used` | Tool selection correctness scenarios |
| 4 | `output_contains` | Agent reasoning verification |
| 5 | `file_unchanged` | Idempotency scenarios |
| 6 | `shell_output_contains` | Debug-and-verify scenarios |

Steps 1-3 are the highest value — they unlock the most interesting scenario categories with the least work. Steps 4-6 are nice-to-haves that make certain scenarios more precisely verifiable.

---

## Scenario Candidates (Concrete)

To be written as JSON scenario files once framework changes land. Draft list:

1. **ambiguous-edit** — File with duplicate blocks, edit only the second one
2. **efficient-grep-and-edit** — Find call sites and add logging, must use grep not shell
3. **add-parameter-across-files** — Add timeout param to ShellTool (struct + args + schema + call sites)
4. **nonexistent-tool** — "Fix the bug in SearchTool" (doesn't exist)
5. **large-file-extraction** — Extract records from 5000-line file, produce summary
6. **diagnose-and-fix-bug** — Broken Python script, find the bug and verify the fix
7. **server-client-coordination** — Background server + client, collect both outputs
8. **already-done** — Change is pre-applied, agent should detect and not re-edit
9. **wrong-line-number** — "Fix bug on line 42" when the actual issue is on line 58
10. **minimal-edit** — Simple task, but assert it completes in ≤ 3 tool calls

---

## Local Model Selection Notes

**Avoid hybrid/recurrent architectures for multi-turn testing.** Models like qwen3-coder-next use a hybrid architecture with recurrent (linear) layers alongside attention layers. llama.cpp's KV cache prefix reuse does not work with recurrent layers — the recurrent state must be recomputed for every token on every request. This means every agent iteration reprocesses the entire conversation from scratch, causing response times to scale linearly with context size.

See: [ggml-org/llama.cpp#18497](https://github.com/ggml-org/llama.cpp/issues/18497)

**Recommended local models for bug bash:** Pure transformer models (Llama, Mistral, standard Qwen3 non-Next) that benefit from KV cache prefix reuse. With caching, only new tokens (tool results, etc.) need processing on each iteration, keeping response times roughly constant regardless of conversation length.
