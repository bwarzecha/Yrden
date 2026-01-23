import SwiftSyntax

/// Represents a parsed property from a struct declaration.
struct ParsedProperty {
    let name: String
    let type: ParsedType
    let isOptional: Bool
}

/// Represents a parsed Swift type for schema generation.
indirect enum ParsedType {
    case primitive(PrimitiveType)
    case array(ParsedType)
    case optional(ParsedType)
    case schemaType(String)  // Name of nested @Schema type
    case unknown(String)

    var isOptional: Bool {
        if case .optional = self { return true }
        return false
    }
}

/// Primitive types that map directly to JSON Schema types.
enum PrimitiveType: String {
    case string = "String"
    case int = "Int"
    case double = "Double"
    case bool = "Bool"

    /// JSON Schema type name for this primitive.
    var jsonSchemaType: String {
        switch self {
        case .string: return "string"
        case .int: return "integer"
        case .double: return "number"
        case .bool: return "boolean"
        }
    }
}

/// Parses struct members to extract property information.
struct TypeParser {

    /// Extracts stored properties from a struct declaration.
    /// - Parameter declaration: The struct declaration syntax
    /// - Returns: Array of parsed properties
    static func parseStructMembers(from declaration: StructDeclSyntax) -> [ParsedProperty] {
        declaration.memberBlock.members.compactMap { member -> ParsedProperty? in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  varDecl.bindingSpecifier.tokenKind == .keyword(.let) ||
                  varDecl.bindingSpecifier.tokenKind == .keyword(.var),
                  let binding = varDecl.bindings.first,
                  let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                  let typeAnnotation = binding.typeAnnotation
            else {
                return nil
            }

            // Skip computed properties (those with accessors)
            if binding.accessorBlock != nil {
                return nil
            }

            let name = identifier.identifier.text
            let parsedType = parseType(typeAnnotation.type)

            return ParsedProperty(
                name: name,
                type: parsedType,
                isOptional: parsedType.isOptional
            )
        }
    }

    /// Parses a type syntax node into a ParsedType.
    /// - Parameter typeSyntax: The type syntax to parse
    /// - Returns: The parsed type representation
    static func parseType(_ typeSyntax: TypeSyntax) -> ParsedType {
        // Handle optional types: T? or Optional<T>
        if let optionalType = typeSyntax.as(OptionalTypeSyntax.self) {
            let wrappedType = parseType(optionalType.wrappedType)
            return .optional(wrappedType)
        }

        // Handle implicitly unwrapped optionals: T!
        if let implicitOptional = typeSyntax.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            let wrappedType = parseType(implicitOptional.wrappedType)
            return .optional(wrappedType)
        }

        // Handle array types: [T]
        if let arrayType = typeSyntax.as(ArrayTypeSyntax.self) {
            let elementType = parseType(arrayType.element)
            return .array(elementType)
        }

        // Handle identifier types (String, Int, custom types, etc.)
        if let identifierType = typeSyntax.as(IdentifierTypeSyntax.self) {
            let typeName = identifierType.name.text

            // Check for primitive types
            if let primitive = PrimitiveType(rawValue: typeName) {
                return .primitive(primitive)
            }

            // Check for Optional<T> syntax
            if typeName == "Optional",
               let genericArgs = identifierType.genericArgumentClause,
               let firstArg = genericArgs.arguments.first {
                let wrappedType = parseType(firstArg.argument)
                return .optional(wrappedType)
            }

            // Check for Array<T> syntax
            if typeName == "Array",
               let genericArgs = identifierType.genericArgumentClause,
               let firstArg = genericArgs.arguments.first {
                let elementType = parseType(firstArg.argument)
                return .array(elementType)
            }

            // Assume it's a custom @Schema type
            return .schemaType(typeName)
        }

        // Unknown type - use description for error reporting
        return .unknown(typeSyntax.description.trimmingCharacters(in: .whitespaces))
    }
}
