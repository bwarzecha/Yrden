---
name: bugbash
description: Run Yrden bug bash scenarios, analyze traces, find bugs and suboptimal behavior, create findings report
argument-hint: "[scenario numbers] [all] [last-failed]"
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Write
  - Edit
  - Task
---

# Bug Bash Runner

You are running the Yrden bug bash — an automated test suite that exercises the Agent's built-in tools against real scenarios. Your job is to run scenarios, analyze ALL traces (pass and fail), and produce a findings report.

## Step 1: Parse Arguments

Arguments: `$ARGUMENTS`

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

1. **Check for API key:**
   ```bash
   # Load env vars if .env exists
   export $(cat .env | grep -v '^#' | xargs) 2>/dev/null
   # Verify key is set
   [ -n "$ANTHROPIC_API_KEY" ] && echo "API key set" || echo "ERROR: ANTHROPIC_API_KEY not set"
   ```
   If the key is missing, stop and tell the user to set it in `.env` or environment.

2. **Check build compiles:**
   ```bash
   swift build --target BugBash 2>&1
   ```
   If the build fails, diagnose and fix the compilation error BEFORE running scenarios. Do not proceed with a broken build.

3. **Check `rg` (ripgrep) is installed** — needed by GrepTool:
   ```bash
   which rg
   ```

## Step 4: Run Scenarios

```bash
# Run specific scenarios
swift run BugBash 01 07 15

# Or run all
swift run BugBash
```

The BugBash runner will:
- Load scenario JSON files from `Examples/BugBash/scenarios/`
- Set up isolated temp directories for each scenario
- Run the Agent with built-in tools
- Check postconditions (file existence, content checks)
- Save full traces to `Examples/BugBash/results/<timestamp>/`
- Print a summary with PASS/FAIL/ERROR for each scenario

**Important:** The runner can take several minutes per scenario. Watch the output for progress. If it appears stuck for more than 5 minutes on a single scenario, that's likely an API timeout — note it but let it complete.

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
