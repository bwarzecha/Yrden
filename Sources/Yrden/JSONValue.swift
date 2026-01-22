import Foundation

/// Type-safe, Sendable, Codable enum for representing arbitrary JSON in Swift.
///
/// JSONValue provides a recursive enum representation of JSON that works with:
/// - Swift 6 concurrency (Sendable)
/// - Serialization (Codable)
/// - Value equality (Equatable, Hashable)
///
/// ## Use Cases
///
/// - JSON Schema representation for LLM structured outputs
/// - Tool argument parsing from LLM responses
/// - Arbitrary JSON data handling
///
/// ## Recommended Usage
///
/// **Always prefer `init(jsonData:)` when you have raw JSON bytes.** This is 4-5x faster
/// than the Codable path and should be used for all performance-critical code paths:
///
/// ```swift
/// // ✅ Fast path — use this for tool arguments, LLM responses, etc.
/// let args = try JSONValue(jsonData: toolCall.arguments.data(using: .utf8)!)
///
/// // ⚠️ Codable path — only when JSONValue is embedded in another Codable type
/// struct SomeType: Codable {
///     let schema: JSONValue  // Codable path used automatically
/// }
/// let value = try JSONDecoder().decode(SomeType.self, from: data)
/// ```
///
/// The Codable conformance exists for compatibility (Handoff, embedding in other types)
/// but has significant overhead (19-35x slower than JSONSerialization) due to Swift's
/// Decoder protocol limitations. See `init(from:)` documentation for details.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    indirect case array([JSONValue])
    indirect case object([String: JSONValue])
}

// MARK: - Custom Codable Implementation

extension JSONValue: Codable {
    /// Decodes a JSON value from any Decoder.
    ///
    /// ## Design Notes: The `try?` Cascade Pattern
    ///
    /// Swift's `Decoder` protocol provides no type inspection API — you cannot ask "what type is
    /// the next value?" before attempting to decode it. The only available operations are:
    /// - `decodeNil()` — returns `Bool`, doesn't throw (the only "peek" operation)
    /// - `decode(T.self)` — attempts decode, throws `DecodingError` on type mismatch
    ///
    /// This is a known Codable limitation: it was designed for **known schemas**, not heterogeneous
    /// JSON. As a result, decoding arbitrary JSON requires trying each type until one succeeds.
    ///
    /// ## Why This Order?
    ///
    /// 1. **null first** — `decodeNil()` is free (no throw), so always check it first
    /// 2. **bool before int** — Prevents `true`/`false` being coerced to `1`/`0` in some decoders
    /// 3. **int before double** — Preserves integer precision (e.g., `42` stays `Int`, not `42.0`)
    /// 4. **Primitives before containers** — Due to recursion, leaf values (strings, numbers, bools)
    ///    vastly outnumber containers. A JSON object with 10 string fields triggers 1 object decode
    ///    and 10 string decodes.
    ///
    /// ## Performance Considerations
    ///
    /// Each failed `try?` internally throws and catches a `DecodingError`. Benchmarks show this
    /// cascade adds significant overhead compared to `JSONSerialization`:
    ///
    /// ```
    /// Payload          JSONSerialization   Fast Path    Codable
    /// ─────────────────────────────────────────────────────────
    /// Small (5 fields)     0.002 ms        0.009 ms     0.034 ms (19x baseline)
    /// Medium (nested)      0.003 ms        0.021 ms     0.098 ms (29x baseline)
    /// Large (100 items)    0.086 ms        0.820 ms     3.055 ms (35x baseline)
    /// ```
    ///
    /// This overhead comes from:
    /// - Creating and catching `DecodingError` for each failed type attempt
    /// - JSONDecoder container setup overhead per value
    /// - Recursive application to every nested value
    ///
    /// Despite the overhead, this Codable implementation is kept for **compatibility** — it allows
    /// `JSONValue` to be embedded in other Codable types and works with any Decoder (not just JSON).
    ///
    /// **For performance-critical paths**, use `init(jsonData:)` which is 4-5x faster than Codable.
    ///
    /// This pattern is industry standard — used by Flight-School/AnyCodable, Mapbox, and Apple's
    /// internal swift-foundation code. There is no significantly better alternative within Codable.
    ///
    /// ## Alternatives Considered
    ///
    /// - **JSONSerialization first**: Decode to `Any`, then convert. Much faster (18-35x) but
    ///   Foundation-only. Implemented as `init(jsonData:)` for the fast path.
    /// - **Store numbers as strings**: Apple's internal approach. Avoids int/double ambiguity but
    ///   adds conversion overhead on every access.
    /// - **Reorder for LLM outputs**: Strings are most common in LLM structured outputs, but the
    ///   performance difference is marginal and the current order prioritizes correctness.
    ///
    /// See `JSONValueDecodingBenchmarkTests` for performance measurements.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // null: Free check (decodeNil returns Bool, doesn't throw)
        if container.decodeNil() {
            self = .null
            return
        }

