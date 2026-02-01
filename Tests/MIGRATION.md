# Test Migration Tracker

Track progress of migrating tests from `_Legacy/YrdenTests/` to `YrdenTests/`.

## Status Legend
- **MIGRATED** — rewritten in new target, legacy file can be deleted
- **DEFERRED** — staying in _Legacy for now (MCP, benchmarks)
- **PENDING** — not yet migrated

## Agent Tests (Phase 2)

| Legacy File | Tests | Migrated To | New Tests | Status |
|-------------|-------|-------------|-----------|--------|
| Agent/AgentFailureTests.swift | 27 | — | — | PENDING |
| Agent/AgentConcurrencyTests.swift | 12 | — | — | PENDING |
| Agent/ToolExecutionEngineTests.swift | 14 | — | — | PENDING |
| Agent/ToolExecutionEngineApprovalTests.swift | 8 | — | — | PENDING |
| Agent/AgentResumeStreamTests.swift | 4 | — | — | PENDING |
| Agent/AgentTests.swift | 19 | Component/Agent/AgentBasicRunTests.swift (partial) | 3 | IN PROGRESS |
| Agent/AgentTestHelpers.swift | helpers | YrdenTestSupport/* | — | MIGRATED |

## Unit Tests (Phase 3)

| Legacy File | Tests | Migrated To | New Tests | Status |
|-------------|-------|-------------|-----------|--------|
| JSONValue/JSONValuePrimitiveTests.swift | 55 | — | — | PENDING |
| JSONValue/JSONValueArrayTests.swift | 31 | — | — | PENDING |
| JSONValue/JSONValueObjectTests.swift | 28 | — | — | PENDING |
| JSONValue/JSONValueEqualityTests.swift | 35 | — | — | PENDING |
| JSONValue/JSONValueE2ETests.swift | 16 | — | — | PENDING |
| JSONValue/JSONValueDecodingBenchmarkTests.swift | 4 | — | — | DEFERRED |
| CompletionTests.swift | 34 | — | — | PENDING |
| MessageTests.swift | 28 | — | — | PENDING |
| LLMErrorTests.swift | 27 | — | — | PENDING |
| ToolTests.swift | 29 | — | — | PENDING |
| StreamingTests.swift | 20 | — | — | PENDING |
| ModelTests.swift | 26 | — | — | PENDING |
| SchemaTests.swift | 5 | — | — | PENDING |
| StructuredOutputTests.swift | 33 | — | — | PENDING |
| AnthropicTypesTests.swift | 29 | — | — | PENDING |
| OpenAITypesTests.swift | 40 | — | — | PENDING |
| YrdenTests.swift | 3 | — | — | PENDING |

## Integration Tests (Phase 5)

| Legacy File | Tests | Migrated To | New Tests | Status |
|-------------|-------|-------------|-----------|--------|
| Integration/AnthropicIntegrationTests.swift | 33 | — | — | PENDING |
| Integration/OpenAIIntegrationTests.swift | 28 | — | — | PENDING |
| Integration/BedrockIntegrationTests.swift | 30 | — | — | PENDING |
| Integration/EndToEndTests.swift | 19 | — | — | PENDING |
| Integration/SchemaIntegrationTests.swift | 15 | — | — | PENDING |
| Integration/TypedOutputIntegrationTests.swift | 12 | — | — | PENDING |
| Integration/MCPIntegrationTests.swift | 6 | — | — | DEFERRED |
| Integration/MCPToolErrorReproTest.swift | 3 | — | — | DEFERRED |
| Integration/CrossProvider/* | 18 | — | — | PENDING |

## MCP Tests (Deferred)

| Legacy File | Tests | Status |
|-------------|-------|--------|
| MCP/MCPValueConversionTests.swift | 25 | DEFERRED |
| MCP/MCPToolProxyTests.swift | 23 | DEFERRED |
| MCP/MCPResilienceTests.swift | 15 | DEFERRED |
| MCP/MCPManagerTests.swift | 14 | DEFERRED |
| MCP/ServerConnectionTests.swift | 14 | DEFERRED |
| MCP/MCPCoordinatorTests.swift | 13 | DEFERRED |
| MCP/MCPToolTests.swift | 9 | DEFERRED |
| MCP/MCPConcurrencyTests.swift | 10 | DEFERRED |

## Totals

- **Total legacy tests:** 858
- **Migrated:** 3 tests (AgentBasicRunTests)
- **Deferred:** ~130 (MCP + benchmarks)
- **Remaining:** ~728

## Infrastructure Status

**Phase 0 (Restructure): COMPLETE**
- All legacy tests in `Tests/_Legacy/YrdenTests/` (no SPM target, invisible to `swift test`)
- `YrdenTestSupport` target created as regular `.target()` in Package.swift
- `YrdenTests` test target depends on `YrdenTestSupport`

**Phase 1 (Test Infrastructure): COMPLETE**
- `Tests/YrdenTestSupport/` contains 11 files:
  - `FakeModel.swift` (107 lines) — actor, queue + callback modes, request recording
  - `FakeModelConvenience.swift` (47 lines) — `singleToolCall()` factory
  - `FakeProvider.swift` (42 lines) — struct matching real provider patterns
  - `MockResponse.swift` (91 lines) — `toolCall()` requires explicit `id:` (no default)
  - `RequestMatchers.swift` (69 lines) — `hasToolResult(for:)`, `toolResultContent(for:)`, etc.
  - `ConfigurableTool.swift` (113 lines) — tool + factories + TestToolError
  - `TestToolTypes.swift` (95 lines) — RetryStatefulTool, SlowTool
  - `FakeTool.swift` (62 lines) — generic `FakeTool<A, R>` with `onCall` delegate + call recording
  - `CallCounter.swift` (22 lines) — thread-safe counter for callbacks
  - `Tags.swift` (7 lines) — `.requiresAPIKey` tag
  - `YrdenTestSupport.swift` (2 lines) — module marker
- 7 smoke tests in `Tests/YrdenTests/Placeholder.swift` verify infrastructure works
- `swift test` passes: 51 tests (44 macro + 7 smoke)

**Phase 2 (Agent Tests): IN PROGRESS**
- `Tests/YrdenTests/Component/Agent/` directory created
- `AgentBasicRunTests.swift` — 3 tests (text response, consecutive runs, message history)
- Next: AgentToolCallTests, AgentStreamingTests (happy paths), then failure/error tests

**Gotchas discovered:**
- `@Schema` macro does not propagate `public` access modifiers.
  Types using `@Schema` in YrdenTestSupport must be `internal`.
  Test targets use `@testable import YrdenTestSupport` to access them.
- Use `FakeTool<A, R>` (not `AnyAgentTool` closures) for tool tests.
  `AnyAgentTool` closure init receives raw JSON — that's the internal escape hatch,
  not the customer-facing `AgentTool` protocol path. Tests should mirror real usage.
