/// Schema-Decoder consistency tests.
///
/// Verifies that JSON property names in the @Schema-generated jsonSchema
/// match what JSONDecoder expects (via CodingKeys). This catches the class
/// of bugs where the macro generates camelCase property names but CodingKeys
/// maps them to snake_case — causing real LLMs to send JSON the decoder rejects.
///
/// The test mechanism:
/// 1. Extract property names and types from the tool's jsonSchema
/// 2. Build minimal valid JSON using those exact property names
/// 3. Decode with JSONDecoder
/// 4. If decoding fails, schema and decoder are out of sync

import Testing
import Foundation
@testable import Yrden

@Suite("Schema-Decoder Consistency")
struct SchemaDecoderConsistencyTests {

    // MARK: - Generic Consistency Checker

    /// Verifies that a @Schema type's jsonSchema property names decode correctly.
    ///
    /// Extracts property names from the schema, builds minimal JSON with dummy
    /// values matching the declared types, and attempts to decode it.
    private func verifyConsistency<T: SchemaType>(
        _ type: T.Type,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let schema = T.jsonSchema

        // Extract "properties" from schema
        guard let properties = schema["properties"]?.objectValue else {
            Issue.record("Schema has no 'properties' object", sourceLocation: sourceLocation)
            return
        }

        // Extract "required" from schema
        let required = schema["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        // Build minimal JSON with dummy values for required properties
        var jsonDict: [String: Any] = [:]
        for (key, propSchema) in properties {
            // Only include required properties (optional ones can be omitted)
            guard required.contains(key) else { continue }

            guard let typeStr = propSchema["type"]?.stringValue else {
                Issue.record("Property '\(key)' has no type in schema", sourceLocation: sourceLocation)
                continue
            }

            jsonDict[key] = dummyValue(forJsonType: typeStr)
        }

        // Serialize to JSON data
        let jsonData = try JSONSerialization.data(withJSONObject: jsonDict)

        // Attempt decode — this is the actual consistency check
        do {
            _ = try JSONDecoder().decode(T.self, from: jsonData)
        } catch {
            Issue.record(
                """
                Schema-decoder mismatch for \(T.self): \(error.localizedDescription)
                Schema property names: \(Array(properties.keys).sorted())
                Required: \(required)
                JSON sent: \(String(data: jsonData, encoding: .utf8) ?? "?")
                """,
                sourceLocation: sourceLocation
            )
        }
    }

    /// Verifies schema structure: additionalProperties, required vs optional alignment.
    private func verifySchemaStructure<T: SchemaType>(
        _ type: T.Type,
        expectedPropertyCount: Int,
        expectedRequiredCount: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let schema = T.jsonSchema

        // Must be an object type
        #expect(schema["type"]?.stringValue == "object",
               "Schema for \(T.self) should be type 'object'", sourceLocation: sourceLocation)

        // Must have additionalProperties: false
        #expect(schema["additionalProperties"]?.boolValue == false,
               "Schema for \(T.self) must have additionalProperties: false", sourceLocation: sourceLocation)

