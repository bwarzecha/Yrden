/// App dependencies for tool execution.

import Foundation

/// Dependencies injected into agent tools.
///
/// Currently minimal since tools come from MCP servers.
struct AppDependencies: Sendable {
    /// Base directory for file operations.
    let baseDirectory: URL

    /// Create default dependencies.
    static func `default`() -> AppDependencies {
        let documentsPath = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        return AppDependencies(
            baseDirectory: documentsPath.appendingPathComponent("YrdenExample")
        )
    }
}
