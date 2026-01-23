import SwiftSyntax
import SwiftSyntaxMacros

public struct SchemaMacro: MemberMacro, ExtensionMacro {

    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // Handle struct declarations
        if let structDecl = declaration.as(StructDeclSyntax.self) {
            let typeName = structDecl.name.text
            let properties = TypeParser.parseStructMembers(from: structDecl)
            let schemaCode = SchemaBuilder.buildStructSchema(typeName: typeName, properties: properties)

            return [DeclSyntax(stringLiteral: schemaCode)]
        }

        // Handle enum declarations
        if let enumDecl = declaration.as(EnumDeclSyntax.self) {
            let typeName = enumDecl.name.text

            // Get raw type from inheritance clause
            guard let rawType = extractEnumRawType(from: enumDecl) else {
                throw SchemaError.enumRequiresRawType(typeName)
            }

            // Extract enum cases
            let cases = extractEnumCases(from: enumDecl)

            if cases.isEmpty {
                throw SchemaError.enumHasNoCases(typeName)
            }

            let schemaCode = SchemaBuilder.buildEnumSchema(
                typeName: typeName,
                rawType: rawType,
                cases: cases
            )

            return [DeclSyntax(stringLiteral: schemaCode)]
        }

        throw SchemaError.requiresStructOrEnum
    }

    // MARK: - ExtensionMacro

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let extensionDecl = try ExtensionDeclSyntax("extension \(type.trimmed): SchemaType {}")
        return [extensionDecl]
    }

    // MARK: - Enum Helpers

    /// Extracts the raw type (String or Int) from an enum's inheritance clause.
    private static func extractEnumRawType(from enumDecl: EnumDeclSyntax) -> String? {
        guard let inheritanceClause = enumDecl.inheritanceClause else {
            return nil
        }

        for inherited in inheritanceClause.inheritedTypes {
            if let identifierType = inherited.type.as(IdentifierTypeSyntax.self) {
                let typeName = identifierType.name.text
                if typeName == "String" || typeName == "Int" {
                    return typeName
                }
            }
        }

        return nil
    }

    /// Extracts case names and raw values from an enum declaration.
    private static func extractEnumCases(from enumDecl: EnumDeclSyntax) -> [(name: String, rawValue: String?)] {
        var cases: [(name: String, rawValue: String?)] = []

        for member in enumDecl.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else {
                continue
            }

            for element in caseDecl.elements {
                let name = element.name.text

                // Check for associated values (not supported)
                if element.parameterClause != nil {
                    continue // Skip cases with associated values
                }

                // Extract raw value if present
                var rawValue: String?
                if let rawValueClause = element.rawValue {
                    rawValue = rawValueClause.value.description.trimmingCharacters(in: .whitespaces)
                }

                cases.append((name: name, rawValue: rawValue))
            }
        }

        return cases
    }
}

// MARK: - Errors

enum SchemaError: Error, CustomStringConvertible {
    case requiresStructOrEnum
    case enumRequiresRawType(String)
    case enumHasNoCases(String)
    case unsupportedType(String)

    var description: String {
        switch self {
        case .requiresStructOrEnum:
            return "@Schema can only be applied to struct or enum declarations"
        case .enumRequiresRawType(let name):
            return "@Schema enum '\(name)' must have String or Int raw type"
        case .enumHasNoCases(let name):
            return "@Schema enum '\(name)' has no cases"
        case .unsupportedType(let type):
            return "Type '\(type)' is not supported by @Schema"
        }
    }
}
