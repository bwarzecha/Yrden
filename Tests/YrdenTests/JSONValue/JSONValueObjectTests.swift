import XCTest
@testable import Yrden

/// Phase 2 tests: Object (dictionary) support
/// Tests Codable, objectValue accessor, subscript access, nested objects, literals
final class JSONValueObjectTests: XCTestCase {

    // MARK: - Basic Object Tests

    func test_roundTrip_object_empty() throws {
        let original: JSONValue = .object([:])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_roundTrip_object_simple() throws {
        let original: JSONValue = .object(["key": .string("value")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_roundTrip_object_multipleKeys() throws {
        let original: JSONValue = .object([
            "name": .string("Alice"),
            "age": .int(30),
            "active": .bool(true)
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_encode_object_empty_producesEmptyObject() throws {
        let value: JSONValue = .object([:])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, "{}")
    }

    func test_encode_object_producesObject() throws {
        let value: JSONValue = .object(["key": .string("value")])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        // Verify it's a JSON object (not synthesized enum format)
        XCTAssertTrue(json.hasPrefix("{"), "Should start with {")
        XCTAssertTrue(json.hasSuffix("}"), "Should end with }")
        XCTAssertTrue(json.contains("\"key\""), "Should contain key")
        XCTAssertTrue(json.contains("\"value\""), "Should contain value")
        XCTAssertFalse(json.contains("object"), "Should not use synthesized format")
        XCTAssertFalse(json.contains("_0"), "Should not use synthesized format")
    }

    func test_decode_object_empty() throws {
        let json = "{}"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .object([:]))
    }

    func test_decode_object_simple() throws {
        let json = """
        {"name": "Alice"}
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .object(["name": .string("Alice")]))
    }

    func test_decode_object_multipleKeys() throws {
        let json = """
        {"name": "Alice", "age": 30, "active": true}
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value["name"], .string("Alice"))
        XCTAssertEqual(value["age"], .int(30))
        XCTAssertEqual(value["active"], .bool(true))
    }

    func test_decode_object_withNullValue() throws {
        let json = """
        {"key": null}
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .object(["key": .null]))
    }

    // MARK: - objectValue Accessor

    func test_objectValue_returnsObject() {
        let dict: [String: JSONValue] = ["a": .int(1), "b": .int(2)]
        let value: JSONValue = .object(dict)
        XCTAssertEqual(value.objectValue, dict)
    }

    func test_objectValue_returnsNil_whenNotObject() {
        XCTAssertNil(JSONValue.string("hello").objectValue)
        XCTAssertNil(JSONValue.int(42).objectValue)
        XCTAssertNil(JSONValue.array([]).objectValue)
        XCTAssertNil(JSONValue.null.objectValue)
    }

    // MARK: - Subscript Access

    func test_subscript_object_existingKey() {
        let value: JSONValue = .object(["name": .string("Alice")])
        XCTAssertEqual(value["name"], .string("Alice"))
    }

    func test_subscript_object_missingKey() {
        let value: JSONValue = .object(["name": .string("Alice")])
        XCTAssertNil(value["missing"])
    }

    func test_subscript_object_onNonObject() {
        XCTAssertNil(JSONValue.string("hello")["key"])
        XCTAssertNil(JSONValue.int(42)["key"])
        XCTAssertNil(JSONValue.null["key"])
    }

    func test_subscript_object_multipleAccess() {
        let value: JSONValue = .object([
            "a": .int(1),
            "b": .int(2),
            "c": .int(3)
        ])
        XCTAssertEqual(value["a"]?.intValue, 1)
        XCTAssertEqual(value["b"]?.intValue, 2)
        XCTAssertEqual(value["c"]?.intValue, 3)
        XCTAssertNil(value["d"])
    }

    // MARK: - Nested Objects

    func test_roundTrip_object_nested() throws {
        let original: JSONValue = .object([
            "user": .object([
                "name": .string("Alice"),
                "profile": .object([
                    "age": .int(30)
                ])
            ])
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_decode_object_nested() throws {
        let json = """
        {"user": {"name": "Alice", "profile": {"age": 30}}}
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value["user"]?["name"]?.stringValue, "Alice")
        XCTAssertEqual(value["user"]?["profile"]?["age"]?.intValue, 30)
    }

    func test_subscript_chained_nestedObjects() {
        let value: JSONValue = .object([
            "level1": .object([
                "level2": .object([
                    "level3": .object([
                        "value": .string("deep")
                    ])
                ])
            ])
        ])
        XCTAssertEqual(value["level1"]?["level2"]?["level3"]?["value"]?.stringValue, "deep")
    }

    func test_subscript_chained_returnsNil_whenPathBroken() {
        let value: JSONValue = .object([
            "a": .object([
                "b": .string("leaf")
            ])
        ])
        // Path exists
        XCTAssertEqual(value["a"]?["b"]?.stringValue, "leaf")
        // Path broken at various points
        XCTAssertNil(value["missing"]?["b"])
        XCTAssertNil(value["a"]?["missing"])
        // Trying to subscript a non-object
        XCTAssertNil(value["a"]?["b"]?["c"])
    }

    // MARK: - Literal Expressibility

    func test_literal_dictionary_empty() {
        let value: JSONValue = [:]
        XCTAssertEqual(value, .object([:]))
    }

    func test_literal_dictionary_simple() {
        let value: JSONValue = ["key": "value"]
        XCTAssertEqual(value, .object(["key": .string("value")]))
    }

    func test_literal_dictionary_mixedTypes() {
        let value: JSONValue = [
            "name": "Alice",
            "age": 30,
            "active": true,
            "score": 95.5
        ]
        XCTAssertEqual(value["name"]?.stringValue, "Alice")
        XCTAssertEqual(value["age"]?.intValue, 30)
        XCTAssertEqual(value["active"]?.boolValue, true)
        XCTAssertEqual(value["score"]?.doubleValue, 95.5)
    }

    func test_literal_dictionary_nested() {
        let value: JSONValue = [
            "user": [
                "name": "Alice",
                "profile": [
                    "age": 30
                ]
            ]
        ]
        XCTAssertEqual(value["user"]?["name"]?.stringValue, "Alice")
        XCTAssertEqual(value["user"]?["profile"]?["age"]?.intValue, 30)
    }

    func test_literal_dictionary_withNull() {
        let value: JSONValue = [
            "present": "value",
            "absent": nil
        ]
        XCTAssertEqual(value["present"], .string("value"))
        XCTAssertEqual(value["absent"], .null)
    }

    // MARK: - Edge Cases

    func test_object_withEmptyStringKey() throws {
        let original: JSONValue = .object(["": .string("empty key")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded[""]?.stringValue, "empty key")
    }

    func test_object_withUnicodeKeys() throws {
        let original: JSONValue = .object([
            "emoji": .string("value"),
            "\u{4E2D}\u{6587}": .string("chinese key")
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded["emoji"]?.stringValue, "value")
        XCTAssertEqual(decoded["\u{4E2D}\u{6587}"]?.stringValue, "chinese key")
    }

    func test_object_manyKeys() throws {
        var dict: [String: JSONValue] = [:]
        for i in 0..<100 {
            dict["key\(i)"] = .int(i)
        }
        let original: JSONValue = .object(dict)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
        // Verify a few specific values
        XCTAssertEqual(decoded["key0"]?.intValue, 0)
        XCTAssertEqual(decoded["key50"]?.intValue, 50)
        XCTAssertEqual(decoded["key99"]?.intValue, 99)
    }

    func test_object_deeplyNested() throws {
        // 10 levels of nesting
        var value: JSONValue = .string("deepest")
        for i in (0..<10).reversed() {
            value = .object(["level\(i)": value])
        }
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, decoded)
    }
}
