/// Retrieve output from a background shell task.
///
/// Thin wrapper around BackgroundTaskRegistry.getOutput, formatting
/// the result as text for the LLM.

import Foundation

@Schema(description: "Get output from a background task")
public struct TaskOutputArgs {
    @Guide(description: "The task ID returned by the shell tool")
    public let taskId: String

    @Guide(description: "Whether to wait for the task to complete")
    public let block: Bool?

    @Guide(description: "Maximum seconds to wait when blocking")
    public let timeout: Int?

    private enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case block
        case timeout
    }
}

public struct TaskOutputTool: TypedTool {
    public typealias Args = TaskOutputArgs

    public let name = "task_output"
    public let description = "Get output from a background task. Use block=true to wait for completion. Use block=false to check current status without waiting."

    public let registry: BackgroundTaskRegistry

    public init(registry: BackgroundTaskRegistry) {
        self.registry = registry
    }

    public func execute(
        context: ToolContext,
        arguments: TaskOutputArgs
    ) async throws -> ToolResult<String> {
        let shouldBlock = arguments.block ?? false
        let timeout: Duration? = arguments.timeout.map { .seconds($0) }

        do {
            let snapshot = try await registry.getOutput(
                taskId: arguments.taskId,
                block: shouldBlock,
                timeout: timeout
            )

            var result = ""
            switch snapshot.status {
            case .running:
                result += "Status: Running\n"
            case .completed:
                if let exitCode = snapshot.exitCode {
                    result += "Status: Completed (Exit code: \(exitCode))\n"
                } else {
                    result += "Status: Completed\n"
                }
            }

            if !snapshot.output.isEmpty {
                result += "Output:\n\(snapshot.output)"
            }

            return .success(result)
        } catch {
            return .error("Task not found: \(arguments.taskId)")
        }
    }
}
