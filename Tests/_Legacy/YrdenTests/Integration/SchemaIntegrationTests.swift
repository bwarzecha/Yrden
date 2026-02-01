import Foundation
import Testing
@testable import Yrden

// MARK: - Schema Types for Testing

/// Tests use @Schema macro to generate JSON schemas at compile time,
/// then send to LLM providers and decode responses into Swift types.

@Schema(description: "Extracted person information")
struct PersonExtraction: Codable, Equatable {
    let name: String
    let age: Int
    let occupation: String?
}

@Schema(description: "Sentiment analysis result")
struct SentimentResult: Codable {
    @Guide(description: "Overall sentiment classification", .options(["positive", "negative", "neutral"]))
    let sentiment: String

    @Guide(description: "Confidence score", .rangeDouble(0.0...1.0))
    let confidence: Double

    @Guide(description: "Key words that influenced the analysis")
    let keywords: [String]
}

@Schema
enum TaskStatus: String, Codable {
    case todo
    case inProgress = "in_progress"
    case done
    case blocked
}

@Schema(description: "A task with status")
struct TaskInfo: Codable {
    @Guide(description: "Task title")
    let title: String

    let status: TaskStatus

    @Guide(description: "Optional notes about the task")
    let notes: String?
}

// MARK: - OpenAI-specific Types (no optional fields for strict mode)

/// OpenAI strict mode requires ALL properties in 'required' array.
/// These types have no optional fields to work with strict: true.

@Schema(description: "Extracted person information")
struct PersonExtractionStrict: Codable, Equatable {
    let name: String
    let age: Int
    let occupation: String  // Not optional
}

@Schema(description: "A task with status")
struct TaskInfoStrict: Codable {
    @Guide(description: "Task title")
    let title: String

    let status: TaskStatus

    @Guide(description: "Notes about the task")
    let notes: String  // Not optional
}

// MARK: - Test Configuration

/// Condition for enabling Anthropic tests
private let hasAnthropicKey = TestConfig.hasAnthropicAPIKey

/// Condition for enabling OpenAI tests
private let hasOpenAIKey = TestConfig.hasOpenAIAPIKey

/// Default config for Anthropic tests
private let anthropicConfig = CompletionConfig(temperature: 0, maxTokens: 2000)

/// Default config for OpenAI tests (no temperature - newer models don't support it)
private let openAIConfig = CompletionConfig(maxTokens: 2000)

// MARK: - Anthropic Schema Integration Tests

@Suite("Schema Integration - Anthropic", .tags(.integration))
struct AnthropicSchemaIntegrationTests {
    private let model = AnthropicModel(
        name: "claude-haiku-4-5",
        provider: AnthropicProvider(apiKey: TestConfig.anthropicAPIKey)
    )

    @Test("Extract person info using tool with @Schema", .enabled(if: hasAnthropicKey))
    func extractPersonInfoWithTool() async throws {
        let tool = ToolDefinition(
            name: "extract_person",
            description: "Extract person information from text",
            inputSchema: PersonExtraction.jsonSchema
        )

        let response = try await model.complete(CompletionRequest(
            messages: [
                .system("Extract person information using the extract_person tool."),
                .user([.text("Sarah Johnson is a 28-year-old product designer working at a tech startup.")])
            ],
            tools: [tool],
            config: anthropicConfig
        ))

        #expect(!response.toolCalls.isEmpty)
        #expect(response.toolCalls[0].name == "extract_person")

        let person = try JSONDecoder().decode(
            PersonExtraction.self,
            from: Data(response.toolCalls[0].arguments.utf8)
        )

        #expect(person.name.lowercased().contains("sarah"))
        #expect(person.age == 28)
        #expect(person.occupation?.lowercased().contains("designer") == true)
    }

    @Test("Sentiment analysis using tool with @Schema", .enabled(if: hasAnthropicKey))
    func sentimentAnalysisWithTool() async throws {
        let tool = ToolDefinition(
            name: "analyze_sentiment",
            description: "Analyze sentiment of text. Return sentiment (positive/negative/neutral), confidence (0-1), and keywords.",
            inputSchema: SentimentResult.jsonSchema
        )

        let response = try await model.complete(CompletionRequest(
            messages: [
                .system("Analyze the sentiment using the analyze_sentiment tool."),
                .user([.text("I absolutely love this product! Best purchase I've made all year.")])
            ],
            tools: [tool],
            config: anthropicConfig
        ))

        #expect(!response.toolCalls.isEmpty)

        let result = try JSONDecoder().decode(
            SentimentResult.self,
            from: Data(response.toolCalls[0].arguments.utf8)
        )

        #expect(result.sentiment == "positive")
        #expect(result.confidence >= 0.5)
        #expect(!result.keywords.isEmpty)
    }

