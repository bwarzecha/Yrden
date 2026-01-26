/// MCP Tool Helper Utilities
///
/// Provides helper functions for working with MCP tools:
/// - ToolInfo wrapper for SwiftUI compatibility
/// - Extracting parameter information from JSON Schema
/// - Parsing user input strings to MCP Value types
/// - Formatting tool results for display

import Foundation
import MCP

// MARK: - ToolInfo (SwiftUI-compatible MCP.Tool wrapper)

/// A SwiftUI-compatible wrapper around MCP.Tool.
///
/// Use this in SwiftUI views to display tools in Lists and ForEach.
///
/// ## Example
/// ```swift
/// let tools = try await server.listTools()
/// let toolInfos = tools.map { ToolInfo($0) }
///
/// List(toolInfos) { tool in
///     Text(tool.name)
///     if let desc = tool.description {
///         Text(desc).font(.caption)
///     }
/// }
/// ```
public struct ToolInfo: Identifiable, Sendable, Equatable {
    /// Unique identifier (tool name).
    public let id: String

    /// The underlying MCP tool.
    public let tool: MCP.Tool

    // Equatable based on tool name (unique within a server)
    public static func == (lhs: ToolInfo, rhs: ToolInfo) -> Bool {
        lhs.id == rhs.id
    }

    /// Create a ToolInfo wrapper.
    ///
    /// - Parameter tool: The MCP tool to wrap
    public init(_ tool: MCP.Tool) {
        self.id = tool.name
        self.tool = tool
    }

    /// Tool name.
    public var name: String { tool.name }

    /// Tool description (optional).
    public var description: String? { tool.description }

    /// Input schema for the tool's parameters.
    public var inputSchema: Value { tool.inputSchema }

    /// Extract parameter information from the input schema.
    public var parameters: [MCPParameterInfo] {
        extractMCPParameters(from: inputSchema)
    }
}

// MARK: - Parameter Extraction

/// Information about a tool parameter extracted from JSON Schema.
public struct MCPParameterInfo: Sendable {
    /// Parameter name (key in properties object).
    public let name: String

    /// JSON Schema type (string, integer, number, boolean, array, object).
    public let type: String

    /// Human-readable description from schema.
    public let description: String?

    /// Whether this parameter is required.
    public let isRequired: Bool

    /// Allowed enum values (if specified in schema).
    public let enumValues: [String]?

    /// Default value (if specified in schema).
    public let defaultValue: Value?

    public init(
        name: String,
        type: String,
        description: String? = nil,
        isRequired: Bool = false,
        enumValues: [String]? = nil,
        defaultValue: Value? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
        self.enumValues = enumValues
        self.defaultValue = defaultValue
    }
}

/// Extract parameter information from a JSON Schema object.
///
/// Parses the `properties` and `required` fields of a JSON Schema
/// to extract parameter metadata.
///
/// ## Example
/// ```swift
/// let tool: MCP.Tool = ...
/// let params = extractParameters(from: tool.inputSchema)
/// for param in params {
///     print("\(param.name): \(param.type) - \(param.description ?? "")")
/// }
/// ```
///
/// - Parameter schema: MCP Value representing a JSON Schema object
/// - Returns: Array of parameter info, sorted by required first then alphabetically
public func extractMCPParameters(from schema: Value) -> [MCPParameterInfo] {
    guard case .object(let obj) = schema,
          case .object(let properties)? = obj["properties"] else {
        return []
    }

    // Extract required field names
    var requiredFields: Set<String> = []
    if case .array(let required)? = obj["required"] {
        for item in required {
            if case .string(let name) = item {
                requiredFields.insert(name)
            }
        }
    }

    // Build parameter info array
    var params: [MCPParameterInfo] = []
    for (name, value) in properties {
        guard case .object(let propObj) = value else { continue }

        // Extract type
        var type = "string"
        if case .string(let t)? = propObj["type"] {
            type = t
        }

        // Extract description
        var description: String? = nil
        if case .string(let d)? = propObj["description"] {
            description = d
        }

        // Extract enum values
        var enumValues: [String]? = nil
        if case .array(let enumArr)? = propObj["enum"] {
            enumValues = enumArr.compactMap { value -> String? in
                switch value {
                case .string(let s): return s
                case .int(let i): return String(i)
                case .double(let d): return String(d)
                case .bool(let b): return String(b)
                default: return nil
                }
            }
        }

        // Extract default value
        let defaultValue = propObj["default"]

        params.append(MCPParameterInfo(
            name: name,
            type: type,
            description: description,
            isRequired: requiredFields.contains(name),
            enumValues: enumValues,
            defaultValue: defaultValue
        ))
    }

    // Sort: required first, then alphabetically
    return params.sorted { a, b in
        if a.isRequired != b.isRequired { return a.isRequired }
        return a.name < b.name
    }
}

// MARK: - User Input Parsing

