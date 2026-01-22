import XCTest
@testable import Yrden

/// Phase 5: End-to-End tests for real-world scenarios
/// Tests JSONValue in the context of JSON Schema, tool arguments, and structured outputs
final class JSONValueE2ETests: XCTestCase {

    // MARK: - JSON Schema Scenarios

    func test_e2e_jsonSchema_simpleObject() throws {
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
        let jsonString = String(data: data, encoding: .utf8)!

        // Verify key elements are present (can't check exact string due to dict ordering)
        XCTAssertTrue(jsonString.contains("\"type\":\"object\""))
        XCTAssertTrue(jsonString.contains("\"additionalProperties\":false"))
        XCTAssertTrue(jsonString.contains("\"name\""))
        XCTAssertTrue(jsonString.contains("\"age\""))

        // Decode back and verify round-trip
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(schema, decoded)

        // Verify we can access nested values
        XCTAssertEqual(decoded["type"]?.stringValue, "object")
        XCTAssertEqual(decoded["properties"]?["name"]?["type"]?.stringValue, "string")
        XCTAssertEqual(decoded["properties"]?["age"]?["type"]?.stringValue, "integer")
        XCTAssertEqual(decoded["additionalProperties"]?.boolValue, false)
    }

    func test_e2e_jsonSchema_withArrayProperty() throws {
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

        XCTAssertEqual(decoded["properties"]?["tags"]?["type"]?.stringValue, "array")
        XCTAssertEqual(decoded["properties"]?["tags"]?["items"]?["type"]?.stringValue, "string")
    }

    func test_e2e_jsonSchema_withEnum() throws {
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
        XCTAssertEqual(enumValues?.count, 3)
        XCTAssertEqual(enumValues?[0].stringValue, "active")
        XCTAssertEqual(enumValues?[1].stringValue, "inactive")
        XCTAssertEqual(enumValues?[2].stringValue, "pending")
    }

    func test_e2e_jsonSchema_nested() throws {
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
        XCTAssertEqual(schema, decoded)

        // Deep access
        XCTAssertEqual(decoded["properties"]?["user"]?["properties"]?["address"]?["properties"]?["city"]?["type"]?.stringValue, "string")
    }

    // MARK: - Tool Arguments Scenarios

    func test_e2e_toolArguments_decodeFromString() throws {
        // Simulate receiving tool arguments from LLM (raw JSON string)
        let llmResponse = """
        {"query": "weather in London", "limit": 5, "include_forecast": true}
        """

        let data = llmResponse.data(using: .utf8)!
        let args = try JSONDecoder().decode(JSONValue.self, from: data)

        // Extract typed values
        XCTAssertEqual(args["query"]?.stringValue, "weather in London")
        XCTAssertEqual(args["limit"]?.intValue, 5)
        XCTAssertEqual(args["include_forecast"]?.boolValue, true)

        // Missing keys return nil (not crash)
        XCTAssertNil(args["missing"])
        XCTAssertNil(args["missing"]?.stringValue)
    }

    func test_e2e_toolArguments_withArray() throws {
        let llmResponse = """
        {"ids": [1, 2, 3, 4, 5], "operation": "delete"}
        """

        let data = llmResponse.data(using: .utf8)!
        let args = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(args["operation"]?.stringValue, "delete")

        let ids = args["ids"]?.arrayValue
        XCTAssertEqual(ids?.count, 5)
        XCTAssertEqual(ids?[0].intValue, 1)
        XCTAssertEqual(ids?[4].intValue, 5)
    }

    func test_e2e_toolArguments_withNestedObject() throws {
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

        XCTAssertEqual(args["action"]?.stringValue, "create")
        XCTAssertEqual(args["data"]?["name"]?.stringValue, "New Item")
        XCTAssertEqual(args["data"]?["metadata"]?["priority"]?.stringValue, "high")
        XCTAssertEqual(args["data"]?["metadata"]?["tags"]?[0]?.stringValue, "urgent")
    }

    func test_e2e_toolArguments_withNull() throws {
        let llmResponse = """
        {"required_field": "value", "optional_field": null}
        """

        let data = llmResponse.data(using: .utf8)!
        let args = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(args["required_field"]?.stringValue, "value")
        XCTAssertEqual(args["optional_field"], .null)
        XCTAssertNil(args["optional_field"]?.stringValue)  // .null has no stringValue
    }

