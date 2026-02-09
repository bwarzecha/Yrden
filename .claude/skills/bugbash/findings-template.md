# Findings Template

Use this template for each finding in the bug bash report.

---

## [Bug/Observation/External]: [Short descriptive title]

**Severity:** Critical / High / Medium / Low
**Affected scenarios:** 05, 08, 10
**Category:** Bug / Observation / External

### Description

What happened and why it matters. Be specific — include the actual behavior and the expected behavior.

### Evidence from trace

Relevant excerpt from the agent trace showing the issue. Include the tool call sequence that demonstrates the problem.

```
iteration 3: tool_call read_file {"path": "wrong/path.txt"}
iteration 3: tool_result error "File not found: wrong/path.txt"
iteration 4: tool_call read_file {"path": "wrong/path.txt"}  <-- same mistake repeated
```

### Source location (for bugs)

`Sources/Yrden/Tools/PathValidator.swift:75` — `resolvePath()`

### Root cause (for bugs)

Explain WHY this happens, not just what happens. Trace the issue to the specific code path.

### Suggested improvement

For bugs: describe the fix (code sketch if helpful).
For observations: describe what "better" would look like and whether it's worth the effort.
