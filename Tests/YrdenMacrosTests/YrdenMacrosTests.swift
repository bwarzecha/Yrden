import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import YrdenMacros

// MARK: - Test Macros Dictionary

let testMacros: [String: Macro.Type] = [
    "Schema": SchemaMacro.self,
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
