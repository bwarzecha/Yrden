/// End-to-end tests for JSONValue in real-world scenarios.
///
/// Covers: JSON schema construction, tool argument parsing,
/// structured output cycles, provider-specific formats, and edge cases.

import Testing
import Foundation
@testable import Yrden

@Suite("JSONValue - E2E Scenarios")
struct JSONValueE2ETests {

    // MARK: - JSON Schema Scenarios

    @Test func e2e_jsonSchema_simpleObject() throws {
        // Build a simple schema like we would for a tool input
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "User name"],
                "age": ["type": "integer", "description": "Age in years"]
            ],
            "required": ["name", "age"],
            "additionalProperties": false
        ]

        // Encode to JSON (what we'd send to LLM provider)
        let data = try JSONEncoder().encode(schema)

        // Decode back and verify round-trip
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(schema == decoded)

        // Verify we can access nested values
        #expect(decoded["type"]?.stringValue == "object")
        #expect(decoded["properties"]?["name"]?["type"]?.stringValue == "string")
        #expect(decoded["properties"]?["age"]?["type"]?.stringValue == "integer")
        #expect(decoded["additionalProperties"]?.boolValue == false)
    }

    @Test func e2e_jsonSchema_withArrayProperty() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "tags": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "List of tags"
                ]
            ],
            "required": ["tags"]
        ]

        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded["properties"]?["tags"]?["type"]?.stringValue == "array")
        #expect(decoded["properties"]?["tags"]?["items"]?["type"]?.stringValue == "string")
    }

    @Test func e2e_jsonSchema_withEnum() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "status": [
                    "type": "string",
                    "enum": ["active", "inactive", "pending"],
                    "description": "Current status"
                ]
            ]
        ]

        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        let enumValues = decoded["properties"]?["status"]?["enum"]?.arrayValue
        #expect(enumValues?.count == 3)
        #expect(enumValues?[0].stringValue == "active")
        #expect(enumValues?[1].stringValue == "inactive")
        #expect(enumValues?[2].stringValue == "pending")
    }

    @Test func e2e_jsonSchema_nested() throws {
        // A more complex schema with nested objects
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "user": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "address": [
                            "type": "object",
                            "properties": [
                                "street": ["type": "string"],
                                "city": ["type": "string"],
                                "zip": ["type": "string"]
                            ],
                            "required": ["street", "city"]
                        ]
                    ],
                    "required": ["name"]
                ]
            ],
            "required": ["user"]
        ]

        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(schema == decoded)

        // Deep access
        #expect(decoded["properties"]?["user"]?["properties"]?["address"]?["properties"]?["city"]?["type"]?.stringValue == "string")
    }

    // MARK: - Tool Arguments Scenarios

    @Test func e2e_toolArguments_decodeFromString() throws {
        // Simulate receiving tool arguments from LLM (raw JSON string)
        let llmResponse = """
        {"query": "weather in London", "limit": 5, "include_forecast": true}
        """

        let data = llmResponse.data(using: .utf8)!
        let args = try JSONDecoder().decode(JSONValue.self, from: data)

        // Extract typed values
        #expect(args["query"]?.stringValue == "weather in London")
        #expect(args["limit"]?.intValue == 5)
        #expect(args["include_forecast"]?.boolValue == true)

        // Missing keys return nil (not crash)
        #expect(args["missing"] == nil)
        #expect(args["missing"]?.stringValue == nil)
    }

    @Test func e2e_toolArguments_withArray() throws {
        let llmResponse = """
        {"ids": [1, 2, 3, 4, 5], "operation": "delete"}
        """

        let data = llmResponse.data(using: .utf8)!
        let args = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(args["operation"]?.stringValue == "delete")

        let ids = args["ids"]?.arrayValue
        #expect(ids?.count == 5)
        #expect(ids?[0].intValue == 1)
        #expect(ids?[4].intValue == 5)
    }

    @Test func e2e_toolArguments_withNestedObject() throws {
        let llmResponse = """
        {
            "action": "create",
            "data": {
                "name": "New Item",
                "metadata": {
                    "priority": "high",
                    "tags": ["urgent", "review"]
                }
            }
        }
        """

        let data = llmResponse.data(using: .utf8)!
        let args = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(args["action"]?.stringValue == "create")
        #expect(args["data"]?["name"]?.stringValue == "New Item")
        #expect(args["data"]?["metadata"]?["priority"]?.stringValue == "high")
        #expect(args["data"]?["metadata"]?["tags"]?[0]?.stringValue == "urgent")
    }

    @Test func e2e_toolArguments_withNull() throws {
        let llmResponse = """
        {"required_field": "value", "optional_field": null}
        """

        let data = llmResponse.data(using: .utf8)!
        let args = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(args["required_field"]?.stringValue == "value")
        #expect(args["optional_field"] == .null)
        #expect(args["optional_field"]?.stringValue == nil)  // .null has no stringValue
    }

    // MARK: - Structured Output Scenarios

    @Test func e2e_structuredOutput_fullCycle() throws {
        // 1. Define expected output schema
        let outputSchema: JSONValue = [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "confidence": ["type": "number"],
                "tags": ["type": "array", "items": ["type": "string"]]
            ],
            "required": ["summary", "confidence", "tags"]
        ]

        // 2. Encode schema (what we'd send to provider)
        let schemaData = try JSONEncoder().encode(outputSchema)

        // 3. Simulate LLM response matching that schema
        let llmOutput = """
        {"summary": "Analysis complete", "confidence": 0.95, "tags": ["urgent", "reviewed"]}
        """

        // 4. Parse response
        let responseData = llmOutput.data(using: .utf8)!
        let result = try JSONDecoder().decode(JSONValue.self, from: responseData)

        // 5. Verify structure matches what schema describes
        #expect(result["summary"]?.stringValue == "Analysis complete")
        #expect(result["confidence"]?.doubleValue == 0.95)
        #expect(result["tags"]?.arrayValue?.count == 2)
        #expect(result["tags"]?[0]?.stringValue == "urgent")
        #expect(result["tags"]?[1]?.stringValue == "reviewed")

        // Schema should also round-trip correctly
        let decodedSchema = try JSONDecoder().decode(JSONValue.self, from: schemaData)
        #expect(outputSchema == decodedSchema)
    }

    @Test func e2e_structuredOutput_complexAnalysis() throws {
        // Simulates a structured analysis output from LLM
        let llmOutput = """
        {
            "analysis": {
                "sentiment": "positive",
                "score": 0.87,
                "entities": [
                    {"name": "Apple Inc", "type": "company", "confidence": 0.95},
                    {"name": "Tim Cook", "type": "person", "confidence": 0.92}
                ],
                "keywords": ["technology", "innovation", "growth"]
            },
            "metadata": {
                "model": "claude-3",
                "tokens_used": 1234,
                "processing_time_ms": 456
            }
        }
        """

        let data = llmOutput.data(using: .utf8)!
        let result = try JSONDecoder().decode(JSONValue.self, from: data)

        // Verify complex nested access
        #expect(result["analysis"]?["sentiment"]?.stringValue == "positive")
        #expect(result["analysis"]?["score"]?.doubleValue == 0.87)

        let entities = result["analysis"]?["entities"]?.arrayValue
        #expect(entities?.count == 2)
        #expect(entities?[0]["name"]?.stringValue == "Apple Inc")
        #expect(entities?[0]["type"]?.stringValue == "company")
        #expect(entities?[1]["name"]?.stringValue == "Tim Cook")

        let keywords = result["analysis"]?["keywords"]?.arrayValue
        #expect(keywords?.count == 3)
        #expect(keywords?[0].stringValue == "technology")
        #expect(keywords?[1].stringValue == "innovation")
        #expect(keywords?[2].stringValue == "growth")

        #expect(result["metadata"]?["tokens_used"]?.intValue == 1234)
    }

    // MARK: - Provider-Specific Format Tests

    @Test func e2e_anthropicToolUseFormat() throws {
        // Anthropic tool_use format simulation
        let toolDefinition: JSONValue = [
            "name": "get_weather",
            "description": "Get current weather for a location",
            "input_schema": [
                "type": "object",
                "properties": [
                    "location": ["type": "string", "description": "City name"],
                    "units": ["type": "string", "enum": ["celsius", "fahrenheit"]]
                ],
                "required": ["location"]
            ]
        ]

        let data = try JSONEncoder().encode(toolDefinition)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded["name"]?.stringValue == "get_weather")
        #expect(decoded["input_schema"]?["type"]?.stringValue == "object")
        #expect(decoded["input_schema"]?["properties"]?["location"]?["type"]?.stringValue == "string")
    }

    @Test func e2e_openaiResponseFormat() throws {
        // OpenAI response_format with strict schema
        let responseFormat: JSONValue = [
            "type": "json_schema",
            "json_schema": [
                "name": "analysis_result",
                "strict": true,
                "schema": [
                    "type": "object",
                    "properties": [
                        "result": ["type": "string"],
                        "score": ["type": "number"]
                    ],
                    "required": ["result", "score"],
                    "additionalProperties": false
                ]
            ]
        ]

        let data = try JSONEncoder().encode(responseFormat)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded["type"]?.stringValue == "json_schema")
        #expect(decoded["json_schema"]?["strict"]?.boolValue == true)
        #expect(decoded["json_schema"]?["schema"]?["additionalProperties"]?.boolValue == false)
    }

    // MARK: - Edge Cases in Real Usage

    @Test func e2e_unicodeInToolArguments() throws {
        let llmResponse = """
        {"query": "天气预报 🌤️", "language": "中文"}
        """

        let data = llmResponse.data(using: .utf8)!
        let args = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(args["query"]?.stringValue == "天气预报 🌤️")
        #expect(args["language"]?.stringValue == "中文")
    }

    @Test func e2e_largeNumbers() throws {
        let llmResponse = """
        {"count": 9223372036854775807, "small": -9223372036854775808, "float": 1.7976931348623157e308}
        """

        let data = llmResponse.data(using: .utf8)!
        let args = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(args["count"]?.intValue == Int.max)
        #expect(args["small"]?.intValue == Int.min)
        #expect(args["float"]?.doubleValue == Double.greatestFiniteMagnitude)
    }

    @Test func e2e_emptyStructures() throws {
        let llmResponse = """
        {"empty_object": {}, "empty_array": [], "empty_string": ""}
        """

        let data = llmResponse.data(using: .utf8)!
        let args = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(args["empty_object"]?.objectValue == [:])
        #expect(args["empty_array"]?.arrayValue == [])
        #expect(args["empty_string"]?.stringValue == "")
    }

    @Test func e2e_specialCharactersInKeys() throws {
        let llmResponse = """
        {"key with spaces": "value1", "key-with-dashes": "value2", "key.with.dots": "value3"}
        """

        let data = llmResponse.data(using: .utf8)!
        let args = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(args["key with spaces"]?.stringValue == "value1")
        #expect(args["key-with-dashes"]?.stringValue == "value2")
        #expect(args["key.with.dots"]?.stringValue == "value3")
    }
}
