/// StructuredOutput Example
/// Demonstrates the typed structured output API for extracting Swift types from LLM responses.
///
/// Requires environment variables:
/// - ANTHROPIC_API_KEY: For Anthropic examples
/// - OPENAI_API_KEY: For OpenAI examples
///
/// Run with: swift run StructuredOutput

import Foundation
import Yrden

// MARK: - Schema Types

@Schema(description: "Extracted information about a person")
struct PersonInfo {
    @Guide(description: "The person's full name")
    let name: String

    @Guide(description: "The person's age in years", .range(0...150))
    let age: Int

    @Guide(description: "The person's occupation or job title")
    let occupation: String
}

@Schema(description: "Sentiment analysis result")
struct SentimentAnalysis {
    @Guide(description: "Overall sentiment", .options(["positive", "negative", "neutral", "mixed"]))
    let sentiment: String

    @Guide(description: "Confidence score", .rangeDouble(0.0...1.0))
    let confidence: Double

    @Guide(description: "Key phrases that influenced the analysis")
    let keyPhrases: [String]

    @Guide(description: "Brief explanation of the sentiment")
    let explanation: String
}

@Schema
enum TaskPriority: String {
    case low
    case medium
    case high
    case urgent
}

@Schema(description: "A task extracted from text")
struct ExtractedTask {
    @Guide(description: "Brief description of the task")
    let title: String

    let priority: TaskPriority

    @Guide(description: "Estimated time in minutes", .range(5...480))
    let estimatedMinutes: Int
}

// MARK: - Helper

func getAPIKey(_ name: String) -> String? {
    ProcessInfo.processInfo.environment[name]
}

// MARK: - OpenAI Example (Native Structured Output)

func runOpenAIExample() async throws {
    guard let apiKey = getAPIKey("OPENAI_API_KEY") else {
        print("⚠️  OPENAI_API_KEY not set, skipping OpenAI example")
        return
    }

    print("\n" + String(repeating: "=", count: 60))
    print("OpenAI Structured Output (Native JSON Mode)")
    print(String(repeating: "=", count: 60))

    let model = OpenAIModel(
        name: "gpt-4o-mini",
        provider: OpenAIProvider(apiKey: apiKey)
    )

    // Example 1: Extract person info using generate()
    print("\n📋 Example 1: Person Extraction")
    print("   Input: \"Dr. Sarah Chen is a 42-year-old neuroscientist at MIT.\"")

    let personResult = try await model.generate(
        "Dr. Sarah Chen is a 42-year-old neuroscientist at MIT.",
        as: PersonInfo.self,
        systemPrompt: "Extract the person's information from the text."
    )

    // Access typed data directly - no manual JSON decoding!
    print("   Result:")
    print("     Name: \(personResult.data.name)")
    print("     Age: \(personResult.data.age)")
    print("     Occupation: \(personResult.data.occupation)")
    print("   Tokens: \(personResult.usage.inputTokens) in, \(personResult.usage.outputTokens) out")

    // Example 2: Sentiment analysis
    print("\n📋 Example 2: Sentiment Analysis")
    print("   Input: \"The product exceeded my expectations! Great quality but shipping was slow.\"")

    let sentimentResult = try await model.generate(
        "The product exceeded my expectations! Great quality but shipping was slow.",
        as: SentimentAnalysis.self,
        systemPrompt: "Analyze the sentiment of the text."
    )

    print("   Result:")
    print("     Sentiment: \(sentimentResult.data.sentiment)")
    print("     Confidence: \(String(format: "%.2f", sentimentResult.data.confidence))")
    print("     Key phrases: \(sentimentResult.data.keyPhrases.joined(separator: ", "))")
    print("     Explanation: \(sentimentResult.data.explanation)")
}

// MARK: - Anthropic Example (Tool-Based Structured Output)

