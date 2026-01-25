/// Test clock for controlling time in tests.
///
/// Enables testing timeouts and delays without real waiting:
/// - Call advance(by:) to move time forward
/// - Sleepers wake when their deadline passes
/// - Tests complete in milliseconds instead of seconds

import Foundation
@testable import Yrden

/// Test clock that can be manually advanced.
///
/// Essential for testing timeouts without waiting real time.
/// ```swift
/// let clock = TestClock()
///
/// // Start a task that sleeps
/// let task = Task {
///     try await clock.sleep(for: .seconds(30))
///     return "done"
/// }
///
/// // Advance time - sleeper wakes immediately
/// await clock.advance(by: .seconds(30))
/// let result = await task.value  // Returns immediately
/// ```
public actor TestClock: ClockProtocol {
    private var currentTime: Date
    private var waiters: [(deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []

    /// Create a test clock starting at a specific time.
    public init(start: Date = Date()) {
        self.currentTime = start
    }

    /// Get current simulated time.
    public nonisolated func now() -> Date {
        // Note: This is approximate - for precise time, use getCurrentTime()
        Date()
    }

    /// Get current simulated time (actor-isolated).
    public func getCurrentTime() -> Date {
        currentTime
    }

    /// Sleep for a duration.
    ///
    /// Does not actually wait - blocks until advance() is called
    /// with enough time to pass the deadline.
    public func sleep(for duration: Duration) async throws {
        let deadline = currentTime.addingTimeInterval(duration.timeInterval)

        // If deadline already passed, return immediately
        if deadline <= currentTime {
            return
        }

        return try await withCheckedThrowingContinuation { continuation in
            waiters.append((deadline, continuation))
            waiters.sort { $0.deadline < $1.deadline }
        }
    }

    /// Advance time by a duration, waking eligible sleepers.
    public func advance(by duration: Duration) {
        currentTime = currentTime.addingTimeInterval(duration.timeInterval)
        wakeEligibleWaiters()
    }

    /// Advance time to a specific point.
    public func advance(to time: Date) {
        guard time > currentTime else { return }
        currentTime = time
        wakeEligibleWaiters()
    }

    private func wakeEligibleWaiters() {
        while let first = waiters.first, first.deadline <= currentTime {
            waiters.removeFirst()
            first.continuation.resume()
        }
    }

    /// Cancel all pending sleeps (for test cleanup).
    public func cancelAll() {
        for waiter in waiters {
            waiter.continuation.resume(throwing: CancellationError())
        }
        waiters.removeAll()
    }

    /// Number of pending sleepers.
    public var pendingWaiterCount: Int {
        waiters.count
    }
}
