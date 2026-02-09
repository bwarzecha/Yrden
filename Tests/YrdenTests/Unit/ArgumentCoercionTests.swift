/// Tests for argument type coercion.
///
/// Verifies that `coerceArgumentTypes` correctly converts mismatched
/// JSON primitive types to match schema declarations. This handles
/// local models that send unquoted numbers for string fields.

import Testing
import Foundation
@testable import Yrden

@Suite("Argument Type Coercion")
struct ArgumentCoercionTests {

    // MARK: - Number → String

    @Test("integer coerced to string")
    func integerCoercedToString() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "content": ["type": "string"]
            ]
        ]

        let data = #"{"content":30}"#.data(using: .utf8)!
        let result = coerceArgumentTypes(data, schema: schema)
        #expect(result != nil)

        let parsed = try JSONDecoder().decode([String: String].self, from: result!)
        #expect(parsed["content"] == "30")
    }

    @Test("double coerced to string")
    func doubleCoercedToString() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "value": ["type": "string"]
            ]
        ]

        let data = #"{"value":3.14}"#.data(using: .utf8)!
        let result = coerceArgumentTypes(data, schema: schema)
        #expect(result != nil)

        let parsed = try JSONDecoder().decode([String: String].self, from: result!)
        #expect(parsed["value"] == "3.14")
    }

    // MARK: - Boolean → String

    @Test("boolean coerced to string")
    func booleanCoercedToString() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "flag": ["type": "string"]
            ]
        ]

        let data = #"{"flag":true}"#.data(using: .utf8)!
        let result = coerceArgumentTypes(data, schema: schema)
        #expect(result != nil)

        let parsed = try JSONDecoder().decode([String: String].self, from: result!)
        #expect(parsed["flag"] == "true")
    }

    // MARK: - No coercion needed

    @Test("returns nil when types already match")
    func noCoercionNeeded() {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "content": ["type": "string"]
            ]
        ]

        let data = #"{"content":"hello"}"#.data(using: .utf8)!
        let result = coerceArgumentTypes(data, schema: schema)
        #expect(result == nil)
    }

    @Test("returns nil for non-string schema fields")
    func nonStringSchemaFieldNotCoerced() {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "count": ["type": "integer"]
            ]
        ]

        // String value for integer field — we don't coerce this direction
        let data = #"{"count":"five"}"#.data(using: .utf8)!
        let result = coerceArgumentTypes(data, schema: schema)
        #expect(result == nil)
    }

    // MARK: - Mixed fields

    @Test("only mismatched string fields are coerced, others left alone")
    func mixedFieldsPartialCoercion() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "path": ["type": "string"],
                "content": ["type": "string"],
                "count": ["type": "integer"]
            ]
        ]

        let data = #"{"path":"/tmp/test.txt","content":42,"count":5}"#.data(using: .utf8)!
        let result = coerceArgumentTypes(data, schema: schema)
        #expect(result != nil)

        let parsed = try JSONDecoder().decode(JSONValue.self, from: result!)
        guard case .object(let obj) = parsed else {
            Issue.record("Expected object")
            return
        }
        // path unchanged (already string)
        #expect(obj["path"] == .string("/tmp/test.txt"))
        // content coerced from int to string
        #expect(obj["content"] == .string("42"))
        // count left as int (schema says integer)
        #expect(obj["count"] == .int(5))
    }

    // MARK: - Edge cases

    @Test("returns nil for invalid JSON data")
    func invalidJSONReturnsNil() {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "content": ["type": "string"]
            ]
        ]

        let data = "not json".data(using: .utf8)!
        let result = coerceArgumentTypes(data, schema: schema)
        #expect(result == nil)
    }

    @Test("returns nil for non-object arguments")
    func nonObjectArgumentsReturnsNil() {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "content": ["type": "string"]
            ]
        ]

        let data = #""just a string""#.data(using: .utf8)!
        let result = coerceArgumentTypes(data, schema: schema)
        #expect(result == nil)
    }
}
