# Testing Guide

This document covers how to run tests, the test architecture, and patterns for writing tests against Yrden's core types.

## Running Tests

### Unit tests (no API keys needed)

```bash
swift test --filter "SchemaTests|ValidationTests"
```

### Integration tests (need API keys)

```bash
export $(cat .env | grep -v '^#' | xargs) && swift test
```

### Specific provider tests

```bash
export $(cat .env | grep -v '^#' | xargs) && swift test --filter "OpenAI"
export $(cat .env | grep -v '^#' | xargs) && swift test --filter "Anthropic"
```

### Targeting integration test suites by env var

Provider integration tests are gated by environment variables. Set one or more to enable specific providers:

| Variable | Effect |
|----------|--------|
| `INTEGRATION=1` | Enable all providers (local only if detected running) |
| `ANTHROPIC_TESTS=1` | Anthropic only |
| `OPENAI_TESTS=1` | OpenAI only |
| `BEDROCK_TESTS=1` | Bedrock only |
| `LOCAL_TESTS=1` | Ollama only (crashes if Ollama is not running) |
| `LM_STUDIO_TESTS=1` | LM Studio only (crashes if not running) |

When no env var is set, integration tests run zero times (they parameterize over `ProviderFixture.all`, which is empty by default).

---

## Test Architecture (Three Layers)

### Layer 1: Schema Correctness

Validates JSON Schema generation against the spec. These tests are pure logic -- no network calls, no API keys. They run fast on every commit.

Location: `Tests/YrdenTests/Unit/SchemaTests.swift`

Tests cover:
- Basic types (String, Int, Double, Bool) map to correct JSON Schema types
- Object properties, required fields, and `additionalProperties: false`
- Optional fields omitted from `required` array
- Arrays with `items` schema
- String and integer enums with `enum` values
- Nested `@Schema` structs with `$ref` / `$defs`
- `@Guide` descriptions appended to property descriptions

### Layer 2: Provider Integration

The same test cases run against ALL providers with real API calls. Provider-specific capabilities gate which tests execute -- unsupported features are skipped, not failed.

Location: `Tests/YrdenTests/Integration/CrossProvider/`

The cross-provider test suites use `ProviderFixture.all` for parameterized tests:

```swift
@Test(arguments: ProviderFixture.all)
func simpleCompletion(fixture: ProviderFixture) async throws {
    let subject = fixture.subject
    let response = try await subject.model.complete("Say 'hello' and nothing else.")

    #expect(response.content?.lowercased().contains("hello") == true)
    #expect(response.stopReason == .endTurn)
    #expect(response.usage.inputTokens > 0)
}
```

Each provider implements `ModelTestSubject`, which exposes:
- `model`: The primary model for testing (cost-effective, e.g., Haiku, GPT-4o-mini)
- `visionModel`: Model that supports image input
- `constraints`: `TestConstraints` wrapping `ModelCapabilities` plus test-specific overrides

### Layer 3: Local Constraint Validation

Unit tests for each constraint type. No network, fast.

Tests each constraint type:
- `.range()` -- boundaries, negative values, overflow
- `.count()` -- empty, exact, min/max
- `.options()` -- valid values, invalid values, case sensitivity
- `.pattern()` -- matches, non-matches, empty input

---

## Testing Agents

`Agent` is an actor. All interaction is through `async` methods. Use Swift Testing's `@Test` with `async throws`:

```swift
import Testing
@testable import Yrden
@testable import YrdenTestSupport

@Test("agent returns text response from model")
func agentRun() async throws {
    let model = FakeModel(responses: [
        MockResponse.text("Hello from the model"),
    ])

    let agent = try Agent<String>(
        model: model,
        systemPrompt: "Be brief.",
        tools: []
    )

    let run = try await agent.run("Say hello")

    #expect(run.isCompleted)
    #expect(run.output == "Hello from the model")
    #expect(run.requestCount == 1)
    #expect(run.toolCallCount == 0)
}
```

### FakeModel

`FakeModel` is the primary test double for `Model`. It has two independent paths:

**Queue mode** (simple text, no tools):
```swift
let model = FakeModel(responses: [
    MockResponse.text("Hello"),
    MockResponse.text("World"),
])
```

**Callback mode** (tool flows -- required for any tool interaction):
```swift
let counter = CallCounter()
let model = FakeModel(onComplete: { request in
    switch await counter.increment() {
    case 1:
        return MockResponse.toolCall(name: "search", arguments: "{}", id: "s1")
    case 2:
        return MockResponse.text("Done")
    default:
        throw LLMError.serverError("Unexpected call")
    }
})
```

Callback mode takes priority over queue mode if both are set.

### Checking AgentRun status

`AgentRun.status` is an enum with four cases:

