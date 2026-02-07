/// Tests for JSONValue object (dictionary) support.
///
/// Covers: Codable round-trips, objectValue accessor, subscript access,
/// nested objects, literal expressibility, and edge cases.

import Testing
import Foundation
@testable import Yrden

@Suite("JSONValue - Objects")
struct JSONValueObjectTests {

    // MARK: - Basic Object Tests

    @Test func roundTrip_object_empty() throws {
        let original: JSONValue = .object([:])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func roundTrip_object_simple() throws {
        let original: JSONValue = .object(["key": .string("value")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func roundTrip_object_multipleKeys() throws {
        let original: JSONValue = .object([
            "name": .string("Alice"),
            "age": .int(30),
            "active": .bool(true)
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func encode_object_empty_producesEmptyObject() throws {
        let value: JSONValue = .object([:])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "{}")
    }

    @Test func encode_object_producesObject() throws {
        let value: JSONValue = .object(["key": .string("value")])
        let data = try JSONEncoder().encode(value)
        // Verify structural correctness by decoding as generic JSON
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(parsed["key"] as? String == "value")
        // Also verify it's NOT using synthesized enum format
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("\"object\""), "Should not use synthesized format")
        #expect(!json.contains("_0"), "Should not use synthesized format")
    }

    @Test func decode_object_empty() throws {
        let json = "{}"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .object([:]))
    }

    @Test func decode_object_simple() throws {
        let json = """
        {"name": "Alice"}
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .object(["name": .string("Alice")]))
    }

    @Test func decode_object_multipleKeys() throws {
        let json = """
        {"name": "Alice", "age": 30, "active": true}
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["name"] == .string("Alice"))
        #expect(value["age"] == .int(30))
        #expect(value["active"] == .bool(true))
    }

    @Test func decode_object_withNullValue() throws {
        let json = """
        {"key": null}
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .object(["key": .null]))
    }

    // MARK: - objectValue Accessor

    @Test func objectValue_returnsObject() {
        let dict: [String: JSONValue] = ["a": .int(1), "b": .int(2)]
        let value: JSONValue = .object(dict)
        #expect(value.objectValue == dict)
    }

    @Test func objectValue_returnsNil_whenNotObject() {
        #expect(JSONValue.string("hello").objectValue == nil)
        #expect(JSONValue.int(42).objectValue == nil)
        #expect(JSONValue.array([]).objectValue == nil)
        #expect(JSONValue.null.objectValue == nil)
    }

    // MARK: - Subscript Access

    @Test func subscript_object_existingKey() {
        let value: JSONValue = .object(["name": .string("Alice")])
        #expect(value["name"] == .string("Alice"))
    }

    @Test func subscript_object_missingKey() {
        let value: JSONValue = .object(["name": .string("Alice")])
        #expect(value["missing"] == nil)
    }

    @Test func subscript_object_onNonObject() {
        #expect(JSONValue.string("hello")["key"] == nil)
        #expect(JSONValue.int(42)["key"] == nil)
        #expect(JSONValue.null["key"] == nil)
    }

    @Test func subscript_object_multipleAccess() {
        let value: JSONValue = .object([
            "a": .int(1),
            "b": .int(2),
            "c": .int(3)
        ])
        #expect(value["a"]?.intValue == 1)
        #expect(value["b"]?.intValue == 2)
        #expect(value["c"]?.intValue == 3)
        #expect(value["d"] == nil)
    }

    // MARK: - Nested Objects

    @Test func roundTrip_object_nested() throws {
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
        #expect(original == decoded)
    }

    @Test func decode_object_nested() throws {
        let json = """
        {"user": {"name": "Alice", "profile": {"age": 30}}}
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["user"]?["name"]?.stringValue == "Alice")
        #expect(value["user"]?["profile"]?["age"]?.intValue == 30)
    }

    @Test func subscript_chained_nestedObjects() {
        let value: JSONValue = .object([
            "level1": .object([
                "level2": .object([
                    "level3": .object([
                        "value": .string("deep")
                    ])
                ])
            ])
        ])
        #expect(value["level1"]?["level2"]?["level3"]?["value"]?.stringValue == "deep")
    }

    @Test func subscript_chained_returnsNil_whenPathBroken() {
        let value: JSONValue = .object([
            "a": .object([
                "b": .string("leaf")
            ])
        ])
        // Path exists
        #expect(value["a"]?["b"]?.stringValue == "leaf")
        // Path broken at various points
        #expect(value["missing"]?["b"] == nil)
        #expect(value["a"]?["missing"] == nil)
        // Trying to subscript a non-object
        #expect(value["a"]?["b"]?["c"] == nil)
    }

    // MARK: - Literal Expressibility

    @Test func literal_dictionary_empty() {
        let value: JSONValue = [:]
        #expect(value == .object([:]))
    }

    @Test func literal_dictionary_simple() {
        let value: JSONValue = ["key": "value"]
        #expect(value == .object(["key": .string("value")]))
    }

    @Test func literal_dictionary_mixedTypes() {
        let value: JSONValue = [
            "name": "Alice",
            "age": 30,
            "active": true,
            "score": 95.5
        ]
        #expect(value["name"]?.stringValue == "Alice")
        #expect(value["age"]?.intValue == 30)
        #expect(value["active"]?.boolValue == true)
        #expect(value["score"]?.doubleValue == 95.5)
    }

    @Test func literal_dictionary_nested() {
        let value: JSONValue = [
            "user": [
                "name": "Alice",
                "profile": [
                    "age": 30
                ]
            ]
        ]
        #expect(value["user"]?["name"]?.stringValue == "Alice")
        #expect(value["user"]?["profile"]?["age"]?.intValue == 30)
    }

    @Test func literal_dictionary_withNull() {
        let value: JSONValue = [
            "present": "value",
            "absent": nil
        ]
        #expect(value["present"] == .string("value"))
        #expect(value["absent"] == .null)
    }

    // MARK: - Edge Cases

    @Test func object_withEmptyStringKey() throws {
        let original: JSONValue = .object(["": .string("empty key")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded[""]?.stringValue == "empty key")
    }

    @Test func object_withUnicodeKeys() throws {
        let original: JSONValue = .object([
            "emoji": .string("value"),
            "\u{4E2D}\u{6587}": .string("chinese key")
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded["emoji"]?.stringValue == "value")
        #expect(decoded["\u{4E2D}\u{6587}"]?.stringValue == "chinese key")
    }

    @Test func object_manyKeys() throws {
        var dict: [String: JSONValue] = [:]
        for i in 0..<100 {
            dict["key\(i)"] = .int(i)
        }
        let original: JSONValue = .object(dict)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
        // Verify a few specific values
        #expect(decoded["key0"]?.intValue == 0)
        #expect(decoded["key50"]?.intValue == 50)
        #expect(decoded["key99"]?.intValue == 99)
    }

    @Test func object_deeplyNested() throws {
        // 10 levels of nesting
        var value: JSONValue = .string("deepest")
        for i in (0..<10).reversed() {
            value = .object(["level\(i)": value])
        }
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == decoded)
    }
}
