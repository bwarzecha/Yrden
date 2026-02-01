import Testing

public extension Tag {
    /// Tests that require real API keys to run.
    /// Disabled by default; enable with `RUN_API_TESTS=1` env var.
    @Tag static var requiresAPIKey: Self
}
