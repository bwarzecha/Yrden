/// Test utilities for MCP tests.
///
/// Provides helpers for:
/// - Collecting events from async streams
/// - Waiting for conditions
/// - Async assertions

import Foundation
import XCTest
@testable import Yrden

// MARK: - Event Collection

/// Collect events from an async stream with timeout.
///
/// Runs an action and collects events emitted during it.
/// ```swift
/// let events = try await collectEvents(from: connection.events, count: 2, timeout: .seconds(1)) {
///     await connection.connect()
/// }
/// XCTAssertEqual(events.count, 2)
/// ```
public func collectEvents<E: Sendable>(
    from stream: AsyncStream<E>,
    count: Int,
    timeout: Duration,
    during action: @Sendable () async throws -> Void
) async throws -> [E] {
    // Use an actor to safely collect events
    let collector = EventCollector<E>(targetCount: count)

    // Start collection task
    let collectionTask = Task {
        await collector.collect(from: stream)
    }

    // Give collector time to start iterating on the stream
    try? await Task.sleep(for: .milliseconds(10))

    // Run the action
    do {
        try await action()
    } catch {
        collectionTask.cancel()
        await collector.stop()
        throw error
    }

    // Wait for collection with timeout
    let deadline = Date().addingTimeInterval(timeout.timeInterval)
    while Date() < deadline {
        if await collector.hasEnough {
            break
        }
        try? await Task.sleep(for: .milliseconds(10))
    }

    collectionTask.cancel()
    await collector.stop()

    return await collector.events
}

/// Actor to safely collect events from a stream.
private actor EventCollector<E: Sendable> {
    private(set) var events: [E] = []
    private var stopped = false
    private let targetCount: Int

    init(targetCount: Int) {
        self.targetCount = targetCount
    }

    var hasEnough: Bool {
        events.count >= targetCount
    }

    func collect(from stream: AsyncStream<E>) async {
        for await event in stream {
            guard !stopped else { break }
            events.append(event)
            if events.count >= targetCount { break }
        }
    }

    func stop() {
        stopped = true
    }
}

// MARK: - Wait For Condition

/// Wait for a condition to become true.
///
/// Polls the condition at regular intervals until it returns true or timeout.
/// ```swift
/// let connected = await waitFor(timeout: .seconds(1)) {
///     await connection.state.isConnected
/// }
/// XCTAssertTrue(connected)
/// ```
public func waitFor(
    timeout: Duration,
    pollInterval: Duration = .milliseconds(10),
    condition: @Sendable @escaping () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout.timeInterval)

    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: pollInterval)
    }

    return false
}

// MARK: - Async Assertions

/// Assert that a condition eventually becomes true.
///
/// Retries until the condition passes or timeout.
/// ```swift
/// await assertEventually {
///     await connection.state.isConnected
/// }
/// ```
public func assertEventually(
    timeout: Duration = .seconds(1),
    message: String = "Condition not met within timeout",
    file: StaticString = #file,
    line: UInt = #line,
    condition: @Sendable @escaping () async -> Bool
) async {
    let passed = await waitFor(timeout: timeout, condition: condition)
    XCTAssertTrue(passed, message, file: file, line: line)
}

/// Assert that a condition never becomes true during the timeout period.
public func assertNever(
    duration: Duration = .milliseconds(100),
    message: String = "Condition became true unexpectedly",
    file: StaticString = #file,
    line: UInt = #line,
    condition: @Sendable @escaping () async -> Bool
) async {
    let becameTrue = await waitFor(timeout: duration, condition: condition)
    XCTAssertFalse(becameTrue, message, file: file, line: line)
}

// MARK: - Event Matchers

/// Find the first event matching a predicate.
public func findEvent<E>(
    in events: [E],
    matching predicate: (E) -> Bool
) -> E? {
    events.first(where: predicate)
}

/// Assert that events contain a matching event.
public func assertContainsEvent<E>(
    _ events: [E],
    matching predicate: (E) -> Bool,
    message: String = "Expected event not found",
    file: StaticString = #file,
    line: UInt = #line
) {
    XCTAssertNotNil(findEvent(in: events, matching: predicate), message, file: file, line: line)
}

// MARK: - Connection State Assertions

extension ConnectionState {
    /// Assert this is the expected connected state with tools.
    public func assertConnected(
        withToolCount expectedCount: Int? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard case .connected(let toolCount, _) = self else {
            XCTFail("Expected connected state, got \(self)", file: file, line: line)
            return
        }

        if let expectedCount = expectedCount {
            XCTAssertEqual(toolCount, expectedCount, "Tool count mismatch", file: file, line: line)
        }
    }

    /// Assert this is the expected failed state.
    public func assertFailed(
        withMessage expectedMessage: String? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard case .failed(let message, _) = self else {
            XCTFail("Expected failed state, got \(self)", file: file, line: line)
            return
        }

        if let expectedMessage = expectedMessage {
            XCTAssertTrue(
                message.contains(expectedMessage),
                "Error message '\(message)' does not contain '\(expectedMessage)'",
                file: file,
                line: line
            )
        }
    }
}
