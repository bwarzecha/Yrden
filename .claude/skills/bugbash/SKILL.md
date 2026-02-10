---
name: bugbash
description: Run Yrden bug bash scenarios, analyze traces, find bugs and suboptimal behavior, create findings report
argument-hint: "[--provider anthropic|openai|ollama|lmstudio] [--model name] [scenario numbers] [all] [last-failed]"
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Write
  - Edit
  - Task
  - AskUserQuestion
---

# Bug Bash Runner

You are running the Yrden bug bash — an automated test suite that exercises the Agent's built-in tools against real scenarios. Your job is to run scenarios, analyze ALL traces (pass and fail), and produce a findings report.

## Step 1: Parse Arguments

Arguments: `$ARGUMENTS`

### Provider and model selection

The BugBash runner supports multiple providers. Parse these flags from the arguments first:

- `--provider <name>` — one of: `anthropic`, `openai`, `ollama`, `lmstudio`
- `--model <name>` — model name (defaults vary by provider, see below)

**If `--provider` is NOT specified in the arguments, ask the user which provider to use** via AskUserQuestion with these options:

| Option | Description |
|--------|-------------|
| `anthropic` | Anthropic API (requires `ANTHROPIC_API_KEY` in `.env`) |
| `openai` | OpenAI API (requires `OPENAI_API_KEY` in `.env`) |
| `lmstudio` | LM Studio local server on `localhost:1234` (no API key needed) |
| `ollama` | Ollama local server on `localhost:11434` (no API key needed) |

**Default models by provider:**

| Provider | Default model |
|----------|---------------|
| `anthropic` | `claude-sonnet-4-5-20250929` |
| `openai` | `gpt-5.2-mini` |
| `ollama` | `qwen/qwen3-coder-next` |
| `lmstudio` | `qwen/qwen3-coder-next` |

### Scenario selection (remaining arguments after removing provider/model flags)

- **Empty or `all`**: Run all scenarios
- **Space-separated numbers** (e.g., `01 07 15`): Run only those scenarios
- **`last-failed`**: Find the most recent results directory, identify FAIL/ERROR scenarios, re-run only those

## Step 2: Discover Available Scenarios

List scenarios dynamically — do NOT assume a fixed set:

```bash
ls Examples/BugBash/scenarios/
```

## Step 3: Preflight Checks

Before running, verify the environment is ready:

1. **Check for API key (cloud providers only):**
   - For `anthropic`: requires `ANTHROPIC_API_KEY`
   - For `openai`: requires `OPENAI_API_KEY`
   - For `ollama` or `lmstudio`: **no API key needed** — these connect to a local server
   ```bash
   # Load env vars if .env exists
   export $(cat .env | grep -v '^#' | xargs) 2>/dev/null
   # Check the relevant key based on provider
   # For anthropic:
   [ -n "$ANTHROPIC_API_KEY" ] && echo "API key set" || echo "ERROR: ANTHROPIC_API_KEY not set"
   # For openai:
   [ -n "$OPENAI_API_KEY" ] && echo "API key set" || echo "ERROR: OPENAI_API_KEY not set"
   ```
   If using a cloud provider and the key is missing, stop and tell the user to set it in `.env` or environment.
   If using `ollama` or `lmstudio`, skip the API key check entirely.

2. **Check build compiles:**
   ```bash
   swift build --target BugBash 2>&1
   ```
   If the build fails, diagnose and fix the compilation error BEFORE running scenarios. Do not proceed with a broken build.

3. **Check `rg` (ripgrep) is installed** — needed by GrepTool:
   ```bash
   which rg
   ```

## Step 4: Run Scenarios (Background with Monitoring)

**ALWAYS run the bug bash in the background** so you can monitor progress and kill it if something goes wrong.

Always pass `--provider` (and `--model` if specified) to `swift run BugBash`. Scenario numbers go at the end.

```bash
# Cloud provider (auto-loads .env for API key)
export $(cat .env | grep -v '^#' | xargs) 2>/dev/null && swift run BugBash --provider anthropic 01 07 15

# Cloud provider with custom model
export $(cat .env | grep -v '^#' | xargs) 2>/dev/null && swift run BugBash --provider anthropic --model claude-haiku-4-5-20251001 05

# Local provider — no env loading needed
swift run BugBash --provider lmstudio 01 07 15
swift run BugBash --provider ollama --model llama3.2

# Run all scenarios
swift run BugBash --provider lmstudio
```

