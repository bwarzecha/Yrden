import SwiftSyntax

/// Represents a parsed property from a struct declaration.
struct ParsedProperty {
    let name: String
    let type: ParsedType
    let isOptional: Bool
    let description: String?
    let constraints: [ParsedConstraint]
}

/// Constraints parsed from @Guide attributes.
/// These are converted to description text since most providers don't support JSON Schema constraints.
enum ParsedConstraint {
    case range(Int, Int)           // .range(min...max)
    case rangeDouble(Double, Double)
    case minimum(Int)              // .minimum(n)
    case maximum(Int)              // .maximum(n)
    case count(Int, Int)           // .count(min...max)
    case exactCount(Int)           // .exactCount(n)
    case options([String])         // .options(["a", "b"])
    case pattern(String)           // .pattern("^[a-z]+$")

    /// Human-readable description of the constraint for inclusion in schema description.
    var descriptionText: String {
        switch self {
        case .range(let min, let max):
            return "Must be between \(min) and \(max)"
        case .rangeDouble(let min, let max):
            return "Must be between \(min) and \(max)"
        case .minimum(let n):
            return "Must be at least \(n)"
        case .maximum(let n):
            return "Must be at most \(n)"
        case .count(let min, let max):
            return "Must have between \(min) and \(max) items"
        case .exactCount(let n):
            return "Must have exactly \(n) items"
        case .options(let opts):
            return "Must be one of: \(opts.joined(separator: ", "))"
        case .pattern(let regex):
            return "Must match pattern: \(regex)"
        }
    }
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

            // Extract @Guide description and constraints if present
            let (description, constraints) = extractGuideInfo(from: varDecl.attributes)

