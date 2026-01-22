/// Type-safe, Sendable, Codable enum for representing arbitrary JSON in Swift.
///
/// JSONValue provides a recursive enum representation of JSON that works with:
/// - Swift 6 concurrency (Sendable)
/// - Serialization (Codable)
/// - Value equality (Equatable, Hashable)
///
/// Use cases:
/// - JSON Schema representation for LLM structured outputs
/// - Tool argument parsing from LLM responses
/// - Arbitrary JSON data handling
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
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Check null first
        if container.decodeNil() {
            self = .null
            return
        }

        // Try bool before int (JSON bools must not be decoded as int)
        if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
            return
        }

        // Try int before double to preserve integer precision
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }

        // Try double
        if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
            return
        }

        // Try string
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }

        // Try array
        if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
            return
        }

        // Try object
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
