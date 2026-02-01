import XCTest
@testable import Yrden

/// Phase 4 tests: Equatable and Hashable
/// Verifies synthesized Equatable/Hashable work correctly for all edge cases
final class JSONValueEqualityTests: XCTestCase {

    // MARK: - Equatable: Same Values Equal

    func test_equatable_null_equal() {
        XCTAssertEqual(JSONValue.null, JSONValue.null)
    }

    func test_equatable_bool_equal() {
        XCTAssertEqual(JSONValue.bool(true), JSONValue.bool(true))
        XCTAssertEqual(JSONValue.bool(false), JSONValue.bool(false))
    }

    func test_equatable_int_equal() {
        XCTAssertEqual(JSONValue.int(42), JSONValue.int(42))
        XCTAssertEqual(JSONValue.int(-100), JSONValue.int(-100))
        XCTAssertEqual(JSONValue.int(0), JSONValue.int(0))
    }

    func test_equatable_double_equal() {
        XCTAssertEqual(JSONValue.double(3.14), JSONValue.double(3.14))
        XCTAssertEqual(JSONValue.double(-2.5), JSONValue.double(-2.5))
    }

    func test_equatable_string_equal() {
        XCTAssertEqual(JSONValue.string("hello"), JSONValue.string("hello"))
        XCTAssertEqual(JSONValue.string(""), JSONValue.string(""))
    }

    func test_equatable_array_equal() {
        let arr1: JSONValue = .array([.int(1), .int(2), .int(3)])
        let arr2: JSONValue = .array([.int(1), .int(2), .int(3)])
        XCTAssertEqual(arr1, arr2)
    }

    func test_equatable_object_equal() {
        let obj1: JSONValue = .object(["a": .int(1), "b": .int(2)])
        let obj2: JSONValue = .object(["a": .int(1), "b": .int(2)])
        XCTAssertEqual(obj1, obj2)
    }

    // MARK: - Equatable: Different Values Not Equal