```swift
switch run.status {
case .completed(let output):
    // Agent finished successfully
case .needsApproval(let pending):
    // Tools need human approval before continuing
case .iterationLimitReached(let limit):
    // Hit max iterations, can resume with more
case .usageLimitReached(let kind):
    // Hit usage limit, cannot resume
}
```

Convenience accessors: `run.isCompleted`, `run.output`, `run.canResume`, `run.pendingApprovals`.

For the "throw on pause" pattern:
```swift
let output = try await agent.run("task").result()
```

---

## Testing Tools

Tools implement the `TypedTool` protocol. Test them by constructing a `ToolContext` and calling `execute` directly:

```swift
@Test("search tool returns results")
func searchTool() async throws {
    let tool = SearchTool()
    let context = ToolContext(
        model: FakeModel(),
        runID: "test-run"
    )

    let result = try await tool.execute(
        context: context,
        arguments: SearchArgs(query: "swift", limit: 5)
    )

    if case .success(let output) = result {
        #expect(output.contains("swift"))
    } else {
        Issue.record("Expected success result")
    }
}
```

### FakeTool

For testing agent-tool interaction without real tool implementations:

```swift
let tool = FakeTool(name: "search", onCall: { (args: ConfigurableToolArgs) in
    .success("results for: \(args.input)")
})

// After agent execution, verify calls received:
let received = await tool.calls
#expect(received.count == 1)
#expect(received[0].input == "hello")
```

### ConfigurableTool

A generic test tool with preset behaviors:

```swift
// Always succeeds
let tool = ConfigurableTool.succeeding("Success", name: "my_tool")

// Always throws
let tool = ConfigurableTool.throwing(TestToolError.generic("Boom"), name: "broken_tool")

// Always returns failure result to LLM
let tool = ConfigurableTool.failing(TestToolError.processingFailed("Bad input"))
```

### Testing tool approval

Wrap any tool with `.requireApproval()` to test the approval flow:

```swift
let tool = ConfigurableTool.succeeding("Done").requireApproval()
let agent = try Agent<String>(model: model, tools: [tool])

let run = try await agent.run("Do the thing")
#expect(run.status == .needsApproval)

// Resume with approval decisions
let continued = try await agent.resume(
    from: run,
    with: .approveAll(from: run)
)
```

---

## Testing Structured Output

### Schema generation

```swift
import Testing
@testable import Yrden

@Schema
struct Person {
    let name: String
    let age: Int
}

@Test("Person generates correct JSON schema")
func personSchema() {
    let schema = Person.jsonSchema

    guard case .object(let obj) = schema else {
        Issue.record("Expected object schema")
        return
    }

    // Verify type
    guard let typeValue = obj["type"], case .string(let type) = typeValue else {
        Issue.record("Missing type field")
        return
    }
    #expect(type == "object")

    // Verify properties exist
    guard let propsValue = obj["properties"], case .object(let props) = propsValue else {
        Issue.record("Missing properties field")
        return
    }
    #expect(props.count == 2)

    // Verify name is string type
    guard let nameSchema = props["name"], case .object(let nameObj) = nameSchema,
          let nameType = nameObj["type"], case .string(let nameTypeStr) = nameType else {
        Issue.record("Invalid name property schema")
        return
    }
    #expect(nameTypeStr == "string")
}
```

### Output validators

```swift
let validator = OutputValidator<Report> { context, report in
    guard report.sections.count >= 3 else {
        throw ValidationRetry("Report must have at least 3 sections")
    }
    return report
}

let agent = try Agent<Report>(
    model: model,
    outputValidators: [validator],
    maxValidationRetries: 3
)
```

---

## Testing with Real Providers

Provider-specific tests go in `Tests/YrdenTests/Integration/Providers/`. They are gated by `ProviderFixture` availability:

```swift
@Suite("Anthropic Provider", .enabled(if: ProviderFixture.anthropic != nil))
struct AnthropicProviderTests {

    private var model: AnthropicModel {
        let apiKey = TestConfig.anthropicAPIKey
        let provider = AnthropicProvider(apiKey: apiKey)
        return AnthropicModel(name: "claude-haiku-4-5-20251001", provider: provider)
    }

    @Test("invalid API key returns invalidAPIKey error")
    func invalidAPIKey() async throws {
        let badProvider = AnthropicProvider(apiKey: "invalid-key")
        let badModel = AnthropicModel(name: "claude-haiku-4-5-20251001", provider: badProvider)

        do {
            _ = try await badModel.complete("Hello")
            Issue.record("Should have thrown")
        } catch let error as LLMError {
            #expect(error == .invalidAPIKey)
        }
    }
}
```

Cross-provider tests verify the same behavior across all enabled providers:

