/// Streaming event types for real-time LLM responses.
///
/// Streaming provides real-time updates as the model generates:
/// - Text deltas for progressive display
/// - Tool call events for UI feedback
/// - Final response when complete
///
/// ## Usage
/// ```swift
/// for await event in model.stream(request) {
///     switch event {
///     case .contentDelta(let text):
///         print(text, terminator: "")
///     case .toolCallStart(let id, let name):
///         print("Calling \(name)...")
///     case .toolCallDelta(let argsDelta):
///         // Accumulate arguments
///     case .toolCallEnd(let id):
///         print("Tool call complete")
///     case .done(let response):
///         print("\nFinished: \(response.stopReason)")
///     }
/// }
/// ```

import Foundation

// MARK: - StreamEvent

/// Events emitted during streaming completion.
///
/// Stream events provide fine-grained updates for real-time UI:
/// - Content arrives incrementally via `.contentDelta`
/// - Tool calls are bracketed by start/delta/end events
/// - `.done` signals completion with full response
///
/// ## Event Flow Examples
///
/// **Text-only response:**
/// ```
/// contentDelta("Hello")
/// contentDelta(" world")
/// contentDelta("!")
/// done(response)
/// ```
///
/// **Tool call response:**
/// ```
/// toolCallStart(id: "1", name: "search")
/// toolCallDelta(#"{"query":"#)
/// toolCallDelta(#""swift"}"#)
/// toolCallEnd(id: "1")
/// done(response)
/// ```
///
/// **Mixed response:**
/// ```
/// contentDelta("Let me search...")
/// toolCallStart(id: "1", name: "search")
/// toolCallDelta(...)
/// toolCallEnd(id: "1")
/// done(response)
/// ```
public enum StreamEvent: Sendable, Equatable, Hashable {
    /// Incremental text content from the model.
    /// Concatenate all deltas to build the full response.
    case contentDelta(String)

    /// Start of a tool call.
    /// - Parameters:
    ///   - id: Unique identifier for this tool call
    ///   - name: Name of the tool being called
    case toolCallStart(id: String, name: String)

    /// Incremental arguments for the current tool call.
    /// Concatenate all deltas to build the full arguments JSON.
    case toolCallDelta(argumentsDelta: String)

    /// End of a tool call.
    /// The tool call is now complete and ready to execute.
    /// - Parameter id: ID of the completed tool call
    case toolCallEnd(id: String)

    /// Stream complete. Contains the full response.
    /// This is always the last event in a stream.
    case done(CompletionResponse)
}

// MARK: - StreamEvent Codable

extension StreamEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case content
        case id
        case name
        case argumentsDelta
        case response
    }

    private enum EventType: String, Codable {
        case contentDelta
        case toolCallStart
        case toolCallDelta
        case toolCallEnd
        case done
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EventType.self, forKey: .type)

        switch type {
        case .contentDelta:
            let content = try container.decode(String.self, forKey: .content)
            self = .contentDelta(content)

        case .toolCallStart:
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            self = .toolCallStart(id: id, name: name)

        case .toolCallDelta:
            let delta = try container.decode(String.self, forKey: .argumentsDelta)
            self = .toolCallDelta(argumentsDelta: delta)

        case .toolCallEnd:
            let id = try container.decode(String.self, forKey: .id)
            self = .toolCallEnd(id: id)

        case .done:
            let response = try container.decode(CompletionResponse.self, forKey: .response)
            self = .done(response)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .contentDelta(let content):
            try container.encode(EventType.contentDelta, forKey: .type)
            try container.encode(content, forKey: .content)

        case .toolCallStart(let id, let name):
            try container.encode(EventType.toolCallStart, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)

        case .toolCallDelta(let delta):
            try container.encode(EventType.toolCallDelta, forKey: .type)
            try container.encode(delta, forKey: .argumentsDelta)

        case .toolCallEnd(let id):
            try container.encode(EventType.toolCallEnd, forKey: .type)
            try container.encode(id, forKey: .id)

        case .done(let response):
            try container.encode(EventType.done, forKey: .type)
            try container.encode(response, forKey: .response)
        }
    }
}
