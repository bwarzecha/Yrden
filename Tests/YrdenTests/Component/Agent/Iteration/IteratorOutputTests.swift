/// Tests for output extraction in the iterator.
///
/// Covers:
/// - String outputs from content
/// - Structured outputs from output tool
/// - Validation and retry

import Testing
import Foundation
@testable import Yrden
@testable import YrdenTestSupport

// MARK: - Test Schema Types

@Schema(description: "A structured report output")
struct TestReport {
    let title: String
    let score: Int
}

@Schema(description: "A simple count result")
struct CountResult {
    let count: Int
}

@Suite("Iterator - Output")
struct IteratorOutputTests {

    // MARK: - Test 8.1: String output extracted from content

    @Test("model text content becomes String output")
    func stringOutputExtractedFromContent() async throws {
        let model = FakeModel(responses: [MockResponse.text("Hello, World!")])
        let agent = try Agent<Void, String>(model: model)

        var output: String?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output == "Hello, World!")
    }

    // MARK: - Test 8.2: Empty string output allowed

    @Test("empty content is valid String output")
    func emptyStringOutputAllowed() async throws {
        let model = FakeModel(responses: [MockResponse.text("")])
        let agent = try Agent<Void, String>(model: model)

        var output: String?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output == "")
    }

    // MARK: - Test 8.3: String output validator called

    @Test("output validator is invoked for String output")
    func stringOutputValidatorCalled() async throws {
        actor InvocationTracker {
            var invoked = false
            func markInvoked() { invoked = true }
        }

        let tracker = InvocationTracker()
        let validator = OutputValidator<Void, String> { _, output in
            await tracker.markInvoked()
            guard output.count >= 5 else {
                throw ValidationRetry("Output must be at least 5 characters")
            }
            return output
        }

        let model = FakeModel(responses: [MockResponse.text("hello world")])
        let agent = try Agent<Void, String>(
            model: model,
            outputValidators: [validator]
        )

        for try await _ in agent.iter("Hi", deps: ()) { }

        let validatorInvoked = await tracker.invoked
        #expect(validatorInvoked)
    }

    // MARK: - Test 8.4: String validator retry loops on ValidationRetry

    @Test("ValidationRetry from validator causes model retry")
    func stringValidatorRetryLoops() async throws {
        let validatorCounter = CallCounter()

        let validator = OutputValidator<Void, String> { _, output in
            _ = await validatorCounter.increment()
            guard output.count >= 10 else {
                throw ValidationRetry("Output must be at least 10 characters")
            }
            return output
        }

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                return MockResponse.text("short")  // Too short, will fail validation
            case 2:
                return MockResponse.text("long enough text")  // Passes validation
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<Void, String>(
            model: model,
            outputValidators: [validator]
        )

        var output: String?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(await validatorCounter.current == 2)
        #expect(output == "long enough text")
    }

    // MARK: - Test 8.5: Structured output parsed from tool arguments

    @Test("structured output is parsed from output tool arguments")
    func structuredOutputParsedFromToolArguments() async throws {
        let model = FakeModel(responses: [
            MockResponse.toolCall(
                name: "final_result",
                arguments: #"{"title":"My Report","score":95}"#,
                id: "out-1"
            )
        ])

        let agent = try Agent<Void, TestReport>(model: model)

        var output: TestReport?
        for try await node in agent.iter("Generate report", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output?.title == "My Report")
        #expect(output?.score == 95)
    }

    // MARK: - Test 8.6: Structured output validator called

    @Test("output validator is invoked for structured output")
    func structuredOutputValidatorCalled() async throws {
        actor InvocationTracker {
            var invoked = false
            func markInvoked() { invoked = true }
        }

        let tracker = InvocationTracker()
        let validator = OutputValidator<Void, TestReport> { _, report in
            await tracker.markInvoked()
            guard report.score >= 0 && report.score <= 100 else {
                throw ValidationRetry("Score must be between 0 and 100")
            }
            return report
        }

        let model = FakeModel(responses: [
            MockResponse.toolCall(
                name: "final_result",
                arguments: #"{"title":"Report","score":85}"#,
                id: "out-1"
            )
        ])

        let agent = try Agent<Void, TestReport>(
            model: model,
            outputValidators: [validator]
        )

        for try await _ in agent.iter("Generate report", deps: ()) { }

        let validatorInvoked = await tracker.invoked
        #expect(validatorInvoked)
    }

    // MARK: - Test 8.7: Invalid JSON retries to model

    @Test("invalid JSON in output tool arguments causes model retry")
    func invalidJSONRetriesToModel() async throws {
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                // Invalid JSON - missing closing brace
                return MockResponse.toolCall(
                    name: "final_result",
                    arguments: #"{"title":"Report","score":85"#,  // Invalid JSON
                    id: "out-1"
                )
            case 2:
                // Valid JSON on retry
                return MockResponse.toolCall(
                    name: "final_result",
                    arguments: #"{"title":"Fixed Report","score":90}"#,
                    id: "out-2"
                )
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<Void, TestReport>(model: model)

        var output: TestReport?
        for try await node in agent.iter("Generate report", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output?.title == "Fixed Report")
        #expect(output?.score == 90)
    }

    // MARK: - Test 8.8: Schema mismatch retries to model

    @Test("schema mismatch in output tool arguments causes model retry")
    func schemaMismatchRetriesToModel() async throws {
        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                // Wrong type: score is string instead of int
                return MockResponse.toolCall(
                    name: "final_result",
                    arguments: #"{"title":"Report","score":"high"}"#,
                    id: "out-1"
                )
            case 2:
                // Correct types on retry
                return MockResponse.toolCall(
                    name: "final_result",
                    arguments: #"{"title":"Report","score":75}"#,
                    id: "out-2"
                )
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<Void, TestReport>(model: model)

        var output: TestReport?
        for try await node in agent.iter("Generate report", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output?.score == 75)
    }

    // MARK: - Test 8.9: Output tool not visible in pending calls

    @Test("output tool call does not appear in beforeTools pending calls")
    func outputToolNotVisibleInPendingCalls() async throws {
        let regularTool = ConfigurableTool.succeeding("result", name: "regular_tool")

        let counter = CallCounter()
        let model = FakeModel(onComplete: { _ in
            switch await counter.increment() {
            case 1:
                // Return both output tool and regular tool
                return MockResponse.toolCalls([
                    ToolCall(id: "out-1", name: "final_result", arguments: #"{"title":"Report","score":80}"#),
                    ToolCall(id: "tc-1", name: "regular_tool", arguments: #"{"input":"test"}"#),
                ])
            case 2:
                return MockResponse.toolCall(
                    name: "final_result",
                    arguments: #"{"title":"Final","score":100}"#,
                    id: "out-2"
                )
            default:
                throw LLMError.serverError("Unexpected")
            }
        })

        let agent = try Agent<Void, TestReport>(
            model: model,
            tools: [AnyAgentTool(regularTool)],
            endStrategy: .exhaustive  // Run all tools before finishing
        )

        var pendingCallNames: [String] = []
        for try await node in agent.iter("Generate report", deps: ()) {
            if case .beforeTools(let ctx) = node {
                pendingCallNames = ctx.pendingCalls.map { $0.call.name }
            }
        }

        // Output tool should NOT appear in pending calls
        #expect(!pendingCallNames.contains("final_result"))
        // Regular tool SHOULD appear
        #expect(pendingCallNames.contains("regular_tool"))
    }

    // MARK: - Test 8.10: Default output tool name

    @Test("default output tool name is final_result when no collision")
    func defaultOutputToolName() async throws {
        let model = FakeModel(responses: [MockResponse.text("Hello")])
        let agent = try Agent<Void, String>(model: model)

        let outputName = await agent.outputToolName
        #expect(outputName == "final_result")
    }

    // MARK: - Test 8.11: Multiple validators run in order

    @Test("multiple validators run in sequence, each receiving previous result")
    func multipleValidatorsRunInOrder() async throws {
        actor OrderTracker {
            var order: [Int] = []
            func append(_ v: Int) { order.append(v) }
        }

        let tracker = OrderTracker()

        // Validator 1: Check minimum length
        let validator1 = OutputValidator<Void, String> { _, output in
            await tracker.append(1)
            guard output.count >= 3 else {
                throw ValidationRetry("Must be at least 3 chars")
            }
            return output
        }

        // Validator 2: Check contains letter 'e'
        let validator2 = OutputValidator<Void, String> { _, output in
            await tracker.append(2)
            guard output.contains("e") else {
                throw ValidationRetry("Must contain letter 'e'")
            }
            return output
        }

        // Validator 3: Check not all uppercase
        let validator3 = OutputValidator<Void, String> { _, output in
            await tracker.append(3)
            guard output != output.uppercased() else {
                throw ValidationRetry("Must not be all uppercase")
            }
            return output
        }

        let model = FakeModel(responses: [MockResponse.text("hello")])  // Passes all
        let agent = try Agent<Void, String>(
            model: model,
            outputValidators: [validator1, validator2, validator3]
        )

        var output: String?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        let callOrder = await tracker.order
        #expect(callOrder == [1, 2, 3])
        #expect(output == "hello")
    }

    // MARK: - Test 8.12: Validator receives correct context

    @Test("validator receives context with correct deps")
    func validatorReceivesCorrectContext() async throws {
        struct TestDeps: Sendable {
            let minLength: Int
        }

        actor MinLengthCapture {
            var value: Int?
            func set(_ v: Int) { value = v }
        }

        let capture = MinLengthCapture()
        let validator = OutputValidator<TestDeps, String> { context, output in
            await capture.set(context.deps.minLength)
            guard output.count >= context.deps.minLength else {
                throw ValidationRetry("Output must be at least \(context.deps.minLength) characters")
            }
            return output
        }

        let model = FakeModel(responses: [MockResponse.text("Hello world")])
        let agent = try Agent<TestDeps, String>(
            model: model,
            outputValidators: [validator]
        )

        let deps = TestDeps(minLength: 5)
        for try await _ in agent.iter("Hi", deps: deps) { }

        let receivedMinLength = await capture.value
        #expect(receivedMinLength == 5)
    }

    // MARK: - Test 8.13: Whitespace-only content is valid String output

    @Test("whitespace-only content is valid String output")
    func whitespaceOnlyContentIsValid() async throws {
        let model = FakeModel(responses: [MockResponse.text("   \n\t  ")])
        let agent = try Agent<Void, String>(model: model)

        var output: String?
        for try await node in agent.iter("Hi", deps: ()) {
            if case .finished(let ctx) = node {
                output = ctx.output
            }
        }

        #expect(output == "   \n\t  ")
    }

    // MARK: - Test 8.14: Validator can throw non-retry error

    @Test("non-ValidationRetry error from validator propagates as error")
    func validatorNonRetryErrorPropagates() async throws {
        struct CustomValidationError: Error {}

        let validator = OutputValidator<Void, String> { _, _ in
            throw CustomValidationError()
        }

        let model = FakeModel(responses: [MockResponse.text("Hello")])
        let agent = try Agent<Void, String>(
            model: model,
            outputValidators: [validator]
        )

        do {
            for try await _ in agent.iter("Hi", deps: ()) { }
            Issue.record("Expected error to be thrown")
        } catch is CustomValidationError {
            // Expected
        } catch {
            Issue.record("Expected CustomValidationError, got \(error)")
        }
    }
}
