/// Context management for long-running agent tasks.
///
/// Three layers applied before each model call to prevent context overflow:
/// 1. **Truncate old tool results** — reclaim space from large outputs
/// 2. **Context pressure hints** — tell the LLM to wrap up as context fills
/// 3. **LLM compaction** — summarize old turns via side API call as last resort

import Foundation
import Yrden

// MARK: - TokenEstimator

/// Rough token estimation based on character count.
///
/// Uses ~4 chars per token heuristic. Sufficient for threshold-based
/// decisions (50%, 75%, 90% of context window).
enum TokenEstimator {

    /// Estimate tokens for a list of messages.
    static func estimate(_ messages: [Message]) -> Int {
        messages.reduce(0) { $0 + estimate($1) }
    }

    /// Estimate tokens for a single message.
    static func estimate(_ message: Message) -> Int {
        let overhead = 4 // per-message overhead (role, formatting)
        switch message {
        case .system(let text):
            return overhead + text.count / 4
        case .user(let parts):
            let charCount = parts.reduce(0) { sum, part in
                switch part {
                case .text(let t): return sum + t.count
                case .image: return sum + 4000
                }
            }
            return overhead + charCount / 4
        case .assistant(let blocks):
            let charCount = blocks.reduce(0) { sum, block in
                switch block {
                case .text(let t): return sum + t.count
                case .thinking(let b): return sum + (b.content?.count ?? 0)
                case .toolUse(let call): return sum + call.name.count + call.arguments.count
                }
            }
            return overhead + charCount / 4
        case .toolResult(_, let content):
            return overhead + content.count / 4
        case .toolResults(let entries):
            let charCount = entries.reduce(0) { sum, entry in
                sum + toolOutputCharCount(entry.output)
            }
            return overhead + charCount / 4
        }
    }

    private static func toolOutputCharCount(_ output: ToolOutput) -> Int {
        switch output {
        case .text(let t): return t.count
        case .json(let j):
            if let data = try? JSONEncoder().encode(j) { return data.count }
            return 100
        case .error(let e): return e.count
        }
    }
}

// MARK: - ContextManagement

/// Application-level context management for the agent loop.
///
/// Call `apply(to:maxContextTokens:model:)` from the `.beforeModel` handler
/// in your `iter()` loop to keep context under control.
enum ContextManagement {

    /// Apply all context management layers in order.
    ///
    /// Modifies messages in-place. Pressure hints are inserted as system
    /// messages directly into the array — no library hooks needed.
    static func apply(
        to messages: inout [Message],
        maxContextTokens: Int,
        model: any Model
    ) async {
        // Layer 1: Truncate old tool results when context > 50%
        let estimated = TokenEstimator.estimate(messages)
        if Double(estimated) / Double(maxContextTokens) > 0.5 {
            truncateOldToolResults(messages: &messages)
        }

        // Layer 3: Compact via LLM if still > 80% (before hints, so hint is accurate)
        let postTruncationEstimate = TokenEstimator.estimate(messages)
        if Double(postTruncationEstimate) / Double(maxContextTokens) > 0.80 {
            do {
                try await compactMessages(messages: &messages, model: model)
            } catch {
                // Compaction failed — continue without it
            }
        }

        // Layer 2: Context pressure hint — insert as system message
        let finalEstimate = TokenEstimator.estimate(messages)
        if let hint = contextPressureHint(estimatedTokens: finalEstimate, maxContextTokens: maxContextTokens) {
            messages.append(.system(hint))
        }
    }

    // MARK: Layer 1: Tool Result Truncation