extension Value {
    /// Parse a user input string into an MCP Value.
    ///
    /// Attempts to detect the appropriate type:
    /// 1. Empty string → returns nil (parameter should be omitted)
    /// 2. JSON object/array → parses as JSON
    /// 3. Integer → .int
    /// 4. Decimal number → .double
    /// 5. "true"/"false" → .bool
    /// 6. Otherwise → .string
    ///
    /// ## Example
    /// ```swift
    /// let value = Value.from(userInput: "42")      // .int(42)
    /// let value = Value.from(userInput: "3.14")    // .double(3.14)
    /// let value = Value.from(userInput: "true")    // .bool(true)
    /// let value = Value.from(userInput: "[1,2,3]") // .array([...])
    /// let value = Value.from(userInput: "hello")   // .string("hello")
    /// ```
    ///
    /// - Parameter input: User-provided string value
    /// - Returns: Parsed Value, or nil if input is empty
    public static func from(userInput input: String) -> Value? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        // Empty string means omit this parameter
        if trimmed.isEmpty {
            return nil
        }

        // Try parsing as JSON object or array
        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
           let data = trimmed.data(using: .utf8),
           let jsonValue = try? JSONDecoder().decode(Value.self, from: data) {
            return jsonValue
        }

        // Try parsing as integer
        if let intVal = Int(trimmed) {
            return .int(intVal)
        }

        // Try parsing as double
        if let doubleVal = Double(trimmed) {
            return .double(doubleVal)
        }

        // Try parsing as boolean
        switch trimmed.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: break
        }

        // Default to string
        return .string(trimmed)
    }

    /// Parse a user input string with a type hint from the schema.
    ///
    /// Uses the schema type to guide parsing, which is more accurate
    /// than pure inference.
    ///
    /// - Parameters:
    ///   - input: User-provided string value
    ///   - schemaType: Expected type from JSON Schema (string, integer, number, boolean, array, object)
    /// - Returns: Parsed Value, or nil if input is empty
    public static func from(userInput input: String, schemaType: String) -> Value? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            return nil
        }

        switch schemaType {
        case "integer":
            if let intVal = Int(trimmed) {
                return .int(intVal)
            }
            // Fall back to string if parsing fails
            return .string(trimmed)

        case "number":
            if let doubleVal = Double(trimmed) {
                return .double(doubleVal)
            }
            return .string(trimmed)

        case "boolean":
            switch trimmed.lowercased() {
            case "true", "1", "yes": return .bool(true)
            case "false", "0", "no": return .bool(false)
            default: return .string(trimmed)
            }

        case "array", "object":
            if let data = trimmed.data(using: .utf8),
               let jsonValue = try? JSONDecoder().decode(Value.self, from: data) {
                return jsonValue
            }
            // Fall back to string
            return .string(trimmed)

        default:
            // "string" or unknown type - just use the string
            return .string(trimmed)
        }
    }
}

// MARK: - Tool Result Formatting

/// Format MCP tool result content as a human-readable string.
///
/// Converts the array of Tool.Content items to a single string
/// suitable for display.
///
/// ## Example
/// ```swift
/// let (content, isError) = try await server.callTool(name: "read_file", arguments: [...])
/// let displayText = formatMCPToolResult(content, isError: isError)
/// print(displayText)
/// ```
///
/// - Parameters:
///   - content: Array of Tool.Content items from tool execution
///   - isError: Whether the tool returned an error
/// - Returns: Formatted string for display
public func formatMCPToolResult(_ content: [MCP.Tool.Content], isError: Bool?) -> String {
    // Map each content item to its string representation
    let parts = content.map { item -> String in
        switch item {
        case .text(let text):
            return text
        case .image(let data, let mimeType, _):
            return "[Image: \(mimeType), \(data.count) bytes]"
        case .audio(let data, let mimeType):
            return "[Audio: \(mimeType), \(data.count) bytes]"
        case .resource(let uri, let mimeType, let text):
            if let text = text {
                return text
            } else {
                return "[Resource: \(uri), \(mimeType)]"
            }
        }
    }

    // Join with newlines
    var result = parts.joined(separator: "\n")

    // Handle empty result
    if result.isEmpty {
        result = "(empty result)"
    }

    // Prefix with ERROR if flagged
    if let isError = isError, isError {
        result = "ERROR:\n\(result)"
    }

    return result
}

// MARK: - Argument Parsing

/// Result of parsing MCP tool arguments.
public enum MCPArgumentsResult: Sendable {
    case success([String: MCP.Value]?)
    case error(ToolExecutionError)
}

/// Parse JSON arguments string to MCP Value dictionary.
///
/// Used by both MCPTool and MCPToolProxy to convert LLM-provided
/// JSON arguments to the format expected by MCP tools.
///
/// ## Example
/// ```swift
/// switch parseMCPArguments(argumentsJSON) {
/// case .success(let args):
///     // Use args with MCP client
/// case .error(let error):
///     return .failure(error)
/// }
/// ```
///
/// - Parameter argumentsJSON: JSON string from LLM
/// - Returns: Parsed arguments or error
public func parseMCPArguments(_ argumentsJSON: String) -> MCPArgumentsResult {
    // Empty or empty object means no arguments
    if argumentsJSON.isEmpty || argumentsJSON == "{}" {
        return .success(nil)
    }

    // Validate UTF-8
    guard let data = argumentsJSON.data(using: .utf8) else {
        return .error(ToolExecutionError.argumentParsing("Invalid UTF-8 in arguments"))
    }

    // Parse as JSON
    do {
        let jsonValue = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let obj) = jsonValue else {
            return .error(ToolExecutionError.argumentParsing("Arguments must be a JSON object"))
        }
        return .success(obj.asMCPValue)
    } catch {
        return .error(ToolExecutionError.argumentParsing(error.localizedDescription))
    }
}
