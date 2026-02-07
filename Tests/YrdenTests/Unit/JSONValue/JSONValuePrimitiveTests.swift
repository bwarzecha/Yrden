/// Tests for JSONValue primitive types: null, bool, int, double, string.
///
/// Covers: Codable round-trips, encoding format verification,
/// type-safe accessors, and literal expressibility.

import Testing
import Foundation
@testable import Yrden

@Suite("JSONValue - Primitives")
struct JSONValuePrimitiveTests {

    // MARK: - Null Tests

    @Test func roundTrip_null() throws {
        let original: JSONValue = .null
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func encode_null_producesNull() throws {
        let value: JSONValue = .null
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "null")
    }

    @Test func decode_null() throws {
        let json = "null"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .null)
    }

    @Test func literal_nil() {
        let value: JSONValue = nil
        #expect(value == .null)
    }

    // MARK: - Bool Tests

    @Test func roundTrip_bool_true() throws {
        let original: JSONValue = .bool(true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func roundTrip_bool_false() throws {
        let original: JSONValue = .bool(false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func encode_bool_true_producesBool() throws {
        let value: JSONValue = .bool(true)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "true")
    }

    @Test func encode_bool_false_producesBool() throws {
        let value: JSONValue = .bool(false)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "false")
    }

    @Test func decode_bool_true() throws {
        let json = "true"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .bool(true))
    }

    @Test func decode_bool_false() throws {
        let json = "false"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .bool(false))
    }

    @Test func boolValue_returnsValue() {
        #expect(JSONValue.bool(true).boolValue == true)
        #expect(JSONValue.bool(false).boolValue == false)
    }

    @Test func boolValue_returnsNil_whenNotBool() {
        #expect(JSONValue.string("true").boolValue == nil)
        #expect(JSONValue.int(1).boolValue == nil)
        #expect(JSONValue.null.boolValue == nil)
    }

    @Test func literal_bool() {
        let trueValue: JSONValue = true
        let falseValue: JSONValue = false
        #expect(trueValue == .bool(true))
        #expect(falseValue == .bool(false))
    }

    // MARK: - Int Tests

    @Test func roundTrip_int_positive() throws {
        let original: JSONValue = .int(42)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func roundTrip_int_negative() throws {
        let original: JSONValue = .int(-42)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func roundTrip_int_zero() throws {
        let original: JSONValue = .int(0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func roundTrip_int_max() throws {
        let original: JSONValue = .int(Int.max)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func roundTrip_int_min() throws {
        let original: JSONValue = .int(Int.min)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func encode_int_producesNumber() throws {
        let value: JSONValue = .int(42)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "42")
    }

    @Test func encode_int_negative_producesNumber() throws {
        let value: JSONValue = .int(-100)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "-100")
    }

    @Test func decode_int() throws {
        let json = "42"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .int(42))
    }

    @Test func decode_int_negative() throws {
        let json = "-999"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .int(-999))
    }

    @Test func intValue_returnsValue() {
        #expect(JSONValue.int(42).intValue == 42)
        #expect(JSONValue.int(-100).intValue == -100)
        #expect(JSONValue.int(0).intValue == 0)
    }

    @Test func intValue_returnsNil_whenNotInt() {
        #expect(JSONValue.string("42").intValue == nil)
        #expect(JSONValue.double(42.0).intValue == nil)
        #expect(JSONValue.bool(true).intValue == nil)
        #expect(JSONValue.null.intValue == nil)
    }

    @Test func literal_int() {
        let value: JSONValue = 42
        #expect(value == .int(42))
    }

    @Test func literal_int_negative() {
        let value: JSONValue = -100
        #expect(value == .int(-100))
    }

    // MARK: - Double Tests

    @Test func roundTrip_double() throws {
        let original: JSONValue = .double(3.14159)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func roundTrip_double_negative() throws {
        let original: JSONValue = .double(-2.718)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func roundTrip_double_zero() throws {
        let original: JSONValue = .double(0.0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        // Note: 0.0 might decode as int(0), so check for either
        switch decoded {
        case .double(let val):
            #expect(val == 0.0)
        case .int(let val):
            #expect(val == 0)
        default:
            Issue.record("Expected double or int, got \(decoded)")
        }
    }

    @Test func encode_double_producesNumber() throws {
        let value: JSONValue = .double(3.14)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        let parsed = Double(json)
        #expect(parsed == 3.14, "Expected 3.14 but got '\(json)'")
    }

    @Test func decode_double() throws {
        let json = "3.14159"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .double(3.14159))
    }

    @Test func decode_double_scientific() throws {
        // Use a value that results in a fractional number to ensure it decodes as double
        let json = "1.5e-2"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .double(0.015))
    }

    @Test func decode_scientific_wholeNumber_decodesAsInt() throws {
        // Scientific notation that results in a whole number decodes as int (correct behavior)
        let json = "1.5e10"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        // 1.5e10 = 15000000000 which is a valid Int, so we decode as int for precision
        #expect(value == .int(15_000_000_000))
    }

    @Test func doubleValue_returnsValue() {
        #expect(JSONValue.double(3.14).doubleValue == 3.14)
        #expect(JSONValue.double(-2.5).doubleValue == -2.5)
    }

    @Test func doubleValue_returnsNil_whenNotDouble() {
        #expect(JSONValue.string("3.14").doubleValue == nil)
        #expect(JSONValue.int(3).doubleValue == nil)
        #expect(JSONValue.bool(true).doubleValue == nil)
        #expect(JSONValue.null.doubleValue == nil)
    }

    @Test func literal_double() {
        let value: JSONValue = 3.14
        #expect(value == .double(3.14))
    }

    @Test func literal_double_negative() {
        let value: JSONValue = -2.5
        #expect(value == .double(-2.5))
    }

    @Test func int_vs_double_distinctionPreserved() throws {
        // When we encode an int, it should decode back as int (no decimal point)
        let intValue: JSONValue = .int(42)
        let intData = try JSONEncoder().encode(intValue)
        let intJson = String(data: intData, encoding: .utf8)!
        #expect(intJson == "42", "Int should encode without decimal")

        // When we encode a double with decimal, it should stay double
        let doubleValue: JSONValue = .double(42.5)
        let doubleData = try JSONEncoder().encode(doubleValue)
        let doubleJson = String(data: doubleData, encoding: .utf8)!
        #expect(doubleJson == "42.5", "Double 42.5 should encode as '42.5'")
    }

    // MARK: - String Tests

    @Test func roundTrip_string() throws {
        let original: JSONValue = .string("hello")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func roundTrip_string_empty() throws {
        let original: JSONValue = .string("")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func roundTrip_string_unicode() throws {
        let original: JSONValue = .string("Hello, \u{1F600} World! \u{4E2D}\u{6587}")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func roundTrip_string_escapedChars() throws {
        let original: JSONValue = .string("Line1\nLine2\tTabbed\"Quoted\"\\Backslash")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(original == decoded)
    }

    @Test func encode_string_producesString() throws {
        let value: JSONValue = .string("hello")
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"hello\"")
    }

    @Test func encode_string_empty_producesString() throws {
        let value: JSONValue = .string("")
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"\"")
    }

    @Test func decode_string() throws {
        let json = "\"hello\""
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .string("hello"))
    }

    @Test func decode_string_empty() throws {
        let json = "\"\""
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .string(""))
    }

    @Test func decode_string_unicode() throws {
        let json = "\"Hello, \\u4e2d\\u6587\""
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == .string("Hello, \u{4E2D}\u{6587}"))
    }

    @Test func stringValue_returnsValue() {
        #expect(JSONValue.string("hello").stringValue == "hello")
        #expect(JSONValue.string("").stringValue == "")
    }

    @Test func stringValue_returnsNil_whenNotString() {
        #expect(JSONValue.int(42).stringValue == nil)
        #expect(JSONValue.double(3.14).stringValue == nil)
        #expect(JSONValue.bool(true).stringValue == nil)
        #expect(JSONValue.null.stringValue == nil)
    }

    @Test func literal_string() {
        let value: JSONValue = "hello"
        #expect(value == .string("hello"))
    }

    @Test func literal_string_empty() {
        let value: JSONValue = ""
        #expect(value == .string(""))
    }

    // MARK: - Encoding Format Verification (NOT synthesized format)

    @Test func encode_notSynthesizedFormat_bool() throws {
        // Synthesized would be: {"bool":{"_0":true}}
        // We want: true
        let value: JSONValue = .bool(true)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("bool"), "Should not use synthesized enum format")
        #expect(!json.contains("_0"), "Should not use synthesized enum format")
        #expect(json == "true")
    }

    @Test func encode_notSynthesizedFormat_string() throws {
        // Synthesized would be: {"string":{"_0":"hello"}}
        // We want: "hello"
        let value: JSONValue = .string("hello")
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("string"), "Should not use synthesized enum format")
        #expect(!json.contains("_0"), "Should not use synthesized enum format")
        #expect(json == "\"hello\"")
    }

    @Test func encode_notSynthesizedFormat_int() throws {
        // Synthesized would be: {"int":{"_0":42}}
        // We want: 42
        let value: JSONValue = .int(42)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("int"), "Should not use synthesized enum format")
        #expect(!json.contains("_0"), "Should not use synthesized enum format")
        #expect(json == "42")
    }

    // MARK: - Cross-type accessor tests

    @Test func accessors_returnNil_forNull() {
        let value: JSONValue = .null
        #expect(value.boolValue == nil)
        #expect(value.intValue == nil)
        #expect(value.doubleValue == nil)
        #expect(value.stringValue == nil)
        #expect(value.arrayValue == nil)
        #expect(value.objectValue == nil)
    }
}