        // Property count must match
        let properties = schema["properties"]?.objectValue ?? [:]
        #expect(properties.count == expectedPropertyCount,
               "Schema for \(T.self) should have \(expectedPropertyCount) properties, got \(properties.count): \(Array(properties.keys).sorted())",
               sourceLocation: sourceLocation)

        // Required count must match
        let required = schema["required"]?.arrayValue ?? []
        #expect(required.count == expectedRequiredCount,
               "Schema for \(T.self) should have \(expectedRequiredCount) required fields, got \(required.count)",
               sourceLocation: sourceLocation)

        // Every required field must exist in properties
        for req in required {
            if let name = req.stringValue {
                #expect(properties[name] != nil,
                       "Required field '\(name)' not found in properties for \(T.self)",
                       sourceLocation: sourceLocation)
            }
        }
    }

    /// Returns a dummy value for a JSON Schema type string.
    private func dummyValue(forJsonType type: String) -> Any {
        switch type {
        case "string": return "test"
        case "integer": return 1
        case "number": return 1.0
        case "boolean": return true
        case "array": return [String]()
        default: return "test"
        }
    }

    // MARK: - Consistency Tests (one per tool Args type)

    @Test("ReadFileArgs schema decodes correctly")
    func readFileArgs() throws {
        try verifyConsistency(ReadFileArgs.self)
        verifySchemaStructure(ReadFileArgs.self, expectedPropertyCount: 3, expectedRequiredCount: 1)
    }

    @Test("WriteFileArgs schema decodes correctly")
    func writeFileArgs() throws {
        try verifyConsistency(WriteFileArgs.self)
        verifySchemaStructure(WriteFileArgs.self, expectedPropertyCount: 2, expectedRequiredCount: 2)
    }

    @Test("EditFileArgs schema decodes correctly")
    func editFileArgs() throws {
        try verifyConsistency(EditFileArgs.self)
        verifySchemaStructure(EditFileArgs.self, expectedPropertyCount: 4, expectedRequiredCount: 4)
    }

    @Test("ShellToolArgs schema decodes correctly")
    func shellToolArgs() throws {
        try verifyConsistency(ShellToolArgs.self)
        verifySchemaStructure(ShellToolArgs.self, expectedPropertyCount: 5, expectedRequiredCount: 1)
    }

    @Test("GlobToolArgs schema decodes correctly")
    func globToolArgs() throws {
        try verifyConsistency(GlobToolArgs.self)
        verifySchemaStructure(GlobToolArgs.self, expectedPropertyCount: 2, expectedRequiredCount: 1)
    }

    @Test("GrepToolArgs schema decodes correctly")
    func grepToolArgs() throws {
        try verifyConsistency(GrepToolArgs.self)
        verifySchemaStructure(GrepToolArgs.self, expectedPropertyCount: 7, expectedRequiredCount: 1)
    }

    @Test("TaskOutputArgs schema decodes correctly")
    func taskOutputArgs() throws {
        try verifyConsistency(TaskOutputArgs.self)
        verifySchemaStructure(TaskOutputArgs.self, expectedPropertyCount: 3, expectedRequiredCount: 1)
    }

    @Test("TaskStopArgs schema decodes correctly")
    func taskStopArgs() throws {
        try verifyConsistency(TaskStopArgs.self)
        verifySchemaStructure(TaskStopArgs.self, expectedPropertyCount: 1, expectedRequiredCount: 1)
    }

    // MARK: - Cross-cutting property name tests

    @Test("CodingKeys types use snake_case in schema")
    func codingKeysUseSnakeCase() {
        // These types have CodingKeys with snake_case remapping.
        // Verify the schema actually uses snake_case, not camelCase.
        let checks: [(String, JSONValue, [String])] = [
            ("EditFileArgs", EditFileArgs.jsonSchema, ["old_string", "new_string", "replace_all"]),
            ("ShellToolArgs", ShellToolArgs.jsonSchema, ["working_directory", "run_in_background"]),
            ("GrepToolArgs", GrepToolArgs.jsonSchema, ["output_mode", "case_insensitive", "context_lines", "max_results"]),
            ("TaskOutputArgs", TaskOutputArgs.jsonSchema, ["task_id"]),
            ("TaskStopArgs", TaskStopArgs.jsonSchema, ["task_id"]),
        ]

        for (typeName, schema, expectedSnakeCaseKeys) in checks {
            let properties = schema["properties"]?.objectValue ?? [:]
            for key in expectedSnakeCaseKeys {
                #expect(properties[key] != nil,
                       "\(typeName) schema should have '\(key)' (snake_case), got keys: \(Array(properties.keys).sorted())")
            }
        }
    }

    @Test("CodingKeys types do NOT have camelCase in schema")
    func noCamelCaseLeaks() {
        // Verify these camelCase names do NOT appear in the schema.
        // If they do, the CodingKeys mapping was ignored.
        let checks: [(String, JSONValue, [String])] = [
            ("EditFileArgs", EditFileArgs.jsonSchema, ["oldString", "newString", "replaceAll"]),
            ("ShellToolArgs", ShellToolArgs.jsonSchema, ["workingDirectory", "runInBackground"]),
            ("GrepToolArgs", GrepToolArgs.jsonSchema, ["outputMode", "caseInsensitive", "contextLines", "maxResults"]),
            ("TaskOutputArgs", TaskOutputArgs.jsonSchema, ["taskId"]),
            ("TaskStopArgs", TaskStopArgs.jsonSchema, ["taskId"]),
        ]

        for (typeName, schema, forbiddenCamelCaseKeys) in checks {
            let properties = schema["properties"]?.objectValue ?? [:]
            for key in forbiddenCamelCaseKeys {
                #expect(properties[key] == nil,
                       "\(typeName) schema should NOT have '\(key)' (camelCase) — CodingKeys mapping was ignored")
            }
        }
    }
}
