import XCTest
@testable import Yrden

/// Phase 3 tests: Array support
/// Tests Codable, arrayValue accessor, subscript access, heterogeneous arrays, mixed nesting
final class JSONValueArrayTests: XCTestCase {

    // MARK: - Basic Array Tests

    func test_roundTrip_array_empty() throws {
        let original: JSONValue = .array([])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_roundTrip_array_homogeneous_ints() throws {
        let original: JSONValue = .array([.int(1), .int(2), .int(3)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_roundTrip_array_homogeneous_strings() throws {
        let original: JSONValue = .array([.string("a"), .string("b"), .string("c")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_encode_array_empty_producesEmptyArray() throws {
        let value: JSONValue = .array([])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, "[]")
    }

    func test_encode_array_producesArray() throws {
        let value: JSONValue = .array([.int(1), .int(2), .int(3)])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, "[1,2,3]")
    }

    func test_encode_array_notSynthesizedFormat() throws {
        let value: JSONValue = .array([.string("a"), .string("b")])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("array"), "Should not use synthesized format")
        XCTAssertFalse(json.contains("_0"), "Should not use synthesized format")
        XCTAssertEqual(json, "[\"a\",\"b\"]")
    }

    func test_decode_array_empty() throws {
        let json = "[]"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .array([]))
    }

    func test_decode_array_simple() throws {
        let json = "[1, 2, 3]"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .array([.int(1), .int(2), .int(3)]))
    }

    // MARK: - arrayValue Accessor

    func test_arrayValue_returnsArray() {
        let arr: [JSONValue] = [.int(1), .int(2), .int(3)]
        let value: JSONValue = .array(arr)
        XCTAssertEqual(value.arrayValue, arr)
    }

    func test_arrayValue_returnsNil_whenNotArray() {
        XCTAssertNil(JSONValue.string("hello").arrayValue)
        XCTAssertNil(JSONValue.int(42).arrayValue)
        XCTAssertNil(JSONValue.object([:]).arrayValue)
        XCTAssertNil(JSONValue.null.arrayValue)
    }

    // MARK: - Subscript Access (by index)

    func test_subscript_array_validIndex() {
        let value: JSONValue = .array([.string("a"), .string("b"), .string("c")])
        XCTAssertEqual(value[0], .string("a"))
        XCTAssertEqual(value[1], .string("b"))
        XCTAssertEqual(value[2], .string("c"))
    }

    func test_subscript_array_outOfBounds() {
        let value: JSONValue = .array([.int(1), .int(2)])
        XCTAssertNil(value[2])
        XCTAssertNil(value[100])
        XCTAssertNil(value[-1])
    }

    func test_subscript_array_onNonArray() {
        XCTAssertNil(JSONValue.string("hello")[0])
        XCTAssertNil(JSONValue.int(42)[0])
        XCTAssertNil(JSONValue.object([:] )[0])
        XCTAssertNil(JSONValue.null[0])
    }

    func test_subscript_array_emptyArray() {
        let value: JSONValue = .array([])
        XCTAssertNil(value[0])
    }

    // MARK: - Heterogeneous Arrays

    func test_roundTrip_array_heterogeneous() throws {
        let original: JSONValue = .array([
            .string("hello"),
            .int(42),
            .double(3.14),
            .bool(true),
            .null
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_decode_array_heterogeneous() throws {
        let json = """
        ["hello", 42, 3.14, true, null]
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value[0]?.stringValue, "hello")
        XCTAssertEqual(value[1]?.intValue, 42)
        XCTAssertEqual(value[2]?.doubleValue, 3.14)
        XCTAssertEqual(value[3]?.boolValue, true)
        XCTAssertEqual(value[4], .null)
    }

    // MARK: - Arrays Containing Objects

    func test_roundTrip_array_ofObjects() throws {
        let original: JSONValue = .array([
            .object(["name": .string("Alice"), "age": .int(30)]),
            .object(["name": .string("Bob"), "age": .int(25)])
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_decode_array_ofObjects() throws {
        let json = """
        [{"name": "Alice"}, {"name": "Bob"}]
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value[0]?["name"]?.stringValue, "Alice")
        XCTAssertEqual(value[1]?["name"]?.stringValue, "Bob")
    }

    func test_subscript_chained_arrayThenObject() {
        let value: JSONValue = .array([
            .object(["value": .int(1)]),
            .object(["value": .int(2)])
        ])
        XCTAssertEqual(value[0]?["value"]?.intValue, 1)
        XCTAssertEqual(value[1]?["value"]?.intValue, 2)
    }

    // MARK: - Objects Containing Arrays

    func test_roundTrip_object_withArrayValue() throws {
        let original: JSONValue = .object([
            "tags": .array([.string("a"), .string("b"), .string("c")])
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_decode_object_withArrayValue() throws {
        let json = """
        {"items": [1, 2, 3]}
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value["items"]?[0]?.intValue, 1)
        XCTAssertEqual(value["items"]?[1]?.intValue, 2)
        XCTAssertEqual(value["items"]?[2]?.intValue, 3)
    }

    func test_subscript_chained_objectThenArray() {
        let value: JSONValue = .object([
            "items": .array([.string("first"), .string("second")])
        ])
        XCTAssertEqual(value["items"]?[0]?.stringValue, "first")
        XCTAssertEqual(value["items"]?[1]?.stringValue, "second")
    }

    // MARK: - Literal Expressibility

    func test_literal_array_empty() {
        let value: JSONValue = []
        XCTAssertEqual(value, .array([]))
    }

    func test_literal_array_homogeneous() {
        let value: JSONValue = [1, 2, 3]
        XCTAssertEqual(value, .array([.int(1), .int(2), .int(3)]))
    }

    func test_literal_array_heterogeneous() {
        let value: JSONValue = ["hello", 42, true, nil]
        XCTAssertEqual(value[0], .string("hello"))
        XCTAssertEqual(value[1], .int(42))
        XCTAssertEqual(value[2], .bool(true))
        XCTAssertEqual(value[3], .null)
    }

    func test_literal_array_ofDictionaries() {
        let value: JSONValue = [
            ["name": "Alice"],
            ["name": "Bob"]
        ]
        XCTAssertEqual(value[0]?["name"]?.stringValue, "Alice")
        XCTAssertEqual(value[1]?["name"]?.stringValue, "Bob")
    }

    func test_literal_dictionary_withArray() {
        let value: JSONValue = [
            "tags": ["a", "b", "c"]
        ]
        XCTAssertEqual(value["tags"]?[0]?.stringValue, "a")
        XCTAssertEqual(value["tags"]?[1]?.stringValue, "b")
        XCTAssertEqual(value["tags"]?[2]?.stringValue, "c")
    }

    // MARK: - Edge Cases

    func test_array_manyElements() throws {
        var elements: [JSONValue] = []
        for i in 0..<100 {
            elements.append(.int(i))
        }
        let original: JSONValue = .array(elements)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded[0]?.intValue, 0)
        XCTAssertEqual(decoded[99]?.intValue, 99)
    }

    func test_array_nestedArrays() throws {
        let original: JSONValue = .array([
            .array([.int(1), .int(2)]),
            .array([.int(3), .int(4)])
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded[0]?[0]?.intValue, 1)
        XCTAssertEqual(decoded[1]?[1]?.intValue, 4)
    }

    func test_array_deeplyNested() throws {
        // 10 levels of nested arrays
        var value: JSONValue = .string("deepest")
        for _ in 0..<10 {
            value = .array([value])
        }
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, decoded)
    }

    func test_complexStructure_mixedNesting() throws {
        let original: JSONValue = .object([
            "users": .array([
                .object([
                    "name": .string("Alice"),
                    "scores": .array([.int(95), .int(87), .int(92)])
                ]),
                .object([
                    "name": .string("Bob"),
                    "scores": .array([.int(88), .int(90)])
                ])
            ]),
            "metadata": .object([
                "version": .int(1),
                "tags": .array([.string("test"), .string("data")])
            ])
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)

        // Verify access paths
        XCTAssertEqual(decoded["users"]?[0]?["name"]?.stringValue, "Alice")
        XCTAssertEqual(decoded["users"]?[0]?["scores"]?[1]?.intValue, 87)
        XCTAssertEqual(decoded["users"]?[1]?["scores"]?[0]?.intValue, 88)
        XCTAssertEqual(decoded["metadata"]?["tags"]?[0]?.stringValue, "test")
    }
}
