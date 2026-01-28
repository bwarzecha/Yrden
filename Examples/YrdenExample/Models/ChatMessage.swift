/// Chat message types for the UI.

import Foundation

/// A block of content within a message - either text or a tool call.
enum ContentBlock: Identifiable, Sendable {
    case text(id: UUID, content: String)
    case toolCall(ToolCallInfo)

    var id: String {
        switch self {
        case .text(let id, _): return id.uuidString
        case .toolCall(let info): return info.id
        }
    }
}

/// A message in the chat conversation.
struct ChatMessage: Identifiable, Sendable {
    let id: UUID
    let role: MessageRole
    var blocks: [ContentBlock]
    let timestamp: Date
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: MessageRole,
        blocks: [ContentBlock] = [],
        timestamp: Date = Date(),
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
        self.isStreaming = isStreaming
    }

    /// Create a user message.
    static func user(_ content: String) -> ChatMessage {
        ChatMessage(role: .user, blocks: [.text(id: UUID(), content: content)])
    }

    /// Create an assistant message.
    static func assistant(_ content: String = "", isStreaming: Bool = false) -> ChatMessage {
        let blocks: [ContentBlock] = content.isEmpty ? [] : [.text(id: UUID(), content: content)]
        return ChatMessage(role: .assistant, blocks: blocks, isStreaming: isStreaming)
    }

    /// Create an error message.
    static func error(_ content: String) -> ChatMessage {
        ChatMessage(role: .error, blocks: [.text(id: UUID(), content: content)])
    }

    /// Get all text content concatenated.
    var content: String {
        blocks.compactMap { block in
            if case .text(_, let content) = block { return content }
            return nil
        }.joined()
    }

    /// Get all tool calls.
    var toolCalls: [ToolCallInfo] {
        blocks.compactMap { block in
            if case .toolCall(let info) = block { return info }
            return nil
        }
    }

    /// Append text to the last text block, or create a new one.
    mutating func appendText(_ text: String) {
        if case .text(let id, let existing) = blocks.last {
            blocks[blocks.count - 1] = .text(id: id, content: existing + text)
        } else {
            blocks.append(.text(id: UUID(), content: text))
        }
    }

    /// Append a tool call block.
    mutating func appendToolCall(_ toolCall: ToolCallInfo) {
        blocks.append(.toolCall(toolCall))
    }

    /// Update a tool call by ID.
    mutating func updateToolCall(id: String, update: (inout ToolCallInfo) -> Void) {
        for i in blocks.indices {
            if case .toolCall(var info) = blocks[i], info.id == id {
                update(&info)
                blocks[i] = .toolCall(info)
                return
            }
        }
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

/// Information about a single tool pending approval.
struct PendingToolInfo: Identifiable, Sendable {
    let id: String
    let toolName: String
    let arguments: String
}

/// Information about pending approval(s) - may contain multiple tools.
struct PendingApprovalInfo: Identifiable, Sendable {
    let id: String  // ID of first tool (for Identifiable)
    let tools: [PendingToolInfo]
    let reason: String

    /// Convenience for single tool name display
    var toolName: String {
        tools.map { $0.toolName }.joined(separator: ", ")
    }

    /// Convenience for single tool (backward compat)
    var arguments: String {
        tools.first?.arguments ?? ""
    }
}
