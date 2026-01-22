# Development Progress

## Session: 2026-01-22 (Part 3)

### Completed

#### JSONValue Implementation - All 5 Phases Complete

Fully implemented `JSONValue` type with comprehensive test coverage (165 tests, 0 failures).

**Implementation** ([Sources/Yrden/JSONValue.swift](../Sources/Yrden/JSONValue.swift)):
- Recursive enum: `null`, `bool`, `int`, `double`, `string`, `array`, `object`
- Custom Codable (not synthesized - proper JSON format, not wrapped enum)
- Type-safe accessors: `boolValue`, `intValue`, `doubleValue`, `stringValue`, `arrayValue`, `objectValue`
- Subscript access: `value["key"]` for objects, `value[0]` for arrays
- Literal expressibility: `nil`, `true`, `42`, `3.14`, `"hello"`, `[1, 2]`, `["a": 1]`
- Sendable, Equatable, Hashable

**Tests** ([Tests/YrdenTests/JSONValue/](../Tests/YrdenTests/JSONValue/)):

| File | Tests | Coverage |
|------|-------|----------|
| [JSONValuePrimitiveTests.swift](../Tests/YrdenTests/JSONValue/JSONValuePrimitiveTests.swift) | 55 | null, bool, int, double, string - roundtrip, encoding, decoding, accessors, literals |
| [JSONValueObjectTests.swift](../Tests/YrdenTests/JSONValue/JSONValueObjectTests.swift) | 29 | objects - roundtrip, accessor, subscript, nested, literals, edge cases |
| [JSONValueArrayTests.swift](../Tests/YrdenTests/JSONValue/JSONValueArrayTests.swift) | 29 | arrays - roundtrip, accessor, subscript, heterogeneous, nested, literals |
| [JSONValueEqualityTests.swift](../Tests/YrdenTests/JSONValue/JSONValueEqualityTests.swift) | 32 | Equatable/Hashable - same/different values, nested, Set/Dictionary usage |
| [JSONValueE2ETests.swift](../Tests/YrdenTests/JSONValue/JSONValueE2ETests.swift) | 20 | real-world: JSON Schema, tool args, structured outputs, provider formats |

**Phases completed:**
1. ✅ Primitives - null, bool, int, double, string + accessors + literals
2. ✅ Object - object case + objectValue + subscript + nested
3. ✅ Array - array case + arrayValue + subscript + mixed
4. ✅ Equatable/Hashable - synthesized works, edge cases verified
5. ✅ E2E - JSON Schema, tool arguments, structured output scenarios

---

## Session: 2026-01-22 (Part 2)

### Completed

#### 1. Research: JSONValue Patterns
Investigated how to represent arbitrary JSON in Swift. Key findings:

- **`[String: Any]` won't work** - not Sendable, not Codable (Swift 6 requirement)
- **JSEN pattern** is industry standard - recursive enum for JSON representation
- **Swift's gap** - no built-in arbitrary JSON type, everyone rolls their own
- **Our scope** - we wrap Apple's JSONDecoder, we don't parse JSON ourselves

Created research document: [docs/research-jsonvalue.md](research-jsonvalue.md)

#### 2. Test Strategy: JSONValue
Defined focused test strategy. Key decisions:

- **Don't test Apple's code** - JSONDecoder handles parsing
- **Test our code** - Codable impl, accessors, subscripts, literals
- **8 test categories** - roundtrip, encoding format, decoding, accessors, subscripts, literals, equatable, **end-to-end**
- **E2E tests critical** - verify full flow (schema → encode → decode → access) works for real scenarios
- **~45 tests total** - small, focused, maintainable

Created test strategy: [docs/test-strategy-jsonvalue.md](test-strategy-jsonvalue.md)

---

## Session: 2026-01-22 (Part 1)

### Completed

#### 1. LLM Provider Design Document
Created comprehensive design document at [docs/llm-provider-design.md](llm-provider-design.md) covering:

- **Design Tenets** (7 core principles):
  - Sendable everywhere
  - Codable by default (opt-in usage)
  - Deps never Codable
  - Lazy initialization
  - State/behavior separation
  - Pausable execution
  - Model-agnostic core

- **Architecture Decision: Model/Provider Split** (PydanticAI-style)
  - `Model` = API format + capabilities + complete()/stream()
  - `Provider` = connection + authentication
  - Avoids N×M type explosion
  - Enables: Azure OpenAI, Ollama, Bedrock with multiple model families

