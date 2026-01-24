import Testing
import Foundation
@testable import Yrden
import MCP

/// Tests for MCP Value <-> JSONValue conversion.
@Suite("MCP Value Conversion")
struct MCPValueConversionTests {

    // MARK: - MCP Value -> JSONValue

    @Test("Convert null")
    func convertNull() {
        let mcpValue = MCP.Value.null
        let jsonValue = JSONValue(mcpValue: mcpValue)
        #expect(jsonValue == .null)
    }

    @Test("Convert bool true")
    func convertBoolTrue() {
        let mcpValue = MCP.Value.bool(true)
        let jsonValue = JSONValue(mcpValue: mcpValue)
        #expect(jsonValue == .bool(true))
    }

    @Test("Convert bool false")
    func convertBoolFalse() {
        let mcpValue = MCP.Value.bool(false)
        let jsonValue = JSONValue(mcpValue: mcpValue)
        #expect(jsonValue == .bool(false))
    }

    @Test("Convert int")
    func convertInt() {
        let mcpValue = MCP.Value.int(42)
        let jsonValue = JSONValue(mcpValue: mcpValue)
        #expect(jsonValue == .int(42))
    }

    @Test("Convert negative int")
    func convertNegativeInt() {
        let mcpValue = MCP.Value.int(-100)
        let jsonValue = JSONValue(mcpValue: mcpValue)
        #expect(jsonValue == .int(-100))
    }

    @Test("Convert double")
    func convertDouble() {
        let mcpValue = MCP.Value.double(3.14159)
        let jsonValue = JSONValue(mcpValue: mcpValue)
        #expect(jsonValue == .double(3.14159))
    }

    @Test("Convert string")
    func convertString() {
        let mcpValue = MCP.Value.string("hello world")
        let jsonValue = JSONValue(mcpValue: mcpValue)
        #expect(jsonValue == .string("hello world"))
    }

    @Test("Convert empty string")
    func convertEmptyString() {
        let mcpValue = MCP.Value.string("")
        let jsonValue = JSONValue(mcpValue: mcpValue)
        #expect(jsonValue == .string(""))
    }

    @Test("Convert simple array")
    func convertSimpleArray() {
        let mcpValue = MCP.Value.array([.int(1), .int(2), .int(3)])
        let jsonValue = JSONValue(mcpValue: mcpValue)
        #expect(jsonValue == .array([.int(1), .int(2), .int(3)]))
    }

    @Test("Convert empty array")
    func convertEmptyArray() {
        let mcpValue = MCP.Value.array([])
        let jsonValue = JSONValue(mcpValue: mcpValue)
        #expect(jsonValue == .array([]))
    }