### Running in background

Use `run_in_background: true` on the Bash tool call. This gives you a task ID you can monitor.

### Monitoring loop

After launching the background task, monitor it using **two methods**:

1. **`TaskOutput` with `block: false`** — check the runner's stdout for scenario-level progress (PASS/FAIL lines, which scenario is active)
2. **Read the progress file** — the runner writes real-time `.progress.jsonl` files to the results directory. Read the latest progress file to see **exactly what tool calls** the model is making.

Check every 30-60 seconds. At each check:

#### Quick check (TaskOutput)
- Which scenario number are we on?
- Are new scenarios completing, or has it been stuck on one?
- Any crash/error output from the runner itself?

#### Deep check (progress file) — do this when a scenario is taking >60s

Read the active scenario's progress file from the results directory:
```
tail -20 Examples/BugBash/results/<timestamp>/<scenario-name>.progress.jsonl
```

Look at the `event` and `detail` fields in each line:
- `tool_call` events show what tool the model is calling and with what arguments
- `tool_result` events show what the tool returned
- `text` events show the model's reasoning

**How to assess progress:**

When doing a deep check, don't just count tool calls — understand what the model is *trying to do* by reading the scenario goal and comparing it to the tool call sequence. Ask yourself:

1. **Read the scenario JSON first** — what is the goal? What would a smart agent do?
2. **Are the tool calls purposeful?** — e.g., `grep` to find references, then `read_file` on 3 specific results = good. `glob` to list files, then `read_file` on every single one = bad (the glob output was enough).
3. **Is there reasoning between calls?** — Look for `text` events between `tool_call` events. A good agent reasons about what it found before deciding the next step. A bad agent blindly chains tools.
4. **Are the arguments progressing?** — Reading 6 different files that were identified as relevant by a prior search is fine. Reading 6 files that seem random or exhaustive (iterating through a directory) is degenerate.

**Degenerate patterns (always bad):**
- **Nonexistent tools**: `"Tool not found: find"` or similar — the model is hallucinating tools that don't exist
- **Malformed arguments**: `"Failed to parse tool arguments"` — the model can't produce valid JSON for tool calls
- **Identical calls repeated**: Same tool, same arguments, multiple times — pure loop
- **Circular reasoning**: The model keeps reading the same files or searching for the same patterns it already found

**Context-dependent patterns (check the goal before judging):**
- **Many consecutive `read_file` calls**: Fine if reading targeted files from a prior search. Bad if exhaustively reading everything found by glob when the task doesn't require file contents.
- **Many consecutive `grep` calls**: Fine if searching for different patterns. Bad if repeating the same search with minor variations.
- **No text between tool calls**: Might be okay for a quick 2-call sequence. Bad if there are 5+ tool calls with zero reasoning in between.

### When to kill the run

