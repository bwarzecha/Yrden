import Foundation
import Testing
@testable import Yrden

/// Benchmarks comparing JSONValue decoding performance.
///
/// These tests measure the overhead of the `try?` cascade pattern used in `JSONValue.init(from:)`
/// compared to baseline `JSONSerialization` decoding to `Any`.
///
/// Run with: `swift test --filter JSONValueDecodingBenchmarkTests`
struct JSONValueDecodingBenchmarkTests {
    // MARK: - Test Data

    /// Small payload: typical LLM tool call arguments
    static let smallPayload: Data = """
    {
        "query": "search term",
        "limit": 10,
        "includeMetadata": true,
        "filters": ["active", "recent"],
        "threshold": 0.85
    }
    """.data(using: .utf8)!

    /// Medium payload: nested structure with mixed types
    static let mediumPayload: Data = """
    {
        "users": [
            {"id": 1, "name": "Alice", "active": true, "score": 95.5},
            {"id": 2, "name": "Bob", "active": false, "score": 87.3},
            {"id": 3, "name": "Charlie", "active": true, "score": 91.0}
        ],
        "metadata": {
            "total": 3,
            "page": 1,
            "hasMore": false
        },
        "tags": ["premium", "verified"]
    }
    """.data(using: .utf8)!

    /// Large payload: 100 items with mixed leaf types
    static let largePayload: Data = {
        var items: [[String: Any]] = []
        for i in 0..<100 {
            items.append([
                "id": i,
                "name": "Item \(i)",
                "price": Double(i) * 1.5,
                "inStock": i % 2 == 0,
                "tags": ["tag\(i % 5)", "category\(i % 3)"],
                "metadata": ["created": "2024-01-\(i % 28 + 1)", "views": i * 10]
            ])
        }
        let payload: [String: Any] = ["items": items, "count": 100]
        return try! JSONSerialization.data(withJSONObject: payload)
    }()

    // MARK: - Benchmark Helpers

