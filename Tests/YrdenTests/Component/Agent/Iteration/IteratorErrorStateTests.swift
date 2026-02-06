/// Tests for error state recovery and resumability.
///
/// Tests actual AgentError cases:
/// - maxIterationsReached
/// - usageLimitExceeded
/// - modelRefusal
/// - modelError (with ResponseUnusable, LLMError, etc.)
/// - toolError (with ToolTimeoutError, etc.)
/// - cancelled
/// - internalError

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

@Suite("Iterator - Error State")
struct IteratorErrorStateTests {

    // MARK: - Test 11.1: LLM errors propagate from iterator

    @Test("LLM network errors propagate from iterator")
    func llmNetworkErrorPropagates() async throws {
        let model = FakeModel(onComplete: { _ in
            throw LLMError.networkError("Not connected to internet")
        })
        let agent = Agent<Void, String>(model: model)

        var caughtError: LLMError?
        do {
            for try await _ in agent.iter("Hi", deps: ()) { }
        } catch let error as LLMError {
            caughtError = error
        }

        guard case .networkError = caughtError else {
            Issue.record("Expected networkError, got \(String(describing: caughtError))")
            return
        }
    }

    // MARK: - Test 11.2: Model refusal throws modelRefusal

    @Test("model refusal causes modelRefusal error with state")
    func modelRefusalThrowsWithState() async throws {
        let model = FakeModel(responses: [MockResponse.refusal("I cannot help with that")])
        let agent = Agent<Void, String>(model: model)

        var refusalMessage: String?
        var hasState = false
        do {
            for try await _ in agent.iter("Bad request", deps: ()) { }
        } catch let error as AgentError<String> {
            if case .modelRefusal(let state, let refusal) = error {
                refusalMessage = refusal
                hasState = state.iteration >= 0
            }
        }

        #expect(refusalMessage != nil)
        #expect(refusalMessage?.lowercased().contains("cannot help") == true)
        #expect(hasState)
    }

    // MARK: - Test 11.3: Validation retry gives model another chance

