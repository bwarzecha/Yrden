# Yrden Code Consolidation Tracker

> Track progress across sessions. Update after completing each issue.

---

## Overall Status

| Phase | Status | Issues | Progress |
|-------|--------|--------|----------|
| Phase 1: Quick Wins | COMPLETED | #2, #5, #6 | 3/3 |
| Phase 2: Infrastructure | NOT STARTED | #3, #4 | 0/2 |
| Phase 3: Major Refactor | NOT STARTED | #1 | 0/1 |
| Phase 4: Follow-up | NOT STARTED | #7, Open Questions | 0/2 |

**Last Updated:** 2026-01-26
**Total Issues:** 7
**Completed:** 3
**In Progress:** 0

---

## Issue Status

### Phase 1: Quick Wins

#### Issue #2: ToolOutput JSON Encoding
| Attribute | Value |
|-----------|-------|
| **Status** | COMPLETED |
| **Priority** | MEDIUM |
| **Estimated Effort** | 30 minutes |
| **Files Modified** | Tool.swift, AnthropicModel.swift, OpenAIModel.swift, BedrockModel.swift |

**Success Criteria:**
- [x] `ToolOutput.jsonString` property exists
- [x] All 3 providers use the property
- [x] JSON encoding logic in exactly 1 location
- [x] No new abstractions added
- [x] All tests pass

**Session Log:**
| Date | Session | Notes |
|------|---------|-------|
| 2026-01-26 | 1 | Added `ToolOutput.jsonString` computed property. Updated all 3 providers to use it. |

---

#### Issue #5: Bedrock Empty Stream Workaround
| Attribute | Value |
|-----------|-------|
| **Status** | COMPLETED |
| **Priority** | MEDIUM |
| **Estimated Effort** | 30 minutes |
| **Files Modified** | BedrockModel.swift |

**Success Criteria:**
- [x] `stream == nil` throws error (not empty response)
- [x] Error message is clear and actionable
- [x] No silent failures
- [ ] Tests updated to expect error (N/A - no test existed for nil stream)

**Session Log:**
| Date | Session | Notes |
|------|---------|-------|
| 2026-01-26 | 1 | Replaced silent empty response with `LLMError.networkError` throw |

---

#### Issue #6: StopReason Mapping Duplication
| Attribute | Value |
|-----------|-------|
| **Status** | COMPLETED |
| **Priority** | LOW |
| **Estimated Effort** | 1 hour |
| **Files Modified** | Completion.swift, AnthropicModel.swift, OpenAIModel.swift |

**Success Criteria:**
- [x] `StopReason.from(anthropicReason:)` factory method exists
- [x] `StopReason.from(openAIReason:hasStopSequences:)` factory method exists
- [x] Bedrock kept `convertStopReason` (typed enum, not string-based - different pattern)
- [x] `mapStopReason()` removed from Anthropic and OpenAI
- [x] Provider-specific logic preserved (OpenAI stopSequences check)
- [x] All tests pass

**Session Log:**
| Date | Session | Notes |
|------|---------|-------|
| 2026-01-26 | 1 | Added factory methods to Completion.swift. Removed mapStopReason from Anthropic/OpenAI. Bedrock uses typed enum so kept convertStopReason. |

---

### Phase 2: Infrastructure

#### Issue #3: ToolCallAccumulator Duplication
| Attribute | Value |
|-----------|-------|
| **Status** | NOT STARTED |
| **Priority** | MEDIUM |
| **Estimated Effort** | 1 hour |
| **Files to Modify** | NEW: StreamingHelpers.swift, AnthropicModel.swift, OpenAIModel.swift |

**Success Criteria:**
- [ ] Single `ToolCallAccumulator` struct in StreamingHelpers.swift
- [ ] Both Anthropic and OpenAI import and use it
- [ ] No inheritance or protocol complexity
- [ ] Unused fields have negligible cost (documented)
- [ ] All streaming tests pass

**Session Log:**
| Date | Session | Notes |
|------|---------|-------|
| - | - | - |

---

#### Issue #4: Retry Infrastructure Inconsistency
| Attribute | Value |
|-----------|-------|
| **Status** | NOT STARTED |
| **Priority** | MEDIUM-HIGH |
| **Estimated Effort** | 2 hours |
| **Files to Modify** | AnthropicModel.swift, AnthropicProvider.swift |

**Success Criteria:**
- [ ] `AnthropicModel` accepts optional `RetryConfig`
- [ ] `AnthropicProvider` passes default `RetryConfig`
- [ ] Anthropic retries on 429 with backoff
- [ ] Anthropic retries on 500+ errors
- [ ] Anthropic parses Retry-After header
- [ ] Behavior matches OpenAI's retry logic
- [ ] All tests pass