    func test_equatable_differentTypes_notEqual() {
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
                    XCTAssertEqual(v1, v2, "Same value at index \(i) should be equal")
                } else {
                    // Note: int(1) and double(1.0) are different types
                    XCTAssertNotEqual(v1, v2, "Different values at \(i) and \(j) should not be equal")
                }
            }
        }
    }

    func test_equatable_bool_differentValues_notEqual() {
        XCTAssertNotEqual(JSONValue.bool(true), JSONValue.bool(false))
    }

    func test_equatable_int_differentValues_notEqual() {
        XCTAssertNotEqual(JSONValue.int(1), JSONValue.int(2))
        XCTAssertNotEqual(JSONValue.int(0), JSONValue.int(1))
        XCTAssertNotEqual(JSONValue.int(-1), JSONValue.int(1))
    }

    func test_equatable_int_zeroEqualsNegativeZero() {
        // In integers, 0 and -0 are the same value
        XCTAssertEqual(JSONValue.int(0), JSONValue.int(-0))
    }

    func test_equatable_double_differentValues_notEqual() {
        XCTAssertNotEqual(JSONValue.double(1.0), JSONValue.double(1.1))
    }

    func test_equatable_string_differentValues_notEqual() {
        XCTAssertNotEqual(JSONValue.string("hello"), JSONValue.string("world"))
        XCTAssertNotEqual(JSONValue.string("hello"), JSONValue.string("Hello"))  // Case sensitive
    }

    func test_equatable_array_differentValues_notEqual() {
        XCTAssertNotEqual(
            JSONValue.array([.int(1), .int(2)]),
            JSONValue.array([.int(1), .int(3)])
        )
    }

    func test_equatable_array_differentLength_notEqual() {
        XCTAssertNotEqual(
            JSONValue.array([.int(1), .int(2)]),
            JSONValue.array([.int(1)])
        )
    }

    func test_equatable_object_differentValues_notEqual() {
        XCTAssertNotEqual(
            JSONValue.object(["a": .int(1)]),
            JSONValue.object(["a": .int(2)])
        )
    }

    func test_equatable_object_differentKeys_notEqual() {
        XCTAssertNotEqual(
            JSONValue.object(["a": .int(1)]),
            JSONValue.object(["b": .int(1)])
        )
    }

    // MARK: - Equatable: Nested Structures

    func test_equatable_nestedObjects_equal() {
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
        XCTAssertEqual(obj1, obj2)
    }

    func test_equatable_nestedObjects_notEqual() {
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
        XCTAssertNotEqual(obj1, obj2)
    }

    func test_equatable_nestedArrays_equal() {
        let arr1: JSONValue = .array([
            .array([.int(1), .int(2)]),
            .array([.int(3), .int(4)])
        ])
        let arr2: JSONValue = .array([
            .array([.int(1), .int(2)]),
            .array([.int(3), .int(4)])
        ])
        XCTAssertEqual(arr1, arr2)
    }

    // MARK: - Object Equality: Key-Order Independent

    func test_equatable_object_keyOrderIndependent() {
        // Swift dictionaries don't guarantee order, but let's verify equality works
        let obj1: JSONValue = .object(["a": .int(1), "b": .int(2), "c": .int(3)])
        let obj2: JSONValue = .object(["c": .int(3), "a": .int(1), "b": .int(2)])
        XCTAssertEqual(obj1, obj2, "Objects with same keys/values should be equal regardless of insertion order")
    }

    func test_equatable_object_manyKeys_orderIndependent() {
        var dict1: [String: JSONValue] = [:]
        var dict2: [String: JSONValue] = [:]

        // Insert in different orders
        for i in 0..<20 {
            dict1["key\(i)"] = .int(i)
            dict2["key\(19 - i)"] = .int(19 - i)
        }

        XCTAssertEqual(JSONValue.object(dict1), JSONValue.object(dict2))
    }

    // MARK: - Array Equality: Order Dependent

    func test_equatable_array_orderDependent() {
        let arr1: JSONValue = .array([.int(1), .int(2), .int(3)])
        let arr2: JSONValue = .array([.int(3), .int(2), .int(1)])
        XCTAssertNotEqual(arr1, arr2, "Arrays with different order should not be equal")
    }

    func test_equatable_array_orderDependent_strings() {
        let arr1: JSONValue = .array([.string("a"), .string("b")])
        let arr2: JSONValue = .array([.string("b"), .string("a")])
        XCTAssertNotEqual(arr1, arr2)
    }

    // MARK: - Hashable: Dictionary Key

    func test_hashable_canUseDictionaryKey_primitives() {
        var dict: [JSONValue: String] = [:]
        dict[.null] = "null"
        dict[.bool(true)] = "true"
        dict[.int(42)] = "42"
        dict[.double(3.14)] = "3.14"
        dict[.string("key")] = "string"

        XCTAssertEqual(dict[.null], "null")
        XCTAssertEqual(dict[.bool(true)], "true")
        XCTAssertEqual(dict[.int(42)], "42")
        XCTAssertEqual(dict[.double(3.14)], "3.14")
        XCTAssertEqual(dict[.string("key")], "string")
    }

    func test_hashable_canUseDictionaryKey_arrays() {
        var dict: [JSONValue: String] = [:]
        dict[.array([.int(1), .int(2)])] = "array1"
        dict[.array([.int(3), .int(4)])] = "array2"

        XCTAssertEqual(dict[.array([.int(1), .int(2)])], "array1")
        XCTAssertEqual(dict[.array([.int(3), .int(4)])], "array2")
    }

    func test_hashable_canUseDictionaryKey_objects() {
        var dict: [JSONValue: String] = [:]
        dict[.object(["a": .int(1)])] = "obj1"
        dict[.object(["b": .int(2)])] = "obj2"

        XCTAssertEqual(dict[.object(["a": .int(1)])], "obj1")
        XCTAssertEqual(dict[.object(["b": .int(2)])], "obj2")
    }

    // MARK: - Hashable: Set

    func test_hashable_canAddToSet_primitives() {
        var set = Set<JSONValue>()
        set.insert(.null)
        set.insert(.bool(true))
        set.insert(.bool(false))
        set.insert(.int(42))
        set.insert(.double(3.14))
        set.insert(.string("hello"))

        XCTAssertEqual(set.count, 6)
        XCTAssertTrue(set.contains(.null))
        XCTAssertTrue(set.contains(.bool(true)))
        XCTAssertTrue(set.contains(.int(42)))
    }

    func test_hashable_setDeduplicates() {
        var set = Set<JSONValue>()
        set.insert(.int(42))
        set.insert(.int(42))  // Duplicate
        set.insert(.string("hello"))
        set.insert(.string("hello"))  // Duplicate

        XCTAssertEqual(set.count, 2)
    }

    func test_hashable_setDeduplicates_objects() {
        var set = Set<JSONValue>()
        set.insert(.object(["a": .int(1)]))
        set.insert(.object(["a": .int(1)]))  // Same content = duplicate

        XCTAssertEqual(set.count, 1)
    }

    func test_hashable_setDeduplicates_arrays() {
        var set = Set<JSONValue>()
        set.insert(.array([.int(1), .int(2)]))
        set.insert(.array([.int(1), .int(2)]))  // Same content = duplicate
        set.insert(.array([.int(2), .int(1)]))  // Different order = different

        XCTAssertEqual(set.count, 2)
    }

    // MARK: - Edge Cases

    func test_equatable_emptyArray_vs_emptyObject() {
        XCTAssertNotEqual(JSONValue.array([]), JSONValue.object([:]))
    }

    func test_equatable_int_vs_double_sameNumericValue() {
        // int(1) and double(1.0) should NOT be equal - different types
        XCTAssertNotEqual(JSONValue.int(1), JSONValue.double(1.0))
        XCTAssertNotEqual(JSONValue.int(0), JSONValue.double(0.0))
    }

    func test_equatable_deeply_nested_equal() {
        // Build identical deeply nested structures
        var value1: JSONValue = .string("leaf")
        var value2: JSONValue = .string("leaf")

        for i in 0..<5 {
            value1 = .object(["level\(i)": value1])
            value2 = .object(["level\(i)": value2])
        }

        XCTAssertEqual(value1, value2)
    }

    func test_equatable_deeply_nested_notEqual() {
        // Build slightly different deeply nested structures
        var value1: JSONValue = .string("leaf1")
        var value2: JSONValue = .string("leaf2")

        for i in 0..<5 {
            value1 = .object(["level\(i)": value1])
            value2 = .object(["level\(i)": value2])
        }

        XCTAssertNotEqual(value1, value2)
    }
}
