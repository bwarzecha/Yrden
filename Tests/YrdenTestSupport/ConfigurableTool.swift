import Foundation
@testable import Yrden

// All types are internal. Test targets access via `@testable import YrdenTestSupport`.
// This avoids issues with @Schema macro not propagating public access modifiers.

/// Arguments for the configurable test tool.
@Schema(description: "Configurable tool arguments")
struct ConfigurableToolArgs {
    let input: String
}

/// A generic test tool that can be configured to return any behavior.
struct ConfigurableTool: TypedTool {
    typealias Args = ConfigurableToolArgs

    /// The behavior to exhibit when called.
    enum Behavior: Sendable {
        case success(String)
        case failure(Error)
        case throwError(Error)
    }

    let toolName: String
    let toolDescription: String
    let behavior: Behavior

    var name: String { toolName }
    var description: String { toolDescription }

    func execute(
        context: ToolContext,
        arguments: Args
    ) async throws -> ToolResult<String> {
        switch behavior {
        case .success(let result):
            return .success(result)
        case .failure(let error):
            return .failure(error)
        case .throwError(let error):
            throw error
        }
    }
}

// MARK: - Convenience Factories

extension ConfigurableTool {
    static func succeeding(
        _ result: String = "Success",
        name: String = "test_tool"
    ) -> ConfigurableTool {
        ConfigurableTool(
            toolName: name,
            toolDescription: "A test tool that succeeds",
            behavior: .success(result)
        )
    }

    static func throwing(
        _ error: Error,
        name: String = "throwing_tool"
    ) -> ConfigurableTool {
        ConfigurableTool(
            toolName: name,
            toolDescription: "A test tool that throws errors",
            behavior: .throwError(error)
        )
    }

    static func failing(
        _ error: Error,
        name: String = "failing_tool"
    ) -> ConfigurableTool {
        ConfigurableTool(
            toolName: name,
            toolDescription: "A test tool that returns failure",
            behavior: .failure(error)
        )
    }

}

// MARK: - Test Errors

/// Common error types for testing.
enum TestToolError: Error, LocalizedError, Sendable {
    case generic(String)
    case crashed(String)
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .generic(let message): return message
        case .crashed(let message): return "Tool crashed: \(message)"
        case .processingFailed(let message): return "Failed to process: \(message)"
        }
    }
}
