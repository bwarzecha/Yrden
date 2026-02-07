/// Tests for JSONValue array support.
///
/// Covers: Codable round-trips, arrayValue accessor, index-based subscript access,
/// heterogeneous arrays, mixed nesting with objects, and edge cases.

import Testing
import Foundation
@testable import Yrden

@Suite("JSONValue - Arrays")
struct JSONValueArrayTests {

    // MARK: - Basic Array Tests

    @Test func roundTrip_array_empty() throws {
        let original: JSONValue = .array([])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func roundTrip_array_homogeneous_ints() throws {
        let original: JSONValue = .array([.int(1), .int(2), .int(3)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func roundTrip_array_homogeneous_strings() throws {
        let original: JSONValue = .array([.string("a"), .string("b"), .string("c")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func encode_array_empty_producesEmptyArray() throws {
        let value: JSONValue = .array([])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "[]")
    }

    @Test func encode_array_producesArray() throws {
        let value: JSONValue = .array([.int(1), .int(2), .int(3)])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "[1,2,3]")
    }

    @Test func encode_array_notSynthesizedFormat() throws {
        let value: JSONValue = .array([.string("a"), .string("b")])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("array"), "Should not use synthesized format")
        #expect(!json.contains("_0"), "Should not use synthesized format")
        #expect(json == "[\"a\",\"b\"]")
    }

    @Test func decode_array_empty() throws {
        let json = "[]"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .array([]))
    }

    @Test func decode_array_simple() throws {
        let json = "[1, 2, 3]"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .array([.int(1), .int(2), .int(3)]))
    }

    // MARK: - arrayValue Accessor

    @Test func arrayValue_returnsArray() {
        let arr: [JSONValue] = [.int(1), .int(2), .int(3)]
        let value: JSONValue = .array(arr)
        #expect(value.arrayValue == arr)
    }

    @Test func arrayValue_returnsNil_whenNotArray() {
        #expect(JSONValue.string("hello").arrayValue == nil)
        #expect(JSONValue.int(42).arrayValue == nil)
        #expect(JSONValue.object([:]).arrayValue == nil)
        #expect(JSONValue.null.arrayValue == nil)
    }

    // MARK: - Subscript Access (by index)

    @Test func subscript_array_validIndex() {
        let value: JSONValue = .array([.string("a"), .string("b"), .string("c")])
        #expect(value[0] == .string("a"))
        #expect(value[1] == .string("b"))
        #expect(value[2] == .string("c"))
    }

    @Test func subscript_array_outOfBounds() {
        let value: JSONValue = .array([.int(1), .int(2)])
        #expect(value[2] == nil)
        #expect(value[100] == nil)
        #expect(value[-1] == nil)
    }

    @Test func subscript_array_onNonArray() {
        #expect(JSONValue.string("hello")[0] == nil)
        #expect(JSONValue.int(42)[0] == nil)
        #expect(JSONValue.object([:] )[0] == nil)
        #expect(JSONValue.null[0] == nil)
    }

    @Test func subscript_array_emptyArray() {
        let value: JSONValue = .array([])
        #expect(value[0] == nil)
    }

    // MARK: - Heterogeneous Arrays

    @Test func roundTrip_array_heterogeneous() throws {
        let original: JSONValue = .array([
            .string("hello"),
            .int(42),
            .double(3.14),
            .bool(true),
            .null
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func decode_array_heterogeneous() throws {
        let json = """
        ["hello", 42, 3.14, true, null]
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value[0]?.stringValue == "hello")
        #expect(value[1]?.intValue == 42)
        #expect(value[2]?.doubleValue == 3.14)
        #expect(value[3]?.boolValue == true)
        #expect(value[4] == .null)
    }

    // MARK: - Arrays Containing Objects

    @Test func roundTrip_array_ofObjects() throws {
        let original: JSONValue = .array([
            .object(["name": .string("Alice"), "age": .int(30)]),
            .object(["name": .string("Bob"), "age": .int(25)])
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func decode_array_ofObjects() throws {
        let json = """
        [{"name": "Alice"}, {"name": "Bob"}]
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value[0]?["name"]?.stringValue == "Alice")
        #expect(value[1]?["name"]?.stringValue == "Bob")
    }

    @Test func subscript_chained_arrayThenObject() {
        let value: JSONValue = .array([
            .object(["value": .int(1)]),
            .object(["value": .int(2)])
        ])
        #expect(value[0]?["value"]?.intValue == 1)
        #expect(value[1]?["value"]?.intValue == 2)
    }

    // MARK: - Objects Containing Arrays

    @Test func roundTrip_object_withArrayValue() throws {
        let original: JSONValue = .object([
            "tags": .array([.string("a"), .string("b"), .string("c")])
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func decode_object_withArrayValue() throws {
        let json = """
        {"items": [1, 2, 3]}
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["items"]?[0]?.intValue == 1)
        #expect(value["items"]?[1]?.intValue == 2)
        #expect(value["items"]?[2]?.intValue == 3)
    }

    @Test func subscript_chained_objectThenArray() {
        let value: JSONValue = .object([
            "items": .array([.string("first"), .string("second")])
        ])
        #expect(value["items"]?[0]?.stringValue == "first")
        #expect(value["items"]?[1]?.stringValue == "second")
    }

    // MARK: - Literal Expressibility

    @Test func literal_array_empty() {
        let value: JSONValue = []
        #expect(value == .array([]))
    }

    @Test func literal_array_homogeneous() {
        let value: JSONValue = [1, 2, 3]
        #expect(value == .array([.int(1), .int(2), .int(3)]))
    }

    @Test func literal_array_heterogeneous() {
        let value: JSONValue = ["hello", 42, true, nil]
        #expect(value[0] == .string("hello"))
        #expect(value[1] == .int(42))
        #expect(value[2] == .bool(true))
        #expect(value[3] == .null)
    }

    @Test func literal_array_ofDictionaries() {
        let value: JSONValue = [
            ["name": "Alice"],
            ["name": "Bob"]
        ]
        #expect(value[0]?["name"]?.stringValue == "Alice")
        #expect(value[1]?["name"]?.stringValue == "Bob")
    }

    @Test func literal_dictionary_withArray() {
        let value: JSONValue = [
            "tags": ["a", "b", "c"]
        ]
        #expect(value["tags"]?[0]?.stringValue == "a")
        #expect(value["tags"]?[1]?.stringValue == "b")
        #expect(value["tags"]?[2]?.stringValue == "c")
    }

    // MARK: - Edge Cases

    @Test func array_manyElements() throws {
        var elements: [JSONValue] = []
        for i in 0..<100 {
            elements.append(.int(i))
        }
        let original: JSONValue = .array(elements)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
        #expect(decoded[0]?.intValue == 0)
        #expect(decoded[99]?.intValue == 99)
    }

    @Test func array_nestedArrays() throws {
        let original: JSONValue = .array([
            .array([.int(1), .int(2)]),
            .array([.int(3), .int(4)])
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
        #expect(decoded[0]?[0]?.intValue == 1)
        #expect(decoded[1]?[1]?.intValue == 4)
    }

    @Test func array_deeplyNested() throws {
        // 10 levels of nested arrays
        var value: JSONValue = .string("deepest")
        for _ in 0..<10 {
            value = .array([value])
        }
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == decoded)
    }

    @Test func complexStructure_mixedNesting() throws {
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
        #expect(original == decoded)

        // Verify access paths
        #expect(decoded["users"]?[0]?["name"]?.stringValue == "Alice")
        #expect(decoded["users"]?[0]?["scores"]?[1]?.intValue == 87)
        #expect(decoded["users"]?[1]?["scores"]?[0]?.intValue == 88)
        #expect(decoded["metadata"]?["tags"]?[0]?.stringValue == "test")
    }
}