    @Test("Extract task with enum using tool", .enabled(if: hasAnthropicKey))
    func extractTaskWithEnumTool() async throws {
        let tool = ToolDefinition(
            name: "extract_task",
            description: "Extract task information. Status must be: todo, in_progress, done, or blocked.",
            inputSchema: TaskInfo.jsonSchema
        )

        let response = try await model.complete(CompletionRequest(
            messages: [
                .system("Extract task information using the extract_task tool."),
                .user([.text("Task: Review the PR - currently being worked on, waiting for CI to pass")])
            ],
            tools: [tool],
            config: anthropicConfig
        ))

        #expect(!response.toolCalls.isEmpty)

        let task = try JSONDecoder().decode(
            TaskInfo.self,
            from: Data(response.toolCalls[0].arguments.utf8)
        )

        #expect(!task.title.isEmpty)
        #expect(task.status == .inProgress || task.status == .blocked)
    }
}

// MARK: - OpenAI Schema Integration Tests

@Suite("Schema Integration - OpenAI", .tags(.integration), .serialized)
struct OpenAISchemaIntegrationTests {
    /// OpenAI strict mode requires ALL properties in 'required' array.
    /// We use PersonExtractionStrict (no optional fields) for reliable structured output.
    private let model = OpenAIModel(
        name: "gpt-5-mini",
        provider: OpenAIProvider(apiKey: TestConfig.openAIAPIKey)
    )

    @Test("Extract person info using tool with @Schema", .enabled(if: hasOpenAIKey))
    func extractPersonInfoWithTool() async throws {
        let tool = ToolDefinition(
            name: "extract_person",
            description: "Extract person information from text: name, age, and occupation",
            inputSchema: PersonExtractionStrict.jsonSchema
        )

        let response = try await model.complete(CompletionRequest(
            messages: [
                .system("Extract person information using the extract_person tool."),
                .user([.text("Marcus Chen is a 35-year-old data scientist at a research lab.")])
            ],
            tools: [tool],
            config: openAIConfig
        ))

        #expect(!response.toolCalls.isEmpty)
        #expect(response.toolCalls[0].name == "extract_person")

        let person = try JSONDecoder().decode(
            PersonExtractionStrict.self,
            from: Data(response.toolCalls[0].arguments.utf8)
        )

        #expect(person.name.lowercased().contains("marcus"))
        #expect(person.age == 35)
        #expect(person.occupation.lowercased().contains("scientist"))
    }

    @Test("Sentiment analysis using tool with @Schema", .enabled(if: hasOpenAIKey))
    func sentimentAnalysisWithTool() async throws {
        let tool = ToolDefinition(
            name: "analyze_sentiment",
            description: "Analyze sentiment of text",
            inputSchema: SentimentResult.jsonSchema
        )

        let response = try await model.complete(CompletionRequest(
            messages: [
                .system("Analyze the sentiment using the analyze_sentiment tool."),
                .user([.text("This is terrible. Complete waste of money, would not recommend.")])
            ],
            tools: [tool],
            config: openAIConfig
        ))

        #expect(!response.toolCalls.isEmpty, "Expected tool calls but got none. Content: \(response.content ?? "nil")")

        let result = try JSONDecoder().decode(
            SentimentResult.self,
            from: Data(response.toolCalls[0].arguments.utf8)
        )

        #expect(result.sentiment == "negative")
        #expect(result.confidence >= 0.5)
        #expect(!result.keywords.isEmpty, "Keywords array should not be empty")
    }