    @Test("Convert mixed array")
    func convertMixedArray() {
        let mcpValue = MCP.Value.array([
            .string("hello"),
            .int(42),
            .bool(true),
            .null
        ])
        let jsonValue = JSONValue(mcpValue: mcpValue)
        #expect(jsonValue == .array([
            .string("hello"),
            .int(42),
            .bool(true),
            .null
        ]))
    }

    @Test("Convert simple object")
    func convertSimpleObject() {
        let mcpValue = MCP.Value.object([
            "name": .string("test"),
            "count": .int(5)
        ])
        let jsonValue = JSONValue(mcpValue: mcpValue)
        #expect(jsonValue == .object([
            "name": .string("test"),
            "count": .int(5)
        ]))
    }

    @Test("Convert empty object")
    func convertEmptyObject() {
        let mcpValue = MCP.Value.object([:])
        let jsonValue = JSONValue(mcpValue: mcpValue)
        #expect(jsonValue == .object([:]))
    }

    @Test("Convert nested object")
    func convertNestedObject() {
        let mcpValue = MCP.Value.object([
            "person": .object([
                "name": .string("Alice"),
                "age": .int(30)
            ]),
            "items": .array([.string("a"), .string("b")])
        ])
        let jsonValue = JSONValue(mcpValue: mcpValue)

        if case .object(let obj) = jsonValue {
            #expect(obj["person"] == .object([
                "name": .string("Alice"),
                "age": .int(30)
            ]))
            #expect(obj["items"] == .array([.string("a"), .string("b")]))
        } else {
            Issue.record("Expected object")
        }
    }

    @Test("Convert data to base64 string")
    func convertData() {
        let data = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]) // "Hello"
        let mcpValue = MCP.Value.data(mimeType: "text/plain", data)
        let jsonValue = JSONValue(mcpValue: mcpValue)

        // "Hello" in base64 is "SGVsbG8="
        #expect(jsonValue == .string("SGVsbG8="))
    }

    // MARK: - JSONValue -> MCP Value

    @Test("Convert JSONValue null to MCP")
    func convertJSONValueNull() {
        let jsonValue = JSONValue.null
        let mcpValue = MCP.Value(jsonValue: jsonValue)
        #expect(mcpValue == .null)
    }

    @Test("Convert JSONValue bool to MCP")
    func convertJSONValueBool() {
        let jsonValue = JSONValue.bool(true)
        let mcpValue = MCP.Value(jsonValue: jsonValue)
        #expect(mcpValue == .bool(true))
    }

    @Test("Convert JSONValue int to MCP")
    func convertJSONValueInt() {
        let jsonValue = JSONValue.int(42)
        let mcpValue = MCP.Value(jsonValue: jsonValue)
        #expect(mcpValue == .int(42))
    }

    @Test("Convert JSONValue double to MCP")
    func convertJSONValueDouble() {
        let jsonValue = JSONValue.double(3.14)
        let mcpValue = MCP.Value(jsonValue: jsonValue)
        #expect(mcpValue == .double(3.14))
    }

    @Test("Convert JSONValue string to MCP")
    func convertJSONValueString() {
        let jsonValue = JSONValue.string("test")
        let mcpValue = MCP.Value(jsonValue: jsonValue)
        #expect(mcpValue == .string("test"))
    }

    @Test("Convert JSONValue array to MCP")
    func convertJSONValueArray() {
        let jsonValue = JSONValue.array([.int(1), .int(2)])
        let mcpValue = MCP.Value(jsonValue: jsonValue)
        #expect(mcpValue == .array([.int(1), .int(2)]))
    }

    @Test("Convert JSONValue object to MCP")
    func convertJSONValueObject() {
        let jsonValue = JSONValue.object(["key": .string("value")])
        let mcpValue = MCP.Value(jsonValue: jsonValue)
        #expect(mcpValue == .object(["key": .string("value")]))
    }

    // MARK: - Round-trip Tests

    @Test("Round-trip preserves complex structure")
    func roundTripComplex() {
        let original = JSONValue.object([
            "name": .string("Test"),
            "count": .int(42),
            "enabled": .bool(true),
            "score": .double(9.5),
            "tags": .array([.string("a"), .string("b")]),
            "nested": .object([
                "value": .null
            ])
        ])

        let mcpValue = MCP.Value(jsonValue: original)
        let roundTripped = JSONValue(mcpValue: mcpValue)

        #expect(roundTripped == original)
    }

    // MARK: - Dictionary Helpers

    @Test("Dictionary asJSONValue conversion")
    func dictionaryAsJSONValue() {
        let mcpDict: [String: MCP.Value] = [
            "name": .string("test"),
            "count": .int(5)
        ]

        let jsonDict = mcpDict.asJSONValue

        #expect(jsonDict["name"] == .string("test"))
        #expect(jsonDict["count"] == .int(5))
    }

    @Test("Dictionary asMCPValue conversion")
    func dictionaryAsMCPValue() {
        let jsonDict: [String: JSONValue] = [
            "name": .string("test"),
            "count": .int(5)
        ]

        let mcpDict = jsonDict.asMCPValue

        #expect(mcpDict["name"] == .string("test"))
        #expect(mcpDict["count"] == .int(5))
    }
}
