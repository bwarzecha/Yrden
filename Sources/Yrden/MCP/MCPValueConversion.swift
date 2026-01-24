/// Conversion utilities between MCP `Value` and Yrden `JSONValue`.
///
/// The MCP SDK uses its own `Value` type for JSON representation,
/// while Yrden uses `JSONValue`. These extensions provide seamless conversion.

import Foundation
import MCP

// MARK: - MCP Value -> Yrden JSONValue

extension JSONValue {
    /// Convert from MCP `Value` to Yrden `JSONValue`.
    public init(mcpValue: MCP.Value) {
        switch mcpValue {
        case .null:
            self = .null
        case .bool(let b):
            self = .bool(b)
        case .int(let i):
            self = .int(i)
        case .double(let d):
            self = .double(d)
        case .string(let s):
            self = .string(s)
        case .data(_, let data):
            // Convert data to base64 string
            self = .string(data.base64EncodedString())
        case .array(let arr):
            self = .array(arr.map { JSONValue(mcpValue: $0) })
        case .object(let obj):
            self = .object(obj.mapValues { JSONValue(mcpValue: $0) })
        }
    }
}

// MARK: - Yrden JSONValue -> MCP Value

extension MCP.Value {
    /// Convert from Yrden `JSONValue` to MCP `Value`.
    public init(jsonValue: JSONValue) {
        switch jsonValue {
        case .null:
            self = .null
        case .bool(let b):
            self = .bool(b)
        case .int(let i):
            self = .int(i)
        case .double(let d):
            self = .double(d)
        case .string(let s):
            self = .string(s)
        case .array(let arr):
            self = .array(arr.map { MCP.Value(jsonValue: $0) })
        case .object(let obj):
            self = .object(obj.mapValues { MCP.Value(jsonValue: $0) })
        }
    }
}

// MARK: - Dictionary Conversion Helpers

extension Dictionary where Key == String, Value == MCP.Value {
    /// Convert MCP Value dictionary to JSONValue dictionary.
    public var asJSONValue: [String: JSONValue] {
        mapValues { JSONValue(mcpValue: $0) }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    /// Convert JSONValue dictionary to MCP Value dictionary.
    public var asMCPValue: [String: MCP.Value] {
        mapValues { MCP.Value(jsonValue: $0) }
    }
}