    @Test("Extract task with enum using tool", .enabled(if: hasOpenAIKey))
    func extractTaskWithEnumTool() async throws {
        let tool = ToolDefinition(
            name: "extract_task",
            description: "Extract task information. Status must be: todo, in_progress, done, or blocked.",
            inputSchema: TaskInfoStrict.jsonSchema
        )

        let response = try await model.complete(CompletionRequest(
            messages: [
                .system("Extract task information using the extract_task tool."),
                .user([.text("Task: Review the PR - currently being worked on, waiting for CI to pass")])
            ],
            tools: [tool],
            config: openAIConfig
        ))

        #expect(!response.toolCalls.isEmpty)

        let task = try JSONDecoder().decode(
            TaskInfoStrict.self,
            from: Data(response.toolCalls[0].arguments.utf8)
        )

        #expect(!task.title.isEmpty)
        #expect(task.status == .inProgress || task.status == .blocked)
    }
}

// MARK: - Schema Serialization Tests (No API key needed)

@Suite("Schema Serialization")
struct SchemaSerializationTests {

    @Test("PersonExtraction schema is valid JSON")
    func personExtractionSchema() throws {
        let schema = PersonExtraction.jsonSchema

        // Validate structure, not just string contents
        guard case .object(let obj) = schema else {
            Issue.record("Expected object schema")
            return
        }

        // Check type is object
        guard let typeValue = obj["type"], case .string(let type) = typeValue else {
            Issue.record("Missing type field")
            return
        }
        #expect(type == "object")

        // Check properties exist with correct types
        guard let propsValue = obj["properties"], case .object(let props) = propsValue else {
            Issue.record("Missing properties field")
            return
        }

        // Validate name property
        guard let nameSchema = props["name"], case .object(let nameObj) = nameSchema,
              let nameType = nameObj["type"], case .string(let nameTypeStr) = nameType else {
            Issue.record("Invalid name property schema")
            return
        }
        #expect(nameTypeStr == "string")

        // Validate age property
        guard let ageSchema = props["age"], case .object(let ageObj) = ageSchema,
              let ageType = ageObj["type"], case .string(let ageTypeStr) = ageType else {
            Issue.record("Invalid age property schema")
            return
        }
        #expect(ageTypeStr == "integer")

        // Validate occupation property (optional)
        guard let occSchema = props["occupation"], case .object(let occObj) = occSchema,
              let occType = occObj["type"], case .string(let occTypeStr) = occType else {
            Issue.record("Invalid occupation property schema")
            return
        }
        #expect(occTypeStr == "string")

        // Check additionalProperties is false
        guard let addPropsValue = obj["additionalProperties"],
              case .bool(let addProps) = addPropsValue else {
            Issue.record("Missing additionalProperties field")
            return
        }
        #expect(addProps == false)

        // Check required array (name and age required, occupation optional)
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
        #expect(!requiredNames.contains("occupation"), "occupation should not be required")
    }

    @Test("Schema round-trips through JSON encoding")
    func schemaRoundTrip() throws {
        let originalSchema = SentimentResult.jsonSchema

        // Encode to JSON
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalSchema)

        // Decode back
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(JSONValue.self, from: data)

        #expect(originalSchema == decoded)
    }

    @Test("Enum schema contains all cases")
    func enumSchemaContainsCases() throws {
        let schema = TaskStatus.jsonSchema

        guard case .object(let obj) = schema,
              let enumValues = obj["enum"],
              case .array(let values) = enumValues else {
            Issue.record("Expected enum array in schema")
            return
        }

        let stringValues = values.compactMap { value -> String? in
            if case .string(let s) = value { return s }
            return nil
        }

        #expect(stringValues.contains("todo"))
        #expect(stringValues.contains("in_progress"))
        #expect(stringValues.contains("done"))
        #expect(stringValues.contains("blocked"))
    }

    @Test("Nested schema type embeds correctly")
    func nestedSchemaEmbeds() throws {
        let schema = TaskWrapper.jsonSchema

        guard case .object(let obj) = schema,
              let props = obj["properties"],
              case .object(let properties) = props,
              let taskSchema = properties["task"],
              case .object(let taskObj) = taskSchema else {
            Issue.record("Expected nested object schema")
            return
        }

        // The nested schema should be a complete object schema
        guard let typeValue = taskObj["type"], case .string(let type) = typeValue else {
            Issue.record("Nested schema missing type field")
            return
        }
        #expect(type == "object")

        // The nested schema should have its own properties
        guard let nestedProps = taskObj["properties"],
              case .object(let nestedProperties) = nestedProps else {
            Issue.record("Nested schema missing properties")
            return
        }

        // Validate nested properties exist
        #expect(nestedProperties["title"] != nil, "Nested schema should have 'title' property")
        #expect(nestedProperties["status"] != nil, "Nested schema should have 'status' property")
        #expect(nestedProperties["notes"] != nil, "Nested schema should have 'notes' property")

        // Validate the nested status is an enum
        guard let statusSchema = nestedProperties["status"],
              case .object(let statusObj) = statusSchema,
              let enumValue = statusObj["enum"],
              case .array(let enumValues) = enumValue else {
            Issue.record("Nested status should be an enum")
            return
        }
        #expect(enumValues.count == 4, "TaskStatus enum should have 4 cases")
    }
}