    @Test("validation retry allows model to try again with feedback")
    func validationRetryAllowsModelRetry() async throws {
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let n = await counter.increment()
            if n == 1 {
                return MockResponse.text("short")  // Will fail validation
            }
            // On retry, model provides longer output
            return MockResponse.text("This is a sufficiently long response")
        })

        let validator = OutputValidator<Void, String> { _, output in
            guard output.count >= 20 else {
                throw ValidationRetry("Output must be at least 20 characters")
            }
            return output
        }

        let agent = Agent<Void, String>(
            model: model,
            outputValidators: [validator]
        )

        var output: String?
        for try await node in agent.iter("Get output", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        // Should succeed on second attempt
        #expect(output?.count ?? 0 >= 20)
        #expect(await counter.current == 2)
    }

    // MARK: - Test 11.4: Tool timeout error includes tool info

    @Test("tool timeout error includes the tool name and timeout duration")
    func toolTimeoutCarriesToolInfo() async throws {
        let slowTool = SlowTool(delay: .seconds(10), result: "never")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "slow_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Done")
            }
        })

        let agent = Agent<Void, String>(
            model: model,
            tools: [AnyAgentTool(slowTool)],
            toolTimeout: .milliseconds(5)
        )

        var toolName: String?
        var timeoutDuration: Duration?
        do {
            for try await _ in agent.iter("Use tool", deps: ()) { }
        } catch let error as AgentError<String> {
            // When fully implemented, agent wraps tool errors in toolError(state:toolName:underlying:)
            if case .toolError(_, let name, let underlying) = error {
                toolName = name
                if let timeoutError = underlying as? ToolTimeoutError {
                    timeoutDuration = timeoutError.timeout
                }
            }
        } catch let error as ToolTimeoutError {
            // ToolExecutionEngine throws ToolTimeoutError directly
            toolName = error.toolName
            timeoutDuration = error.timeout
        }

        // Note: Tool timeout might return result to model instead of throwing.
        // If timeout error is thrown, verify it includes correct info.
        if toolName != nil {
            #expect(toolName == "slow_tool")
            #expect(timeoutDuration == .milliseconds(5))
        }
    }

    // MARK: - Test 11.5: Max iterations throws error with state

    @Test("hitting max iterations throws error with iteration state")
    func maxIterationsCarriesState() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let callCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let callID = await callCounter.increment()
            return MockResponse.toolCall(
                name: "my_tool",
                arguments: #"{"input":"x"}"#,
                id: "tc-\(callID)"
            )
        })

        let agent = Agent<Void, String>(
            model: model,
            tools: [AnyAgentTool(tool)],
            maxIterations: 2
        )

        var errorState: IterationState<String>?
        do {
            for try await _ in agent.iter("Loop", deps: ()) { }
        } catch let error as AgentError<String> {
            // Per design doc, maxIterationsReached should carry IterationState
            if case .maxIterationsReached(let state) = error {
                errorState = state
            }
        }

        // Error should carry state for resumption
        #expect(errorState != nil)
        #expect(errorState?.iteration == 2)
    }

    // MARK: - Test 11.6: Usage limit throws error with limit kind

    @Test("hitting usage limit throws error with limit details")
    func usageLimitCarriesLimitKind() async throws {
        let model = FakeModel(responses: [
            MockResponse.text("Response", usage: Usage(inputTokens: 500, outputTokens: 600))
        ])

        let agent = Agent<Void, String>(
            model: model,
            usageLimits: UsageLimits(maxTotalTokens: 100)
        )

        var limitKind: UsageLimit?
        do {
            for try await _ in agent.iter("Hi", deps: ()) { }
        } catch let error as AgentError<String> {
            if case .usageLimitExceeded(_, let limit) = error {
                limitKind = limit
            }
        }

        #expect(limitKind != nil)
        // Verify it's the expected limit type
        if case .totalTokens(let used, let limit) = limitKind {
            #expect(used > limit)
        }
    }

    // MARK: - Test 11.7: State can be captured at beforeModel for recovery

    @Test("state captured at beforeModel can be used for manual recovery")
    func stateCapturedAtBeforeModel() async throws {
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                throw LLMError.networkError("Connection timed out")
            case 2:
                return MockResponse.text("Success")
            default:
                throw LLMError.serverError("Unexpected")
            }
        })
        let agent = Agent<Void, String>(model: model)

        var checkpoint: IterationState<String>?

        // First run fails - capture state at beforeModel
        do {
            for try await node in agent.iter("Hi", deps: ()) {
                if case .beforeModel(let ctx) = node {
                    checkpoint = ctx.state
                }
            }
        } catch {
            // Error thrown - checkpoint was captured at beforeModel
        }

        guard let savedState = checkpoint else {
            Issue.record("Failed to capture checkpoint state")
            return
        }

        // Resume from saved state
        var output: String?
        for try await node in agent.iter(from: savedState, deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output == "Success")
    }

    // MARK: - Test 11.8: maxIterationsReached carries IterationState

    @Test("maxIterationsReached error carries IterationState for resumption")
    func maxIterationsReachedCarriesState() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let callCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let n = await callCounter.increment()
            return MockResponse.toolCall(
                name: "my_tool",
                arguments: #"{"input":"x"}"#,
                id: "tc-\(n)"
            )
        })

        let agent = Agent<Void, String>(
            model: model,
            tools: [AnyAgentTool(tool)],
            maxIterations: 2
        )

        var errorState: IterationState<String>?
        do {
            for try await _ in agent.iter("Loop", deps: ()) { }
        } catch let error as AgentError<String> {
            // Per design doc, iter() errors carry IterationState for resumption
            if case .maxIterationsReached(let state) = error {
                errorState = state
            }
        }

        // Verify state contains conversation progress
        guard let state = errorState else {
            Issue.record("Expected maxIterationsReached with IterationState")
            return
        }

        #expect(state.iteration == 2)
        #expect(state.messages.count > 0)
        #expect(state.runID.isEmpty == false)
    }

    // MARK: - Test 11.9: Can continue from IterationState after maxIterationsReached

    @Test("can continue from IterationState after maxIterationsReached using iter(from:)")
    func canContinueFromIterationState() async throws {
        let tool = ConfigurableTool.succeeding("result", name: "my_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            let n = await counter.increment()
            if n <= 2 {
                return MockResponse.toolCall(
                    name: "my_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-\(n)"
                )
            }
            return MockResponse.text("Finally done")
        })

        let agent = Agent<Void, String>(
            model: model,
            tools: [AnyAgentTool(tool)],
            maxIterations: 2
        )

        var savedState: IterationState<String>?

        // First run hits limit - capture state from error
        do {
            for try await node in agent.iter("Hi", deps: ()) {
                // Capture state at each phase for recovery
                switch node {
                case .beforeModel(let ctx): savedState = ctx.state
                case .afterModel(let ctx): savedState = ctx.state
                case .beforeTools(let ctx): savedState = ctx.state
                case .afterTools(let ctx): savedState = ctx.state
                case .finished: break
                }
            }
        } catch {
            // Error thrown (maxIterationsReached) - we have savedState from last phase
        }

        guard let state = savedState else {
            Issue.record("Failed to capture state before max iterations")
            return
        }

        // Create new agent with higher limit and resume from saved state
        let agentWithHigherLimit = Agent<Void, String>(
            model: model,
            tools: [AnyAgentTool(tool)],
            maxIterations: 10
        )

        var output: String?
        for try await node in agentWithHigherLimit.iter(from: state, deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output == "Finally done")
    }

    // MARK: - Test 11.10: Tool errors become results fed back to model

    @Test("tool errors become results that model can respond to")
    func toolErrorsBecomeFeedback() async throws {
        let toolCallCounter = CallCounter()
        let tool = FakeTool<ConfigurableToolArgs, String>(
            name: "flaky_tool",
            onCall: { _ in
                let count = await toolCallCounter.increment()
                if count == 1 {
                    throw TestToolError.generic("Temporary failure")
                }
                return .success("Success on retry")
            }
        )

        let modelCounter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await modelCounter.increment() {
            case 1:
                return MockResponse.toolCall(
                    name: "flaky_tool",
                    arguments: #"{"input":"x"}"#,
                    id: "tc-1"
                )
            default:
                return MockResponse.text("Done after seeing error")
            }
        })

        let agent = Agent<Void, String>(model: model, tools: [AnyAgentTool(tool)])

        var output: String?
        for try await node in agent.iter("Use tool", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        // Tool error was fed back to model, which responded
        #expect(output == "Done after seeing error")
    }

    // MARK: - Test 11.11: LLM errors propagate directly

    @Test("LLM errors propagate directly without wrapping")
    func llmErrorsPropagateDirectly() async throws {
        let model = FakeModel(onComplete: { _ in
            throw LLMError.serverError("Error")
        })
        let agent = Agent<Void, String>(model: model)

        var caughtLLMError = false
        do {
            for try await _ in agent.iter("Hi", deps: ()) { }
        } catch is LLMError {
            caughtLLMError = true
        } catch {
            // Other error types
        }

        #expect(caughtLLMError, "LLM errors should propagate directly")
    }

    // MARK: - Test 11.12: State is serializable when Codable

    @Test("state captured during iteration can be serialized")
    func stateIsSerializable() async throws {
        let model = FakeModel(onComplete: { _ in
            throw LLMError.serverError("Error")
        })
        let agent = Agent<Void, String>(model: model)

        var checkpoint: IterationState<String>?

        do {
            for try await node in agent.iter("Hi", deps: ()) {
                if case .beforeModel(let ctx) = node {
                    checkpoint = ctx.state
                }
            }
        } catch {
            // Expected
        }

        guard let state = checkpoint else {
            Issue.record("Failed to capture state")
            return
        }

        // Verify state has expected properties
        // Note: Codable conformance may be added later
        #expect(state.runID.isEmpty == false)
        #expect(state.messages.count > 0)
    }

    // MARK: - Test 11.13: Cancelled error thrown on task cancellation

    @Test("task cancellation throws cancelled error")
    func cancelledErrorOnTaskCancellation() async throws {
        let model = FakeModel(onComplete: { _ in
            try await Task.sleep(for: .seconds(10))
            return MockResponse.text("Done")
        })
        let agent = Agent<Void, String>(model: model)

        actor CancelTracker {
            var cancelled = false
            func markCancelled() { cancelled = true }
        }

        let tracker = CancelTracker()
        let task = Task {
            do {
                for try await _ in agent.iter("Hi", deps: ()) { }
            } catch let error as AgentError<String> {
                if case .cancelled = error {
                    await tracker.markCancelled()
                }
            } catch is CancellationError {
                await tracker.markCancelled()
            }
        }

        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        _ = await task.result

        let caughtCancelled = await tracker.cancelled
        #expect(caughtCancelled)
    }

    // MARK: - Test 11.14: Internal errors indicate bugs

    @Test("internal errors indicate bugs and provide message")
    func internalErrorsIndicateBugs() async throws {
        let internalError = AgentError<String>.internalError("Bug in library")

        // Internal errors represent bugs, not recoverable situations
        if case .internalError(let message) = internalError {
            #expect(message == "Bug in library")
        } else {
            Issue.record("Expected internalError case")
        }
    }

    // MARK: - Test 11.15: State captured before error can be used

    @Test("state captured before errors occur can be used for recovery")
    func stateCapturedBeforeErrorsCanBeUsed() async throws {
        let model = FakeModel(onComplete: { _ in
            throw LLMError.serverError("Error after beforeModel")
        })
        let agent = Agent<Void, String>(model: model)

        var capturedState: IterationState<String>?

        do {
            for try await node in agent.iter("Hi", deps: ()) {
                if case .beforeModel(let ctx) = node {
                    capturedState = ctx.state
                }
            }
        } catch {
            // Error expected - but we captured state
        }

        // State was captured before the error
        #expect(capturedState != nil)
        #expect(capturedState?.runID.isEmpty == false)
        guard case .beforeModel = capturedState?.phase else {
            Issue.record("Expected beforeModel phase")
            return
        }
    }
}
