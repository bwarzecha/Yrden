# Research: JSONValue Implementation

> Research findings and design recommendations for implementing JSONValue in Yrden.
> Date: 2026-01-22

---

## Executive Summary

The next implementation step is `JSONValue` - a recursive enum representing arbitrary JSON data. This document synthesizes research on existing Swift patterns, libraries, and best practices to inform our implementation.

**Key Recommendation**: Implement a custom `JSONValue` enum following the JSEN pattern, but tailored to our specific needs (Sendable, Codable, Equatable, convenience accessors for LLM use cases).

---

## Research Findings

### 1. Why Not `[String: Any]`?

The current `SchemaType` protocol uses `[String: Any]`:

```swift
public protocol SchemaType: Codable, Sendable {
    static var jsonSchema: [String: Any] { get }  // ❌ Problem
}
```

**Problems:**
- `Any` doesn't conform to `Codable` - can't serialize agent state
- `Any` doesn't conform to `Sendable` - not safe for Swift 6 concurrency
- No compile-time type safety - crashes at runtime on bad access
- No `Equatable` support - can't compare JSON values

**Sources:**
- [Swift by Sundell - Customizing Codable](https://www.swiftbysundell.com/articles/customizing-codable-types-in-swift/)
- [Adam Rackis - swift-codable-any](https://adamrackis.dev/blog/swift-codable-any)

### 2. JSEN Pattern (Industry Standard)

[JSEN](https://github.com/rogerluan/JSEN) (JSON Swift Enum Notation) is the established pattern for type-safe JSON in Swift:

```swift
public enum JSEN: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    indirect case array([JSEN])
    indirect case dictionary([String: JSEN])
}
```

**Key features:**
- `indirect` keyword for recursive types (arrays, objects)
- Native `Codable` support (Swift 5.5+ synthesizes it automatically)
- Includes `decode(as:)` utility for converting to typed structs

**Sources:**
- [JSEN GitHub](https://github.com/rogerluan/JSEN)
- [Swift Package Index - JSEN](https://swiftpackageindex.com/rogerluan/JSEN)

### 3. Swift 5.5+ Codable Synthesis for Enums

Swift 5.5 added automatic Codable synthesis for enums with associated values (SE-0295):

```swift
// Automatically Codable!
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    indirect case array([JSONValue])
    indirect case object([String: JSONValue])
}
```

**Default encoding:**
```json
// .string("hello") encodes to:
{"string": {"_0": "hello"}}

// Can customize with manual Codable implementation
```

**Sources:**
- [Hacking with Swift - Codable Enums](https://www.hackingwithswift.com/swift/5.5/codable-enums)
- [Sarunw - Codable synthesis for enums](https://sarunw.com/posts/codable-synthesis-for-enums-with-associated-values-in-swift/)

### 4. Existing Swift LLM Libraries Approach

**SwiftAI (mi12labs):**
- Uses `@Generable` macro for structured output
- Generates JSON Schema at compile time
- Uses typed Swift structs, not raw JSON values

**MacPaw/OpenAI:**
- Provides `JSONSchemaField` for type-safe schema building
- Uses `.dynamicJsonSchema(schema)` for runtime schemas
- Schema is `Codable`

**AnthropicSwiftSDK (fumito-ito):**
- Handles tool_use content blocks
- Uses typed Message structures
- JSON arguments as `String` (raw JSON)

**Observation:** Most libraries avoid raw JSON manipulation where possible, preferring typed structures. But all need some form of dynamic JSON for:
- Tool argument parsing
- Schema representation
- Structured output validation

### 5. Apple Foundation Models Framework

Apple's `@Generable` macro (iOS 26+) generates schemas at compile time:

```swift
@Generable
struct MovieInfo {
    @Guide(description: "The movie title")
    var title: String

    @Guide(description: "Release year", .range(1900...2100))
    var year: Int
}
```

**Key insight:** Apple made the schema exportable as JSON for use with MLX models, confirming the need for a JSON schema representation that can be:
1. Generated at compile time
2. Serialized to JSON
3. Sent to different providers

**Sources:**
- [Apple Foundation Models Documentation](https://developer.apple.com/documentation/FoundationModels)
- [WWDC25 - Meet the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2025/286/)

### 6. Provider API Requirements

Each provider needs JSON schemas in slightly different formats:

| Provider | Schema Location | Format |
|----------|-----------------|--------|
| Anthropic | `tools[].input_schema` | JSON Schema object |
| OpenAI | `response_format.json_schema.schema` | JSON Schema with `strict: true` |
| Bedrock | `toolConfig.tools[].toolSpec.inputSchema` | JSON Schema object |

All providers accept standard JSON Schema, so our `JSONValue` needs to:
1. Represent any valid JSON Schema
2. Serialize to JSON `Data` for HTTP requests
3. Be constructible from macro-generated code

**Sources:**
- [Anthropic Structured Outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs)
- [OpenAI Structured Outputs](https://platform.openai.com/docs/guides/structured-outputs)
- [AWS Bedrock Tool Use](https://docs.aws.amazon.com/bedrock/latest/userguide/tool-use.html)

---

## Design Recommendations

### Recommendation 1: Custom JSONValue Enum

```swift
/// Type-safe, Sendable, Codable JSON representation.
public enum JSONValue: Sendable, Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    indirect case array([JSONValue])
    indirect case object([String: JSONValue])
}
```

**Rationale:**
- Separate `int` and `double` cases for precision (unlike JSEN which uses only `Double`)
- `indirect` for recursive cases
- `Hashable` enables use as dictionary keys (useful for caching)
- Order: null, primitives, composites (logical grouping)

### Recommendation 2: Custom Codable Implementation

Don't rely on synthesized Codable (which wraps in `{"string": {"_0": value}}`).
Instead, encode/decode as actual JSON:

```swift
extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.typeMismatch(...)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}
```

### Recommendation 3: Convenience Accessors

For ergonomic access without force unwrapping:

```swift
extension JSONValue {
    // Type-safe accessors
    var stringValue: String? {
        guard case .string(let v) = self else { return nil }
        return v
    }

    var intValue: Int? { ... }
    var doubleValue: Double? { ... }
    var boolValue: Bool? { ... }
    var arrayValue: [JSONValue]? { ... }
    var objectValue: [String: JSONValue]? { ... }

    // Subscript for objects
    subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    // Subscript for arrays
    subscript(index: Int) -> JSONValue? {
        guard case .array(let arr) = self, arr.indices.contains(index) else { return nil }
        return arr[index]
    }
}
```

### Recommendation 4: Literal Expressibility

For clean test code and inline schemas:

```swift
extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
```

**Usage:**
```swift
let schema: JSONValue = [
    "type": "object",
    "properties": [
        "name": ["type": "string"],
        "age": ["type": "integer"]
    ],
    "required": ["name", "age"]
]
```

### Recommendation 5: Parsing Utilities

For working with raw JSON strings (e.g., tool arguments from LLM):

```swift
extension JSONValue {
    /// Parse from JSON string
    static func parse(_ json: String) throws -> JSONValue {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Convert to JSON string
    func toJSONString(prettyPrinted: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8)!
    }

    /// Decode to typed value
    func decode<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
```

---

## Implementation Plan

### File: `Sources/Yrden/JSONValue.swift`

```
JSONValue.swift (~150 lines)
├── JSONValue enum definition
├── Codable implementation (custom)
├── Equatable, Hashable (synthesized)
├── Convenience accessors (stringValue, etc.)
├── Subscript accessors
├── Literal expressibility extensions
└── Parsing utilities (parse, toJSONString, decode)
```

### File: `Tests/YrdenTests/JSONValueTests.swift`

```
JSONValueTests.swift (~200 lines)
├── Codable round-trip tests
│   ├── test_null_roundtrip
│   ├── test_bool_roundtrip
│   ├── test_int_roundtrip
│   ├── test_double_roundtrip
│   ├── test_string_roundtrip
│   ├── test_array_roundtrip
│   ├── test_object_roundtrip
│   └── test_nested_roundtrip
├── Equatable tests
├── Literal expressibility tests
├── Subscript accessor tests
├── Parsing tests
│   ├── test_parse_valid_json
│   ├── test_parse_invalid_json
│   └── test_parse_unicode
├── Edge cases
│   ├── test_empty_array
│   ├── test_empty_object
│   ├── test_deeply_nested
│   ├── test_large_numbers
│   └── test_special_characters
└── JSON Schema specific tests
    ├── test_encode_simple_schema
    └── test_encode_complex_schema
```

---

## Update to SchemaType Protocol

After implementing `JSONValue`, update the protocol:

```swift
// Before (current)
public protocol SchemaType: Codable, Sendable {
    static var jsonSchema: [String: Any] { get }  // ❌ Not Sendable
}

// After
public protocol SchemaType: Codable, Sendable {
    static var jsonSchema: JSONValue { get }  // ✅ Sendable + Codable
}
```

---

## Open Questions

1. **Int vs Number**: Should we distinguish `int` and `double`, or use a single `number(Double)` case?
   - **Recommendation**: Keep both for precision when dealing with integer IDs, counts, etc.
   - JSON Schema distinguishes `"type": "integer"` from `"type": "number"`

2. **Error handling in accessors**: Should `stringValue` etc. return `nil` or throw?
   - **Recommendation**: Return `nil` for optional chaining ergonomics
   - Add throwing variants if needed later

3. **CustomStringConvertible**: Should we implement pretty-print description?
   - **Recommendation**: Yes, useful for debugging

---

## References

### Swift Patterns
- [JSEN - JSON Swift Enum Notation](https://github.com/rogerluan/JSEN)
- [Swift by Sundell - Customizing Codable](https://www.swiftbysundell.com/articles/customizing-codable-types-in-swift/)
- [SE-0295 - Codable synthesis for enums](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0295-codable-synthesis-for-enums-with-associated-values.md)

### LLM Libraries
- [SwiftAI (mi12labs)](https://github.com/mi12labs/SwiftAI)
- [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI)
- [SwiftAnthropic](https://github.com/jamesrochabrun/SwiftAnthropic)
- [AnthropicSwiftSDK](https://github.com/fumito-ito/AnthropicSwiftSDK)

### Provider APIs
- [Anthropic Structured Outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs)
- [OpenAI Structured Outputs](https://platform.openai.com/docs/guides/structured-outputs)
- [AWS Bedrock Converse API](https://docs.aws.amazon.com/bedrock/latest/userguide/conversation-inference-call.html)
- [AWS SDK for Swift - Bedrock Examples](https://docs.aws.amazon.com/sdk-for-swift/latest/developer-guide/swift_bedrock-runtime_code_examples.html)

### Apple
- [Foundation Models Framework](https://developer.apple.com/documentation/FoundationModels)
- [WWDC25 - Meet Foundation Models](https://developer.apple.com/videos/play/wwdc2025/286/)

### PydanticAI
- [PydanticAI Models Overview](https://ai.pydantic.dev/models/overview/)
- [Model/Provider Architecture](https://deepwiki.com/pydantic/pydantic-ai/3.1-openai-models)
