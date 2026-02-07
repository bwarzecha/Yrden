/// Test utilities for MCP tests.
///
/// Provides helpers for:
/// - Collecting events from async streams
/// - Waiting for conditions

import Foundation
@testable import Yrden

// MARK: - Event Collection

/// Collect events from an async stream with timeout.
///
/// Runs an action and collects events emitted during it.
/// ```swift
/// let events = try await collectEvents(from: connection.events, count: 2, timeout: .seconds(1)) {
///     await connection.connect()
/// }
/// #expect(events.count == 2)
/// ```
public func collectEvents<E: Sendable>(
    from stream: AsyncStream<E>,
    count: Int,
    timeout: Duration,
    during action: @Sendable () async throws -> Void
) async throws -> [E] {
    let collector = EventCollector<E>(targetCount: count)

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
/// #expect(connected)
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

// MARK: - Event Matchers

/// Find the first event matching a predicate.
public func findEvent<E>(
    in events: [E],
    matching predicate: (E) -> Bool
) -> E? {
    events.first(where: predicate)
}