**Auto-kill** (don't wait, kill immediately) if you observe:
1. **3+ "Tool not found" errors** in one scenario — the model doesn't understand the available tools
2. **3+ "Failed to parse" errors** in one scenario — the model can't produce valid tool arguments
3. **Same tool call with identical arguments repeated** — pure loop, no learning
4. **Exhaustive iteration without purpose** — e.g., glob found 15 files and the model is reading all 15 one-by-one when the task only asked to "list and categorize" (no file contents needed)

**Kill after patience** (wait 2-3 minutes first):
1. **No new progress lines** appearing in the progress file — model or API may be hung
2. **Single scenario running for >3 minutes** with tool calls still happening but no meaningful progress toward the goal
3. **Runner crash/panic** in stderr

After killing, note:
- Which scenarios completed successfully before the kill
- Which scenario was active when killed and why you killed it
- The specific degenerate pattern observed (quote the progress file lines)
- Whether the pattern suggests the model is fundamentally incapable vs just inefficient

Analyze whatever traces were saved and report the kill reason in findings.

### Runner behavior

The BugBash runner will:
- Load scenario JSON files from `Examples/BugBash/scenarios/`
- Set up isolated temp directories for each scenario
- Run the Agent with built-in tools
- Check postconditions (file existence, content checks)
- Save full traces to `Examples/BugBash/results/<timestamp>/`
- Print a summary with PASS/FAIL/ERROR for each scenario

## Step 5: Analyze ALL Traces

After the run completes, analyze **every** trace — not just failures. Even passing scenarios can reveal issues.

### Use subagents for parallel analysis

When there are 4+ scenario traces to analyze, use the **Task tool** to launch subagents in parallel. This dramatically speeds up analysis:

```
Launch up to 5 Task subagents simultaneously, each analyzing a batch of traces:
- Agent 1: Analyze traces for scenarios 01-04
- Agent 2: Analyze traces for scenarios 05-08
- Agent 3: Analyze traces for scenarios 09-12
- Agent 4: Analyze traces for scenarios 13-16
- Agent 5: Analyze traces for scenarios 17-20
```

Each subagent should:
1. Read the trace file(s) for its assigned scenarios
2. Read the corresponding scenario JSON to understand what was expected
3. Analyze the trace looking for the categories below
4. Return a structured list of findings

For 3 or fewer scenarios, analyze them directly without subagents.

### What to look for in each trace

- **Bugs**: Tool errors, incorrect behavior, crashes, wrong file paths, data loss
- **Wasted iterations**: Unnecessary tool calls, going in circles, retrying things that won't work
- **Near-misses**: The agent recovered, but shouldn't have needed to (confusing error messages, unclear tool output)
- **Performance issues**: Excessive retries, slow paths, unnecessary reads
- **Tool ergonomics**: Confusing error messages, missing features, unintuitive behavior
- **External issues**: API timeouts, rate limits (not library bugs, but worth noting)

### Reading the trace format

Each trace file is a JSON object with the full `AgentRun`:
- `iterations[]` — each iteration has a `modelResponse` and `toolResults`
- `modelResponse.contentBlocks` — what the model said/did (text + tool calls)
- `toolResults` — output from each tool execution (check for errors here)
- Look at the SEQUENCE of iterations — this reveals the agent's reasoning chain

## Step 6: Create Findings Report

Collect findings from all subagents (or your direct analysis) and deduplicate.

For each notable finding, create a structured entry. Read the template from `.claude/skills/bugbash/findings-template.md` for the format.

Classify each finding as:
- **Bug**: Something is broken in the Yrden library code
- **Observation**: Working but suboptimal — could be better
- **External**: API timeout, rate limit, or other non-library issue

For bugs, always identify:
- The source file and function where the bug lives
- The root cause (not just the symptom)
- A suggested fix

For observations, describe:
- What happened and why it's suboptimal
- What "better" would look like
- Whether it's worth fixing (severity)

**Deduplicate:** If the same root cause appears in multiple scenarios (common!), write ONE finding that lists all affected scenarios. Do not repeat the same finding for each scenario.

## Step 7: Summary

Present a concise summary at the end:

```
## Bug Bash Summary

**Run:** <timestamp>
**Scenarios:** X total, Y passed, Z failed, W errors

### Findings (N total)
- X Bugs (Y critical, Z high, W medium)
- X Observations
- X External issues

### Critical/High Priority
1. [Bug] Title — affected scenarios, one-line root cause
2. ...

### Details
[Full findings entries below]
```

## Error Recovery

- **Build fails**: Read the error, fix the code, rebuild. Common causes: missing import, type mismatch after a refactor.
- **API key missing**: Tell the user. Don't try to proceed without it.
- **Scenario setup fails** (e.g., git clone timeout): Note as External. Check if the scenario's `setup.sh` needs network access.
- **Runner crashes**: Read the crash output, check if it's a BugBash runner bug vs a scenario issue. If the runner itself is broken, that's a Critical bug.
- **Trace file missing**: The runner may have crashed mid-scenario. Check stderr output from the run.
- **`last-failed` with no previous results**: Fall back to running all scenarios.

## Tips

- If `swift run BugBash` fails to build, check for compilation errors first
- If a scenario hits an API timeout, note it as External but also check if the request was unreasonably large
- Group related findings — if the same root cause affects multiple scenarios, write one finding covering all of them
- When reading traces, pay attention to the tool call sequence — the ORDER of calls reveals agent reasoning quality
- Look for patterns across scenarios — if the agent struggles with the same thing in multiple scenarios, that's a high-priority finding
- When launching subagents for trace analysis, give each one the results directory path and its assigned scenario numbers — don't make them re-discover what you already know