    /// Measures execution time of a closure over multiple iterations.
    func measureTime(iterations: Int = 1000, _ block: () throws -> Void) rethrows -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            try block()
        }
        let end = CFAbsoluteTimeGetCurrent()
        return (end - start) / Double(iterations) * 1000 // ms per iteration
    }

    // MARK: - Benchmarks

    @Test("Benchmark: Small payload - JSONValue vs JSONSerialization")
    func benchmarkSmallPayload() throws {
        let iterations = 10000

        // Baseline: JSONSerialization to Any
        let baselineMs = measureTime(iterations: iterations) {
            _ = try! JSONSerialization.jsonObject(with: Self.smallPayload)
        }

        // JSONValue via Codable (try? cascade)
        let codableMs = measureTime(iterations: iterations) {
            _ = try! JSONDecoder().decode(JSONValue.self, from: Self.smallPayload)
        }

        // JSONValue via fast path (JSONSerialization + conversion)
        let fastPathMs = measureTime(iterations: iterations) {
            _ = try! JSONValue(jsonData: Self.smallPayload)
        }

        let codableOverhead = ((codableMs / baselineMs) - 1) * 100
        let fastPathOverhead = ((fastPathMs / baselineMs) - 1) * 100

        print("""

        📊 Small Payload Benchmark (\(iterations) iterations)
        ─────────────────────────────────────────
        JSONSerialization:      \(String(format: "%.4f", baselineMs)) ms/iter (baseline)
        JSONValue (fast path):  \(String(format: "%.4f", fastPathMs)) ms/iter (+\(String(format: "%.0f", fastPathOverhead))%)
        JSONValue (Codable):    \(String(format: "%.4f", codableMs)) ms/iter (+\(String(format: "%.0f", codableOverhead))%)

        """)

        // Sanity check: Both paths should decode correctly
        let decodedCodable = try JSONDecoder().decode(JSONValue.self, from: Self.smallPayload)
        let decodedFast = try JSONValue(jsonData: Self.smallPayload)
        #expect(decodedCodable["query"]?.stringValue == "search term")
        #expect(decodedFast["query"]?.stringValue == "search term")
        #expect(decodedCodable == decodedFast)
    }

    @Test("Benchmark: Medium payload - JSONValue vs JSONSerialization")
    func benchmarkMediumPayload() throws {
        let iterations = 5000

        let baselineMs = measureTime(iterations: iterations) {
            _ = try! JSONSerialization.jsonObject(with: Self.mediumPayload)
        }

        let codableMs = measureTime(iterations: iterations) {
            _ = try! JSONDecoder().decode(JSONValue.self, from: Self.mediumPayload)
        }

        let fastPathMs = measureTime(iterations: iterations) {
            _ = try! JSONValue(jsonData: Self.mediumPayload)
        }

        let codableOverhead = ((codableMs / baselineMs) - 1) * 100
        let fastPathOverhead = ((fastPathMs / baselineMs) - 1) * 100

        print("""

        📊 Medium Payload Benchmark (\(iterations) iterations)
        ─────────────────────────────────────────
        JSONSerialization:      \(String(format: "%.4f", baselineMs)) ms/iter (baseline)
        JSONValue (fast path):  \(String(format: "%.4f", fastPathMs)) ms/iter (+\(String(format: "%.0f", fastPathOverhead))%)
        JSONValue (Codable):    \(String(format: "%.4f", codableMs)) ms/iter (+\(String(format: "%.0f", codableOverhead))%)

        """)

        // Sanity check
        let decodedFast = try JSONValue(jsonData: Self.mediumPayload)
        #expect(decodedFast["users"]?.arrayValue?.count == 3)
    }

    @Test("Benchmark: Large payload - JSONValue vs JSONSerialization")
    func benchmarkLargePayload() throws {
        let iterations = 1000

        let baselineMs = measureTime(iterations: iterations) {
            _ = try! JSONSerialization.jsonObject(with: Self.largePayload)
        }

        let codableMs = measureTime(iterations: iterations) {
            _ = try! JSONDecoder().decode(JSONValue.self, from: Self.largePayload)
        }

        let fastPathMs = measureTime(iterations: iterations) {
            _ = try! JSONValue(jsonData: Self.largePayload)
        }

        let codableOverhead = ((codableMs / baselineMs) - 1) * 100
        let fastPathOverhead = ((fastPathMs / baselineMs) - 1) * 100

        print("""

        📊 Large Payload Benchmark (\(iterations) iterations)
        ─────────────────────────────────────────
        JSONSerialization:      \(String(format: "%.4f", baselineMs)) ms/iter (baseline)
        JSONValue (fast path):  \(String(format: "%.4f", fastPathMs)) ms/iter (+\(String(format: "%.0f", fastPathOverhead))%)
        JSONValue (Codable):    \(String(format: "%.4f", codableMs)) ms/iter (+\(String(format: "%.0f", codableOverhead))%)

        """)

        // Sanity check
        let decodedFast = try JSONValue(jsonData: Self.largePayload)
        #expect(decodedFast["count"]?.intValue == 100)
        #expect(decodedFast["items"]?.arrayValue?.count == 100)
    }

    @Test("Benchmark: Leaf type distribution analysis")
    func benchmarkLeafTypeDistribution() throws {
        // Demonstrates that leaf values dominate container values
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Self.largePayload)

        var counts: [String: Int] = [
            "null": 0, "bool": 0, "int": 0, "double": 0,
            "string": 0, "array": 0, "object": 0
        ]

        func countTypes(_ value: JSONValue) {
            switch value {
            case .null: counts["null"]! += 1
            case .bool: counts["bool"]! += 1
            case .int: counts["int"]! += 1
            case .double: counts["double"]! += 1
            case .string: counts["string"]! += 1
            case .array(let arr):
                counts["array"]! += 1
                arr.forEach { countTypes($0) }
            case .object(let obj):
                counts["object"]! += 1
                obj.values.forEach { countTypes($0) }
            }
        }

        countTypes(decoded)

        let totalLeaves = counts["null"]! + counts["bool"]! + counts["int"]!
            + counts["double"]! + counts["string"]!
        let totalContainers = counts["array"]! + counts["object"]!

        print("""

        📊 Leaf Type Distribution (Large Payload)
        ─────────────────────────────────────────
        Strings:    \(counts["string"]!)
        Integers:   \(counts["int"]!)
        Doubles:    \(counts["double"]!)
        Booleans:   \(counts["bool"]!)
        Nulls:      \(counts["null"]!)
        ─────────────────────────────────────────
        Arrays:     \(counts["array"]!)
        Objects:    \(counts["object"]!)
        ─────────────────────────────────────────
        Total leaves:     \(totalLeaves)
        Total containers: \(totalContainers)
        Leaf:Container ratio: \(String(format: "%.1f", Double(totalLeaves) / Double(totalContainers))):1

        """)

        // Verify leaves dominate (should be at least 3:1 for typical JSON)
        #expect(totalLeaves > totalContainers * 2)
    }
}
