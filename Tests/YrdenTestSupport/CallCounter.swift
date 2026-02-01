/// Thread-safe call counter for FakeModel callbacks.
///
/// Needed because `@Sendable` closures can't capture mutable variables.
///
/// ```swift
/// let counter = CallCounter()
/// let model = FakeModel(onComplete: { request in
///     let call = await counter.increment()
///     // call == 1, 2, 3, ...
/// })
/// ```
public actor CallCounter {
    private var count: Int = 0

    public init() {}

    /// Increment and return the new count (1-based).
    public func increment() -> Int {
        count += 1
        return count
    }

    /// Current count without incrementing.
    public var current: Int { count }
}
