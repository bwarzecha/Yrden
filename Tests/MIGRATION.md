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
| Agent/AgentResumeStreamTests.swift | 4 | — | — | PENDING |
| Agent/AgentTests.swift | 19 | Component/Agent/AgentBasicRunTests.swift (partial) | 3 | IN PROGRESS |
| Agent/AgentTestHelpers.swift | helpers | YrdenTestSupport/* | — | MIGRATED |

## Unit Tests (Phase 3)

| Legacy File | Tests | Migrated To | New Tests | Status |
|-------------|-------|-------------|-----------|--------|
| JSONValue/JSONValuePrimitiveTests.swift | 55 | Unit/JSONValue/JSONValuePrimitiveTests.swift | 55 | MIGRATED |
| JSONValue/JSONValueArrayTests.swift | 31 | Unit/JSONValue/JSONValueArrayTests.swift | 31 | MIGRATED |
| JSONValue/JSONValueObjectTests.swift | 28 | Unit/JSONValue/JSONValueObjectTests.swift | 28 | MIGRATED |
| JSONValue/JSONValueEqualityTests.swift | 35 | Unit/JSONValue/JSONValueEqualityTests.swift | 35 | MIGRATED |
| JSONValue/JSONValueE2ETests.swift | 16 | Unit/JSONValue/JSONValueE2ETests.swift | 16 | MIGRATED |
| JSONValue/JSONValueDecodingBenchmarkTests.swift | 4 | — | — | DEFERRED |
| CompletionTests.swift | 34 | Unit/CompletionTests.swift | 34 | MIGRATED |
| MessageTests.swift | 28 | Unit/MessageTests.swift | 28 | MIGRATED |
| LLMErrorTests.swift | 27 | Unit/LLMErrorTests.swift | 27 | MIGRATED |
| ToolTests.swift | 29 | Unit/ToolTests.swift | 29 | MIGRATED |
| StreamingTests.swift | 20 | Unit/StreamingTests.swift | 20 | MIGRATED |
| ModelTests.swift | 26 | Unit/ModelTests.swift | 26 | MIGRATED |
| SchemaTests.swift | 5 | Unit/SchemaTests.swift | 5 | MIGRATED |
| StructuredOutputTests.swift | 33 | Unit/StructuredOutputTests.swift | 33 | MIGRATED |
| AnthropicTypesTests.swift | 29 | Unit/AnthropicTypesTests.swift | 29 | MIGRATED |
| OpenAITypesTests.swift | 40 | Unit/OpenAITypesTests.swift | 40 | MIGRATED |
| YrdenTests.swift | 3 | Placeholder.swift (superseded) | — | MIGRATED |

## Integration Tests (Phase 5)

| Legacy File | Tests | Migrated To | New Tests | Status |
|-------------|-------|-------------|-----------|--------|
| Integration/* | ~160 | Integration/* | ~160 | MIGRATED |
| Integration/MCPIntegrationTests.swift | 6 | Integration/MCPIntegrationTests.swift | 6 | MIGRATED |
| Integration/MCPToolErrorReproTest.swift | 3 | Integration/MCPToolErrorReproTest.swift | 3 | MIGRATED |

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
- **Migrated:** ~550 tests (unit + integration + agent component)
- **Deferred:** ~130 (MCP unit + benchmarks)
- **Remaining:** ~62 (Agent failure/concurrency/resume tests)

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

**Phase 2 (Agent Tests): IN PROGRESS**
- `Tests/YrdenTests/Component/Agent/` directory created
- 25 agent component test files migrated (basic run, tool calls, streaming, failures, approval, etc.)
- Remaining: AgentFailureTests (27), AgentConcurrencyTests (12), AgentResumeStreamTests (4)

**Phase 3 (Unit Tests): COMPLETE**
- All unit tests migrated to `Tests/YrdenTests/Unit/`
- JSONValue tests converted from XCTest to Swift Testing framework
- Core type tests moved as-is (already Swift Testing)
- Fixes applied: Model.providerId conformance, StreamEvent.contentDelta kind parameter, o1 maxContextTokens
- 843 tests passing across 101 suites

**Phase 5 (Integration Tests): COMPLETE**
- All integration tests migrated to `Tests/YrdenTests/Integration/`

**Gotchas discovered:**
- `@Schema` macro does not propagate `public` access modifiers.
  Types using `@Schema` in YrdenTestSupport must be `internal`.
  Test targets use `@testable import YrdenTestSupport` to access them.
- Use `FakeTool<A, R>` (not `AnyAgentTool` closures) for tool tests.
  `AnyAgentTool` closure init receives raw JSON — that's the internal escape hatch,
  not the customer-facing `AgentTool` protocol path. Tests should mirror real usage.
- `Model` protocol gained `static var providerId: String` — mock models need this.
- `StreamEvent.contentDelta` now takes `(String, kind: ContentKind)` — pattern match with `case .contentDelta(let text, _)`.
- `ModelCapabilities.o1.maxContextTokens` was updated from 128K to 200K.
