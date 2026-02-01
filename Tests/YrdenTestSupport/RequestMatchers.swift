@testable import Yrden

/// Thrown when a tool result lookup by call ID finds no matching result.
public struct ToolResultNotFound: Error, CustomStringConvertible {
    public let callId: String
    public let availableIds: Set<String>

    public var description: String {
        "No tool result found for call ID '\(callId)'. Available IDs: \(availableIds.sorted())"
    }
}

/// Helpers for verifying what the agent sent to the model inside callbacks.
extension CompletionRequest {
    /// Does this request contain a tool result for the given call ID?
    public func hasToolResult(for callId: String) -> Bool {
        messages.contains { message in
            switch message {
            case .toolResult(let id, _):
                return id == callId
            case .toolResults(let entries):
                return entries.contains { $0.id == callId }
            default:
                return false
            }
        }
    }

    /// Get the tool result content for a specific call ID, or nil.
    public func toolResultContent(for callId: String) -> String? {
        for message in messages {
            switch message {
            case .toolResult(let id, let content) where id == callId:
                return content
            case .toolResults(let entries):
                if let entry = entries.first(where: { $0.id == callId }) {
                    switch entry.output {
                    case .text(let text): return text
                    case .error(let msg): return msg
                    case .json: return entry.output.jsonString
                    }
                }
            default:
                continue
            }
        }
        return nil
    }

    /// Number of tool result entries across all messages.
    public var toolResultCount: Int {
        messages.reduce(0) { count, message in
            switch message {
            case .toolResult:
                return count + 1
            case .toolResults(let entries):
                return count + entries.count
            default:
                return count
            }
        }
    }

    /// Get the ToolOutput for a specific call ID, or nil.
    /// Use this to check result type (`.text` vs `.error`) without matching strings.
    public func toolResultOutput(for callId: String) -> ToolOutput? {
        for message in messages {
            switch message {
            case .toolResult(let id, let content) where id == callId:
                return .text(content)
            case .toolResults(let entries):
                if let entry = entries.first(where: { $0.id == callId }) {
                    return entry.output
                }
            default:
                continue
            }
        }
        return nil
    }

    /// Check if a tool result for the given call ID is an error.
    /// Throws if no result exists for the given ID.
    public func isToolResultError(for callId: String) throws -> Bool {
        guard let output = toolResultOutput(for: callId) else {
            throw ToolResultNotFound(callId: callId, availableIds: toolResultIds)
        }
        if case .error = output { return true }
        return false
    }

    /// Check if a tool result for the given call ID is a success (text or json).
    /// Throws if no result exists for the given ID.
    public func isToolResultSuccess(for callId: String) throws -> Bool {
        guard let output = toolResultOutput(for: callId) else {
            throw ToolResultNotFound(callId: callId, availableIds: toolResultIds)
        }
        switch output {
        case .text, .json: return true
        case .error: return false
        }
    }

    /// All tool call IDs referenced in tool result messages.
    public var toolResultIds: Set<String> {
        var ids = Set<String>()
        for message in messages {
            switch message {
            case .toolResult(let id, _):
                ids.insert(id)
            case .toolResults(let entries):
                entries.forEach { ids.insert($0.id) }
            default:
                break
            }
        }
        return ids
    }
}
