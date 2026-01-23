import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import YrdenMacros

// MARK: - Test Macros Dictionary

let testMacros: [String: Macro.Type] = [
    "Schema": SchemaMacro.self,
    "Guide": GuideMacro.self,
]

// MARK: - Basic Struct Tests

@Suite("Schema Macro - Basic Structs")
struct SchemaBasicStructTests {

    @Test("Empty struct generates empty properties")
    func emptyStruct() {
        assertMacroExpansion(
            """
            @Schema
            struct Empty {
            }
            """,
            expandedSource: """
            struct Empty {

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [:],
                        "required": [],
                        "additionalProperties": false
                    ]
                }
            }

            extension Empty: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Struct with String property")
    func stringProperty() {
        assertMacroExpansion(
            """
            @Schema
            struct Person {
                let name: String
            }
            """,
            expandedSource: """
            struct Person {
                let name: String

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"]
                        ],
                        "required": ["name"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Person: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Struct with Int property")
    func intProperty() {
        assertMacroExpansion(
            """
            @Schema
            struct User {
                let age: Int
            }
            """,
            expandedSource: """
            struct User {
                let age: Int

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "age": ["type": "integer"]
                        ],
                        "required": ["age"],
                        "additionalProperties": false
                    ]
                }
            }

            extension User: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Struct with all primitive types")
    func allPrimitiveTypes() {
        assertMacroExpansion(
            """
            @Schema
            struct AllTypes {
                let text: String
                let count: Int
                let score: Double
                let active: Bool
            }
            """,
            expandedSource: """
            struct AllTypes {
                let text: String
                let count: Int
                let score: Double
                let active: Bool

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "count": ["type": "integer"],
                            "score": ["type": "number"],
                            "active": ["type": "boolean"]
                        ],
                        "required": ["text", "count", "score", "active"],
                        "additionalProperties": false
                    ]
                }
            }

            extension AllTypes: SchemaType {
            }
            """,
            macros: testMacros
        )
    }
}

// MARK: - Optional Type Tests

@Suite("Schema Macro - Optional Types")
struct SchemaOptionalTests {

    @Test("Optional property not in required array")
    func optionalProperty() {
        assertMacroExpansion(
            """
            @Schema
            struct User {
                let name: String
                let nickname: String?
            }
            """,
            expandedSource: """
            struct User {
                let name: String
                let nickname: String?

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "nickname": ["type": "string"]
                        ],
                        "required": ["name"],
                        "additionalProperties": false
                    ]
                }
            }

            extension User: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("All optional properties")
    func allOptionalProperties() {
        assertMacroExpansion(
            """
            @Schema
            struct Config {
                let timeout: Int?
                let retries: Int?
            }
            """,
            expandedSource: """
            struct Config {
                let timeout: Int?
                let retries: Int?

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "timeout": ["type": "integer"],
                            "retries": ["type": "integer"]
                        ],
                        "required": [],
                        "additionalProperties": false
                    ]
                }
            }

            extension Config: SchemaType {
            }
            """,
            macros: testMacros
        )
    }
}

// MARK: - Array Type Tests

@Suite("Schema Macro - Array Types")
struct SchemaArrayTests {