// Wrapper type for nested schema test (must be at file scope for @Schema macro)
@Schema
private struct TaskWrapper {
    let task: TaskInfo
}

// MARK: - Additional Test Types for Comprehensive Coverage

/// Test type with @Guide constraints to verify LLM respects them
@Schema(description: "Rating with constrained score")
struct RatingResult: Codable {
    @Guide(description: "Rating score", .range(1...5))
    let score: Int

    @Guide(description: "Brief explanation for the rating")
    let explanation: String
}

/// Test type for arrays of @Schema types
@Schema(description: "A product review")
struct ProductReview: Codable {
    let reviewer: String
    let rating: Int
}

@Schema(description: "Collection of product reviews")
struct ReviewCollection: Codable {
    let productName: String
    let reviews: [ProductReview]
}

/// OpenAI-compatible version (all fields required)
@Schema(description: "Rating with constrained score")
struct RatingResultStrict: Codable {
    @Guide(description: "Rating score from 1 to 5")
    let score: Int

    @Guide(description: "Brief explanation for the rating")
    let explanation: String
}

@Schema(description: "Collection of product reviews")
struct ReviewCollectionStrict: Codable {
    let productName: String
    let reviews: [ProductReview]
}

// MARK: - Comprehensive Schema Tests (Anthropic)

@Suite("Schema Comprehensive - Anthropic", .tags(.integration))
struct AnthropicSchemaComprehensiveTests {
    private let model = AnthropicModel(
        name: "claude-haiku-4-5",
        provider: AnthropicProvider(apiKey: TestConfig.anthropicAPIKey)
    )

    @Test("@Guide constraints are included in schema", .enabled(if: hasAnthropicKey))
    func guideConstraintsInSchema() async throws {
        let tool = ToolDefinition(
            name: "rate_content",
            description: "Rate the content quality. Score must be 1-5.",
            inputSchema: RatingResult.jsonSchema
        )

        let response = try await model.complete(CompletionRequest(
            messages: [
                .system("Rate the content using the rate_content tool. The score MUST be between 1 and 5."),
                .user([.text("This is excellent content, very well written and informative.")])
            ],
            tools: [tool],
            config: anthropicConfig
        ))

        #expect(!response.toolCalls.isEmpty)

        let rating = try JSONDecoder().decode(
            RatingResult.self,
            from: Data(response.toolCalls[0].arguments.utf8)
        )

        #expect(rating.score >= 1 && rating.score <= 5, "Score \(rating.score) should be between 1 and 5")
        #expect(!rating.explanation.isEmpty)
    }

    @Test("Arrays of @Schema types work correctly", .enabled(if: hasAnthropicKey))
    func arrayOfSchemaTypes() async throws {
        let tool = ToolDefinition(
            name: "extract_reviews",
            description: "Extract product reviews from text",
            inputSchema: ReviewCollection.jsonSchema
        )

        let response = try await model.complete(CompletionRequest(
            messages: [
                .system("Extract all product reviews using the extract_reviews tool."),
                .user([.text("""
                    Product: Wireless Headphones

                    Review 1: John says "Great sound quality!" - 5 stars
                    Review 2: Sarah says "Comfortable but battery could be better" - 4 stars
                    Review 3: Mike says "Not worth the price" - 2 stars
                    """)])
            ],
            tools: [tool],
            config: anthropicConfig
        ))

        #expect(!response.toolCalls.isEmpty)

        let collection = try JSONDecoder().decode(
            ReviewCollection.self,
            from: Data(response.toolCalls[0].arguments.utf8)
        )

        #expect(collection.productName.lowercased().contains("headphone"))
        #expect(collection.reviews.count >= 2, "Expected at least 2 reviews, got \(collection.reviews.count)")

        for review in collection.reviews {
            #expect(!review.reviewer.isEmpty)
            #expect(review.rating >= 1 && review.rating <= 5)
        }
    }
}

