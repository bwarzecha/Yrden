/// Chat message types for the UI.

import Foundation

/// A message in the chat conversation.
struct ChatMessage: Identifiable, Sendable {
    let id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date
    var toolCalls: [ToolCallInfo]
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        toolCalls: [ToolCallInfo] = [],
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolCalls = toolCalls
        self.isStreaming = isStreaming
    }

    /// Create a user message.
    static func user(_ content: String) -> ChatMessage {
        ChatMessage(role: .user, content: content)
    }

    /// Create an assistant message.
    static func assistant(_ content: String, isStreaming: Bool = false) -> ChatMessage {
        ChatMessage(role: .assistant, content: content, isStreaming: isStreaming)
    }

    /// Create an error message.
    static func error(_ content: String) -> ChatMessage {
        ChatMessage(role: .error, content: content)
    }
}

/// Message sender role.
enum MessageRole: String, Sendable {
    case user
    case assistant
    case error
}

/// Information about a tool call for display.
struct ToolCallInfo: Identifiable, Sendable {
    let id: String
    let name: String
    var arguments: String
    var result: String?
    var duration: Duration?
    var status: ToolCallStatus

    init(
        id: String,
        name: String,
        arguments: String = "",
        result: String? = nil,
        duration: Duration? = nil,
        status: ToolCallStatus = .pending
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.result = result
        self.duration = duration
        self.status = status
    }
}

/// Status of a tool call.
enum ToolCallStatus: String, Sendable {
    case pending
    case running
    case completed
    case failed
    case needsApproval
}

/// Information about a pending approval.
struct PendingApprovalInfo: Identifiable, Sendable {
    let id: String
    let toolName: String
    let arguments: String
    let reason: String
}