```swift
@Suite("Cross-Provider Completion")
struct CrossProviderCompletionTests {

    @Test(arguments: ProviderFixture.all)
    func completionWithSystemMessage(fixture: ProviderFixture) async throws {
        let subject = fixture.subject
        guard subject.constraints.supportsSystemMessage else { return }

        let request = CompletionRequest(
            messages: [
                .system("You are a pirate. Always respond in pirate speak."),
                .user("Say hello")
            ]
        )

        let response = try await subject.model.complete(request)
        #expect(response.content != nil)
    }
}
```

---

## Environment Setup

Create a `.env` file in the project root (gitignored):

```bash
# Required for Anthropic tests
ANTHROPIC_API_KEY=sk-ant-...

# Required for OpenAI tests
OPENAI_API_KEY=sk-...

# Required for Bedrock tests (either explicit credentials or AWS profile)
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_DEFAULT_REGION=us-east-1

# Optional
AWS_SESSION_TOKEN=...
AWS_PROFILE=default
OLLAMA_PORT=11434
LM_STUDIO_PORT=1234
LM_STUDIO_MODEL=qwen/qwen3-4b-2507
```

`TestConfig` loads keys from environment variables first, then falls back to parsing the `.env` file. Template values (starting with `your-`) are rejected.

---

## Test Principles

- **Real providers for integration tests.** Do not mock LLM responses in integration tests. Use `FakeModel` for unit and component tests.
- **Skip unsupported features.** Use capability checks (`guard subject.constraints.supportsVision else { return }`) or suite-level gating (`.enabled(if: ProviderFixture.anthropic != nil)`).
- **Use cheap models in CI.** Anthropic: `claude-haiku-4-5-20251001`. OpenAI: `gpt-5-mini`. Bedrock: `us.anthropic.claude-haiku-4-5-20251001-v1:0`.
- **Deterministic prompts.** Use low temperature and explicit expected values (e.g., "Say 'hello' and nothing else").
- **Test the protocol, not the implementation.** Component tests use `FakeModel` against the `Agent` actor. Integration tests use real providers against the `Model` protocol.
- **One assertion per test.** Each `@Test` function validates a single behavior. Use descriptive test names.

---

## Serialization Tests

`AgentRun`, `IterationState`, and all message types conform to `Codable`. Test round-trip serialization to verify cross-session persistence:

```swift
@Test("AgentRun round-trips through JSON")
func runSerialization() async throws {
    let model = FakeModel(responses: [MockResponse.text("Hello")])
    let agent = try Agent<String>(model: model, systemPrompt: "Be brief.")

    let run = try await agent.run("Hello")
    let data = try JSONEncoder().encode(run)
    let decoded = try JSONDecoder().decode(AgentRun<String>.self, from: data)

    #expect(run.isCompleted == decoded.isCompleted)
    #expect(run.output == decoded.output)
    #expect(run.runID == decoded.runID)
    #expect(run.usage == decoded.usage)
    #expect(run.messages.count == decoded.messages.count)
}
```

This pattern is used for testing pause/resume across sessions: serialize the `AgentRun` (or `IterationState`), then resume with `agent.iter(from: savedState)` or `agent.resume(from: decodedRun, with: options)`.

---

## Test Directory Structure

```
Tests/
├── YrdenTestSupport/             # Shared test doubles and helpers
│   ├── FakeModel.swift           # Mock model (queue or callback mode)
│   ├── FakeProvider.swift        # Mock provider
│   ├── FakeTool.swift            # Delegate-based fake tool
│   ├── ConfigurableTool.swift    # Preset-behavior test tool
│   ├── MockResponse.swift        # CompletionResponse factories
│   ├── CallCounter.swift         # Thread-safe call counter for callbacks
│   ├── TestConfig.swift          # API key loading and env setup
│   ├── TestToolTypes.swift       # Shared tool arg types
│   └── Tags.swift                # Test suite tags
├── YrdenTests/
│   ├── Unit/                     # Pure logic, no network
│   │   ├── SchemaTests.swift
│   │   ├── ToolTests.swift
│   │   ├── MessageTests.swift
│   │   ├── StreamingTests.swift
│   │   ├── JSONValue/            # JSONValue type tests
│   │   └── MCP/                  # MCP unit tests
│   ├── Component/                # Agent + FakeModel tests
│   │   ├── Agent/
│   │   │   ├── AgentBasicRunTests.swift
│   │   │   ├── AgentToolCallTests.swift
│   │   │   ├── AgentToolApprovalTests.swift
│   │   │   ├── AgentStreamTests.swift
│   │   │   ├── AgentUsageLimitsTests.swift
│   │   │   ├── AgentOutputValidatorTests.swift
│   │   │   └── Iteration/        # Iterator step-by-step tests
│   │   └── MCP/                  # MCP component tests
│   └── Integration/              # Real API calls
│       ├── CrossProvider/        # Same tests across all providers
│       ├── Providers/            # Provider-specific tests
│       ├── SchemaIntegrationTests.swift
│       └── EndToEndTests.swift
└── YrdenMacrosTests/             # @Schema and @Guide macro tests
```
