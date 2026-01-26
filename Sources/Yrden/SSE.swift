/// Server-Sent Events (SSE) format constants.
///
/// Used for parsing streaming responses from LLM providers.

import Foundation

// MARK: - SSE Format Constants

/// Constants for parsing Server-Sent Events streams.
enum SSE {
    /// Prefix for data lines in SSE format.
    static let dataPrefix = "data: "

    /// Prefix for event type lines in SSE format.
    static let eventPrefix = "event: "

    /// OpenAI's stream termination marker.
    static let done = "[DONE]"

    /// Length of the data prefix for use with dropFirst().
    static let dataPrefixLength = 6

    /// Length of the event prefix for use with dropFirst().
    static let eventPrefixLength = 7
}