            return ParsedProperty(
                name: name,
                type: parsedType,
                isOptional: parsedType.isOptional,
                description: description,
                constraints: constraints
            )
        }
    }

    /// Extracts description and constraints from a @Guide attribute if present.
    /// - Parameter attributes: The attribute list from a variable declaration
    /// - Returns: Tuple of (description, constraints) from @Guide
    private static func extractGuideInfo(from attributes: AttributeListSyntax) -> (String?, [ParsedConstraint]) {
        for attribute in attributes {
            guard let attr = attribute.as(AttributeSyntax.self),
                  let identifier = attr.attributeName.as(IdentifierTypeSyntax.self),
                  identifier.name.text == "Guide",
                  case let .argumentList(arguments) = attr.arguments
            else {
                continue
            }

            var description: String?
            var constraints: [ParsedConstraint] = []

            for argument in arguments {
                // First argument with label "description" or no label is the description
                if argument.label?.text == "description" || (argument.label == nil && description == nil) {
                    if let stringLiteral = argument.expression.as(StringLiteralExprSyntax.self),
                       let segment = stringLiteral.segments.first,
                       case let .stringSegment(stringSegment) = segment {
                        description = stringSegment.content.text
                    }
                    continue
                }

                // Parse constraint expressions (e.g., .range(1...100))
                if let constraint = parseConstraint(from: argument.expression) {
                    constraints.append(constraint)
                }
            }

            return (description, constraints)
        }
        return (nil, [])
    }

    /// Parses a constraint expression like .range(1...100) or .options(["a", "b"])
    private static func parseConstraint(from expr: ExprSyntax) -> ParsedConstraint? {
        // Handle member access: .range(...), .options(...), etc.
        guard let functionCall = expr.as(FunctionCallExprSyntax.self),
              let memberAccess = functionCall.calledExpression.as(MemberAccessExprSyntax.self)
        else {
            return nil
        }

        let constraintName = memberAccess.declName.baseName.text
        let args = Array(functionCall.arguments)

        switch constraintName {
        case "range":
            // .range(1...100) - closed range
            if let firstArg = args.first?.expression,
               let rangeExpr = firstArg.as(SequenceExprSyntax.self) {
                return parseClosedRange(from: rangeExpr, isDouble: false)
            }
            return nil

        case "rangeDouble":
            // .rangeDouble(0.0...1.0)
            if let firstArg = args.first?.expression,
               let rangeExpr = firstArg.as(SequenceExprSyntax.self) {
                return parseClosedRange(from: rangeExpr, isDouble: true)
            }
            return nil

        case "minimum":
            // .minimum(1)
            if let firstArg = args.first?.expression,
               let intValue = parseIntLiteral(from: firstArg) {
                return .minimum(intValue)
            }
            return nil

        case "maximum":
            // .maximum(100)
            if let firstArg = args.first?.expression,
               let intValue = parseIntLiteral(from: firstArg) {
                return .maximum(intValue)
            }
            return nil

        case "count":
            // .count(1...10)
            if let firstArg = args.first?.expression,
               let rangeExpr = firstArg.as(SequenceExprSyntax.self),
               let constraint = parseClosedRange(from: rangeExpr, isDouble: false),
               case .range(let min, let max) = constraint {
                return .count(min, max)
            }
            return nil

        case "exactCount":
            // .exactCount(5)
            if let firstArg = args.first?.expression,
               let intValue = parseIntLiteral(from: firstArg) {
                return .exactCount(intValue)
            }
            return nil

        case "options":
            // .options(["a", "b", "c"])
            if let firstArg = args.first?.expression,
               let arrayExpr = firstArg.as(ArrayExprSyntax.self) {
                let options = arrayExpr.elements.compactMap { element -> String? in
                    if let stringLiteral = element.expression.as(StringLiteralExprSyntax.self),
                       let segment = stringLiteral.segments.first,
                       case let .stringSegment(stringSegment) = segment {
                        return stringSegment.content.text
                    }
                    return nil
                }
                if !options.isEmpty {
                    return .options(options)
                }
            }
            return nil

        case "pattern":
            // .pattern("^[a-z]+$")
            if let firstArg = args.first?.expression,
               let stringLiteral = firstArg.as(StringLiteralExprSyntax.self),
               let segment = stringLiteral.segments.first,
               case let .stringSegment(stringSegment) = segment {
                return .pattern(stringSegment.content.text)
            }
            return nil

        default:
            return nil
        }
    }

    /// Parses a closed range expression like 1...100
    private static func parseClosedRange(from expr: SequenceExprSyntax, isDouble: Bool) -> ParsedConstraint? {
        let elements = Array(expr.elements)
        guard elements.count == 3 else { return nil }

        // Middle element should be the ... operator
        guard let operatorExpr = elements[1].as(BinaryOperatorExprSyntax.self),
              operatorExpr.operator.text == "..."
        else {
            return nil
        }

        if isDouble {
            if let minValue = parseDoubleLiteral(from: elements[0]),
               let maxValue = parseDoubleLiteral(from: elements[2]) {
                return .rangeDouble(minValue, maxValue)
            }
        } else {
            if let minValue = parseIntLiteral(from: elements[0]),
               let maxValue = parseIntLiteral(from: elements[2]) {
                return .range(minValue, maxValue)
            }
        }

        return nil
    }

    /// Parses an integer literal from an expression
    private static func parseIntLiteral(from expr: ExprSyntax) -> Int? {
        if let intLiteral = expr.as(IntegerLiteralExprSyntax.self) {
            return Int(intLiteral.literal.text)
        }
        // Handle prefix operators like negative numbers
        if let prefixExpr = expr.as(PrefixOperatorExprSyntax.self),
           prefixExpr.operator.text == "-",
           let intLiteral = prefixExpr.expression.as(IntegerLiteralExprSyntax.self),
           let value = Int(intLiteral.literal.text) {
            return -value
        }
        return nil
    }

    /// Parses a double literal from an expression
    private static func parseDoubleLiteral(from expr: ExprSyntax) -> Double? {
        if let floatLiteral = expr.as(FloatLiteralExprSyntax.self) {
            return Double(floatLiteral.literal.text)
        }
        if let intLiteral = expr.as(IntegerLiteralExprSyntax.self) {
            return Double(intLiteral.literal.text)
        }
        // Handle prefix operators like negative numbers
        if let prefixExpr = expr.as(PrefixOperatorExprSyntax.self),
           prefixExpr.operator.text == "-" {
            if let floatLiteral = prefixExpr.expression.as(FloatLiteralExprSyntax.self),
               let value = Double(floatLiteral.literal.text) {
                return -value
            }
            if let intLiteral = prefixExpr.expression.as(IntegerLiteralExprSyntax.self),
               let value = Double(intLiteral.literal.text) {
                return -value
            }
        }
        return nil
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
