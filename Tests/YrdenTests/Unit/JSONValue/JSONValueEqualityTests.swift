/// Tests for JSONValue Equatable and Hashable conformance.
///
/// Covers: equality for all types, cross-type inequality, nested structure equality,
/// key-order independence for objects, order dependence for arrays,
/// Hashable usage in dictionaries and sets.

import Testing
import Foundation
@testable import Yrden

@Suite("JSONValue - Equality & Hashing")
struct JSONValueEqualityTests {

    // MARK: - Equatable: Same Values Equal

    @Test func equatable_null_equal() {
        #expect(JSONValue.null == JSONValue.null)
    }

    @Test func equatable_bool_equal() {
        #expect(JSONValue.bool(true) == JSONValue.bool(true))
        #expect(JSONValue.bool(false) == JSONValue.bool(false))
    }

    @Test func equatable_int_equal() {
        #expect(JSONValue.int(42) == JSONValue.int(42))
        #expect(JSONValue.int(-100) == JSONValue.int(-100))
        #expect(JSONValue.int(0) == JSONValue.int(0))
    }

    @Test func equatable_double_equal() {
        #expect(JSONValue.double(3.14) == JSONValue.double(3.14))
        #expect(JSONValue.double(-2.5) == JSONValue.double(-2.5))
    }

    @Test func equatable_string_equal() {
        #expect(JSONValue.string("hello") == JSONValue.string("hello"))
        #expect(JSONValue.string("") == JSONValue.string(""))
    }

    @Test func equatable_array_equal() {
        let arr1: JSONValue = .array([.int(1), .int(2), .int(3)])
        let arr2: JSONValue = .array([.int(1), .int(2), .int(3)])
        #expect(arr1 == arr2)
    }

    @Test func equatable_object_equal() {
        let obj1: JSONValue = .object(["a": .int(1), "b": .int(2)])
        let obj2: JSONValue = .object(["a": .int(1), "b": .int(2)])
        #expect(obj1 == obj2)
    }

    // MARK: - Equatable: Different Values Not Equal

    @Test func equatable_differentTypes_notEqual() {
        let values: [JSONValue] = [
            .null,
            .bool(true),
            .int(1),
            .double(1.0),
            .string("1"),
            .array([.int(1)]),
            .object(["1": .int(1)])
        ]

        // Each value should only equal itself
        for (i, v1) in values.enumerated() {
            for (j, v2) in values.enumerated() {
                if i == j {
                    #expect(v1 == v2, "Same value at index \(i) should be equal")
                } else {
                    // Note: int(1) and double(1.0) are different types
                    #expect(v1 != v2, "Different values at \(i) and \(j) should not be equal")
                }
            }
        }
    }

    @Test func equatable_bool_differentValues_notEqual() {
        #expect(JSONValue.bool(true) != JSONValue.bool(false))
    }

    @Test func equatable_int_differentValues_notEqual() {
        #expect(JSONValue.int(1) != JSONValue.int(2))
        #expect(JSONValue.int(0) != JSONValue.int(1))
        #expect(JSONValue.int(-1) != JSONValue.int(1))
    }

    @Test func equatable_int_zeroEqualsNegativeZero() {
        // In integers, 0 and -0 are the same value
        #expect(JSONValue.int(0) == JSONValue.int(-0))
    }

    @Test func equatable_double_differentValues_notEqual() {
        #expect(JSONValue.double(1.0) != JSONValue.double(1.1))
    }

    @Test func equatable_string_differentValues_notEqual() {
        #expect(JSONValue.string("hello") != JSONValue.string("world"))
        #expect(JSONValue.string("hello") != JSONValue.string("Hello"))  // Case sensitive
    }

