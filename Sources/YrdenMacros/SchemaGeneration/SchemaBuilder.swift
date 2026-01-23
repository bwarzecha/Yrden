import SwiftSyntax

/// Builds Swift source code that generates JSONValue schema literals.
struct SchemaBuilder {

    /// Generates the Swift code for a struct's jsonSchema property.
    /// - Parameters:
    ///   - typeName: Name of the struct
    ///   - properties: Parsed properties of the struct
    /// - Returns: Swift source code string for the jsonSchema computed property
    static func buildStructSchema(typeName: String, properties: [ParsedProperty]) -> String {
        let propertiesCode = buildPropertiesDict(properties)
        let requiredCode = buildRequiredArray(properties)

        return """
        static var jsonSchema: JSONValue {
            [
                "type": "object",
                "properties": \(propertiesCode),
                "required": \(requiredCode),
                "additionalProperties": false
            ]
        }
        """
    }

    /// Generates the Swift code for an enum's jsonSchema property.
    /// - Parameters:
    ///   - typeName: Name of the enum
    ///   - rawType: The raw type ("String" or "Int")
    ///   - cases: Array of (caseName, rawValue) tuples
    /// - Returns: Swift source code string for the jsonSchema computed property
    static func buildEnumSchema(
        typeName: String,
        rawType: String,
        cases: [(name: String, rawValue: String?)]
    ) -> String {
        let jsonType = rawType == "Int" ? "integer" : "string"

        // Build enum values array
        let enumValues: String
        if rawType == "Int" {
            // For Int enums, track raw values like Swift does:
            // - Start at 0 if no explicit value
            // - Continue from last explicit value + 1
            var nextValue = 0
            var values: [String] = []
            for enumCase in cases {
                if let rawValue = enumCase.rawValue {
                    values.append(rawValue)
                    // Update nextValue for subsequent cases
                    if let intValue = Int(rawValue) {
                        nextValue = intValue + 1
                    }
                } else {
                    values.append("\(nextValue)")
                    nextValue += 1
                }
            }
            enumValues = "[\(values.joined(separator: ", "))]"
        } else {
            // For String enums, use raw values or case names
            let values = cases.map { enumCase -> String in
                let value = enumCase.rawValue ?? enumCase.name
                // Remove quotes if already present, then add them
                let cleanValue = value.filter { $0 != "\"" }
                return "\"\(cleanValue)\""
            }
            enumValues = "[\(values.joined(separator: ", "))]"
        }

        return """
        static var jsonSchema: JSONValue {
            [
                "type": "\(jsonType)",
                "enum": \(enumValues)
            ]
        }
        """
    }

    // MARK: - Private Helpers

    /// Builds the "properties" dictionary code.
    private static func buildPropertiesDict(_ properties: [ParsedProperty]) -> String {
        if properties.isEmpty {
            return "[:]"
        }

        let entries = properties.map { property -> String in
            let schemaCode = buildTypeSchema(property.type)
            return "\"\(property.name)\": \(schemaCode)"
        }

        return "[\n                \(entries.joined(separator: ",\n                "))\n            ]"
    }

    /// Builds the "required" array code.
    private static func buildRequiredArray(_ properties: [ParsedProperty]) -> String {
        let required = properties
            .filter { !$0.isOptional }
            .map { "\"\($0.name)\"" }

        if required.isEmpty {
            return "[]"
        }

        return "[\(required.joined(separator: ", "))]"
    }

    /// Builds the schema code for a single type.
    private static func buildTypeSchema(_ type: ParsedType) -> String {
        switch type {
        case .primitive(let primitive):
            return "[\"type\": \"\(primitive.jsonSchemaType)\"]"

        case .array(let elementType):
            let itemsSchema = buildTypeSchema(elementType)
            return "[\"type\": \"array\", \"items\": \(itemsSchema)]"

        case .optional(let wrappedType):
            // Optional types have the same schema as their wrapped type
            return buildTypeSchema(wrappedType)

        case .schemaType(let typeName):
            // Reference another @Schema type's jsonSchema
            return "\(typeName).jsonSchema"

        case .unknown(let typeName):
            // Fall back to referencing as a schema type
            return "\(typeName).jsonSchema"
        }
    }
}