- **10 Design Decisions** with rationale and alternatives considered:
  1. Model/Provider split
  2. Swift API surface (TBD - options documented)
  3. Request type with convenience overloads
  4. Models implement both streaming and non-streaming
  5. Fine-grained streaming events
  6. Closed Message enum
  7. JSONValue for schema representation
  8. Typed error enum
  9. Unified tool system
  10. Codable opt-in for serialization

- **Apple Ecosystem Opportunities** identified (future, not blocking):
  - Handoff, CloudKit sync, SwiftUI binding, Siri/Shortcuts, Background tasks, On-device models

- **Risks and Open Questions** documented

#### 2. Test Configuration Setup
Created environment variable support for integration tests:

- [.env.template](.env.template) - Template for API keys
- [Tests/YrdenTests/TestConfig.swift](../Tests/YrdenTests/TestConfig.swift) - Loads keys from env vars or .env file
- Updated [.gitignore](../.gitignore) to exclude `.env` files

**Key design decision:** Tests fail loudly if required API keys are missing (no silent skipping).

---

## Next Steps

### Immediate (Next Session)

1. **Update SchemaType Protocol**
   - Change `[String: Any]` to `JSONValue`
   - Location: `Sources/Yrden/Yrden.swift`

2. **Core Message Types**
   - `Message`, `ContentPart`
   - `ToolCall`, `ToolDefinition`, `ToolOutput`
   - `CompletionRequest`, `CompletionConfig`
   - `CompletionResponse`, `StopReason`, `Usage`
   - `StreamEvent`
   - `ModelCapabilities`
   - `LLMError`

3. **Model/Provider Protocols**
   - `Provider` protocol
   - `Model` protocol
   - Convenience extensions

4. **Anthropic Model (POC)**
   - First real provider implementation
   - Validates design assumptions
   - Integration tests with real API

### Medium-term

5. **OpenAI Model**
   - Validates abstraction works across providers
   - Different capabilities (test o1 handling)

6. **Provider Variants**
   - `AzureOpenAIProvider`
   - `LocalProvider` (Ollama)

7. **@Schema Macro**
   - JSON Schema generation from Swift types
   - `@Guide` for constraints

---

## File Structure (Current)

```
Yrden/
├── CLAUDE.md                           # Project instructions
├── Package.swift
├── docs/
│   ├── llm-provider-design.md          # ✅ Design document
│   ├── research-jsonvalue.md           # ✅ JSONValue research
│   ├── test-strategy-jsonvalue.md      # ✅ JSONValue test plan
│   └── progress.md                     # ✅ This file
├── Sources/
│   ├── Yrden/
│   │   ├── Yrden.swift                 # SchemaType protocol, @Schema macro decl
│   │   └── JSONValue.swift             # ✅ JSONValue enum (Sendable, Codable)
│   └── YrdenMacros/
│       ├── YrdenMacros.swift           # Plugin entry point
│       └── SchemaMacro.swift           # Macro implementation (stub)
├── Tests/
│   ├── YrdenTests/
│   │   ├── YrdenTests.swift            # Basic tests
│   │   ├── TestConfig.swift            # ✅ API key loading
│   │   └── JSONValue/                  # ✅ JSONValue tests (165 tests)
│   │       ├── JSONValuePrimitiveTests.swift   # ✅ 55 tests
│   │       ├── JSONValueObjectTests.swift      # ✅ 29 tests
│   │       ├── JSONValueArrayTests.swift       # ✅ 29 tests
│   │       ├── JSONValueEqualityTests.swift    # ✅ 32 tests
│   │       └── JSONValueE2ETests.swift         # ✅ 20 tests
│   └── YrdenMacrosTests/
│       └── YrdenMacrosTests.swift      # Macro tests
├── .env.template                       # ✅ API key template
└── .gitignore                          # ✅ Updated for .env
```

---

## Design Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-01-22 | Model/Provider split | Follow PydanticAI, avoid N×M explosion |
| 2026-01-22 | JSONValue over [String: Any] | Sendable + Codable required |
| 2026-01-22 | Codable opt-in | Enable Apple features without requiring them |
| 2026-01-22 | Deps never Codable | Keep deps flexible (DB, HTTP clients) |
| 2026-01-22 | Tests fail on missing keys | No silent skipping |
| 2026-01-22 | Custom Codable for JSONValue | Synthesized Codable wraps values incorrectly |
| 2026-01-22 | Separate int/double cases | JSON Schema distinguishes integer vs number |
| 2026-01-22 | Test our code, not Apple's | JSONDecoder handles parsing, we test our wrapper |
| 2026-01-22 | Incremental implementation | Each feature tested before adding next; primitives → object → array → e2e |
