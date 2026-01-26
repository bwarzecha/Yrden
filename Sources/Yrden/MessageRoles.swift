/// Message role constants used across providers.
///
/// Centralizes role strings to ensure consistency between providers.

import Foundation

// MARK: - Message Roles

/// Standard message roles used in chat completion APIs.
enum MessageRole {
    static let system = "system"
    static let user = "user"
    static let assistant = "assistant"
    /// OpenAI-specific role for tool result messages.
    static let tool = "tool"
}

// MARK: - Tool Types

/// Tool type identifiers used in API requests.
enum ToolType {
    /// OpenAI function tool type.
    static let function = "function"
}
