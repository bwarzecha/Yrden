import Foundation
import Testing
@testable import Yrden

// MARK: - Test Types

@Schema
struct SimpleUser {
    let name: String
    let age: Int
}

@Schema
struct UserProfile {
    let username: String
    let email: String
    let score: Double
    let isActive: Bool
    let tags: [String]
    let bio: String?
}

@Schema
enum Status: String {
    case pending
    case active
    case completed
}

@Schema
enum Priority: Int {
    case low = 1
    case medium = 2
    case high = 3
}

// MARK: - Tests

@Suite("Schema Macro - Integration")
struct SchemaIntegrationTests {

    @Test("SimpleUser generates correct schema")
    func simpleUserSchema() {
        let schema = SimpleUser.jsonSchema

        guard case .object(let obj) = schema else {
            Issue.record("Expected object schema")
            return
        }

        // Check type
        guard let typeValue = obj["type"], case .string(let type) = typeValue else {
            Issue.record("Missing type field")
            return
        }
        #expect(type == "object")

        // Check properties
        guard let propsValue = obj["properties"], case .object(let props) = propsValue else {
            Issue.record("Missing properties field")
            return
        }
        #expect(props.count == 2)

        // Check name property
        guard let nameSchema = props["name"], case .object(let nameObj) = nameSchema,
              let nameType = nameObj["type"], case .string(let nameTypeStr) = nameType else {
            Issue.record("Invalid name property schema")
            return
        }
        #expect(nameTypeStr == "string")

        // Check age property
        guard let ageSchema = props["age"], case .object(let ageObj) = ageSchema,
              let ageType = ageObj["type"], case .string(let ageTypeStr) = ageType else {
            Issue.record("Invalid age property schema")
            return
        }
        #expect(ageTypeStr == "integer")

        // Check required array
        guard let reqValue = obj["required"], case .array(let required) = reqValue else {
            Issue.record("Missing required field")
            return
        }
        let requiredNames = required.compactMap { value -> String? in
            guard case .string(let str) = value else { return nil }
            return str
        }
        #expect(requiredNames.contains("name"))
        #expect(requiredNames.contains("age"))

        // Check additionalProperties
        guard let addPropsValue = obj["additionalProperties"],
              case .bool(let addProps) = addPropsValue else {
            Issue.record("Missing additionalProperties field")
            return
        }
        #expect(addProps == false)
    }

    @Test("UserProfile with optionals and arrays")
    func userProfileSchema() {
        let schema = UserProfile.jsonSchema

        guard case .object(let obj) = schema else {
            Issue.record("Expected object schema")
            return
        }

        // Check properties count
        guard let propsValue = obj["properties"], case .object(let props) = propsValue else {
            Issue.record("Missing properties field")
            return
        }
        #expect(props.count == 6)

        // Check tags is array
        guard let tagsSchema = props["tags"], case .object(let tagsObj) = tagsSchema,
              let tagsType = tagsObj["type"], case .string(let tagsTypeStr) = tagsType else {
            Issue.record("Invalid tags property schema")
            return
        }
        #expect(tagsTypeStr == "array")

        // Check tags items
        guard let itemsValue = tagsObj["items"], case .object(let itemsObj) = itemsValue,
              let itemsType = itemsObj["type"], case .string(let itemsTypeStr) = itemsType else {
            Issue.record("Invalid tags items schema")
            return
        }
        #expect(itemsTypeStr == "string")

        // Check required array excludes bio (optional)
        guard let reqValue = obj["required"], case .array(let required) = reqValue else {
            Issue.record("Missing required field")
            return
        }
        let requiredNames = required.compactMap { value -> String? in
            guard case .string(let str) = value else { return nil }
            return str
        }
        #expect(requiredNames.count == 5)
        #expect(!requiredNames.contains("bio"))
        #expect(requiredNames.contains("username"))
        #expect(requiredNames.contains("tags"))
    }

    @Test("String enum generates correct schema")
    func stringEnumSchema() {
        let schema = Status.jsonSchema

        guard case .object(let obj) = schema else {
            Issue.record("Expected object schema")
            return
        }

        // Check type
        guard let typeValue = obj["type"], case .string(let type) = typeValue else {
            Issue.record("Missing type field")
            return
        }
        #expect(type == "string")

        // Check enum values
        guard let enumValue = obj["enum"], case .array(let values) = enumValue else {
            Issue.record("Missing enum field")
            return
        }
        let enumStrings = values.compactMap { value -> String? in
            guard case .string(let str) = value else { return nil }
            return str
        }
        #expect(enumStrings.count == 3)
        #expect(enumStrings.contains("pending"))
        #expect(enumStrings.contains("active"))
        #expect(enumStrings.contains("completed"))
    }

    @Test("Int enum generates correct schema")
    func intEnumSchema() {
        let schema = Priority.jsonSchema

        guard case .object(let obj) = schema else {
            Issue.record("Expected object schema")
            return
        }

        // Check type
        guard let typeValue = obj["type"], case .string(let type) = typeValue else {
            Issue.record("Missing type field")
            return
        }
        #expect(type == "integer")

        // Check enum values
        guard let enumValue = obj["enum"], case .array(let values) = enumValue else {
            Issue.record("Missing enum field")
            return
        }
        let enumInts = values.compactMap { value -> Int? in
            guard case .int(let i) = value else { return nil }
            return i
        }
        #expect(enumInts.count == 3)
        #expect(enumInts.contains(1))
        #expect(enumInts.contains(2))
        #expect(enumInts.contains(3))
    }

    @Test("Schema can be serialized to JSON")
    func schemaSerialization() throws {
        let schema = SimpleUser.jsonSchema

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(schema)
        let jsonString = String(data: data, encoding: .utf8)!

        // Verify it contains expected keys
        #expect(jsonString.contains("\"type\":\"object\""))
        #expect(jsonString.contains("\"additionalProperties\":false"))
        #expect(jsonString.contains("\"properties\""))
        #expect(jsonString.contains("\"required\""))
    }
}
