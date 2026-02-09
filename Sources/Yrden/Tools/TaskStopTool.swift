/// Stop a running background task.
///
/// Thin wrapper around BackgroundTaskRegistry.stop, formatting
/// confirmation as text for the LLM.

import Foundation

@Schema(description: "Stop a running background task")
public struct TaskStopArgs {
    @Guide(description: "The task ID to stop")
    public let taskId: String

    private enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
    }
}

public struct TaskStopTool: TypedTool {
    public typealias Args = TaskStopArgs

    public let name = "task_stop"
    public let description = "Stop a running background task by its ID. Uses graceful termination (SIGTERM) with escalation to SIGKILL."

    public let registry: BackgroundTaskRegistry

    public init(registry: BackgroundTaskRegistry) {
        self.registry = registry
    }

    public func execute(
        context: ToolContext,
        arguments: TaskStopArgs
    ) async throws -> ToolResult<String> {
        do {
            try await registry.stop(taskId: arguments.taskId)
            return .success("Task \(arguments.taskId) stopped.")
        } catch {
            return .error("Task not found: \(arguments.taskId)")
        }
    }
}
