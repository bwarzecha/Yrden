import SwiftSyntax

/// Builds Swift source code that generates JSONValue schema literals.
struct SchemaBuilder {

    /// Generates the Swift code for a struct's jsonSchema property.
    /// - Parameters:
    ///   - typeName: Name of the struct
    ///   - properties: Parsed properties of the struct
    ///   - description: Optional type-level description
    /// - Returns: Swift source code string for the jsonSchema computed property
    static func buildStructSchema(
        typeName: String,
        properties: [ParsedProperty],
        description: String? = nil
    ) -> String {
        let propertiesCode = buildPropertiesDict(properties)
        let requiredCode = buildRequiredArray(properties)

        var schemaEntries = [
            "\"type\": \"object\"",
        ]

        if let desc = description {
            schemaEntries.append("\"description\": \"\(escapeString(desc))\"")
        }

        schemaEntries.append("\"properties\": \(propertiesCode)")
        schemaEntries.append("\"required\": \(requiredCode)")
        schemaEntries.append("\"additionalProperties\": false")

        let schemaContent = schemaEntries.joined(separator: ",\n            ")

        return """
        static var jsonSchema: JSONValue {
            [
                \(schemaContent)
            ]
        }
        """
    }

    /// Generates the Swift code for an enum's jsonSchema property.
    /// - Parameters:
    ///   - typeName: Name of the enum
    ///   - rawType: The raw type ("String" or "Int")
    ///   - cases: Array of (caseName, rawValue) tuples
    ///   - description: Optional type-level description
    /// - Returns: Swift source code string for the jsonSchema computed property
    static func buildEnumSchema(
        typeName: String,
        rawType: String,
        cases: [(name: String, rawValue: String?)],
        description: String? = nil
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

        var schemaEntries = [
            "\"type\": \"\(jsonType)\"",
        ]

        if let desc = description {
            schemaEntries.append("\"description\": \"\(escapeString(desc))\"")
        }

        schemaEntries.append("\"enum\": \(enumValues)")

        let schemaContent = schemaEntries.joined(separator: ",\n            ")

        return """
        static var jsonSchema: JSONValue {
            [
                \(schemaContent)
            ]
        }
        """
    }

    // MARK: - Private Helpers

    /// Escapes special characters in strings for Swift string literals.
    private static func escapeString(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Builds the "properties" dictionary code.
    private static func buildPropertiesDict(_ properties: [ParsedProperty]) -> String {
        if properties.isEmpty {
            return "[:]"
        }

        let entries = properties.map { property -> String in
            let schemaCode = buildTypeSchema(
                property.type,
                description: property.description,
                constraints: property.constraints
            )
            return "\"\(property.name)\": \(schemaCode)"
        }

        return "[\n                \(entries.joined(separator: ",\n                "))\n            ]"
    }

    /// Combines description and constraints into a single description string.
    private static func buildFullDescription(
        description: String?,
        constraints: [ParsedConstraint]
    ) -> String? {
        var parts: [String] = []

        if let desc = description, !desc.isEmpty {
            parts.append(desc)
        }

        for constraint in constraints {
            parts.append(constraint.descriptionText)
        }

        return parts.isEmpty ? nil : parts.joined(separator: ". ")
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
    private static func buildTypeSchema(
        _ type: ParsedType,
        description: String? = nil,
        constraints: [ParsedConstraint] = []
    ) -> String {
        // Build description text (excludes .options since we use enum for that)
        let descriptionOnlyConstraints = constraints.filter {
            if case .options = $0 { return false }
            return true
        }
        let fullDescription = buildFullDescription(description: description, constraints: descriptionOnlyConstraints)

        // Extract enum values from .options constraint
        let enumValues: [String]? = constraints.compactMap { constraint -> [String]? in
            if case .options(let opts) = constraint { return opts }
            return nil
        }.first

        switch type {
        case .primitive(let primitive):
            return buildPrimitiveSchema(
                type: primitive.jsonSchemaType,
                description: fullDescription,
                enumValues: enumValues
            )

        case .array(let elementType):
            let itemsSchema = buildTypeSchema(elementType)
            if let desc = fullDescription {
                return "[\"type\": \"array\", \"description\": \"\(escapeString(desc))\", \"items\": \(itemsSchema)]"
            }
            return "[\"type\": \"array\", \"items\": \(itemsSchema)]"

        case .optional(let wrappedType):
            // Optional types have the same schema as their wrapped type
            return buildTypeSchema(wrappedType, description: description, constraints: constraints)

        case .schemaType(let typeName):
            // Reference another @Schema type's jsonSchema
            // Note: Can't add description to referenced schemas inline
            return "\(typeName).jsonSchema"

        case .unknown(let typeName):
            // Fall back to referencing as a schema type
            return "\(typeName).jsonSchema"
        }
    }

    /// Builds schema for primitive types with optional description and enum.
    private static func buildPrimitiveSchema(
        type: String,
        description: String?,
        enumValues: [String]?
    ) -> String {
        var parts: [String] = ["\"type\": \"\(type)\""]

        if let desc = description {
            parts.append("\"description\": \"\(escapeString(desc))\"")
        }

        if let values = enumValues {
            let enumArray = values.map { "\"\($0)\"" }.joined(separator: ", ")
            parts.append("\"enum\": [\(enumArray)]")
        }

        return "[\(parts.joined(separator: ", "))]"
    }
}