**Verification:**
```bash
# Test retry behavior manually
export $(cat .env | grep -v '^#' | xargs) && swift test --filter "Anthropic"
```

**Session Log:**
| Date | Session | Notes |
|------|---------|-------|
| - | - | - |

---

### Phase 3: Major Refactor

#### Issue #1: Agent Loop Triple Duplication
| Attribute | Value |
|-----------|-------|
| **Status** | NOT STARTED |
| **Priority** | HIGH |
| **Estimated Effort** | 4-6 hours |
| **Files to Modify** | Agent.swift |

**Success Criteria:**
- [ ] Single loop implementation in `runLoop()`
- [ ] `runStreamInternal()` calls `runLoop()` with StreamingLoopObserver
- [ ] `resume()` calls `runLoop()` after tool resolution
- [ ] Zero duplication of while-loop structure
- [ ] Line count reduced by ~80+ lines
- [ ] All agent tests pass
- [ ] `run()`, `runStream()`, `iter()`, `resume()` all work correctly

**Pre-Implementation Investigation:**
- [ ] Verify StreamingLoopObserver handles all needed events
- [ ] Document what `streamModelResponse()` does vs observer
- [ ] Identify any missing observer callbacks

**Verification:**
```bash
# Run all agent tests
export $(cat .env | grep -v '^#' | xargs) && swift test --filter "Agent"

# Manual verification with example app
cd Examples/YrdenExample && swift run
```

**Session Log:**
| Date | Session | Notes |
|------|---------|-------|
| - | - | - |

---

### Phase 4: Follow-up

#### Issue #7: HTTPClient.handleCommonStatus Unused
| Attribute | Value |
|-----------|-------|
| **Status** | DEFERRED |
| **Priority** | LOW |
| **Estimated Effort** | - |
| **Decision** | Document why unused, revisit after Phase 2 |

**Notes:**
- Each provider has different error handling needs
- Forcing shared helper may reduce flexibility
- Will revisit after retry consolidation

**Session Log:**
| Date | Session | Notes |
|------|---------|-------|
| - | - | - |

---

#### Open Questions
| Question | Status | Answer |
|----------|--------|--------|
| Q1: StreamingLoopObserver gaps? | NOT INVESTIGATED | - |
| Q2: Message conversion protocol? | DEFERRED | - |
| Q3: Bedrock SDK retry behavior? | NOT INVESTIGATED | - |
| Q4: OpenAI dual-API extraction? | DEFERRED | - |

---

## Session History

### Session Template
```markdown
### Session: YYYY-MM-DD

**Duration:** X hours
**Issues Worked:** #X, #Y

**Completed:**
- Description of what was done

**Blockers:**
- Any issues encountered

**Next Steps:**
- What to do next session
```

---

### Sessions

### Session: 2026-01-26

**Duration:** ~1.5 hours
**Issues Worked:** #2, #5, #6

**Completed:**
- Issue #2: Added `ToolOutput.jsonString` computed property to Tool.swift
- Issue #2: Updated all 3 providers (Anthropic, OpenAI, Bedrock) to use the property
- Issue #5: Replaced silent empty response fallback with explicit error in BedrockModel
- Issue #6: Added `StopReason.from(anthropicReason:)` factory method
- Issue #6: Added `StopReason.from(openAIReason:hasStopSequences:)` factory method
- Issue #6: Removed `mapStopReason()` from AnthropicModel and OpenAIModel
- All tests pass (pre-existing failures unrelated to changes)

**Blockers:**
- None

**Next Steps:**
- Phase 2: Issue #3 (ToolCallAccumulator) and Issue #4 (Retry Infrastructure)

---

## Metrics

### Code Reduction Tracking

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| Agent.swift loop code | 240 lines | - | (Phase 3) |
| ToolOutput encoding sites | 3 | 1 | -2 sites |
| ToolCallAccumulator definitions | 2 | - | (Phase 2) |
| mapStopReason implementations | 3 | 1 (Bedrock typed) | -2 sites |
| **Total duplicated lines** | ~300 | - | - |

### Test Coverage

| Test Suite | Before | After |
|------------|--------|-------|
| Agent tests | PASS | PASS |
| Anthropic tests | PASS | PASS |
| OpenAI tests | PASS | PASS |
| Bedrock tests | PASS | - |

---

## How to Update This Tracker

After each session:

1. Update issue status (NOT STARTED → IN PROGRESS → COMPLETED)
2. Check off completed success criteria
3. Add session log entry
4. Update metrics if applicable
5. Note any blockers or deviations from plan

After completing an issue:

1. Verify all success criteria are checked
2. Run relevant tests
3. Update "Completed" count in Overall Status
4. Move to next issue in phase