        // bool: Must check before int to prevent true/false → 1/0 coercion
        if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
            return
        }

        // int: Check before double to preserve integer precision
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }

        // double: Remaining numeric values
        if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
            return
        }

        // string: Most common leaf type in practice
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }

        // array: Container type (less frequent than leaves due to recursion)
        if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
            return
        }

        // object: Container type
        if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
            return
        }

        throw DecodingError.typeMismatch(
            JSONValue.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unable to decode JSON value"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

// MARK: - Fast Path via JSONSerialization

extension JSONValue {
    /// Decodes JSON data using `JSONSerialization` — **the recommended initializer**.
    ///
    /// This is 4-5x faster than the Codable path and should be used for all hot paths:
    /// - Parsing LLM tool call arguments
    /// - Parsing structured output responses
    /// - Any code path where you have raw JSON `Data`
    ///
    /// The Codable conformance (`init(from:)`) exists only for compatibility when
    /// `JSONValue` is embedded in other Codable types (e.g., during Handoff serialization).
    ///
    /// - Parameter jsonData: Raw JSON data to decode.
    /// - Throws: `JSONValue.Error.unsupportedType` for non-JSON-compatible Foundation types,
    ///           or any error from `JSONSerialization`.
    public init(jsonData: Data) throws {
        let foundation = try JSONSerialization.jsonObject(with: jsonData, options: .fragmentsAllowed)
        try self.init(foundationValue: foundation)
    }

    /// Converts a Foundation JSON object (`Any` from `JSONSerialization`) to `JSONValue`.
    ///
    /// - Parameter foundationValue: A value from `JSONSerialization.jsonObject()`.
    /// - Throws: `JSONValue.Error.unsupportedType` if the value isn't JSON-compatible.
    public init(foundationValue: Any) throws {
        switch foundationValue {
        case is NSNull:
            self = .null
        case let bool as Bool:
            self = .bool(bool)
        case let int as Int:
            self = .int(int)
        case let double as Double:
            // Check if it's actually an integer stored as Double
            if double.truncatingRemainder(dividingBy: 1) == 0,
               double >= Double(Int.min), double <= Double(Int.max) {
                self = .int(Int(double))
            } else {
                self = .double(double)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(try array.map { try JSONValue(foundationValue: $0) })
        case let dict as [String: Any]:
            self = .object(try dict.mapValues { try JSONValue(foundationValue: $0) })
        default:
            throw Error.unsupportedType(String(describing: type(of: foundationValue)))
        }
    }

    /// Errors that can occur during JSON parsing.
    public enum Error: Swift.Error, CustomStringConvertible {
        case unsupportedType(String)

        public var description: String {
            switch self {
            case .unsupportedType(let type):
                return "Unsupported JSON type: \(type)"
            }
        }
    }
}

// MARK: - Type-Safe Accessors

extension JSONValue {
    /// Returns the Bool value if this is a `.bool` case, nil otherwise.
    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    /// Returns the Int value if this is an `.int` case, nil otherwise.
    public var intValue: Int? {
        guard case .int(let value) = self else { return nil }
        return value
    }

    /// Returns the Double value if this is a `.double` case, nil otherwise.
    public var doubleValue: Double? {
        guard case .double(let value) = self else { return nil }
        return value
    }

    /// Returns the String value if this is a `.string` case, nil otherwise.
    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// Returns the array if this is an `.array` case, nil otherwise.
    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    /// Returns the object dictionary if this is an `.object` case, nil otherwise.
    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

// MARK: - Subscript Accessors

extension JSONValue {
    /// Access object values by key. Returns nil if not an object or key doesn't exist.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    /// Access array values by index. Returns nil if not an array or index out of bounds.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let arr) = self, arr.indices.contains(index) else { return nil }
        return arr[index]
    }
}

// MARK: - Literal Expressibility

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