    /// Truncate tool results in older messages to reclaim context space.
    ///
    /// Keeps the most recent `preserveRecentCount` tool result messages intact.
    /// Older tool results are truncated to ~200 characters using head+tail strategy.
    static func truncateOldToolResults(
        messages: inout [Message],
        preserveRecentCount: Int = 3
    ) {
        var toolResultCount = 0
        let maxTruncatedLength = 200

        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            switch messages[i] {
            case .toolResult(let id, let content):
                toolResultCount += 1
                if toolResultCount > preserveRecentCount && content.count > maxTruncatedLength {
                    messages[i] = .toolResult(
                        toolCallId: id,
                        content: OutputTruncation.truncate(content, maxLength: maxTruncatedLength)
                    )
                }

            case .toolResults(let entries):
                toolResultCount += 1
                if toolResultCount > preserveRecentCount {
                    let truncated = entries.map { entry in
                        truncateEntry(entry, maxLength: maxTruncatedLength)
                    }
                    if truncated != entries {
                        messages[i] = .toolResults(truncated)
                    }
                }

            default:
                break
            }
        }
    }

    private static func truncateEntry(_ entry: ToolResultEntry, maxLength: Int) -> ToolResultEntry {
        switch entry.output {
        case .text(let text):
            guard text.count > maxLength else { return entry }
            return ToolResultEntry(
                id: entry.id,
                output: .text(OutputTruncation.truncate(text, maxLength: maxLength))
            )
        case .json(let json):
            if let data = try? JSONEncoder().encode(json),
               let str = String(data: data, encoding: .utf8),
               str.count > maxLength {
                return ToolResultEntry(
                    id: entry.id,
                    output: .text(OutputTruncation.truncate(str, maxLength: maxLength))
                )
            }
            return entry
        case .error:
            return entry
        }
    }

    // MARK: Layer 2: Context Pressure Hints

    /// Returns a hint to append to the system prompt based on context usage.
    static func contextPressureHint(
        estimatedTokens: Int,
        maxContextTokens: Int
    ) -> String? {
        guard maxContextTokens > 0 else { return nil }
        let ratio = Double(estimatedTokens) / Double(maxContextTokens)

        if ratio >= 0.90 {
            return "URGENT: Context is nearly full. You MUST finish immediately. Write your final answer now."
        } else if ratio >= 0.75 {
            return "Important: Context is 75%+ full. Start producing your final output now. Do not start new explorations."
        } else if ratio >= 0.50 {
            return "Note: You have used over half your context window. Be efficient — avoid reading files you've already seen."
        }

        return nil
    }

    // MARK: Layer 3: LLM Compaction

    /// Compact old messages by summarizing them via a side LLM call.
    ///
    /// Preserves the first user message (enriched with summary) and the last
    /// `preserveRecentTurns` messages. Everything in between is replaced with
    /// a summary generated by the model.
    static func compactMessages(
        messages: inout [Message],
        model: any Model,
        preserveRecentTurns: Int = 4
    ) async throws {
        guard messages.count > preserveRecentTurns + 2 else { return }

        // Find split point — ensure recent section doesn't start with tool results
        var splitPoint = max(1, messages.count - preserveRecentTurns)
        while splitPoint > 1 && isToolResultMessage(messages[splitPoint]) {
            splitPoint -= 1
        }

        let middleMessages = Array(messages[1..<splitPoint])
        guard middleMessages.count >= 2 else { return }

        var transcript = buildTranscript(from: middleMessages)

        let maxTranscriptLength = 50_000
        if transcript.count > maxTranscriptLength {
            transcript = OutputTruncation.truncate(transcript, maxLength: maxTranscriptLength)
        }

        let summaryRequest = CompletionRequest(
            messages: [
                .system(
                    "Summarize the following conversation between a user and an AI assistant. "
                    + "Preserve key facts, tool results, file contents, decisions, and important details. "
                    + "Be concise but don't lose critical information. Output only the summary."
                ),
                .user(transcript),
            ]
        )

        let response = try await model.complete(summaryRequest)
        let summary = response.content ?? "[Summary unavailable]"

        let originalPrompt = extractUserText(from: messages[0])

        var newMessages: [Message] = []
        newMessages.reserveCapacity(1 + (messages.count - splitPoint))
        newMessages.append(.user(
            "[Original task]\n\(originalPrompt)\n\n[Summary of earlier conversation]\n\(summary)"
        ))
        newMessages.append(contentsOf: messages[splitPoint...])
        messages = newMessages
    }

    // MARK: - Private Helpers

    private static func isToolResultMessage(_ message: Message) -> Bool {
        switch message {
        case .toolResult, .toolResults: return true
        default: return false
        }
    }

    private static func extractUserText(from message: Message) -> String {
        guard case .user(let parts) = message else { return "" }
        return parts.compactMap { part -> String? in
            if case .text(let t) = part { return t }
            return nil
        }.joined()
    }

    private static func buildTranscript(from messages: [Message]) -> String {
        var transcript = ""
        for msg in messages {
            switch msg {
            case .system(let text):
                transcript += "[System]: \(text)\n\n"
            case .user(let parts):
                let text = parts.compactMap { part -> String? in
                    if case .text(let t) = part { return t }
                    return nil
                }.joined()
                transcript += "[User]: \(text)\n\n"
            case .assistant(let blocks):
                let text = blocks.compactMap { $0.textContent }.joined()
                let tools = blocks.compactMap { $0.toolCall?.name }
                if !text.isEmpty { transcript += "[Assistant]: \(text)\n" }
                if !tools.isEmpty {
                    transcript += "[Tools called: \(tools.joined(separator: ", "))]\n"
                }
                transcript += "\n"
            case .toolResult(_, let content):
                transcript += "[Tool result]: \(String(content.prefix(500)))\n\n"
            case .toolResults(let entries):
                for entry in entries {
                    let preview: String
                    switch entry.output {
                    case .text(let t): preview = String(t.prefix(500))
                    case .json: preview = "[JSON data]"
                    case .error(let e): preview = "Error: \(e)"
                    }
                    transcript += "[Tool result]: \(preview)\n"
                }
                transcript += "\n"
            }
        }
        return transcript
    }
}