    // MARK: - Structured Output Scenarios

    func test_e2e_structuredOutput_fullCycle() throws {
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
        XCTAssertEqual(result["summary"]?.stringValue, "Analysis complete")
        XCTAssertEqual(result["confidence"]?.doubleValue, 0.95)
        XCTAssertEqual(result["tags"]?.arrayValue?.count, 2)
        XCTAssertEqual(result["tags"]?[0]?.stringValue, "urgent")
        XCTAssertEqual(result["tags"]?[1]?.stringValue, "reviewed")

        // Schema should also round-trip correctly
        let decodedSchema = try JSONDecoder().decode(JSONValue.self, from: schemaData)
        XCTAssertEqual(outputSchema, decodedSchema)
    }

    func test_e2e_structuredOutput_complexAnalysis() throws {
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
        XCTAssertEqual(result["analysis"]?["sentiment"]?.stringValue, "positive")
        XCTAssertEqual(result["analysis"]?["score"]?.doubleValue, 0.87)

        let entities = result["analysis"]?["entities"]?.arrayValue
        XCTAssertEqual(entities?.count, 2)
        XCTAssertEqual(entities?[0]["name"]?.stringValue, "Apple Inc")
        XCTAssertEqual(entities?[0]["type"]?.stringValue, "company")
        XCTAssertEqual(entities?[1]["name"]?.stringValue, "Tim Cook")

        let keywords = result["analysis"]?["keywords"]?.arrayValue
        XCTAssertEqual(keywords?.count, 3)

        XCTAssertEqual(result["metadata"]?["tokens_used"]?.intValue, 1234)
    }

    // MARK: - Provider-Specific Format Tests

    func test_e2e_anthropicToolUseFormat() throws {
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

        XCTAssertEqual(decoded["name"]?.stringValue, "get_weather")
        XCTAssertEqual(decoded["input_schema"]?["type"]?.stringValue, "object")
        XCTAssertEqual(decoded["input_schema"]?["properties"]?["location"]?["type"]?.stringValue, "string")
    }

    func test_e2e_openaiResponseFormat() throws {
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

        XCTAssertEqual(decoded["type"]?.stringValue, "json_schema")
        XCTAssertEqual(decoded["json_schema"]?["strict"]?.boolValue, true)
        XCTAssertEqual(decoded["json_schema"]?["schema"]?["additionalProperties"]?.boolValue, false)
    }

    // MARK: - Edge Cases in Real Usage

    func test_e2e_unicodeInToolArguments() throws {
        let llmResponse = """
        {"query": "天气预报 🌤️", "language": "中文"}
        """

        let data = llmResponse.data(using: .utf8)!
        let args = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(args["query"]?.stringValue, "天气预报 🌤️")
        XCTAssertEqual(args["language"]?.stringValue, "中文")
    }

    func test_e2e_largeNumbers() throws {
        let llmResponse = """
        {"count": 9223372036854775807, "small": -9223372036854775808, "float": 1.7976931348623157e308}
        """

        let data = llmResponse.data(using: .utf8)!
        let args = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(args["count"]?.intValue, Int.max)
        XCTAssertEqual(args["small"]?.intValue, Int.min)
        XCTAssertEqual(args["float"]?.doubleValue, Double.greatestFiniteMagnitude)
    }

    func test_e2e_emptyStructures() throws {
        let llmResponse = """
        {"empty_object": {}, "empty_array": [], "empty_string": ""}
        """

        let data = llmResponse.data(using: .utf8)!
        let args = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(args["empty_object"]?.objectValue, [:])
        XCTAssertEqual(args["empty_array"]?.arrayValue, [])
        XCTAssertEqual(args["empty_string"]?.stringValue, "")
    }

    func test_e2e_specialCharactersInKeys() throws {
        let llmResponse = """
        {"key with spaces": "value1", "key-with-dashes": "value2", "key.with.dots": "value3"}
        """

        let data = llmResponse.data(using: .utf8)!
        let args = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(args["key with spaces"]?.stringValue, "value1")
        XCTAssertEqual(args["key-with-dashes"]?.stringValue, "value2")
        XCTAssertEqual(args["key.with.dots"]?.stringValue, "value3")
    }
}