// MARK: - Comprehensive Schema Tests (OpenAI)

@Suite("Schema Comprehensive - OpenAI", .tags(.integration), .serialized)
struct OpenAISchemaComprehensiveTests {
    private let model = OpenAIModel(
        name: "gpt-5-mini",
        provider: OpenAIProvider(apiKey: TestConfig.openAIAPIKey)
    )

    @Test("@Guide constraints are included in schema", .enabled(if: hasOpenAIKey))
    func guideConstraintsInSchema() async throws {
        let tool = ToolDefinition(
            name: "rate_content",
            description: "Rate the content quality. Score must be 1-5.",
            inputSchema: RatingResultStrict.jsonSchema
        )

        let response = try await model.complete(CompletionRequest(
            messages: [
                .system("Rate the content using the rate_content tool. The score MUST be between 1 and 5."),
                .user([.text("This is excellent content, very well written and informative.")])
            ],
            tools: [tool],
            config: openAIConfig
        ))

        #expect(!response.toolCalls.isEmpty)

        let rating = try JSONDecoder().decode(
            RatingResultStrict.self,
            from: Data(response.toolCalls[0].arguments.utf8)
        )

        #expect(rating.score >= 1 && rating.score <= 5, "Score \(rating.score) should be between 1 and 5")
        #expect(!rating.explanation.isEmpty)
    }

    @Test("Arrays of @Schema types work correctly", .enabled(if: hasOpenAIKey))
    func arrayOfSchemaTypes() async throws {
        let tool = ToolDefinition(
            name: "extract_reviews",
            description: "Extract product reviews from text. Each review should have reviewer name and rating (1-5).",
            inputSchema: ReviewCollectionStrict.jsonSchema
        )

        let response = try await model.complete(CompletionRequest(
            messages: [
                .system("Extract all product reviews using the extract_reviews tool."),
                .user([.text("""
                    Product: Wireless Headphones

                    Review 1: John says "Great sound quality!" - 5 stars
                    Review 2: Sarah says "Comfortable but battery could be better" - 4 stars
                    """)])
            ],
            tools: [tool],
            config: openAIConfig
        ))

        #expect(!response.toolCalls.isEmpty, "Expected tool calls but got content: \(response.content ?? "nil")")

        let collection = try JSONDecoder().decode(
            ReviewCollectionStrict.self,
            from: Data(response.toolCalls[0].arguments.utf8)
        )

        #expect(collection.productName.lowercased().contains("headphone"))
        #expect(collection.reviews.count >= 2, "Expected at least 2 reviews, got \(collection.reviews.count)")

        for review in collection.reviews {
            #expect(!review.reviewer.isEmpty, "Reviewer name should not be empty")
            #expect(review.rating >= 1 && review.rating <= 5, "Rating \(review.rating) should be between 1 and 5")
        }
    }

    @Test("@Schema type works with outputSchema (direct structured output)", .enabled(if: hasOpenAIKey))
    func schemaTypeWithOutputSchema() async throws {
        let response = try await model.complete(CompletionRequest(
            messages: [
                .system("Extract the person's information and respond with JSON."),
                .user([.text("Dr. Emily Watson is a 42-year-old neuroscientist at Stanford University.")])
            ],
            outputSchema: PersonExtractionStrict.jsonSchema,
            config: openAIConfig
        ))

        #expect(response.content != nil, "Expected content but got nil")

        let person = try JSONDecoder().decode(
            PersonExtractionStrict.self,
            from: Data(response.content!.utf8)
        )

        #expect(person.name.lowercased().contains("emily") || person.name.lowercased().contains("watson"))
        #expect(person.age == 42)
        #expect(person.occupation.lowercased().contains("scientist") || person.occupation.lowercased().contains("neuro"))
    }
}

// MARK: - Tags

extension Tag {
    @Tag static var integration: Self
}