    @Test("Array of strings")
    func arrayOfStrings() {
        assertMacroExpansion(
            """
            @Schema
            struct Tags {
                let items: [String]
            }
            """,
            expandedSource: """
            struct Tags {
                let items: [String]

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "items": ["type": "array", "items": ["type": "string"]]
                        ],
                        "required": ["items"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Tags: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Array of integers")
    func arrayOfIntegers() {
        assertMacroExpansion(
            """
            @Schema
            struct Numbers {
                let values: [Int]
            }
            """,
            expandedSource: """
            struct Numbers {
                let values: [Int]

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "values": ["type": "array", "items": ["type": "integer"]]
                        ],
                        "required": ["values"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Numbers: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Optional array")
    func optionalArray() {
        assertMacroExpansion(
            """
            @Schema
            struct Data {
                let tags: [String]?
            }
            """,
            expandedSource: """
            struct Data {
                let tags: [String]?

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "tags": ["type": "array", "items": ["type": "string"]]
                        ],
                        "required": [],
                        "additionalProperties": false
                    ]
                }
            }

            extension Data: SchemaType {
            }
            """,
            macros: testMacros
        )
    }
}

// MARK: - Enum Tests

@Suite("Schema Macro - Enums")
struct SchemaEnumTests {

    @Test("String enum")
    func stringEnum() {
        assertMacroExpansion(
            """
            @Schema
            enum Status: String {
                case pending
                case active
                case completed
            }
            """,
            expandedSource: """
            enum Status: String {
                case pending
                case active
                case completed

                static var jsonSchema: JSONValue {
                    [
                        "type": "string",
                        "enum": ["pending", "active", "completed"]
                    ]
                }
            }

            extension Status: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("String enum with explicit raw values")
    func stringEnumWithRawValues() {
        assertMacroExpansion(
            """
            @Schema
            enum Priority: String {
                case low = "LOW"
                case medium = "MEDIUM"
                case high = "HIGH"
            }
            """,
            expandedSource: """
            enum Priority: String {
                case low = "LOW"
                case medium = "MEDIUM"
                case high = "HIGH"

                static var jsonSchema: JSONValue {
                    [
                        "type": "string",
                        "enum": ["LOW", "MEDIUM", "HIGH"]
                    ]
                }
            }

            extension Priority: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Int enum")
    func intEnum() {
        assertMacroExpansion(
            """
            @Schema
            enum Level: Int {
                case low
                case medium
                case high
            }
            """,
            expandedSource: """
            enum Level: Int {
                case low
                case medium
                case high

                static var jsonSchema: JSONValue {
                    [
                        "type": "integer",
                        "enum": [0, 1, 2]
                    ]
                }
            }

            extension Level: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Int enum with explicit raw values")
    func intEnumWithRawValues() {
        assertMacroExpansion(
            """
            @Schema
            enum ErrorCode: Int {
                case notFound = 404
                case serverError = 500
            }
            """,
            expandedSource: """
            enum ErrorCode: Int {
                case notFound = 404
                case serverError = 500

                static var jsonSchema: JSONValue {
                    [
                        "type": "integer",
                        "enum": [404, 500]
                    ]
                }
            }

            extension ErrorCode: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Int enum with mixed explicit and implicit raw values")
    func intEnumMixedRawValues() {
        // Swift continues from the last explicit value
        assertMacroExpansion(
            """
            @Schema
            enum Rating: Int {
                case terrible = 1
                case bad
                case okay
                case good = 10
                case excellent
            }
            """,
            expandedSource: """
            enum Rating: Int {
                case terrible = 1
                case bad
                case okay
                case good = 10
                case excellent

                static var jsonSchema: JSONValue {
                    [
                        "type": "integer",
                        "enum": [1, 2, 3, 10, 11]
                    ]
                }
            }

            extension Rating: SchemaType {
            }
            """,
            macros: testMacros
        )
    }
}

// MARK: - Nested Type Tests

@Suite("Schema Macro - Nested Types")
struct SchemaNestedTests {

    @Test("Struct with nested schema type")
    func nestedSchemaType() {
        assertMacroExpansion(
            """
            @Schema
            struct Person {
                let name: String
                let address: Address
            }
            """,
            expandedSource: """
            struct Person {
                let name: String
                let address: Address

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "address": Address.jsonSchema
                        ],
                        "required": ["name", "address"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Person: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Array of nested schema type")
    func arrayOfNestedType() {
        assertMacroExpansion(
            """
            @Schema
            struct Order {
                let items: [OrderItem]
            }
            """,
            expandedSource: """
            struct Order {
                let items: [OrderItem]

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "items": ["type": "array", "items": OrderItem.jsonSchema]
                        ],
                        "required": ["items"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Order: SchemaType {
            }
            """,
            macros: testMacros
        )
    }
}

// MARK: - Description Tests

@Suite("Schema Macro - Descriptions")
struct SchemaDescriptionTests {

    @Test("Struct with type-level description")
    func structWithDescription() {
        assertMacroExpansion(
            """
            @Schema(description: "A user in the system")
            struct User {
                let name: String
            }
            """,
            expandedSource: """
            struct User {
                let name: String

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "description": "A user in the system",
                        "properties": [
                            "name": ["type": "string"]
                        ],
                        "required": ["name"],
                        "additionalProperties": false
                    ]
                }
            }

            extension User: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Enum with type-level description")
    func enumWithDescription() {
        assertMacroExpansion(
            """
            @Schema(description: "Current status of the task")
            enum Status: String {
                case pending
                case done
            }
            """,
            expandedSource: """
            enum Status: String {
                case pending
                case done

                static var jsonSchema: JSONValue {
                    [
                        "type": "string",
                        "description": "Current status of the task",
                        "enum": ["pending", "done"]
                    ]
                }
            }

            extension Status: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Property with @Guide description")
    func propertyWithGuideDescription() {
        assertMacroExpansion(
            """
            @Schema
            struct SearchQuery {
                @Guide(description: "The search terms")
                let query: String
            }
            """,
            expandedSource: """
            struct SearchQuery {
                let query: String

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "query": ["type": "string", "description": "The search terms"]
                        ],
                        "required": ["query"],
                        "additionalProperties": false
                    ]
                }
            }

            extension SearchQuery: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Multiple properties with @Guide descriptions")
    func multiplePropertiesWithGuide() {
        assertMacroExpansion(
            """
            @Schema(description: "Search parameters")
            struct SearchParams {
                @Guide(description: "Search terms to look for")
                let query: String

                @Guide(description: "Maximum number of results")
                let limit: Int

                let includeArchived: Bool
            }
            """,
            expandedSource: """
            struct SearchParams {
                let query: String

                let limit: Int

                let includeArchived: Bool

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "description": "Search parameters",
                        "properties": [
                            "query": ["type": "string", "description": "Search terms to look for"],
                            "limit": ["type": "integer", "description": "Maximum number of results"],
                            "includeArchived": ["type": "boolean"]
                        ],
                        "required": ["query", "limit", "includeArchived"],
                        "additionalProperties": false
                    ]
                }
            }

            extension SearchParams: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Description with special characters escaped")
    func descriptionWithSpecialCharacters() {
        assertMacroExpansion(
            #"""
            @Schema(description: "Contains \"quotes\" and backslash\\")
            struct Test {
                let value: String
            }
            """#,
            expandedSource: #"""
            struct Test {
                let value: String

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "description": "Contains \"quotes\" and backslash\\",
                        "properties": [
                            "value": ["type": "string"]
                        ],
                        "required": ["value"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Test: SchemaType {
            }
            """#,
            macros: testMacros
        )
    }

    @Test("@Guide on array property")
    func guideOnArrayProperty() {
        assertMacroExpansion(
            """
            @Schema
            struct TaggedItem {
                @Guide(description: "List of tags")
                let tags: [String]
            }
            """,
            expandedSource: """
            struct TaggedItem {
                let tags: [String]

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "tags": ["type": "array", "description": "List of tags", "items": ["type": "string"]]
                        ],
                        "required": ["tags"],
                        "additionalProperties": false
                    ]
                }
            }

            extension TaggedItem: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("@Guide on optional property")
    func guideOnOptionalProperty() {
        assertMacroExpansion(
            """
            @Schema
            struct Profile {
                @Guide(description: "User's biography")
                let bio: String?
            }
            """,
            expandedSource: """
            struct Profile {
                let bio: String?

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "bio": ["type": "string", "description": "User's biography"]
                        ],
                        "required": [],
                        "additionalProperties": false
                    ]
                }
            }

            extension Profile: SchemaType {
            }
            """,
            macros: testMacros
        )
    }
}

// MARK: - Constraint Tests

@Suite("Schema Macro - Constraints")
struct SchemaConstraintTests {

    @Test("@Guide with .range constraint")
    func guideWithRangeConstraint() {
        assertMacroExpansion(
            """
            @Schema
            struct Pagination {
                @Guide(description: "Results per page", .range(1...100))
                let limit: Int
            }
            """,
            expandedSource: """
            struct Pagination {
                let limit: Int

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "limit": ["type": "integer", "description": "Results per page. Must be between 1 and 100"]
                        ],
                        "required": ["limit"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Pagination: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("@Guide with .minimum constraint")
    func guideWithMinimumConstraint() {
        assertMacroExpansion(
            """
            @Schema
            struct Counter {
                @Guide(description: "Count value", .minimum(0))
                let count: Int
            }
            """,
            expandedSource: """
            struct Counter {
                let count: Int

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "count": ["type": "integer", "description": "Count value. Must be at least 0"]
                        ],
                        "required": ["count"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Counter: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("@Guide with .maximum constraint")
    func guideWithMaximumConstraint() {
        assertMacroExpansion(
            """
            @Schema
            struct Percentage {
                @Guide(description: "Percentage value", .maximum(100))
                let value: Int
            }
            """,
            expandedSource: """
            struct Percentage {
                let value: Int

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "value": ["type": "integer", "description": "Percentage value. Must be at most 100"]
                        ],
                        "required": ["value"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Percentage: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("@Guide with .count constraint on array")
    func guideWithCountConstraint() {
        assertMacroExpansion(
            """
            @Schema
            struct Tags {
                @Guide(description: "List of tags", .count(1...10))
                let items: [String]
            }
            """,
            expandedSource: """
            struct Tags {
                let items: [String]

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "items": ["type": "array", "description": "List of tags. Must have between 1 and 10 items", "items": ["type": "string"]]
                        ],
                        "required": ["items"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Tags: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("@Guide with .exactCount constraint")
    func guideWithExactCountConstraint() {
        assertMacroExpansion(
            """
            @Schema
            struct Coordinates {
                @Guide(description: "XYZ coordinates", .exactCount(3))
                let values: [Double]
            }
            """,
            expandedSource: """
            struct Coordinates {
                let values: [Double]

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "values": ["type": "array", "description": "XYZ coordinates. Must have exactly 3 items", "items": ["type": "number"]]
                        ],
                        "required": ["values"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Coordinates: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("@Guide with .options constraint generates enum")
    func guideWithOptionsConstraint() {
        assertMacroExpansion(
            """
            @Schema
            struct SortConfig {
                @Guide(description: "Sort order", .options(["asc", "desc"]))
                let order: String
            }
            """,
            expandedSource: """
            struct SortConfig {
                let order: String

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "order": ["type": "string", "description": "Sort order", "enum": ["asc", "desc"]]
                        ],
                        "required": ["order"],
                        "additionalProperties": false
                    ]
                }
            }

            extension SortConfig: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("@Guide with .pattern constraint")
    func guideWithPatternConstraint() {
        assertMacroExpansion(
            #"""
            @Schema
            struct Email {
                @Guide(description: "Email address", .pattern("^[a-z]+@[a-z]+\\.[a-z]+$"))
                let address: String
            }
            """#,
            expandedSource: #"""
            struct Email {
                let address: String

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "address": ["type": "string", "description": "Email address. Must match pattern: ^[a-z]+@[a-z]+\\.[a-z]+$"]
                        ],
                        "required": ["address"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Email: SchemaType {
            }
            """#,
            macros: testMacros
        )
    }

    @Test("@Guide with multiple constraints")
    func guideWithMultipleConstraints() {
        assertMacroExpansion(
            """
            @Schema
            struct Rating {
                @Guide(description: "User rating", .minimum(1), .maximum(5))
                let score: Int
            }
            """,
            expandedSource: """
            struct Rating {
                let score: Int

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "score": ["type": "integer", "description": "User rating. Must be at least 1. Must be at most 5"]
                        ],
                        "required": ["score"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Rating: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("@Guide with .rangeDouble constraint")
    func guideWithRangeDoubleConstraint() {
        assertMacroExpansion(
            """
            @Schema
            struct Threshold {
                @Guide(description: "Confidence threshold", .rangeDouble(0.0...1.0))
                let value: Double
            }
            """,
            expandedSource: """
            struct Threshold {
                let value: Double

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "value": ["type": "number", "description": "Confidence threshold. Must be between 0.0 and 1.0"]
                        ],
                        "required": ["value"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Threshold: SchemaType {
            }
            """,
            macros: testMacros
        )
    }
}

// MARK: - Edge Case Tests

@Suite("Schema Macro - Edge Cases")
struct SchemaEdgeCaseTests {

    @Test("Optional<T> generic syntax")
    func optionalGenericSyntax() {
        assertMacroExpansion(
            """
            @Schema
            struct Config {
                let timeout: Optional<Int>
            }
            """,
            expandedSource: """
            struct Config {
                let timeout: Optional<Int>

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "timeout": ["type": "integer"]
                        ],
                        "required": [],
                        "additionalProperties": false
                    ]
                }
            }

            extension Config: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Array<T> generic syntax")
    func arrayGenericSyntax() {
        assertMacroExpansion(
            """
            @Schema
            struct List {
                let items: Array<String>
            }
            """,
            expandedSource: """
            struct List {
                let items: Array<String>

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "items": ["type": "array", "items": ["type": "string"]]
                        ],
                        "required": ["items"],
                        "additionalProperties": false
                    ]
                }
            }

            extension List: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("var properties work same as let")
    func varProperties() {
        assertMacroExpansion(
            """
            @Schema
            struct Mutable {
                var name: String
                var count: Int
            }
            """,
            expandedSource: """
            struct Mutable {
                var name: String
                var count: Int

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "count": ["type": "integer"]
                        ],
                        "required": ["name", "count"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Mutable: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Computed properties are skipped")
    func computedPropertiesSkipped() {
        assertMacroExpansion(
            """
            @Schema
            struct WithComputed {
                let name: String
                var displayName: String {
                    return name.uppercased()
                }
            }
            """,
            expandedSource: """
            struct WithComputed {
                let name: String
                var displayName: String {
                    return name.uppercased()
                }

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"]
                        ],
                        "required": ["name"],
                        "additionalProperties": false
                    ]
                }
            }

            extension WithComputed: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Optional nested schema type")
    func optionalNestedType() {
        assertMacroExpansion(
            """
            @Schema
            struct Person {
                let name: String
                let address: Address?
            }
            """,
            expandedSource: """
            struct Person {
                let name: String
                let address: Address?

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "address": Address.jsonSchema
                        ],
                        "required": ["name"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Person: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Single case enum")
    func singleCaseEnum() {
        assertMacroExpansion(
            """
            @Schema
            enum SingleValue: String {
                case only
            }
            """,
            expandedSource: """
            enum SingleValue: String {
                case only

                static var jsonSchema: JSONValue {
                    [
                        "type": "string",
                        "enum": ["only"]
                    ]
                }
            }

            extension SingleValue: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Negative numbers in range constraint")
    func negativeRangeConstraint() {
        assertMacroExpansion(
            """
            @Schema
            struct Temperature {
                @Guide(description: "Temperature in Celsius", .range(-40...50))
                let value: Int
            }
            """,
            expandedSource: """
            struct Temperature {
                let value: Int

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "value": ["type": "integer", "description": "Temperature in Celsius. Must be between -40 and 50"]
                        ],
                        "required": ["value"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Temperature: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Negative minimum constraint")
    func negativeMinimumConstraint() {
        assertMacroExpansion(
            """
            @Schema
            struct Balance {
                @Guide(description: "Account balance", .minimum(-1000))
                let amount: Int
            }
            """,
            expandedSource: """
            struct Balance {
                let amount: Int

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "amount": ["type": "integer", "description": "Account balance. Must be at least -1000"]
                        ],
                        "required": ["amount"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Balance: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Nested array [[String]]")
    func nestedArray() {
        assertMacroExpansion(
            """
            @Schema
            struct Matrix {
                let rows: [[String]]
            }
            """,
            expandedSource: """
            struct Matrix {
                let rows: [[String]]

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "rows": ["type": "array", "items": ["type": "array", "items": ["type": "string"]]]
                        ],
                        "required": ["rows"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Matrix: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Description with newline")
    func descriptionWithNewline() {
        assertMacroExpansion(
            #"""
            @Schema(description: "Line one\nLine two")
            struct MultiLine {
                let value: String
            }
            """#,
            expandedSource: #"""
            struct MultiLine {
                let value: String

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "description": "Line one\nLine two",
                        "properties": [
                            "value": ["type": "string"]
                        ],
                        "required": ["value"],
                        "additionalProperties": false
                    ]
                }
            }

            extension MultiLine: SchemaType {
            }
            """#,
            macros: testMacros
        )
    }

    @Test("Mixed let and var properties")
    func mixedLetVar() {
        assertMacroExpansion(
            """
            @Schema
            struct Mixed {
                let id: String
                var name: String
                let count: Int?
                var active: Bool
            }
            """,
            expandedSource: """
            struct Mixed {
                let id: String
                var name: String
                let count: Int?
                var active: Bool

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string"],
                            "name": ["type": "string"],
                            "count": ["type": "integer"],
                            "active": ["type": "boolean"]
                        ],
                        "required": ["id", "name", "active"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Mixed: SchemaType {
            }
            """,
            macros: testMacros
        )
    }

    @Test("Empty description with constraint only shows constraint")
    func emptyDescriptionWithConstraint() {
        // Empty description should be omitted, leaving only constraint text
        assertMacroExpansion(
            """
            @Schema
            struct Simple {
                @Guide(description: "", .minimum(0))
                let value: Int
            }
            """,
            expandedSource: """
            struct Simple {
                let value: Int

                static var jsonSchema: JSONValue {
                    [
                        "type": "object",
                        "properties": [
                            "value": ["type": "integer", "description": "Must be at least 0"]
                        ],
                        "required": ["value"],
                        "additionalProperties": false
                    ]
                }
            }

            extension Simple: SchemaType {
            }
            """,
            macros: testMacros
        )
    }
}
