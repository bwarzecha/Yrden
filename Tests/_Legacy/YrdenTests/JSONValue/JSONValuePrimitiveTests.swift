import XCTest
@testable import Yrden

/// Phase 1 tests: null, bool, int, double, string primitives
/// Tests Codable round-trips, encoding format, accessors, and literal expressibility
final class JSONValuePrimitiveTests: XCTestCase {

    // MARK: - Null Tests

    func test_roundTrip_null() throws {
        let original: JSONValue = .null
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_encode_null_producesNull() throws {
        let value: JSONValue = .null
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, "null")
    }

    func test_decode_null() throws {
        let json = "null"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .null)
    }

    func test_literal_nil() {
        let value: JSONValue = nil
        XCTAssertEqual(value, .null)
    }

    // MARK: - Bool Tests

    func test_roundTrip_bool_true() throws {
        let original: JSONValue = .bool(true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_roundTrip_bool_false() throws {
        let original: JSONValue = .bool(false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_encode_bool_true_producesBool() throws {
        let value: JSONValue = .bool(true)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, "true")
    }

    func test_encode_bool_false_producesBool() throws {
        let value: JSONValue = .bool(false)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, "false")
    }

    func test_decode_bool_true() throws {
        let json = "true"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .bool(true))
    }

    func test_decode_bool_false() throws {
        let json = "false"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .bool(false))
    }

    func test_boolValue_returnsValue() {
        XCTAssertEqual(JSONValue.bool(true).boolValue, true)
        XCTAssertEqual(JSONValue.bool(false).boolValue, false)
    }

    func test_boolValue_returnsNil_whenNotBool() {
        XCTAssertNil(JSONValue.string("true").boolValue)
        XCTAssertNil(JSONValue.int(1).boolValue)
        XCTAssertNil(JSONValue.null.boolValue)
    }

    func test_literal_bool() {
        let trueValue: JSONValue = true
        let falseValue: JSONValue = false
        XCTAssertEqual(trueValue, .bool(true))
        XCTAssertEqual(falseValue, .bool(false))
    }

    // MARK: - Int Tests

    func test_roundTrip_int_positive() throws {
        let original: JSONValue = .int(42)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_roundTrip_int_negative() throws {
        let original: JSONValue = .int(-42)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_roundTrip_int_zero() throws {
        let original: JSONValue = .int(0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_roundTrip_int_max() throws {
        let original: JSONValue = .int(Int.max)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_roundTrip_int_min() throws {
        let original: JSONValue = .int(Int.min)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_encode_int_producesNumber() throws {
        let value: JSONValue = .int(42)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, "42")
    }

    func test_encode_int_negative_producesNumber() throws {
        let value: JSONValue = .int(-100)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, "-100")
    }

    func test_decode_int() throws {
        let json = "42"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .int(42))
    }

    func test_decode_int_negative() throws {
        let json = "-999"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .int(-999))
    }

    func test_intValue_returnsValue() {
        XCTAssertEqual(JSONValue.int(42).intValue, 42)
        XCTAssertEqual(JSONValue.int(-100).intValue, -100)
        XCTAssertEqual(JSONValue.int(0).intValue, 0)
    }

    func test_intValue_returnsNil_whenNotInt() {
        XCTAssertNil(JSONValue.string("42").intValue)
        XCTAssertNil(JSONValue.double(42.0).intValue)
        XCTAssertNil(JSONValue.bool(true).intValue)
        XCTAssertNil(JSONValue.null.intValue)
    }

    func test_literal_int() {
        let value: JSONValue = 42
        XCTAssertEqual(value, .int(42))
    }

    func test_literal_int_negative() {
        let value: JSONValue = -100
        XCTAssertEqual(value, .int(-100))
    }

    // MARK: - Double Tests

    func test_roundTrip_double() throws {
        let original: JSONValue = .double(3.14159)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_roundTrip_double_negative() throws {
        let original: JSONValue = .double(-2.718)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_roundTrip_double_zero() throws {
        let original: JSONValue = .double(0.0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        // Note: 0.0 might decode as int(0), so check for either
        if case .double(let val) = decoded {
            XCTAssertEqual(val, 0.0)
        } else if case .int(let val) = decoded {
            XCTAssertEqual(val, 0)
        } else {
            XCTFail("Expected double or int, got \(decoded)")
        }
    }

    func test_encode_double_producesNumber() throws {
        let value: JSONValue = .double(3.14)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.hasPrefix("3.14"), "Expected '3.14...' but got '\(json)'")
    }

    func test_decode_double() throws {
        let json = "3.14159"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .double(3.14159))
    }

    func test_decode_double_scientific() throws {
        // Use a value that results in a fractional number to ensure it decodes as double
        let json = "1.5e-2"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .double(0.015))
    }

    func test_decode_scientific_wholeNumber_decodesAsInt() throws {
        // Scientific notation that results in a whole number decodes as int (correct behavior)
        let json = "1.5e10"
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        // 1.5e10 = 15000000000 which is a valid Int, so we decode as int for precision
        XCTAssertEqual(value, .int(15_000_000_000))
    }

    func test_doubleValue_returnsValue() {
        XCTAssertEqual(JSONValue.double(3.14).doubleValue, 3.14)
        XCTAssertEqual(JSONValue.double(-2.5).doubleValue, -2.5)
    }

    func test_doubleValue_returnsNil_whenNotDouble() {
        XCTAssertNil(JSONValue.string("3.14").doubleValue)
        XCTAssertNil(JSONValue.int(3).doubleValue)
        XCTAssertNil(JSONValue.bool(true).doubleValue)
        XCTAssertNil(JSONValue.null.doubleValue)
    }

    func test_literal_double() {
        let value: JSONValue = 3.14
        XCTAssertEqual(value, .double(3.14))
    }

    func test_literal_double_negative() {
        let value: JSONValue = -2.5
        XCTAssertEqual(value, .double(-2.5))
    }

    func test_int_vs_double_distinctionPreserved() throws {
        // When we encode an int, it should decode back as int (no decimal point)
        let intValue: JSONValue = .int(42)
        let intData = try JSONEncoder().encode(intValue)
        let intJson = String(data: intData, encoding: .utf8)!
        XCTAssertEqual(intJson, "42", "Int should encode without decimal")

        // When we encode a double with decimal, it should stay double
        let doubleValue: JSONValue = .double(42.5)
        let doubleData = try JSONEncoder().encode(doubleValue)
        let doubleJson = String(data: doubleData, encoding: .utf8)!
        XCTAssertTrue(doubleJson.contains("."), "Double with fractional part should have decimal")
    }

    // MARK: - String Tests

    func test_roundTrip_string() throws {
        let original: JSONValue = .string("hello")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_roundTrip_string_empty() throws {
        let original: JSONValue = .string("")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_roundTrip_string_unicode() throws {
        let original: JSONValue = .string("Hello, \u{1F600} World! \u{4E2D}\u{6587}")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_roundTrip_string_escapedChars() throws {
        let original: JSONValue = .string("Line1\nLine2\tTabbed\"Quoted\"\\Backslash")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_encode_string_producesString() throws {
        let value: JSONValue = .string("hello")
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, "\"hello\"")
    }

    func test_encode_string_empty_producesString() throws {
        let value: JSONValue = .string("")
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, "\"\"")
    }

    func test_decode_string() throws {
        let json = "\"hello\""
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .string("hello"))
    }

    func test_decode_string_empty() throws {
        let json = "\"\""
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .string(""))
    }

    func test_decode_string_unicode() throws {
        let json = "\"Hello, \\u4e2d\\u6587\""
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .string("Hello, \u{4E2D}\u{6587}"))
    }

    func test_stringValue_returnsValue() {
        XCTAssertEqual(JSONValue.string("hello").stringValue, "hello")
        XCTAssertEqual(JSONValue.string("").stringValue, "")
    }

    func test_stringValue_returnsNil_whenNotString() {
        XCTAssertNil(JSONValue.int(42).stringValue)
        XCTAssertNil(JSONValue.double(3.14).stringValue)
        XCTAssertNil(JSONValue.bool(true).stringValue)
        XCTAssertNil(JSONValue.null.stringValue)
    }

    func test_literal_string() {
        let value: JSONValue = "hello"
        XCTAssertEqual(value, .string("hello"))
    }

    func test_literal_string_empty() {
        let value: JSONValue = ""
        XCTAssertEqual(value, .string(""))
    }

    // MARK: - Encoding Format Verification (NOT synthesized format)

    func test_encode_notSynthesizedFormat_bool() throws {
        // Synthesized would be: {"bool":{"_0":true}}
        // We want: true
        let value: JSONValue = .bool(true)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("bool"), "Should not use synthesized enum format")
        XCTAssertFalse(json.contains("_0"), "Should not use synthesized enum format")
        XCTAssertEqual(json, "true")
    }

    func test_encode_notSynthesizedFormat_string() throws {
        // Synthesized would be: {"string":{"_0":"hello"}}
        // We want: "hello"
        let value: JSONValue = .string("hello")
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("string"), "Should not use synthesized enum format")
        XCTAssertFalse(json.contains("_0"), "Should not use synthesized enum format")
        XCTAssertEqual(json, "\"hello\"")
    }

    func test_encode_notSynthesizedFormat_int() throws {
        // Synthesized would be: {"int":{"_0":42}}
        // We want: 42
        let value: JSONValue = .int(42)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("int"), "Should not use synthesized enum format")
        XCTAssertFalse(json.contains("_0"), "Should not use synthesized enum format")
        XCTAssertEqual(json, "42")
    }

    // MARK: - Cross-type accessor tests

    func test_accessors_returnNil_forNull() {
        let value: JSONValue = .null
        XCTAssertNil(value.boolValue)
        XCTAssertNil(value.intValue)
        XCTAssertNil(value.doubleValue)
        XCTAssertNil(value.stringValue)
        XCTAssertNil(value.arrayValue)
        XCTAssertNil(value.objectValue)
    }
}
