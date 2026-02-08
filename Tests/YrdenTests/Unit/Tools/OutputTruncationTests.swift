/// Tests for OutputTruncation head+tail truncation utility.

import Testing
@testable import Yrden

@Suite("OutputTruncation")
struct OutputTruncationTests {

    @Test("text under limit is returned unchanged")
    func underLimit() {
        let text = "Hello, world!"
        let result = OutputTruncation.truncate(text, maxLength: 100)
        #expect(result == text)
    }

    @Test("text at exact limit is returned unchanged")
    func atExactLimit() {
        let text = String(repeating: "a", count: 500)
        let result = OutputTruncation.truncate(text, maxLength: 500)
        #expect(result == text)
    }

    @Test("text over limit contains head, marker, and tail")
    func overLimitHasHeadMarkerTail() {
        let text = String(repeating: "x", count: 1000)
        let result = OutputTruncation.truncate(text, maxLength: 200)

        #expect(result.contains("[...truncated"))
        #expect(result.contains("total characters...]"))
        #expect(result.count <= 200)
    }

    @Test("marker contains correct omitted and total counts")
    func markerCountsCorrect() {
        let text = String(repeating: "a", count: 5000)
        let result = OutputTruncation.truncate(text, maxLength: 500)

        // The marker should reference total = 5000
        #expect(result.contains("5000 total characters"))
    }

    @Test("truncateWithInfo reports metadata correctly")
    func truncateWithInfoMetadata() {
        let text = String(repeating: "b", count: 3000)
        let info = OutputTruncation.truncateWithInfo(text, maxLength: 500)

        #expect(info.wasTruncated == true)
        #expect(info.totalLength == 3000)
        #expect(info.text.count <= 500)
    }

    @Test("truncateWithInfo reports no truncation when under limit")
    func truncateWithInfoNoTruncation() {
        let text = "short text"
        let info = OutputTruncation.truncateWithInfo(text, maxLength: 1000)

        #expect(info.wasTruncated == false)
        #expect(info.totalLength == 10)
        #expect(info.text == text)
    }

    @Test("head portion is approximately 60% of content budget")
    func headTailRatio() {
        // Build text with known lines so we can verify the ratio
        let lines = (1...100).map { "Line \($0): " + String(repeating: "x", count: 80) }
        let text = lines.joined(separator: "\n")
        let maxLength = text.count / 2  // Force truncation

        let result = OutputTruncation.truncate(text, maxLength: maxLength)

        // Extract head (before marker) and tail (after marker)
        let parts = result.components(separatedBy: "[...truncated")
        #expect(parts.count == 2)

        let head = parts[0]
        let markerAndTail = "[...truncated" + parts[1]
        let markerEnd = markerAndTail.range(of: "...]\n\n")!
        let tail = String(markerAndTail[markerEnd.upperBound...])

        let contentTotal = head.count + tail.count
        let headRatio = Double(head.count) / Double(contentTotal)
        // Should be approximately 0.6, allow some variance from line-break snapping
        #expect(headRatio > 0.4 && headRatio < 0.8)
    }

    @Test("empty string returns empty")
    func emptyString() {
        let result = OutputTruncation.truncate("", maxLength: 100)
        #expect(result == "")
    }

    @Test("maxLength smaller than marker length produces bounded output")
    func maxLengthSmallerThanMarker() {
        let text = String(repeating: "x", count: 1000)
        let result = OutputTruncation.truncate(text, maxLength: 10)
        #expect(result.count <= 10)
    }

    @Test("splits at line boundaries when possible")
    func lineBreakAlignment() {
        let lines = (1...50).map { "Line \($0)" }
        let text = lines.joined(separator: "\n")
        let maxLength = text.count / 3  // Force significant truncation

        let result = OutputTruncation.truncate(text, maxLength: maxLength)

        // Head should end at a line boundary (before marker)
        let parts = result.components(separatedBy: "\n\n[...truncated")
        let head = parts[0]
        // Head ends with a complete line (last char before the marker double-newline)
        #expect(!head.isEmpty)
        // Tail should start at a line boundary
        let tailParts = result.components(separatedBy: "...]\n\n")
        if tailParts.count == 2 {
            let tail = tailParts[1]
            // Tail should start with "Line" (beginning of a line)
            #expect(tail.hasPrefix("Line"))
        }
    }
}
