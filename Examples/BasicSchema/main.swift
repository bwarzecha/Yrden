/// BasicSchema Example
/// Demonstrates @Schema and @Guide macro usage for JSON Schema generation.
///
/// Run with: swift run BasicSchema

import Foundation
import Yrden

// MARK: - Simple Struct

@Schema
struct Person {
    let name: String
    let age: Int
}

// MARK: - All Primitive Types

@Schema(description: "Demonstrates all supported primitive types")
struct AllPrimitives {
    let stringValue: String
    let intValue: Int
    let doubleValue: Double
    let boolValue: Bool
}

// MARK: - Optional Fields

@Schema
struct UserProfile {
    let username: String
    let email: String
    let bio: String?        // Optional - not in required array
    let website: String?    // Optional
}

// MARK: - Arrays

@Schema
struct TodoList {
    let title: String
    let items: [String]
    let tags: [String]?     // Optional array
}

// MARK: - Nested Types

@Schema
struct Address {
    let street: String
    let city: String
    let country: String
}

@Schema
struct Company {
    let name: String
    let headquarters: Address   // Nested @Schema type
    let employees: [Person]     // Array of @Schema type
}

// MARK: - Enums

@Schema
enum Status: String {
    case pending
    case active
    case completed
    case cancelled
}

@Schema
enum Priority: Int {
    case low = 1
    case medium = 2
    case high = 3
    case critical = 4
}

// MARK: - With Descriptions and Constraints

@Schema(description: "Search query parameters for the API")
struct SearchQuery {
    @Guide(description: "Natural language search terms")
    let query: String

    @Guide(description: "Maximum results to return", .range(1...100))
    let limit: Int

    @Guide(description: "Page number for pagination", .minimum(1))
    let page: Int

    @Guide(description: "Minimum relevance score", .rangeDouble(0.0...1.0))
    let threshold: Double

    @Guide(description: "Tags to filter by", .count(1...10))
    let tags: [String]?

    @Guide(description: "Sort order", .options(["relevance", "date", "popularity"]))
    let sortBy: String
}

// MARK: - Main

func printSchema<T: SchemaType>(_ type: T.Type) {
    print("=== \(type) ===")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(type.jsonSchema),
       let json = String(data: data, encoding: .utf8) {
        print(json)
    }
    print()
}

print("Yrden @Schema Examples")
print("======================\n")

print("--- Simple Struct ---")
printSchema(Person.self)

print("--- All Primitives ---")
printSchema(AllPrimitives.self)

print("--- Optional Fields ---")
printSchema(UserProfile.self)

print("--- Arrays ---")
printSchema(TodoList.self)

print("--- Nested Types ---")
printSchema(Address.self)
printSchema(Company.self)

print("--- String Enum ---")
printSchema(Status.self)

print("--- Int Enum ---")
printSchema(Priority.self)

print("--- With Descriptions & Constraints ---")
printSchema(SearchQuery.self)

print("All examples completed successfully!")
