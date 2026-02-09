# Iterator API Test Specification

> Comprehensive test plan for `iter()` API with detailed setup, assertions, and rationale for each test case.

## Table of Contents

1. [Overview](#overview)
2. [Test Infrastructure](#test-infrastructure)
3. [IteratorBasicTests](#1-iteratorbasictests)
4. [IteratorPhaseTests](#2-iteratorphasetests)
5. [IteratorToolExecutionTests](#3-iteratortoolexecutiontests)
6. [IteratorToolApprovalTests](#4-iteratortoolapprovetests)
7. [IteratorStateMutationTests](#5-iteratorstatemutationtests)
8. [IteratorStreamingTests](#6-iteratorstreamingtests)
9. [IteratorStateTests](#7-iteratorstatetests)
10. [IteratorOutputTests](#8-iteratoroutputtests)
11. [IteratorErrorTests](#9-iteratorerrortests)
12. [IteratorCancellationTests](#10-iteratorcancellationtests)
13. [IteratorErrorStateTests](#11-iteratorerrorstatetests)
14. [IteratorResumeTests](#12-iteratorresumetests)

---

## Overview

### Test File Structure

```
Tests/YrdenTests/Component/Agent/Iteration/
├── IteratorBasicTests.swift          # ✅ EXISTS (12 tests)
├── IteratorPhaseTests.swift          # 17 tests
├── IteratorToolExecutionTests.swift  # 16 tests
├── IteratorToolApprovalTests.swift   # 13 tests
├── IteratorStateMutationTests.swift  # 9 tests
├── IteratorStreamingTests.swift      # 14 tests (DEFERRED)
├── IteratorStateTests.swift          # 12 tests
├── IteratorOutputTests.swift         # 10 tests
├── IteratorErrorTests.swift          # 10 tests
├── IteratorCancellationTests.swift   # 18 tests (NEW)
├── IteratorErrorStateTests.swift     # 15 tests (NEW)
└── IteratorResumeTests.swift         # 12 tests (DEFERRED)
                                      ─────────
                                      ~158 tests total
```

### Test Naming Convention

```swift
@Test("descriptive sentence about behavior")
func camelCaseDescriptiveName() async throws { ... }
```

### Common Test Pattern

```swift
@Test("description")
func testName() async throws {
    // SETUP: Create model, tools, agent
    let model = FakeModel(...)
    let agent = Agent<Void, String>(model: model, ...)

    // EXECUTE: Run iterator
    var collected: [SomeType] = []
    for try await node in agent.iter("prompt", deps: ()) {
        // Collect data from nodes
    }

    // ASSERT: Verify expectations
    #expect(collected == expected)
}
```

---

## Test Infrastructure

### Existing Tools (from YrdenTestSupport)

#### FakeModel

Two modes of operation:

```swift
// Queue mode - simple responses in order
let model = FakeModel(responses: [
    MockResponse.text("Hello"),
    MockResponse.text("World"),
])

// Callback mode - dynamic responses based on request
let counter = CallCounter()
let model = FakeModel(onComplete: { request in
    switch await counter.increment() {
    case 1: return MockResponse.toolCall(name: "search", arguments: "{}", id: "tc-1")
    case 2: return MockResponse.text("Done")
    default: throw LLMError.serverError("Unexpected")
    }
})
```

#### MockResponse

Factory methods for CompletionResponse:

```swift
MockResponse.text("content")                           // Simple text
MockResponse.toolCall(name:, arguments:, id:)          // Single tool call
MockResponse.toolCalls([ToolCall(...), ...])           // Multiple tool calls
MockResponse.refusal("reason")                         // Model refusal
MockResponse.maxTokens("partial")                      // Truncated response
MockResponse.contentFiltered()                         // Filtered content
```

#### FakeTool / ConfigurableTool

```swift
// FakeTool - records calls, configurable result
let tool = FakeTool<ConfigurableToolArgs, String>(
    name: "my_tool",
    onCall: { args in .success("result: \(args.input)") }
)

// ConfigurableTool - preset behaviors
let tool = ConfigurableTool.succeeding("result", name: "my_tool")
let tool = ConfigurableTool.failing(MyError(), name: "my_tool")
```

#### CallCounter

Thread-safe counter for multi-call scenarios:

```swift
let counter = CallCounter()
// In async context:
switch await counter.increment() {
case 1: // First call
case 2: // Second call
}
```

### New Helpers Needed

#### Phase Name Extraction

```swift
extension IterationNode {
    var phaseName: String {
        switch self {
        case .beforeModel: return "beforeModel"
        case .afterModel: return "afterModel"
        case .beforeTools: return "beforeTools"
        case .afterTools: return "afterTools"
        case .finished: return "finished"
        }
    }
}
```

#### Message Inspection

```swift
extension [Message] {
    func hasToolResult(for callId: String) -> Bool {
        contains { message in
            if case .toolResult(_, let id) = message { return id == callId }
            return false
        }
    }

    func toolResultContent(for callId: String) -> String? {
        for message in self {
            if case .toolResult(let content, let id) = message, id == callId {
                return content
            }
        }
        return nil
    }
}
```

---

## 1. IteratorBasicTests

**File**: `Tests/YrdenTests/Component/Agent/Iteration/IteratorBasicTests.swift`
**Status**: ✅ EXISTS (12 tests)
**Scope**: Simple text responses without tool calls, verifying basic phase sequences.

### Why This File Is Critical

These tests establish the fundamental contract of the iterator:
- Nodes are yielded in the correct order
- State is correctly populated at each phase
- The iterator terminates properly
- Independent runs don't interfere

If these fail, nothing else will work.

---

### Test 1.1: simpleTextPhaseSequence

**Purpose**: Verify the simplest happy path - text response with no tools yields exactly three phases.

**Setup**:
```swift
let model = FakeModel(responses: [MockResponse.text("Hello")])
let agent = Agent<Void, String>(model: model, systemPrompt: "You are helpful.")
```

**Execution**:
```swift
var phases: [String] = []
for try await node in agent.iter("Hi", deps: ()) {
    phases.append(node.phaseName)
}
```

**Assertion**:
```swift
#expect(phases == ["beforeModel", "afterModel", "finished"])
```

**Why Critical**: This is the baseline. If we can't handle "model returns text, we're done", nothing works.

---

### Test 1.2: beforeModelIsFirst

**Purpose**: Verify that the very first node is always `.beforeModel`.

**Setup**:
```swift
let model = FakeModel(responses: [MockResponse.text("Hello")])
let agent = Agent<Void, String>(model: model)
```

**Execution**:
```swift
var firstNode: IterationNode<Void, String>?
for try await node in agent.iter("Hi", deps: ()) {
    firstNode = node
    break  // Only take first
}
```

**Assertion**:
```swift
guard case .beforeModel = firstNode else {
    Issue.record("Expected .beforeModel as first node")
    return
}
```

**Why Critical**: The design guarantees nodes are yielded BEFORE execution. If `.afterModel` comes first, execution timing is broken.

---

### Test 1.3: finishedIsLast

**Purpose**: Verify that the last node is always `.finished`.

**Setup**:
```swift
let model = FakeModel(responses: [MockResponse.text("Hello")])
let agent = Agent<Void, String>(model: model)
```

**Execution**:
```swift
var lastNode: IterationNode<Void, String>?
for try await node in agent.iter("Hi", deps: ()) {
    lastNode = node
}
```

**Assertion**:
```swift
guard case .finished = lastNode else {
    Issue.record("Expected .finished as last node")
    return
}
```

**Why Critical**: The iterator must terminate with `.finished` containing the output. If it ends on another phase, the output is inaccessible.

---

### Test 1.4: finishedContainsOutput

**Purpose**: Verify that `.finished` context contains the correct output value.

**Setup**:
```swift
let model = FakeModel(responses: [MockResponse.text("Hello from model")])
let agent = Agent<Void, String>(model: model)
```

**Execution**:
```swift
var output: String?
for try await node in agent.iter("Hi", deps: ()) {
    if case .finished(let ctx) = node {
        output = ctx.output
    }
}
```

**Assertion**:
```swift
#expect(output == "Hello from model")
```

**Why Critical**: The whole point of the iterator is to produce an output. If the output is wrong or missing, the API is broken.

---

### Test 1.5: finishedContainsMessages

**Purpose**: Verify that `.finished` context contains the complete conversation history.

**Setup**:
```swift
let model = FakeModel(responses: [MockResponse.text("Response")])
let agent = Agent<Void, String>(model: model, systemPrompt: "System")
```

**Execution**:
```swift
var messages: [Message]?
for try await node in agent.iter("User prompt", deps: ()) {
    if case .finished(let ctx) = node {
        messages = ctx.messages
    }
}
```

**Assertions** (multiple):
```swift
// Don't assert exact message count - system prompt handling is implementation detail
#expect(messages?.isEmpty == false)
#expect(messages?.contains(where: { if case .user = $0 { return true } else { return false } }) == true)
#expect(messages?.contains(where: { if case .assistant = $0 { return true } else { return false } }) == true)
```

**Why Critical**: Message history is needed for:
- Continuation/resume
- Debugging
- Context engineering
If messages are missing or malformed, all advanced use cases break.

---

### Test 1.6: beforeModelHasUserMessage

**Purpose**: Verify that in `.beforeModel`, the state contains the user's prompt (what WILL be sent).

**Setup**:
```swift
let model = FakeModel(responses: [MockResponse.text("Hi")])
let agent = Agent<Void, String>(model: model)
```

**Execution**:
```swift
var beforeModelMessages: [Message]?
for try await node in agent.iter("Hello world", deps: ()) {
    if case .beforeModel(let ctx) = node {
        beforeModelMessages = ctx.state.messages
    }
}
```

**Assertion**:
```swift
#expect(beforeModelMessages?.contains(.user("Hello world")) == true)
```

**Why Critical**: This validates the "before" semantic - the state shows what WILL happen, allowing inspection/modification before execution.

---

### Test 1.7: afterModelHasResponse

**Purpose**: Verify that `.afterModel` context contains the full model response.

**Setup**:
```swift
let model = FakeModel(responses: [MockResponse.text("Model says hi")])
let agent = Agent<Void, String>(model: model)
```

**Execution**:
```swift
var response: CompletionResponse?
for try await node in agent.iter("Hi", deps: ()) {
    if case .afterModel(let ctx) = node {
        response = ctx.response
    }
}
```

**Assertion**:
```swift
#expect(response?.content == "Model says hi")
```

**Why Critical**: `.afterModel` is where you inspect the model's response before deciding what to do next. If the response is wrong or unavailable, inspection is impossible.

---

### Test 1.8: consistentRunID

**Purpose**: Verify that all nodes in a single iteration share the same `runID`.

**Setup**:
```swift
let model = FakeModel(responses: [MockResponse.text("Hi")])
let agent = Agent<Void, String>(model: model)
```

**Execution**:
```swift
var runIDs: Set<String> = []
for try await node in agent.iter("Hi", deps: ()) {
    switch node {
    case .beforeModel(let ctx): runIDs.insert(ctx.state.runID)
    case .afterModel(let ctx): runIDs.insert(ctx.state.runID)
    case .beforeTools(let ctx): runIDs.insert(ctx.state.runID)
    case .afterTools(let ctx): runIDs.insert(ctx.state.runID)
    case .finished(let ctx): runIDs.insert(ctx.runID)
    }
}
```

**Assertions**:
```swift
#expect(runIDs.count == 1, "All nodes should have same runID")
#expect(runIDs.first?.isEmpty == false, "runID should not be empty")
```

**Why Critical**: `runID` is used for:
- Correlating logs
- Tracking a run across serialization/resume
- Debugging
If it changes mid-run or is empty, correlation breaks.

---

### Test 1.9: iterWithHistory

**Purpose**: Verify that `messageHistory` parameter correctly prepends previous messages.

**Setup**:
```swift
let model = FakeModel(responses: [MockResponse.text("Continuation")])
let agent = Agent<Void, String>(model: model)

let history: [Message] = [
    .user("First"),
    .assistant("Response to first"),
]
```

**Execution**:
```swift
var beforeModelMessages: [Message]?
for try await node in agent.iter("Second", deps: (), messageHistory: history) {
    if case .beforeModel(let ctx) = node {
        beforeModelMessages = ctx.state.messages
    }
}
```

**Assertions**:
```swift
#expect(beforeModelMessages?.count == 3)  // 2 history + 1 new
#expect(beforeModelMessages?.contains(.user("First")) == true)
#expect(beforeModelMessages?.contains(.user("Second")) == true)
```

**Why Critical**: Continuation from previous conversations is a core use case. If history isn't preserved, multi-turn conversations break.

---

### Test 1.10: consecutiveIterationsIndependent

**Purpose**: Verify that separate `iter()` calls don't share state.

**Setup**:
```swift
let counter = CallCounter()
let model = FakeModel(onComplete: { _ in
    let n = await counter.increment()
    return MockResponse.text("Response \(n)")
})
let agent = Agent<Void, String>(model: model)
```

**Execution**:
```swift
var output1: String?
for try await node in agent.iter("First", deps: ()) {
    if case .finished(let ctx) = node { output1 = ctx.output }
}

var output2: String?
for try await node in agent.iter("Second", deps: ()) {
    if case .finished(let ctx) = node { output2 = ctx.output }
}
```

**Assertions**:
```swift
#expect(output1 == "Response 1")
#expect(output2 == "Response 2")
```

**Why Critical**: State isolation is fundamental. If runs leak into each other, the iterator is non-deterministic and unusable.

---

## 2. IteratorPhaseTests

**File**: `Tests/YrdenTests/Component/Agent/Iteration/IteratorPhaseTests.swift`
**Status**: To be created
**Scope**: Phase transitions involving tool calls, multiple iterations, output tool behavior.

### Why This File Is Critical

These tests verify the complex state machine transitions when tools are involved. The iterator must correctly:
- Yield `beforeTools` and `afterTools` when tools are called
- Loop back to `beforeModel` when more work is needed
- Handle the output tool specially (invisible in approval flow)
- Respect `maxIterations` limits

---

### Test 2.1: toolCallYieldsBeforeToolsPhase

**Purpose**: Verify that when the model returns a tool call, we get the full 5-phase sequence.

**Setup**:
```swift
let tool = ConfigurableTool.succeeding("tool result", name: "my_tool")

let counter = CallCounter()
let model = FakeModel(onComplete: { _ in
    switch await counter.increment() {
    case 1: return MockResponse.toolCall(name: "my_tool", arguments: #"{"input":"x"}"#, id: "tc-1")
    case 2: return MockResponse.text("Done")
    default: throw LLMError.serverError("Unexpected")
    }
})

let agent = Agent<Void, String>(
    model: model,
    tools: [AnyAgentTool(tool)]
)
```

**Execution**:
```swift
var phases: [String] = []
for try await node in agent.iter("Use tool", deps: ()) {
    phases.append(node.phaseName)
}
```

**Assertion**:
```swift
#expect(phases == [
    "beforeModel",   // First model call
    "afterModel",    // Model returned tool call
    "beforeTools",   // About to execute tool
    "afterTools",    // Tool executed
    "beforeModel",   // Second model call (with tool result)
    "afterModel",    // Model returned text
    "finished"       // Done
])
```

**Why Critical**: This tests the complete tool flow. Every tool-using agent goes through this sequence.

---

### Test 2.2: afterToolsFollowsBeforeTools

**Purpose**: Verify that `beforeTools` is always immediately followed by `afterTools` (no phases in between).

**Setup**: Same as 2.1

**Execution**:
```swift
var seenBeforeTools = false
var phaseAfterBeforeTools: String?

for try await node in agent.iter("Use tool", deps: ()) {
    if seenBeforeTools && phaseAfterBeforeTools == nil {
        phaseAfterBeforeTools = node.phaseName
    }
    if case .beforeTools = node {
        seenBeforeTools = true
    }
}
```

**Assertion**:
```swift
#expect(phaseAfterBeforeTools == "afterTools")
```

**Why Critical**: Phase ordering is deterministic. If phases appear in wrong order, state management breaks.

---

### Test 2.3: multipleToolCallsInSingleBeforeTools

**Purpose**: Verify that multiple tool calls from a single model response appear in one `beforeTools` context.

**Setup**:
```swift
let toolA = ConfigurableTool.succeeding("a-result", name: "tool_a")
let toolB = ConfigurableTool.succeeding("b-result", name: "tool_b")
let toolC = ConfigurableTool.succeeding("c-result", name: "tool_c")

let counter = CallCounter()
let model = FakeModel(onComplete: { _ in
    switch await counter.increment() {
    case 1:
        return MockResponse.toolCalls([
            ToolCall(id: "tc-a", name: "tool_a", arguments: #"{"input":"a"}"#),
            ToolCall(id: "tc-b", name: "tool_b", arguments: #"{"input":"b"}"#),
            ToolCall(id: "tc-c", name: "tool_c", arguments: #"{"input":"c"}"#),
        ])
    case 2: return MockResponse.text("Done")
    default: throw LLMError.serverError("Unexpected")
    }
})

let agent = Agent<Void, String>(
    model: model,
    tools: [AnyAgentTool(toolA), AnyAgentTool(toolB), AnyAgentTool(toolC)]
)
```

**Execution**:
```swift
var pendingCallCount: Int?
for try await node in agent.iter("Use all tools", deps: ()) {
    if case .beforeTools(let ctx) = node {
        pendingCallCount = ctx.pendingCalls.count
    }
}
```

**Assertion**:
```swift
#expect(pendingCallCount == 3)
```

**Why Critical**: Batch tool calls must be handled together. If they're split into separate phases, approval logic becomes complicated.

---

### Test 2.4: loopContinuesAfterToolsIfNoOutput

**Purpose**: Verify that after tool execution (with no output), we loop back to `beforeModel`.

**Setup**: Same as 2.1 (tool call → text response)

**Execution**:
```swift
var beforeModelCount = 0
for try await node in agent.iter("Use tool", deps: ()) {
    if case .beforeModel = node {
        beforeModelCount += 1
    }
}
```

**Assertion**:
```swift
#expect(beforeModelCount == 2)  // Initial + after tools
```

**Why Critical**: The agent loop must continue until output is produced. If it stops after tools without output, the agent is stuck.

---

### Test 2.5: multipleIterationsYieldMultipleBeforeModel

**Purpose**: Verify that a multi-turn conversation yields `beforeModel` for each model call.

**Setup**:
```swift
let tool = ConfigurableTool.succeeding("result", name: "my_tool")

let counter = CallCounter()
let model = FakeModel(onComplete: { _ in
    switch await counter.increment() {
    case 1: return MockResponse.toolCall(name: "my_tool", arguments: #"{"input":"1"}"#, id: "tc-1")
    case 2: return MockResponse.toolCall(name: "my_tool", arguments: #"{"input":"2"}"#, id: "tc-2")
    case 3: return MockResponse.text("Done")
    default: throw LLMError.serverError("Unexpected")
    }
})

let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])
```

**Execution**:
```swift
var beforeModelCount = 0
for try await node in agent.iter("Use tool twice", deps: ()) {
    if case .beforeModel = node { beforeModelCount += 1 }
}
```

**Assertion**:
```swift
#expect(beforeModelCount == 3)  // Initial + 2 after-tool loops
```

**Why Critical**: Each model call should be observable. If some are hidden, context engineering opportunities are lost.

---

### Test 2.6: noToolsSkipsToolPhases

**Purpose**: Verify that when there are no tool calls, `beforeTools` and `afterTools` are never yielded.

**Setup**:
```swift
let model = FakeModel(responses: [MockResponse.text("Just text")])
let agent = Agent<Void, String>(model: model)
```

**Execution**:
```swift
var phases: [String] = []
for try await node in agent.iter("Hi", deps: ()) {
    phases.append(node.phaseName)
}
```

**Assertion**:
```swift
#expect(!phases.contains("beforeTools"))
#expect(!phases.contains("afterTools"))
```

**Why Critical**: Tool phases should only appear when tools are involved. Spurious phases would confuse users.

---

### Test 2.7: iterationCounterIncrements

**Purpose**: Verify that `state.iteration` increments with each model call loop.

**Setup**: Same as 2.5 (3 model calls)

**Execution**:
```swift
var iterations: [Int] = []
for try await node in agent.iter("Multi-turn", deps: ()) {
    if case .beforeModel(let ctx) = node {
        iterations.append(ctx.state.iteration)
    }
}
```

**Assertion**:
```swift
#expect(iterations == [0, 1, 2])  // 0-indexed
```

**Why Critical**: Iteration count is used for:
- Debugging ("which loop are we on?")
- Limits ("stop after N iterations")
- Progress tracking

---

### Test 2.8: toolCallCountAccumulates

**Purpose**: Verify that `state.toolCallCount` accurately tracks total tool calls across iterations.

**Setup**: Same as 2.5 (2 tool calls across 2 iterations)

**Execution**:
```swift
var finalToolCallCount: Int?
for try await node in agent.iter("Multi-tool", deps: ()) {
    if case .finished(let ctx) = node {
        finalToolCallCount = ctx.state.toolCallCount
    }
}
```

**Assertion**:
```swift
#expect(finalToolCallCount == 2)
```

**Why Critical**: Tool call counting is used for usage limits and billing tracking.

---

### Test 2.9: outputToolYieldsFinishedDirectly

**Purpose**: Verify that when output tool is called (for structured output), we go directly to `finished` without `beforeTools`.

**Setup**:
```swift
@Schema struct MyOutput: SchemaType {
    let result: String
}

let model = FakeModel(responses: [
    MockResponse.toolCall(
        name: "final_result",  // Default output tool name
        arguments: #"{"result":"structured output"}"#,
        id: "output-1"
    )
])

let agent = Agent<Void, MyOutput>(model: model)
```

**Execution**:
```swift
var phases: [String] = []
for try await node in agent.iter("Get output", deps: ()) {
    phases.append(node.phaseName)
}
```

**Assertion**:
```swift
#expect(phases == ["beforeModel", "afterModel", "finished"])
#expect(!phases.contains("beforeTools"))  // Output tool is invisible
```

**Why Critical**: Output tool is a structured output mechanism, not a real tool. It shouldn't appear in approval flow.

---

### Test 2.10: invalidOutputToolContinuesLoop

**Purpose**: Verify that invalid output tool arguments cause a retry (loop continues with error feedback).

**Setup**:
```swift
@Schema struct MyOutput: SchemaType {
    let count: Int
}

let counter = CallCounter()
let model = FakeModel(onComplete: { _ in
    switch await counter.increment() {
    case 1:
        // Invalid: "count" should be Int, not String
        return MockResponse.toolCall(
            name: "final_result",
            arguments: #"{"count":"not a number"}"#,
            id: "output-1"
        )
    case 2:
        // Valid
        return MockResponse.toolCall(
            name: "final_result",
            arguments: #"{"count":42}"#,
            id: "output-2"
        )
    default: throw LLMError.serverError("Unexpected")
    }
})

let agent = Agent<Void, MyOutput>(model: model)
```

**Execution**:
```swift
var beforeModelCount = 0
var output: MyOutput?
for try await node in agent.iter("Get count", deps: ()) {
    if case .beforeModel = node { beforeModelCount += 1 }
    if case .finished(let ctx) = node { output = ctx.output }
}
```

**Assertions**:
```swift
#expect(beforeModelCount == 2)  // Retry after validation error
#expect(output?.count == 42)
```

**Why Critical**: Validation errors must loop back to the model with feedback, not crash.

---

### Test 2.11: outputToolWithRegularToolsEarlyStrategy

**Purpose**: Verify that with `EndStrategy.early`, output tool terminates immediately even if regular tools are present.

**Setup**:
```swift
@Schema struct MyOutput: SchemaType {
    let result: String
}

let tool = FakeTool<ConfigurableToolArgs, String>(
    name: "regular_tool",
    onCall: { _ in .success("should not execute") }
)

let model = FakeModel(responses: [
    MockResponse.toolCalls([
        ToolCall(id: "output-1", name: "final_result", arguments: #"{"result":"done"}"#),
        ToolCall(id: "tc-1", name: "regular_tool", arguments: #"{"input":"x"}"#),
    ])
])

let agent = Agent<Void, MyOutput>(
    model: model,
    tools: [AnyAgentTool(tool)],
    endStrategy: .early
)
```

**Execution**:
```swift
var phases: [String] = []
for try await node in agent.iter("Mixed tools", deps: ()) {
    phases.append(node.phaseName)
}
let toolCalls = await tool.calls
```

**Assertions**:
```swift
#expect(phases == ["beforeModel", "afterModel", "finished"])
#expect(toolCalls.isEmpty)  // Regular tool was NOT executed
```

**Why Critical**: Early strategy is the default - output found means we're done. Regular tools shouldn't run.

---

### Test 2.12: outputToolWithRegularToolsExhaustiveStrategy

**Purpose**: Verify that with `EndStrategy.exhaustive`, all tools run before finishing.

**Setup**:
```swift
@Schema struct MyOutput: SchemaType {
    let result: String
}

let tool = FakeTool<ConfigurableToolArgs, String>(
    name: "regular_tool",
    onCall: { _ in .success("executed") }
)

let counter = CallCounter()
let model = FakeModel(onComplete: { _ in
    switch await counter.increment() {
    case 1:
        return MockResponse.toolCalls([
            ToolCall(id: "output-1", name: "final_result", arguments: #"{"result":"done"}"#),
            ToolCall(id: "tc-1", name: "regular_tool", arguments: #"{"input":"x"}"#),
        ])
    case 2:
        return MockResponse.text("acknowledged")  // After tool result
    default: throw LLMError.serverError("Unexpected")
    }
})

let agent = Agent<Void, MyOutput>(
    model: model,
    tools: [AnyAgentTool(tool)],
    endStrategy: .exhaustive
)
```

**Execution**:
```swift
var phases: [String] = []
for try await node in agent.iter("Mixed tools", deps: ()) {
    phases.append(node.phaseName)
}
let toolCalls = await tool.calls
```

**Assertions**:
```swift
#expect(phases.contains("beforeTools"))
#expect(phases.contains("afterTools"))
#expect(toolCalls.count == 1)  // Regular tool WAS executed
```

**Why Critical**: Exhaustive strategy runs all tools. Important when side effects matter.

---

### Test 2.13: maxIterationsThrowsAfterLimit

**Purpose**: Verify that exceeding `maxIterations` throws an error.

**Setup**:
```swift
let tool = ConfigurableTool.succeeding("result", name: "my_tool")

// Model always returns tool call (infinite loop without limit)
let model = FakeModel(onComplete: { _ in
    MockResponse.toolCall(name: "my_tool", arguments: #"{"input":"x"}"#, id: "tc-\(UUID())")
})

let agent = Agent<Void, String>(
    model: model,
    tools: [AnyAgentTool(tool)],
    maxIterations: 3
)
```

**Execution & Assertion**:
```swift
do {
    for try await _ in agent.iter("Loop forever", deps: ()) { }
    Issue.record("Expected maxIterationsExceeded error")
} catch let error as AgentError {
    guard case .maxIterationsExceeded = error else {
        Issue.record("Expected .maxIterationsExceeded, got \(error)")
        return
    }
    // Success
}
```

**Why Critical**: Without iteration limits, an agent could loop forever. This is a safety mechanism.

---

### Test 2.14: emptyModelResponseForStringOutputSucceeds

**Purpose**: Verify that empty content is valid for String output type.

**Setup**:
```swift
let model = FakeModel(responses: [
    CompletionResponse(
        content: "",  // Empty string
        refusal: nil,
        toolCalls: [],
        stopReason: .endTurn,
        usage: Usage(inputTokens: 10, outputTokens: 0)
    )
])

let agent = Agent<Void, String>(model: model)
```

**Execution**:
```swift
var output: String?
for try await node in agent.iter("Hi", deps: ()) {
    if case .finished(let ctx) = node { output = ctx.output }
}
```

**Assertion**:
```swift
#expect(output == "")  // Empty string is valid
```

**Why Critical**: Per design doc: "Empty Model Response Handling" - String output accepts empty.

---

### Test 2.15: emptyModelResponseForStructuredOutputContinues

**Purpose**: Verify that empty content with no tools for structured output causes a retry.

**Setup**:
```swift
@Schema struct MyOutput: SchemaType {
    let value: Int
}

let counter = CallCounter()
let model = FakeModel(onComplete: { _ in
    switch await counter.increment() {
    case 1:
        // Empty response - no content, no tools
        return CompletionResponse(
            content: nil,
            refusal: nil,
            toolCalls: [],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 0)
        )
    case 2:
        // Valid output tool
        return MockResponse.toolCall(
            name: "final_result",
            arguments: #"{"value":42}"#,
            id: "output-1"
        )
    default: throw LLMError.serverError("Unexpected")
    }
})

let agent = Agent<Void, MyOutput>(model: model)
```

**Execution**:
```swift
var beforeModelCount = 0
for try await node in agent.iter("Get value", deps: ()) {
    if case .beforeModel = node { beforeModelCount += 1 }
}
```

**Assertion**:
```swift
#expect(beforeModelCount == 2)  // Empty response caused retry
```

**Why Critical**: For structured output, empty response isn't valid. Must retry.

---

## 3. IteratorToolExecutionTests

**File**: `Tests/YrdenTests/Component/Agent/Iteration/IteratorToolExecutionTests.swift`
**Status**: To be created
**Scope**: Tool execution mechanics, result handling, failure behavior.

### Why This File Is Critical

These tests verify that tools actually execute correctly through the iterator:
- Arguments are parsed and passed correctly
- Results flow back to messages
- Failures are handled gracefully (as results, not exceptions)
- Timeouts work

---

### Test 3.1: toolReceivesCorrectArguments

**Purpose**: Verify that tool receives correctly parsed arguments from the model.

**Setup**:
```swift
let tool = FakeTool<ConfigurableToolArgs, String>(
    name: "my_tool",
    onCall: { args in .success("got: \(args.input)") }
)

let counter = CallCounter()
let model = FakeModel(onComplete: { _ in
    switch await counter.increment() {
    case 1:
        return MockResponse.toolCall(
            name: "my_tool",
            arguments: #"{"input":"hello world"}"#,
            id: "tc-1"
        )
    case 2: return MockResponse.text("Done")
    default: throw LLMError.serverError("Unexpected")
    }
})

let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])
```

**Execution**:
```swift
for try await _ in agent.iter("Use tool", deps: ()) { }
let calls = await tool.calls
```

**Assertion**:
```swift
#expect(calls.count == 1)
#expect(calls[0].input == "hello world")
```

**Why Critical**: If arguments aren't parsed correctly, tools receive garbage.

---

### Test 3.2: toolResultAddedToMessagesAfterAfterTools

**Purpose**: Verify that after `afterTools` phase, tool results are in the message history.

**Setup**: Same as 3.1

**Execution**:
```swift
var messagesAfterAfterTools: [Message]?
for try await node in agent.iter("Use tool", deps: ()) {
    if case .afterTools(let ctx) = node {
        // Messages at this point should include tool result
    }
    if case .beforeModel(let ctx) = node {
        // Second beforeModel should have tool result in history
        if ctx.state.iteration > 0 {
            messagesAfterAfterTools = ctx.state.messages
        }
    }
}
```

**Assertion**:
```swift
#expect(messagesAfterAfterTools?.hasToolResult(for: "tc-1") == true)
#expect(messagesAfterAfterTools?.toolResultContent(for: "tc-1") == "got: hello world")
```

**Why Critical**: Tool results must flow back to the model. If missing, the model can't see what happened.

---

### Test 3.3: toolResultIDMatchesCallID

**Purpose**: Verify that tool result message uses the exact same ID as the tool call.

**Setup**: Same as 3.1 with specific ID "call-xyz-123"

**Execution**:
```swift
var resultId: String?
for try await node in agent.iter("Use tool", deps: ()) {
    // Extract tool result ID from messages
    ...
}
```

**Assertion**:
```swift
#expect(resultId == "call-xyz-123")
```

**Why Critical**: API providers require exact ID matching. Wrong IDs cause errors.

---

### Test 3.4: multipleToolsAllExecuted

**Purpose**: Verify that all tools in a batch are executed.

**Setup**:
```swift
let toolA = FakeTool<ConfigurableToolArgs, String>(name: "tool_a", onCall: { _ in .success("a") })
let toolB = FakeTool<ConfigurableToolArgs, String>(name: "tool_b", onCall: { _ in .success("b") })
let toolC = FakeTool<ConfigurableToolArgs, String>(name: "tool_c", onCall: { _ in .success("c") })

// Model returns all 3 tool calls at once
...
```

**Execution**:
```swift
for try await _ in agent.iter("Use all", deps: ()) { }
let aCalls = await toolA.calls
let bCalls = await toolB.calls
let cCalls = await toolC.calls
```

**Assertions**:
```swift
#expect(aCalls.count == 1)
#expect(bCalls.count == 1)
#expect(cCalls.count == 1)
```

**Why Critical**: Batch execution must run all tools, not stop after first.

---

### Test 3.5: toolsExecuteInOriginalOrder

**Purpose**: Verify that results maintain the original call order.

**Setup**: Same as 3.4

**Execution**:
```swift
var resultOrder: [String] = []
for try await node in agent.iter("Use all", deps: ()) {
    if case .afterTools(let ctx) = node {
        resultOrder = ctx.results.map { $0.call.name }
    }
}
```

**Assertion**:
```swift
#expect(resultOrder == ["tool_a", "tool_b", "tool_c"])
```

**Why Critical**: Deterministic ordering helps debugging and makes output predictable.

---

### Test 3.6: toolContextHasCorrectDeps

**Purpose**: Verify that tools receive the dependencies passed to `iter()`.

**Setup**:
```swift
struct MyDeps: Sendable {
    let apiKey: String
}

var receivedApiKey: String?
let tool = FakeTool<ConfigurableToolArgs, String>(
    name: "my_tool",
    onCall: { [weak receivedApiKey] args in
        // Can't capture in test, so use different approach
        .success("ok")
    }
)

// Need custom tool that captures deps
actor DepsCapturingTool: AgentTool {
    typealias Deps = MyDeps
    var capturedDeps: MyDeps?

    func call(context: AgentContext<MyDeps>, arguments: ConfigurableToolArgs) async throws -> ToolResult<String> {
        capturedDeps = context.deps
        return .success("ok")
    }
}
```

**Execution**:
```swift
let myDeps = MyDeps(apiKey: "secret-123")
for try await _ in agent.iter("Use tool", deps: myDeps) { }
let captured = await depsCapturingTool.capturedDeps
```

**Assertion**:
```swift
#expect(captured?.apiKey == "secret-123")
```

**Why Critical**: Dependencies are how tools access external resources. If deps are wrong, tools can't function.

---

### Test 3.7: toolExceptionBecomesFailureResult

**Purpose**: Verify that tool exceptions become failure results, not thrown errors.

**Setup**:
```swift
struct MyToolError: Error {}

let tool = FakeTool<ConfigurableToolArgs, String>(
    name: "failing_tool",
    onCall: { _ in throw MyToolError() }
)

let counter = CallCounter()
let model = FakeModel(onComplete: { request in
    switch await counter.increment() {
    case 1:
        return MockResponse.toolCall(name: "failing_tool", arguments: #"{"input":"x"}"#, id: "tc-1")
    case 2:
        // Model should receive error in tool result
        let resultContent = request.toolResultContent(for: "tc-1")
        #expect(resultContent?.contains("Error") == true || resultContent?.contains("MyToolError") == true)
        return MockResponse.text("Acknowledged error")
    default: throw LLMError.serverError("Unexpected")
    }
})

let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])
```

**Execution & Assertion**:
```swift
// Should NOT throw - tool errors are results, not exceptions
var output: String?
for try await node in agent.iter("Use failing tool", deps: ()) {
    if case .finished(let ctx) = node { output = ctx.output }
}
#expect(output == "Acknowledged error")
```

**Why Critical**: Per design: "Errors as Results" - tool failures are data for the model, not crashes.

---

### Test 3.8: toolNotFoundBecomesFailureResult

**Purpose**: Verify that calling an unknown tool returns a failure result.

**Setup**:
```swift
// No tools registered!
let model = FakeModel(onComplete: { _ in
    switch await counter.increment() {
    case 1:
        return MockResponse.toolCall(name: "nonexistent_tool", arguments: "{}", id: "tc-1")
    case 2:
        // Should have error result
        return MockResponse.text("Tool not found acknowledged")
    default: throw LLMError.serverError("Unexpected")
    }
})

let agent = Agent<Void, String>(model: model, tools: [])  // No tools!
```

**Execution**:
```swift
var output: String?
for try await node in agent.iter("Use unknown tool", deps: ()) {
    if case .finished(let ctx) = node { output = ctx.output }
}
```

**Assertion**:
```swift
#expect(output == "Tool not found acknowledged")
```

**Why Critical**: Unknown tools shouldn't crash - model should learn the tool doesn't exist.

---

### Test 3.9: argumentParsingErrorBecomesFailureResult

**Purpose**: Verify that invalid JSON arguments become a failure result.

**Setup**:
```swift
let tool = ConfigurableTool.succeeding("ok", name: "my_tool")

let model = FakeModel(onComplete: { _ in
    switch await counter.increment() {
    case 1:
        return MockResponse.toolCall(
            name: "my_tool",
            arguments: "not valid json {{{",  // Invalid!
            id: "tc-1"
        )
    case 2:
        return MockResponse.text("Parse error acknowledged")
    default: throw LLMError.serverError("Unexpected")
    }
})
```

**Execution & Assertion**: Should complete without throwing, model sees error.

**Why Critical**: Malformed arguments from model shouldn't crash the agent.

---

### Test 3.10: toolTimeoutBecomesFailureResult

**Purpose**: Verify that tool timeout becomes a failure result.

**Setup**:
```swift
let slowTool = FakeTool<ConfigurableToolArgs, String>(
    name: "slow_tool",
    onCall: { _ in
        try await Task.sleep(for: .seconds(10))  // Very slow
        return .success("finally")
    }
)

let agent = Agent<Void, String>(
    model: model,
    tools: [AnyAgentTool(slowTool, timeout: .milliseconds(100))]  // 100ms timeout
)
```

**Execution**:
```swift
for try await node in agent.iter("Use slow tool", deps: ()) {
    if case .afterTools(let ctx) = node {
        #expect(ctx.results[0].result.isFailure)
        // Check that error mentions timeout
    }
}
```

**Why Critical**: Timeouts prevent hanging. The model should learn the tool timed out.

---

### Test 3.11: failureResultSentToModelAsContent

**Purpose**: Verify that failure result error messages appear in tool_result content.

**Setup**: Same as 3.7 (throwing tool)

**Execution**:
```swift
var toolResultContent: String?
for try await node in agent.iter("Use tool", deps: ()) {
    if case .beforeModel(let ctx) = node, ctx.state.iteration > 0 {
        toolResultContent = ctx.state.messages.toolResultContent(for: "tc-1")
    }
}
```

**Assertion**:
```swift
#expect(toolResultContent?.contains("Error") == true)
```

**Why Critical**: The model needs to see WHY a tool failed to adapt its strategy.

---

### Test 3.12: perToolTimeoutRespected

**Purpose**: Verify that per-tool timeout takes precedence over engine default.

**Setup**:
```swift
let fastTool = FakeTool<..>(name: "fast", timeout: .seconds(1))
let slowTool = FakeTool<..>(name: "slow", timeout: .seconds(30))

let agent = Agent<..>(
    model: model,
    tools: [AnyAgentTool(fastTool), AnyAgentTool(slowTool)],
    toolTimeout: .seconds(5)  // Engine default
)
```

**Assertion**: Fast tool times out at 1s, not 5s.

**Why Critical**: Different tools have different execution profiles.

---

### Test 3.13: engineDefaultTimeoutUsedWhenNoPerTool

**Purpose**: Verify that engine default timeout applies when tool has none.

**Setup**:
```swift
let tool = FakeTool<..>(name: "my_tool")  // No per-tool timeout

let agent = Agent<..>(
    model: model,
    tools: [AnyAgentTool(tool)],
    toolTimeout: .milliseconds(100)  // Engine default
)
```

**Assertion**: Tool times out at 100ms (engine default).

---

### Test 3.14: noTimeoutAllowsLongExecution

**Purpose**: Verify that without timeout, long-running tools complete.

**Setup**:
```swift
let slowTool = FakeTool<..>(name: "slow", onCall: { _ in
    try await Task.sleep(for: .seconds(2))
    return .success("done")
})

let agent = Agent<..>(
    model: model,
    tools: [AnyAgentTool(slowTool)],
    toolTimeout: nil  // No timeout
)
```

**Assertion**: Tool completes successfully after 2 seconds.

---

## 4. IteratorToolApprovalTests

**File**: `Tests/YrdenTests/Component/Agent/Iteration/IteratorToolApprovalTests.swift`
**Status**: To be created
**Scope**: approve/deny/replace decisions in beforeTools phase.

### Why This File Is Critical

These tests verify the approval flow that gives users control over tool execution:
- Default behavior (pending = execute)
- Explicit approval
- Denial with message
- Replacement with synthetic result

This is a key differentiator of `iter()` over `run()`.

---

### Test 4.1: pendingDecisionExecutesByDefault

**Purpose**: Verify that without any action, pending tools execute.

**Setup**:
```swift
let tool = FakeTool<ConfigurableToolArgs, String>(
    name: "my_tool",
    onCall: { _ in .success("executed") }
)

// Model returns tool call, then text
...
```

**Execution**:
```swift
for try await node in agent.iter("Use tool", deps: ()) {
    // Don't call approve(), deny(), or replace()
    // Just let iteration continue
}
let calls = await tool.calls
```

**Assertion**:
```swift
#expect(calls.count == 1)  // Tool WAS executed
```

**Why Critical**: Default behavior must work without explicit action. Most users won't call approve() for every tool.

---

### Test 4.2: approveExecutesTool

**Purpose**: Verify that explicit `approve()` executes the tool.

**Setup**: Same as 4.1

**Execution**:
```swift
for try await node in agent.iter("Use tool", deps: ()) {
    if case .beforeTools(let ctx) = node {
        ctx.approve(ctx.pendingCalls[0].call)
    }
}
let calls = await tool.calls
```

**Assertion**:
```swift
#expect(calls.count == 1)
```

**Why Critical**: Explicit approval should work (even if same as default).

---

### Test 4.3: denySkipsExecutionWithMessage

**Purpose**: Verify that `deny()` prevents execution and sends message to model.

**Setup**: Same as 4.1

**Execution**:
```swift
for try await node in agent.iter("Use tool", deps: ()) {
    if case .beforeTools(let ctx) = node {
        ctx.deny(ctx.pendingCalls[0].call, message: "Not allowed today")
    }
    if case .afterTools(let ctx) = node {
        #expect(ctx.results[0].output.contains("Tool denied: Not allowed today"))
    }
}
let calls = await tool.calls
```

**Assertions**:
```swift
#expect(calls.isEmpty)  // Tool was NOT executed
```

**Why Critical**: Denial is the primary approval mechanism. Must prevent execution and inform model.

---

### Test 4.4: replaceSkipsExecutionWithResult

**Purpose**: Verify that `replace()` skips execution and uses synthetic result.

**Setup**: Same as 4.1

**Execution**:
```swift
for try await node in agent.iter("Use tool", deps: ()) {
    if case .beforeTools(let ctx) = node {
        ctx.replace(ctx.pendingCalls[0].call, withResult: "cached value from yesterday")
    }
    if case .afterTools(let ctx) = node {
        #expect(ctx.results[0].output == "cached value from yesterday")
    }
}
let calls = await tool.calls
```

**Assertion**:
```swift
#expect(calls.isEmpty)  // Tool was NOT executed
```

**Why Critical**: Replacement enables caching, mocking, testing scenarios.

---

### Test 4.5: mixedDecisionsRespected

**Purpose**: Verify that different decisions for different tools are respected.

**Setup**:
```swift
let toolA = FakeTool<..>(name: "tool_a", onCall: { _ in .success("a") })
let toolB = FakeTool<..>(name: "tool_b", onCall: { _ in .success("b") })
let toolC = FakeTool<..>(name: "tool_c", onCall: { _ in .success("c") })

// Model returns all 3 tool calls
```

**Execution**:
```swift
for try await node in agent.iter("Use all", deps: ()) {
    if case .beforeTools(let ctx) = node {
        for pending in ctx.pendingCalls {
            switch pending.call.name {
            case "tool_a": ctx.approve(pending.call)
            case "tool_b": ctx.deny(pending.call, message: "denied")
            case "tool_c": ctx.replace(pending.call, withResult: "replaced")
            default: break
            }
        }
    }
}
```

**Assertions**:
```swift
#expect((await toolA.calls).count == 1)  // Approved - executed
#expect((await toolB.calls).isEmpty)      // Denied - not executed
#expect((await toolC.calls).isEmpty)      // Replaced - not executed
```

**Why Critical**: Real-world approval logic applies different decisions to different tools.

---

### Test 4.6: allToolsDenied

**Purpose**: Verify behavior when all tools are denied.

**Setup**:
```swift
// 3 tools, all denied
```

**Execution**:
```swift
for try await node in agent.iter("Use all", deps: ()) {
    if case .beforeTools(let ctx) = node {
        for pending in ctx.pendingCalls {
            ctx.deny(pending.call, message: "all denied")
        }
    }
    if case .afterTools(let ctx) = node {
        #expect(ctx.results.count == 3)
        #expect(ctx.results.allSatisfy { $0.output.contains("Tool denied") })
    }
}
```

**Why Critical**: Edge case - must handle gracefully, not crash.

---

### Test 4.7: allToolsReplaced

**Purpose**: Verify behavior when all tools are replaced.

**Setup & Execution**: Similar to 4.6 but with `replace()`

**Why Critical**: Edge case for caching scenarios.

---

### Test 4.8: pendingCallsShowsRequiresApprovalFlag

**Purpose**: Verify that `requiresApproval` flag from tool definition is exposed.

**Setup**:
```swift
let normalTool = ConfigurableTool.succeeding("ok", name: "normal")
let sensitiveT = ConfigurableTool.succeeding("ok", name: "sensitive")

let agent = Agent<Void, String>(
    model: model,
    tools: [
        AnyAgentTool(normalTool, requiresApproval: false),
        AnyAgentTool(sensitiveT, requiresApproval: true),
    ]
)
```

**Execution**:
```swift
for try await node in agent.iter("Use both", deps: ()) {
    if case .beforeTools(let ctx) = node {
        let normal = ctx.pendingCalls.first { $0.call.name == "normal" }
        let sensitive = ctx.pendingCalls.first { $0.call.name == "sensitive" }

        #expect(normal?.requiresApproval == false)
        #expect(sensitive?.requiresApproval == true)
    }
}
```

**Why Critical**: Users need to know which tools are flagged as sensitive.

---

### Test 4.9: requiresApprovalFlagIsInformationalOnly

**Purpose**: Verify that `requiresApproval` flag doesn't auto-deny in `iter()`.

**Setup**:
```swift
let tool = ConfigurableTool.succeeding("ok", name: "sensitive")

let agent = Agent<Void, String>(
    model: model,
    tools: [AnyAgentTool(tool, requiresApproval: true)]
)
```

**Execution**:
```swift
for try await node in agent.iter("Use tool", deps: ()) {
    // Don't call deny() - just let it execute
}
let calls = await tool.calls
```

**Assertion**:
```swift
#expect(calls.count == 1)  // Tool executed despite requiresApproval=true
```

**Why Critical**: `iter()` is for manual control. The flag is informational, not enforced.

---

### Test 4.10: decisionPersistsInStatePhase

**Purpose**: Verify that decisions are stored in `state.phase` for serialization.

**Setup**: Same tool setup

**Execution**:
```swift
for try await node in agent.iter("Use tool", deps: ()) {
    if case .beforeTools(let ctx) = node {
        ctx.deny(ctx.pendingCalls[0].call, message: "denied")

        // Check state reflects decision
        guard case .beforeTools(let calls) = ctx.state.phase else {
            Issue.record("Expected beforeTools phase")
            return
        }
        #expect(calls[0].decision == .denied("denied"))
    }
}
```

**Why Critical**: Decisions must survive serialization for cross-session approval.

---

### Test 4.11: deniedToolMessageFormat

**Purpose**: Verify exact format of denied tool message.

**Setup & Execution**:
```swift
ctx.deny(pending.call, message: "User said no")
// ...
#expect(result.output == "Tool denied: User said no")
```

**Why Critical**: Consistent format helps model understand denials.

---

### Test 4.12: replacedToolUsesExactResult

**Purpose**: Verify that replacement uses exact string without modification.

**Setup & Execution**:
```swift
ctx.replace(pending.call, withResult: "Custom result with special chars: <>&\"'")
// ...
#expect(result.output == "Custom result with special chars: <>&\"'")
```

**Why Critical**: Replacement must be exact - no escaping or transformation.

---

## 5. IteratorStateMutationTests

**File**: `Tests/YrdenTests/Component/Agent/Iteration/IteratorStateMutationTests.swift`
**Status**: To be created
**Scope**: State modification via context objects.

### Why This File Is Critical

State mutation is how users do context engineering:
- Compacting messages before model calls
- Injecting system prompts dynamically
- Modifying tool results before they enter context

If mutations don't work correctly, context engineering breaks.

---

### Test 5.1: appendMessageBeforeModelAffectsRequest

**Purpose**: Verify that appending a message before model call affects what's sent.

**Setup**:
```swift
let model = FakeModel(onComplete: { request in
    // Check that our injected message is present
    let hasInjected = request.messages.contains { msg in
        if case .system(let text) = msg { return text.contains("INJECTED") }
        return false
    }
    #expect(hasInjected, "Injected message should be in request")
    return MockResponse.text("Done")
})
```

**Execution**:
```swift
for try await node in agent.iter("Hi", deps: ()) {
    if case .beforeModel(let ctx) = node {
        ctx.state.messages.append(.system("INJECTED CONTEXT"))
    }
}
```

**Why Critical**: This is core context engineering - adding context dynamically.

---

### Test 5.2: modifyMessagesArrayBeforeModel

**Purpose**: Verify that replacing messages entirely works.

**Setup**: Similar to 5.1 but checking message count

**Execution**:
```swift
if case .beforeModel(let ctx) = node {
    // Replace with just user message
    ctx.state.messages = [.user("Only this")]
}
```

**Assertion**: Request has only the replacement message.

---

### Test 5.3: compactMessagesBeforeModel

**Purpose**: Verify context compaction (keeping only recent messages).

**Setup**:
```swift
let history = (1...100).map { Message.user("Message \($0)") }
```

**Execution**:
```swift
if case .beforeModel(let ctx) = node {
    // Keep only last 10
    ctx.state.messages = Array(ctx.state.messages.suffix(10))
}
```

**Assertion**: Request has 10 messages.

**Why Critical**: Context window management is essential for long conversations.

---

### Test 5.4: mutationBeforeStreamAffectsRequest

**Purpose**: Verify that mutations before `stream()` affect the request.

**Setup**: Same as 5.1

**Execution**:
```swift
if case .beforeModel(let ctx) = node {
    ctx.state.messages.append(.system("BEFORE STREAM"))
    for await _ in ctx.stream() { }  // Triggers execution
}
```

**Assertion**: Request includes "BEFORE STREAM".

---

### Test 5.5: mutationDuringStreamDoesNotAffectCurrentRequest

**Purpose**: Verify that mutations during streaming don't affect in-flight request.

**Setup**:
```swift
var injectedDuringStream = false
let model = FakeModel(onComplete: { request in
    // Check for message that was added during stream
    let hasDuring = request.messages.contains { ... }
    if injectedDuringStream {
        #expect(!hasDuring, "Message added during stream should NOT be in request")
    }
    return MockResponse.text("Done")
})
```

**Execution**:
```swift
if case .beforeModel(let ctx) = node {
    for await _ in ctx.stream() {
        // Add during stream
        ctx.state.messages.append(.system("DURING STREAM"))
        injectedDuringStream = true
    }
}
```

**Why Critical**: Per design: mutations during streaming are allowed but don't affect current request.

---

### Test 5.6: mutationDuringStreamPersistsInState

**Purpose**: Verify that mutations during streaming persist for next iteration.

**Setup**: Tool call scenario (so there's a next iteration)

**Execution**:
```swift
var addedDuringStream = false
for try await node in agent.iter("Multi-turn", deps: ()) {
    if case .beforeModel(let ctx) = node {
        if !addedDuringStream {
            for await _ in ctx.stream() {
                ctx.state.messages.append(.system("PERSISTENT"))
                addedDuringStream = true
            }
        } else {
            // Second beforeModel - check if PERSISTENT is there
            #expect(ctx.state.messages.contains { ... })
        }
    }
}
```

---

### Test 5.4: replaceResultModifiesMessageContent

**Purpose**: Verify that `replaceResult()` changes what goes into messages.

**Setup**: Tool call scenario

**Execution**:
```swift
if case .afterTools(let ctx) = node {
    ctx.replaceResult(forCallId: "tc-1", with: "SUMMARIZED: blah blah")
}
// Check in next beforeModel
if case .beforeModel(let ctx) = node, ctx.state.iteration > 0 {
    #expect(ctx.state.messages.toolResultContent(for: "tc-1") == "SUMMARIZED: blah blah")
}
```

**Why Critical**: Result summarization is key for context management.

---

### Test 5.5: removeResultOmitsFromMessages

**Purpose**: Verify that `removeResult()` prevents result from entering messages.

**Setup & Execution**: Similar, but use `removeResult()`

**Assertion**: No tool result message for that call ID.

---

### Test 5.6: contextIsReferenceType

**Purpose**: Verify that context is a class (reference type) - mutations visible without reassignment.

**Execution**:
```swift
if case .beforeModel(let ctx) = node {
    let originalCount = ctx.state.messages.count
    ctx.state.messages.append(.system("Added"))

    // Without reassigning ctx, check it's visible
    #expect(ctx.state.messages.count == originalCount + 1)
}
```

**Why Critical**: If contexts were structs, mutations would require explicit reassignment.

---

### Test 5.7: stateChangeVisibleToIterator

**Purpose**: Verify that iterator sees state changes made through context.

**Setup**: Check in afterModel that message added in beforeModel persists.

---

### Test 5.8: earlyLoopTerminationCleanup

**Purpose**: Verify that breaking out of iteration loop early doesn't leak resources or corrupt state.

**Execution**:
```swift
for try await node in agent.iter("Hi", deps: ()) {
    if case .beforeModel = node {
        break  // Exit early, before finished
    }
}

// Agent should be usable for new iteration
var output: String?
for try await node in agent.iter("Second", deps: ()) {
    if case .finished(let ctx) = node { output = ctx.output }
}
#expect(output != nil)
```

**Why Critical**: Users may break out of loops for various reasons; this shouldn't break the agent.

---

**Note**: Tests for mutations during streaming are in IteratorStreamingTests (streaming must be implemented first).

---

## 6. IteratorStreamingTests

**File**: `Tests/YrdenTests/Component/Agent/Iteration/IteratorStreamingTests.swift`
**Status**: To be created (may be deferred)
**Scope**: `ctx.stream()` behavior.

### Why This File Is Critical (When Implemented)

Streaming enables real-time UI updates. Tests verify:
- Streaming triggers execution
- Events are yielded correctly
- Stream can only be called once

### Note: Streaming May Be Deferred

Initial implementation may leave `stream()` as `fatalError("Not implemented")`. These tests would be enabled when streaming is implemented.

---

### Tests 6.1-6.12 (Summary)

| Test | Purpose |
|------|---------|
| `streamTriggersModelExecution` | `stream()` causes model to execute |
| `noStreamStillExecutesOnAdvance` | Without `stream()`, execution happens on `next()` |
| `streamYieldsContentDeltas` | Text tokens come through |
| `streamYieldsToolCallEvents` | Tool call events come through |
| `streamCompletesWithResponse` | Response available after stream |
| `toolStreamYieldsStartedEvents` | Tool start events |
| `toolStreamYieldsCompletedEvents` | Tool completion events |
| `toolStreamYieldsFailedEvents` | Tool failure events |
| `toolStreamYieldsDeniedEventsImmediately` | Denied events before execution |
| `toolStreamYieldsEventsInExecutionOrder` | Parallel tools interleave |
| `streamOnlyCallableOnce` | Second call fails |
| `streamAfterAdvanceFails` | Can't stream after moving on |

---

## 7. IteratorStateTests

**File**: `Tests/YrdenTests/Component/Agent/Iteration/IteratorStateTests.swift`
**Status**: To be created
**Scope**: `IterationState` properties and helpers.

### Why This File Is Critical

These tests verify the state struct itself works correctly:
- Copy methods (`with(phase:)`)
- Usage tracking
- Phase enum
- Codable conformance

---

### Test 7.1: withPhaseCreatesNewState

**Purpose**: Verify `state.with(phase:)` returns a new state with different phase.

**Setup**:
```swift
let state = IterationState<String>(
    runID: "run-1",
    messages: [.user("hi")],
    usage: Usage(inputTokens: 10, outputTokens: 5),
    iteration: 0,
    toolCallCount: 0,
    phase: .beforeModel
)
```

**Execution**:
```swift
let newState = state.with(phase: .afterModel(response: someResponse))
```

**Assertions**:
```swift
#expect(newState.runID == state.runID)
#expect(newState.messages == state.messages)
guard case .afterModel = newState.phase else {
    Issue.record("Expected afterModel phase")
    return
}
guard case .beforeModel = state.phase else {
    Issue.record("Original should still be beforeModel")
    return
}
```

**Why Critical**: Immutable phase + copy method is how state transitions work.

---

### Test 7.2: withPhasePreservesOtherProperties

**Purpose**: Verify that `with(phase:)` doesn't lose any properties.

**Assertions**: Check all properties preserved (runID, messages, usage, iteration, toolCallCount).

---

### Test 7.3-7.5: Usage Tracking Tests

| Test | Purpose |
|------|---------|
| `usageAvailableAtEveryPhase` | Usage accessible in all contexts |
| `usageUpdatedAfterModelCall` | afterModel has new tokens |
| `usageAccumulatesAcrossIterations` | Multi-turn adds up |

---

### Test 7.6-7.9: Phase Enum Tests

| Test | Purpose |
|------|---------|
| `beforeModelPhaseHasNoAssociatedValue` | Simple case |
| `afterModelPhaseContainsResponse` | Has full response |
| `beforeToolsPhaseContainsPendingDecisions` | Has decisions array |
| `afterToolsPhaseContainsResults` | Has results array |

---

### Test 7.10-7.12: Codable Tests

| Test | Purpose |
|------|---------|
| `stateIsEncodable` | JSONEncoder works |
| `stateIsDecodable` | Roundtrip works |
| `pendingDecisionIsEncodable` | Decisions survive serialization |

---

## 8. IteratorOutputTests

**File**: `Tests/YrdenTests/Component/Agent/Iteration/IteratorOutputTests.swift`
**Status**: To be created
**Scope**: Output extraction for String vs structured types.

### Why This File Is Critical

Output extraction is the final step - how we get the typed result:
- String outputs from content
- Structured outputs from output tool
- Validation and retry

---

### Test 8.1-8.4: String Output Tests

| Test | Purpose |
|------|---------|
| `stringOutputExtractedFromContent` | Model text → String output |
| `emptyStringOutputAllowed` | Empty content → "" |
| `stringOutputValidatorCalled` | Validator runs |
| `stringValidatorRetryLoops` | ValidationRetry continues loop |

---

### Test 8.5-8.8: Structured Output Tests

| Test | Purpose |
|------|---------|
| `structuredOutputParsedFromToolArguments` | Output tool → typed |
| `structuredOutputValidatorCalled` | Validator runs |
| `invalidJSONRetriesToModel` | Bad JSON → retry |
| `schemaMismatchRetriesToModel` | Wrong shape → retry |

---

### Test 8.9-8.10: Output Tool Tests

| Test | Purpose |
|------|---------|
| `outputToolNotVisibleInPendingCalls` | Hidden from approval |
| `customOutputToolNameUsed` | Custom name works |

---

## 9. IteratorErrorTests

**File**: `Tests/YrdenTests/Component/Agent/Iteration/IteratorErrorTests.swift`
**Status**: To be created
**Scope**: Error propagation and usage limits (cancellation moved to IteratorCancellationTests, error state to IteratorErrorStateTests).

### Why This File Is Critical

Error handling ensures the iterator fails gracefully and propagates errors correctly. Note: All errors now carry resumable state - those tests are in IteratorErrorStateTests.

---

### Test 9.1-9.4: Error Propagation Tests

| Test | Purpose |
|------|---------|
| `modelErrorPropagates` | LLM error thrown from iterator |
| `modelRefusalThrows` | Refusal → error |
| `maxTokensThrows` | Truncation → error |
| `contentFilteredThrows` | Filtered → error |

---

### Test 9.5-9.9: Usage Limit Tests

| Test | Purpose |
|------|---------|
| `inputTokenLimitThrows` | Input limit enforced |
| `outputTokenLimitThrows` | Output limit enforced |
| `totalTokenLimitThrows` | Total limit enforced |
| `requestLimitThrows` | Request count limit |
| `toolCallLimitThrows` | Tool call limit |

---

### Test 9.10: maxIterationsReachedThrows

Already covered in IteratorPhaseTests but included here for completeness.

---

## 10. IteratorCancellationTests

**File**: `Tests/YrdenTests/Component/Agent/Iteration/IteratorCancellationTests.swift`
**Status**: To be created
**Scope**: Cancellation at every phase, state validity after cancellation, resumability.

### Why This File Is Critical

Cancellation is a core concern for long-running agent operations. These tests verify:
- Cancellation is cooperative (checked at phase boundaries)
- State is always valid after cancellation (atomic transitions)
- Cancelled error carries resumable state
- Resume from cancellation works correctly

### Design Context: Atomic State Transitions

State only transitions when an operation FULLY completes. During execution, state remains at the "before" phase:
- During model call → state is still `.beforeModel`
- During tool execution → state is still `.beforeTools`
- Cancel at any point → state is last completed phase → always resumable

---

### Test 10.1: cancelAtBeforeModelPreservesState

**Purpose**: Verify cancellation at beforeModel preserves valid state with user prompt.

**Setup**:
```swift
let model = FakeModel(responses: [MockResponse.text("Hello")])
let agent = Agent<Void, String>(model: model)
```

**Execution**:
```swift
var capturedState: IterationState<String>?
let task = Task {
    for try await node in agent.iter("Hi", deps: ()) {
        if case .beforeModel(let ctx) = node {
            capturedState = ctx.state
            throw CancellationError()
        }
    }
}

do {
    try await task.value
} catch is CancellationError {
    // Expected
}
```

**Assertion**:
```swift
#expect(capturedState != nil)
#expect(capturedState?.phase == .beforeModel)
#expect(capturedState?.messages.contains(.user("Hi")) == true)
```

**Why Critical**: Validates that state at beforeModel is complete and resumable.

---

### Test 10.2: cancelAtAfterModelPreservesResponse

**Purpose**: Verify cancellation at afterModel preserves the model response in state.

**Setup**:
```swift
let model = FakeModel(responses: [MockResponse.text("Model response")])
let agent = Agent<Void, String>(model: model)
```

**Execution**:
```swift
var capturedState: IterationState<String>?
for try await node in agent.iter("Hi", deps: ()) {
    if case .afterModel(let ctx) = node {
        capturedState = ctx.state
        break  // Exit early (simulates cancellation point)
    }
}
```

**Assertion**:
```swift
guard case .afterModel(let response) = capturedState?.phase else {
    Issue.record("Expected afterModel phase")
    return
}
#expect(response.content == "Model response")
```

**Why Critical**: State at afterModel includes the response for inspection or retry decisions.

---

### Test 10.3: cancelAtBeforeToolsPreservesPendingCalls

**Purpose**: Verify cancellation at beforeTools preserves all pending tool calls with decisions.

**Setup**:
```swift
let tool = ConfigurableTool.succeeding("result", name: "my_tool")
let counter = CallCounter()
let model = FakeModel(onComplete: { _ in
    switch await counter.increment() {
    case 1: return MockResponse.toolCall(name: "my_tool", arguments: #"{"input":"x"}"#, id: "tc-1")
    default: return MockResponse.text("Done")
    }
})
let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])
```

**Execution**:
```swift
var capturedState: IterationState<String>?
for try await node in agent.iter("Use tool", deps: ()) {
    if case .beforeTools(let ctx) = node {
        ctx.approve(ctx.pendingCalls[0].call)  // Make a decision
        capturedState = ctx.state
        break
    }
}
```

**Assertion**:
```swift
guard case .beforeTools(let calls) = capturedState?.phase else {
    Issue.record("Expected beforeTools phase")
    return
}
#expect(calls.count == 1)
#expect(calls[0].decision == .approved)
```

**Why Critical**: Decisions made before cancellation are preserved for resume.

---

### Test 10.4: cancelAtAfterToolsPreservesResults

**Purpose**: Verify cancellation at afterTools preserves all tool execution results.

**Setup**: Same as 10.3

**Execution**:
```swift
var capturedState: IterationState<String>?
for try await node in agent.iter("Use tool", deps: ()) {
    if case .afterTools(let ctx) = node {
        capturedState = ctx.state
        break
    }
}
```

**Assertion**:
```swift
guard case .afterTools(let results) = capturedState?.phase else {
    Issue.record("Expected afterTools phase")
    return
}
#expect(results.count == 1)
#expect(results[0].call.id == "tc-1")
```

**Why Critical**: Tool results are preserved for context continuity on resume.

---

### Test 10.5: cancelDuringModelCallStateIsBeforeModel

**Purpose**: Verify that cancellation during model execution keeps state at beforeModel (atomic transition).

**Setup**:
```swift
let slowModel = FakeModel(onComplete: { _ in
    try await Task.sleep(for: .seconds(10))
    return MockResponse.text("Done")
})
let agent = Agent<Void, String>(model: slowModel)
```

**Execution**:
```swift
var errorState: IterationState<String>?
let task = Task {
    do {
        for try await node in agent.iter("Hi", deps: ()) {
            // Model call happens when advancing past beforeModel
        }
    } catch let error as AgentError<String> {
        if case .cancelled(let state, _) = error {
            errorState = state
        }
    }
}

try await Task.sleep(for: .milliseconds(100))
task.cancel()
try? await task.value
```

**Assertion**:
```swift
#expect(errorState != nil)
guard case .beforeModel = errorState?.phase else {
    Issue.record("Expected beforeModel phase (atomic: model call didn't complete)")
    return
}
```

**Why Critical**: Atomic transitions ensure state never shows "partial" model response.

---

### Test 10.6: cancelDuringToolExecutionStateIsBeforeTools

**Purpose**: Verify that cancellation during tool execution keeps state at beforeTools (atomic transition).

**Setup**:
```swift
let slowTool = FakeTool<ConfigurableToolArgs, String>(
    name: "slow_tool",
    onCall: { _ in
        try await Task.sleep(for: .seconds(10))
        return .success("result")
    }
)
// Model returns tool call, then we cancel during execution
```

**Execution & Assertion**:
```swift
// Cancel during tool execution
// Error state should be .beforeTools, not partial .afterTools
guard case .beforeTools = errorState?.phase else {
    Issue.record("Expected beforeTools phase (atomic: tools didn't complete)")
    return
}
```

**Why Critical**: Atomic transitions mean resume will re-execute ALL tools.

---

### Test 10.7: cancelledErrorCarriesValidState

**Purpose**: Verify that AgentError.cancelled includes the last valid IterationState.

**Setup**:
```swift
let model = FakeModel(responses: [MockResponse.text("Hello")])
let agent = Agent<Void, String>(model: model)
```

**Execution**:
```swift
var capturedError: AgentError<String>?
let task = Task {
    do {
        for try await node in agent.iter("Hi", deps: ()) {
            if case .beforeModel = node {
                task.cancel()
            }
        }
    } catch let error as AgentError<String> {
        capturedError = error
    }
}
try? await task.value
```

**Assertion**:
```swift
guard case .cancelled(let state, _) = capturedError else {
    Issue.record("Expected .cancelled error")
    return
}
#expect(state.runID.isEmpty == false)
#expect(state.messages.isEmpty == false)
```

**Why Critical**: Error IS the checkpoint - no manual state tracking needed.

---

### Test 10.8: cancelledErrorIncludesOperationInfo

**Purpose**: Verify that cancelled error includes information about what operation was in progress.

**Setup**: Same as 10.5 (slow model)

**Execution & Assertion**:
```swift
guard case .cancelled(_, let during) = capturedError else {
    Issue.record("Expected .cancelled error")
    return
}
#expect(during == .modelCall)
```

**Why Critical**: Helps debugging and deciding retry strategy.

---

### Test 10.9: resumeFromCancelledAtBeforeModel

**Purpose**: Verify that resuming from cancelled state at beforeModel retries the model call.

**Setup**:
```swift
let counter = CallCounter()
let model = FakeModel(onComplete: { _ in
    let n = await counter.increment()
    if n == 1 { throw CancellationError() }  // First call "cancelled"
    return MockResponse.text("Success on retry")
})
let agent = Agent<Void, String>(model: model)
```

**Execution**:
```swift
var savedState: IterationState<String>?

// First run - capture state at beforeModel, then "cancel"
do {
    for try await node in agent.iter("Hi", deps: ()) {
        if case .beforeModel(let ctx) = node {
            savedState = ctx.state
        }
    }
} catch {
    // Expected cancellation
}

// Resume from saved state
var output: String?
for try await node in agent.iter(from: savedState!, deps: ()) {
    if case .finished(let ctx) = node {
        output = ctx.output
    }
}
```

**Assertion**:
```swift
#expect(output == "Success on retry")
#expect(await counter.value == 2)  // Model called twice
```

**Why Critical**: Core resume functionality after cancellation.

---

### Test 10.10: resumeFromCancelledPreservesDecisions

**Purpose**: Verify that tool approval decisions survive cancellation and resume.

**Setup**:
```swift
let tool = FakeTool<ConfigurableToolArgs, String>(name: "my_tool", onCall: { _ in .success("result") })
// Model returns tool call
```

**Execution**:
```swift
var savedState: IterationState<String>?

// First run - make decisions then cancel
for try await node in agent.iter("Use tool", deps: ()) {
    if case .beforeTools(let ctx) = node {
        ctx.deny(ctx.pendingCalls[0].call, message: "Not now")
        savedState = ctx.state
        break
    }
}

// Resume - check decisions preserved
for try await node in agent.iter(from: savedState!, deps: ()) {
    if case .beforeTools(let ctx) = node {
        #expect(ctx.pendingCalls[0].decision == .denied("Not now"))
    }
}
```

**Why Critical**: Cross-session approval workflows depend on decision persistence.

---

### Test 10.11: resumeFromCancelledDuringToolsRestartsAll

**Purpose**: Verify that resume after cancellation during tool execution re-executes ALL tools (atomic).

**Setup**:
```swift
let callCounts = CallCounts()  // Tracks per-tool call counts
let toolA = FakeTool<..>(name: "tool_a", onCall: { _ in
    await callCounts.increment("a")
    return .success("a")
})
let toolB = FakeTool<..>(name: "tool_b", onCall: { _ in
    await callCounts.increment("b")
    try await Task.sleep(for: .seconds(10))  // Slow - will be cancelled
    return .success("b")
})
// Model returns both tools
```

**Execution**:
```swift
// First run - tool_a completes, tool_b cancelled mid-execution
// Resume - BOTH tools should execute again
```

**Assertion**:
```swift
#expect(await callCounts.value("a") == 2)  // Ran twice
#expect(await callCounts.value("b") == 2)  // Ran twice (completed on retry)
```

**Why Critical**: Atomic transitions mean partial tool completion is discarded.

---

### Test 10.12: doubleCancellationIdempotent

**Purpose**: Verify that cancelling an already-cancelled task doesn't crash or corrupt state.

**Execution**:
```swift
let task = Task {
    for try await _ in agent.iter("Hi", deps: ()) { }
}
task.cancel()
task.cancel()  // Second cancel
// Should not crash
```

**Why Critical**: Edge case safety.

---

### Test 10.13: newIterationAfterCancelIndependent

**Purpose**: Verify that starting a new iteration after cancellation is completely independent.

**Execution**:
```swift
// First iteration - cancel
let task1 = Task { ... }
task1.cancel()

// Second iteration - should work normally
var output: String?
for try await node in agent.iter("Fresh start", deps: ()) {
    if case .finished(let ctx) = node { output = ctx.output }
}
#expect(output != nil)
```

**Why Critical**: Cancellation shouldn't pollute agent state.

---

### Test 10.14: cancellationReleasesResources

**Purpose**: Verify that cancellation properly releases resources (no leaks).

**Note**: This may require instrumentation or weak references to verify cleanup.

---

### Test 10.15: cancelDuringStreamingStateIsBeforePhase

**Purpose**: Verify that cancellation during streaming keeps state at the "before" phase.

**Setup**:
```swift
// Model that streams slowly
```

**Execution**:
```swift
for try await node in agent.iter("Hi", deps: ()) {
    if case .beforeModel(let ctx) = node {
        let streamTask = Task {
            var tokenCount = 0
            for try await _ in ctx.stream() {
                tokenCount += 1
                if tokenCount > 3 { throw CancellationError() }
            }
        }
        // Cancel during streaming
    }
}
```

**Assertion**:
```swift
// State should still be .beforeModel (streaming is part of model call)
guard case .beforeModel = errorState?.phase else {
    Issue.record("Expected beforeModel phase")
    return
}
```

**Why Critical**: Streaming doesn't change atomic transition semantics.

---

### Test 10.16: cancelledDuringToolStreamingStateIsBeforeTools

**Purpose**: Verify cancellation during tool streaming keeps state at beforeTools.

Similar to 10.15 but for tool execution streaming.

---

### Test 10.17: concurrentIterationsCancelIndependently

**Purpose**: Verify that cancelling one iteration doesn't affect another concurrent iteration.

**Execution**:
```swift
let task1 = Task { for try await _ in agent.iter("Task 1", deps: ()) { } }
let task2 = Task { for try await _ in agent.iter("Task 2", deps: ()) { } }

task1.cancel()
let result2 = try await task2.value  // Should complete normally
```

**Why Critical**: Concurrent usage safety.

---

### Test 10.18: cancellationPropagatesThroughNestedAgentTool

**Purpose**: Verify that cancellation propagates to inner agents when using agent-as-tool pattern.

**Setup**:
```swift
// Tool that calls another agent internally
```

**Execution**:
```swift
// Cancel outer iteration
// Inner agent should also be cancelled
```

**Why Critical**: Nested agent patterns need proper cancellation propagation.

---

## 11. IteratorErrorStateTests

**File**: `Tests/YrdenTests/Component/Agent/Iteration/IteratorErrorStateTests.swift`
**Status**: To be created
**Scope**: Verify all errors carry resumable state, error state validity, resumability from errors.

### Why This File Is Critical

The key design principle is: **all errors are checkpoints**. Every error (except truly fatal ones) carries `IterationState` that can be used to resume. These tests verify that contract.

### Design Context: Error Types

```swift
public enum AgentError<Output: SchemaType>: Error {
    // All carry resumable state
    case cancelled(state: IterationState<Output>, during: CancelledOperation)
    case modelError(state: IterationState<Output>, underlying: Error)
    case modelRefusal(state: IterationState<Output>, refusal: String)
    case validationFailed(state: IterationState<Output>, output: Output?, message: String)
    case toolError(state: IterationState<Output>, toolName: String, underlying: Error)
    case maxIterationsReached(state: IterationState<Output>)
    case usageLimitExceeded(state: IterationState<Output>, limit: UsageLimit)

    // Non-resumable (no state)
    case internalError(String)
    case invalidConfiguration(String)
}
```

---

### Test 11.1: modelErrorCarriesBeforeModelState

**Purpose**: Verify that model network/API errors include state at beforeModel phase.

**Setup**:
```swift
let model = FakeModel(onComplete: { _ in
    throw URLError(.notConnectedToInternet)
})
let agent = Agent<Void, String>(model: model)
```

**Execution**:
```swift
var errorState: IterationState<String>?
do {
    for try await _ in agent.iter("Hi", deps: ()) { }
} catch let error as AgentError<String> {
    if case .modelError(let state, _) = error {
        errorState = state
    }
}
```

**Assertion**:
```swift
#expect(errorState != nil)
guard case .beforeModel = errorState?.phase else {
    Issue.record("Expected beforeModel phase")
    return
}
#expect(errorState?.messages.contains(.user("Hi")) == true)
```

**Why Critical**: Network errors are transient - retry should be possible from same state.

---

### Test 11.2: modelRefusalCarriesAfterModelState

**Purpose**: Verify that model refusal includes state at afterModel with the refusal response.

**Setup**:
```swift
let model = FakeModel(responses: [MockResponse.refusal("I cannot help with that")])
let agent = Agent<Void, String>(model: model)
```

**Execution**:
```swift
var errorState: IterationState<String>?
var refusalMessage: String?
do {
    for try await _ in agent.iter("Bad request", deps: ()) { }
} catch let error as AgentError<String> {
    if case .modelRefusal(let state, let refusal) = error {
        errorState = state
        refusalMessage = refusal
    }
}
```

**Assertion**:
```swift
#expect(refusalMessage == "I cannot help with that")
guard case .afterModel(let response) = errorState?.phase else {
    Issue.record("Expected afterModel phase")
    return
}
#expect(response.refusal != nil)
```

**Why Critical**: User can see the refusal and decide how to handle (modify request, etc.).

---

### Test 11.3: validationFailedCarriesAfterModelState

**Purpose**: Verify that output validation failure includes state with the invalid response.

**Setup**:
```swift
@Schema struct MyOutput: SchemaType {
    let count: Int
}

let counter = CallCounter()
let model = FakeModel(onComplete: { _ in
    switch await counter.increment() {
    case 1: return MockResponse.toolCall(
        name: "final_result",
        arguments: #"{"count": "not a number"}"#,  // Invalid
        id: "out-1"
    )
    default: throw LLMError.serverError("No more retries")
    }
})
let agent = Agent<Void, MyOutput>(model: model, maxRetries: 0)  // No auto-retry
```

**Execution**:
```swift
var errorState: IterationState<MyOutput>?
do {
    for try await _ in agent.iter("Get count", deps: ()) { }
} catch let error as AgentError<MyOutput> {
    if case .validationFailed(let state, _, _) = error {
        errorState = state
    }
}
```

**Assertion**:
```swift
guard case .afterModel = errorState?.phase else {
    Issue.record("Expected afterModel phase with invalid response")
    return
}
```

**Why Critical**: User can inspect what the model returned and adjust prompt.

---

### Test 11.4: toolErrorCarriesBeforeToolsState

**Purpose**: Verify that tool execution error includes state at beforeTools.

**Setup**:
```swift
struct ToolFailure: Error {}
let tool = FakeTool<ConfigurableToolArgs, String>(
    name: "failing_tool",
    onCall: { _ in throw ToolFailure() }
)
```

**Execution & Assertion**:
```swift
guard case .beforeTools(let calls) = errorState?.phase else {
    Issue.record("Expected beforeTools phase")
    return
}
#expect(calls.count == 1)
```

**Why Critical**: Resume will retry all tools from known state.

---

### Test 11.5: maxIterationsCarriesCurrentState

**Purpose**: Verify that hitting max iterations includes complete state.

**Setup**:
```swift
let tool = ConfigurableTool.succeeding("result", name: "my_tool")
let model = FakeModel(onComplete: { _ in
    MockResponse.toolCall(name: "my_tool", arguments: "{}", id: "tc-\(UUID())")
})
let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)], maxIterations: 2)
```

**Execution**:
```swift
var errorState: IterationState<String>?
do {
    for try await _ in agent.iter("Loop", deps: ()) { }
} catch let error as AgentError<String> {
    if case .maxIterationsReached(let state) = error {
        errorState = state
    }
}
```

**Assertion**:
```swift
#expect(errorState?.iteration == 2)
#expect(errorState?.toolCallCount >= 2)
```

**Why Critical**: User can increase limit and continue from exact state.

---

### Test 11.6: usageLimitCarriesCurrentState

**Purpose**: Verify that hitting usage limit includes state with usage info.

**Setup**:
```swift
let agent = Agent<Void, String>(
    model: model,
    usageLimits: UsageLimits(maxTotalTokens: 100)
)
```

**Execution & Assertion**:
```swift
guard case .usageLimitExceeded(let state, let limit) = error else { ... }
#expect(state.usage.totalTokens > 0)
```

**Why Critical**: User can see actual usage and decide next steps.

---

### Test 11.7: canResumeFromModelError

**Purpose**: Verify that resuming from model error retries the model call.

**Setup**:
```swift
let counter = CallCounter()
let model = FakeModel(onComplete: { _ in
    switch await counter.increment() {
    case 1: throw URLError(.timedOut)  // First call fails
    case 2: return MockResponse.text("Success")
    default: throw LLMError.serverError("Unexpected")
    }
})
```

**Execution**:
```swift
var checkpoint: IterationState<String>?

// First run fails
do {
    for try await _ in agent.iter("Hi", deps: ()) { }
} catch let error as AgentError<String> {
    if case .modelError(let state, _) = error {
        checkpoint = state
    }
}

// Resume
var output: String?
for try await node in agent.iter(from: checkpoint!, deps: ()) {
    if case .finished(let ctx) = node { output = ctx.output }
}
```

**Assertion**:
```swift
#expect(output == "Success")
```

**Why Critical**: Transient errors should be retryable.

---

### Test 11.8: canResumeFromMaxIterations

**Purpose**: Verify that resuming after max iterations with increased limit continues.

**Setup**: Agent with maxIterations: 2, model that eventually returns text

**Execution**:
```swift
// First run hits limit
var checkpoint: IterationState<String>?
do { ... } catch { checkpoint = error.state }

// Resume with more iterations allowed
agent.maxIterations = 10
var output: String?
for try await node in agent.iter(from: checkpoint!, deps: ()) {
    if case .finished(let ctx) = node { output = ctx.output }
}
```

**Assertion**:
```swift
#expect(output != nil)
```

**Why Critical**: Iteration limits shouldn't lose progress.

---

### Test 11.9: canResumeFromValidationFailed

**Purpose**: Verify that resuming from validation failure with modified prompt succeeds.

**Setup**: Structured output agent, model returns invalid then valid

**Execution**:
```swift
var checkpoint: IterationState<MyOutput>?
do { ... } catch { checkpoint = error.state }

// Modify messages to help model
var modifiedState = checkpoint!
modifiedState.messages.append(.system("Return a valid integer for count"))

for try await node in agent.iter(from: modifiedState, deps: ()) {
    if case .finished(let ctx) = node {
        #expect(ctx.output.count is Int)
    }
}
```

**Why Critical**: Validation feedback loop with user intervention.

---

### Test 11.10: canResumeFromToolError

**Purpose**: Verify that resuming from tool error retries the tools.

Similar pattern to 11.7 but for tool execution.

---

### Test 11.11: errorStateIsAlwaysAtPhaseBoundary

**Purpose**: Verify that error state is never "between" phases (atomic transitions).

**Execution**:
```swift
// Trigger various errors, verify state.phase is always a valid case
for error in [modelError, toolError, cancelled, ...] {
    let phase = error.state.phase
    // Should be .beforeModel, .afterModel, .beforeTools, or .afterTools
    // Never nil, never "partial"
}
```

**Why Critical**: Core guarantee of atomic transition design.

---

### Test 11.12: errorStateIsSerializable

**Purpose**: Verify that state from errors can be serialized and deserialized.

**Execution**:
```swift
let checkpoint = error.state
let data = try JSONEncoder().encode(checkpoint)
let restored = try JSONDecoder().decode(IterationState<String>.self, from: data)

#expect(restored.runID == checkpoint.runID)
#expect(restored.messages == checkpoint.messages)
```

**Why Critical**: Cross-session resume requires serialization.

---

### Test 11.13: allResumableErrorsHaveState

**Purpose**: Verify that all resumable error cases have non-nil state.

**Execution**:
```swift
// Generate each error type, verify state is present
let errors: [AgentError<String>] = [
    .cancelled(state: ..., during: ...),
    .modelError(state: ..., underlying: ...),
    .modelRefusal(state: ..., refusal: ...),
    .validationFailed(state: ..., output: ..., message: ...),
    .toolError(state: ..., toolName: ..., underlying: ...),
    .maxIterationsReached(state: ...),
    .usageLimitExceeded(state: ..., limit: ...),
]

for error in errors {
    #expect(error.state != nil)  // Via computed property
}
```

**Why Critical**: API contract verification.

---

### Test 11.14: nonResumableErrorsHaveNoState

**Purpose**: Verify that truly fatal errors don't pretend to have resumable state.

**Execution**:
```swift
let fatalErrors: [AgentError<String>] = [
    .internalError("Bug"),
    .invalidConfiguration("Bad config"),
]

for error in fatalErrors {
    #expect(error.state == nil)
}
```

**Why Critical**: Clear distinction between resumable and fatal errors.

---

### Test 11.15: errorStateMatchesLastNodeState

**Purpose**: Verify that error state exactly matches the state from the last yielded node.

**Execution**:
```swift
var lastNodeState: IterationState<String>?
do {
    for try await node in agent.iter("Hi", deps: ()) {
        lastNodeState = node.state  // Track every node
    }
} catch let error as AgentError<String> {
    #expect(error.state == lastNodeState)
}
```

**Why Critical**: Error state should be consistent with iteration state.

---

## 12. IteratorResumeTests

**File**: `Tests/YrdenTests/Component/Agent/Iteration/IteratorResumeTests.swift`
**Status**: To be created (may be deferred)
**Scope**: Cross-session resume from serialized state.

### Why This File Is Critical (When Implemented)

Resume enables:
- Pause for human approval (overnight review)
- Crash recovery
- Checkpoint/restore for long runs

### Note: Resume May Be Deferred

Initial implementation may not support full serialization. These tests would be enabled when Codable conformance is complete.

---

### Tests 10.1-10.12 (Summary)

| Test | Purpose |
|------|---------|
| `resumeFromBeforeModelContinues` | Resume from beforeModel |
| `resumeFromAfterModelContinues` | Resume from afterModel |
| `resumeFromBeforeToolsContinues` | Resume from beforeTools |
| `resumeFromAfterToolsContinues` | Resume from afterTools |
| `resumePreservesMessages` | Messages survive |
| `resumePreservesUsage` | Usage survives |
| `resumePreservesIteration` | Counter survives |
| `resumePreservesRunID` | ID survives |
| `resumePreservesApprovedDecision` | Approved decision survives |
| `resumePreservesDeniedDecision` | Denied decision survives |
| `resumePreservesReplacedDecision` | Replaced decision survives |
| `resumeAllowsDecisionChange` | Can change decision on resume |

---

## Summary

### Total Tests: ~158

| File | Count | Priority |
|------|-------|----------|
| IteratorBasicTests | 12 | ✅ EXISTS |
| IteratorPhaseTests | 17 | HIGH |
| IteratorToolExecutionTests | 16 | HIGH |
| IteratorToolApprovalTests | 13 | HIGH |
| IteratorCancellationTests | 18 | HIGH (NEW) |
| IteratorErrorStateTests | 15 | HIGH (NEW) |
| IteratorStateMutationTests | 9 | MEDIUM |
| IteratorOutputTests | 10 | MEDIUM |
| IteratorErrorTests | 10 | MEDIUM |
| IteratorStateTests | 12 | LOW |
| IteratorStreamingTests | 14 | DEFERRED |
| IteratorResumeTests | 12 | DEFERRED |

### Implementation Order

1. **IteratorBasicTests** - Already exists, verify passes
2. **IteratorPhaseTests** - Core state machine
3. **IteratorToolExecutionTests** - Tool mechanics
4. **IteratorToolApprovalTests** - Approval flow
5. **IteratorCancellationTests** - Cancellation and atomic transitions (NEW)
6. **IteratorErrorStateTests** - Error-with-state pattern (NEW)
7. **IteratorStateMutationTests** - Context engineering
8. **IteratorOutputTests** - Output extraction
9. **IteratorErrorTests** - Error propagation
10. **IteratorStateTests** - State helpers
11. **IteratorStreamingTests** - When streaming implemented
12. **IteratorResumeTests** - When Codable complete

### Verification

```bash
# Run all iterator tests
swift test --filter "Iterator"

# Run specific file
swift test --filter "IteratorPhase"

# Run single test
swift test --filter "toolCallYieldsBeforeToolsPhase"
```
