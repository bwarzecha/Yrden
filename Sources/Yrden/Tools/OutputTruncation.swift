/// Head+tail truncation for large tool outputs.
///
/// When shell output or file content exceeds the character budget,
/// keeps 60% from the head and 40% from the tail with a marker showing
/// how much was omitted. Splits at line boundaries when possible.

import Foundation

public enum OutputTruncation {

    /// Truncate text using head+tail strategy (60% head, 40% tail).
    /// Returns original text if within limit.
    public static func truncate(_ text: String, maxLength: Int) -> String {
        truncateWithInfo(text, maxLength: maxLength).text
    }

    /// Truncate with metadata about what happened.
    public static func truncateWithInfo(
        _ text: String,
        maxLength: Int
    ) -> (text: String, wasTruncated: Bool, totalLength: Int) {
        let totalLength = text.count
        guard totalLength > maxLength else {
            return (text, false, totalLength)
        }

        let omitted = totalLength - maxLength
        let marker = marker(omitted: omitted, total: totalLength)

        // Budget for actual content after reserving space for the marker
        let contentBudget = maxLength - marker.count
        guard contentBudget > 0 else {
            // maxLength too small to fit even the marker — return truncated marker
            return (String(marker.prefix(maxLength)), true, totalLength)
        }

        let headBudget = Int(Double(contentBudget) * 0.6)
        let tailBudget = contentBudget - headBudget

        let headEnd = snapToLineBreak(in: text, near: headBudget, direction: .backward)
        let tailStart = snapToLineBreak(
            in: text,
            near: totalLength - tailBudget,
            direction: .forward
        )

        let head = text[text.startIndex..<text.index(text.startIndex, offsetBy: headEnd)]
        let tail = text[text.index(text.startIndex, offsetBy: tailStart)..<text.endIndex]

        return (String(head) + marker + String(tail), true, totalLength)
    }

    // MARK: - Private

    private static func marker(omitted: Int, total: Int) -> String {
        "\n\n[...truncated \(omitted) of \(total) total characters...]\n\n"
    }

    private enum SnapDirection {
        case forward
        case backward
    }

    /// Adjust a character offset to the nearest line break within a small window.
    /// Returns the adjusted offset (clamped to valid range).
    private static func snapToLineBreak(
        in text: String,
        near offset: Int,
        direction: SnapDirection
    ) -> Int {
        let clamped = max(0, min(offset, text.count))
        let windowSize = 200

        switch direction {
        case .backward:
            // Look backward from offset for a newline
            let searchStart = max(0, clamped - windowSize)
            let startIdx = text.index(text.startIndex, offsetBy: searchStart)
            let endIdx = text.index(text.startIndex, offsetBy: clamped)
            let window = text[startIdx..<endIdx]
            if let lastNewline = window.lastIndex(of: "\n") {
                return text.distance(from: text.startIndex, to: text.index(after: lastNewline))
            }
            return clamped

        case .forward:
            // Look forward from offset for a newline
            let searchEnd = min(text.count, clamped + windowSize)
            let startIdx = text.index(text.startIndex, offsetBy: clamped)
            let endIdx = text.index(text.startIndex, offsetBy: searchEnd)
            let window = text[startIdx..<endIdx]
            if let firstNewline = window.firstIndex(of: "\n") {
                return text.distance(from: text.startIndex, to: text.index(after: firstNewline))
            }
            return clamped
        }
    }
}