    @Test func equatable_array_differentValues_notEqual() {
        #expect(
            JSONValue.array([.int(1), .int(2)]) !=
            JSONValue.array([.int(1), .int(3)])
        )
    }

    @Test func equatable_array_differentLength_notEqual() {
        #expect(
            JSONValue.array([.int(1), .int(2)]) !=
            JSONValue.array([.int(1)])
        )
    }

    @Test func equatable_object_differentValues_notEqual() {
        #expect(
            JSONValue.object(["a": .int(1)]) !=
            JSONValue.object(["a": .int(2)])
        )
    }

    @Test func equatable_object_differentKeys_notEqual() {
        #expect(
            JSONValue.object(["a": .int(1)]) !=
            JSONValue.object(["b": .int(1)])
        )
    }

    // MARK: - Equatable: Nested Structures

    @Test func equatable_nestedObjects_equal() {
        let obj1: JSONValue = .object([
            "user": .object([
                "name": .string("Alice"),
                "age": .int(30)
            ])
        ])
        let obj2: JSONValue = .object([
            "user": .object([
                "name": .string("Alice"),
                "age": .int(30)
            ])
        ])
        #expect(obj1 == obj2)
    }

    @Test func equatable_nestedObjects_notEqual() {
        let obj1: JSONValue = .object([
            "user": .object([
                "name": .string("Alice"),
                "age": .int(30)
            ])
        ])
        let obj2: JSONValue = .object([
            "user": .object([
                "name": .string("Alice"),
                "age": .int(31)  // Different age
            ])
        ])
        #expect(obj1 != obj2)
    }

    @Test func equatable_nestedArrays_equal() {
        let arr1: JSONValue = .array([
            .array([.int(1), .int(2)]),
            .array([.int(3), .int(4)])
        ])
        let arr2: JSONValue = .array([
            .array([.int(1), .int(2)]),
            .array([.int(3), .int(4)])
        ])
        #expect(arr1 == arr2)
    }

    // MARK: - Object Equality: Key-Order Independent

    @Test func equatable_object_keyOrderIndependent() {
        // Swift dictionaries don't guarantee order, but let's verify equality works
        let obj1: JSONValue = .object(["a": .int(1), "b": .int(2), "c": .int(3)])
        let obj2: JSONValue = .object(["c": .int(3), "a": .int(1), "b": .int(2)])
        #expect(obj1 == obj2, "Objects with same keys/values should be equal regardless of insertion order")
    }

    @Test func equatable_object_manyKeys_orderIndependent() {
        var dict1: [String: JSONValue] = [:]
        var dict2: [String: JSONValue] = [:]

        // Insert in different orders
        for i in 0..<20 {
            dict1["key\(i)"] = .int(i)
            dict2["key\(19 - i)"] = .int(19 - i)
        }

        #expect(JSONValue.object(dict1) == JSONValue.object(dict2))
    }

    // MARK: - Array Equality: Order Dependent

    @Test func equatable_array_orderDependent() {
        let arr1: JSONValue = .array([.int(1), .int(2), .int(3)])
        let arr2: JSONValue = .array([.int(3), .int(2), .int(1)])
        #expect(arr1 != arr2, "Arrays with different order should not be equal")
    }

    @Test func equatable_array_orderDependent_strings() {
        let arr1: JSONValue = .array([.string("a"), .string("b")])
        let arr2: JSONValue = .array([.string("b"), .string("a")])
        #expect(arr1 != arr2)
    }

    // MARK: - Hashable: Dictionary Key

    @Test func hashable_canUseDictionaryKey_primitives() {
        var dict: [JSONValue: String] = [:]
        dict[.null] = "null"
        dict[.bool(true)] = "true"
        dict[.int(42)] = "42"
        dict[.double(3.14)] = "3.14"
        dict[.string("key")] = "string"

        #expect(dict[.null] == "null")
        #expect(dict[.bool(true)] == "true")
        #expect(dict[.int(42)] == "42")
        #expect(dict[.double(3.14)] == "3.14")
        #expect(dict[.string("key")] == "string")
    }

    @Test func hashable_canUseDictionaryKey_arrays() {
        var dict: [JSONValue: String] = [:]
        dict[.array([.int(1), .int(2)])] = "array1"
        dict[.array([.int(3), .int(4)])] = "array2"

        #expect(dict[.array([.int(1), .int(2)])] == "array1")
        #expect(dict[.array([.int(3), .int(4)])] == "array2")
    }

    @Test func hashable_canUseDictionaryKey_objects() {
        var dict: [JSONValue: String] = [:]
        dict[.object(["a": .int(1)])] = "obj1"
        dict[.object(["b": .int(2)])] = "obj2"

        #expect(dict[.object(["a": .int(1)])] == "obj1")
        #expect(dict[.object(["b": .int(2)])] == "obj2")
    }

    // MARK: - Hashable: Set

    @Test func hashable_canAddToSet_primitives() {
        var set = Set<JSONValue>()
        set.insert(.null)
        set.insert(.bool(true))
        set.insert(.bool(false))
        set.insert(.int(42))
        set.insert(.double(3.14))
        set.insert(.string("hello"))

        #expect(set.count == 6)
        #expect(set.contains(.null))
        #expect(set.contains(.bool(true)))
        #expect(set.contains(.int(42)))
    }

    @Test func hashable_setDeduplicates() {
        var set = Set<JSONValue>()
        set.insert(.int(42))
        set.insert(.int(42))  // Duplicate
        set.insert(.string("hello"))
        set.insert(.string("hello"))  // Duplicate

        #expect(set.count == 2)
    }

    @Test func hashable_setDeduplicates_objects() {
        var set = Set<JSONValue>()
        set.insert(.object(["a": .int(1)]))
        set.insert(.object(["a": .int(1)]))  // Same content = duplicate

        #expect(set.count == 1)
    }

    @Test func hashable_setDeduplicates_arrays() {
        var set = Set<JSONValue>()
        set.insert(.array([.int(1), .int(2)]))
        set.insert(.array([.int(1), .int(2)]))  // Same content = duplicate
        set.insert(.array([.int(2), .int(1)]))  // Different order = different

        #expect(set.count == 2)
    }

    // MARK: - Edge Cases

    @Test func equatable_emptyArray_vs_emptyObject() {
        #expect(JSONValue.array([]) != JSONValue.object([:]))
    }

    @Test func equatable_int_vs_double_sameNumericValue() {
        // int(1) and double(1.0) should NOT be equal - different types
        #expect(JSONValue.int(1) != JSONValue.double(1.0))
        #expect(JSONValue.int(0) != JSONValue.double(0.0))
    }

    @Test func equatable_deeply_nested_equal() {
        // Build identical deeply nested structures
        var value1: JSONValue = .string("leaf")
        var value2: JSONValue = .string("leaf")

        for i in 0..<5 {
            value1 = .object(["level\(i)": value1])
            value2 = .object(["level\(i)": value2])
        }

        #expect(value1 == value2)
    }

    @Test func equatable_deeply_nested_notEqual() {
        // Build slightly different deeply nested structures
        var value1: JSONValue = .string("leaf1")
        var value2: JSONValue = .string("leaf2")

        for i in 0..<5 {
            value1 = .object(["level\(i)": value1])
            value2 = .object(["level\(i)": value2])
        }

        #expect(value1 != value2)
    }
}