func runAnthropicExample() async throws {
    guard let apiKey = getAPIKey("ANTHROPIC_API_KEY") else {
        print("⚠️  ANTHROPIC_API_KEY not set, skipping Anthropic example")
        return
    }

    print("\n" + String(repeating: "=", count: 60))
    print("Anthropic Structured Output (Tool-Based)")
    print(String(repeating: "=", count: 60))

    let model = AnthropicModel(
        name: "claude-haiku-4-5",
        provider: AnthropicProvider(apiKey: apiKey)
    )

    // Example 1: Extract person info using generateWithTool()
    print("\n📋 Example 1: Person Extraction")
    print("   Input: \"Marcus Johnson is a 35-year-old software architect in Seattle.\"")

    let personResult = try await model.generateWithTool(
        "Marcus Johnson is a 35-year-old software architect in Seattle.",
        as: PersonInfo.self,
        toolName: "extract_person",
        toolDescription: "Extract person information from text",
        systemPrompt: "Use the extract_person tool to extract information."
    )

    // Access typed data directly - no manual JSON decoding!
    print("   Result:")
    print("     Name: \(personResult.data.name)")
    print("     Age: \(personResult.data.age)")
    print("     Occupation: \(personResult.data.occupation)")
    print("   Tokens: \(personResult.usage.inputTokens) in, \(personResult.usage.outputTokens) out")

    // Example 2: Task extraction
    print("\n📋 Example 2: Task Extraction")
    print("   Input: \"Finish the API documentation by Friday - this is urgent, about 2 hours.\"")

    let taskResult = try await model.generateWithTool(
        "Finish the API documentation by Friday - this is urgent and should take about 2 hours.",
        as: ExtractedTask.self,
        toolName: "extract_task",
        toolDescription: "Extract task details including title, priority, and time estimate"
    )

    print("   Result:")
    print("     Title: \(taskResult.data.title)")
    print("     Priority: \(taskResult.data.priority.rawValue)")
    print("     Estimated: \(taskResult.data.estimatedMinutes) minutes")
}

// MARK: - Error Handling Example

func demonstrateErrorHandling() {
    print("\n" + String(repeating: "=", count: 60))
    print("Error Handling with StructuredOutputError")
    print(String(repeating: "=", count: 60))

    print("""

    The typed API throws StructuredOutputError for various failure modes:

    • .modelRefused(reason)     - Model declined to generate output
    • .emptyResponse            - No content or tool calls returned
    • .unexpectedTextResponse   - Expected tool call, got text
    • .unexpectedToolCall       - Expected text, got tool call
    • .decodingFailed(json)     - JSON didn't match schema
    • .incompleteResponse       - Response truncated (max tokens)

    Example usage:

        do {
            let result = try await model.generate(prompt, as: MyType.self)
            print(result.data.name)  // Already typed!
        } catch let error as StructuredOutputError {
            switch error {
            case .modelRefused(let reason):
                print("Model refused: \\(reason)")
            case .decodingFailed(let json, let error):
                print("Failed to decode: \\(json)")
            default:
                print("Error: \\(error)")
            }
        }
    """)
}

// MARK: - Main

print("""
╔══════════════════════════════════════════════════════════════╗
║           Yrden Typed Structured Output Examples             ║
╠══════════════════════════════════════════════════════════════╣
║  This example demonstrates the typed API for extracting      ║
║  Swift types directly from LLM responses.                    ║
║                                                              ║
║  • generate() - Native structured output (OpenAI)            ║
║  • generateWithTool() - Tool-based extraction (Anthropic)    ║
║  • TypedResponse<T> - Decoded data + usage metadata          ║
║                                                              ║
║  No manual JSON decoding needed - access result.data!        ║
╚══════════════════════════════════════════════════════════════╝
""")

do {
    try await runOpenAIExample()
    try await runAnthropicExample()
    demonstrateErrorHandling()
    print("\n✅ All examples completed successfully!")
} catch {
    print("\n❌ Error: \(error)")
}
