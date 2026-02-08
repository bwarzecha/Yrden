/// MLX Exploration - POC for local model inference via mlx-swift-lm
///
/// Tests basic completion, tool calling, thinking blocks, template
/// introspection, and vision with local MLX models on Apple Silicon.
///
/// Usage:
///   swift run MLXExploration [phase]
///
/// Phases:
///   1 - Basic completion with Qwen3-8B (default)
///   2 - Tool calling
///   3 - Thinking & template introspection
///   4 - Vision with Qwen3-VL

import Foundation
import CoreImage
import MLXLLM
import MLXVLM
import MLXLMCommon
import Jinja
import Hub
import Tokenizers

// MARK: - Configuration

let qwen3ModelId = "mlx-community/Qwen3-8B-4bit"

// MARK: - Phase 1: Basic Completion

func phase1BasicCompletion() async throws {
    print("=== Phase 1: Basic Completion ===\n")
    print("Loading model: \(qwen3ModelId)...")

    let container = try await LLMModelFactory.shared.loadContainer(
        configuration: ModelConfiguration(id: qwen3ModelId)
    ) { progress in
        let pct = Int(progress.fractionCompleted * 100)
        if pct % 10 == 0 {
            print("  Loading: \(pct)%")
        }
    }

    print("Model loaded.\n")

    // --- Test 1: Simple non-streaming completion ---
    print("--- Test 1: Simple completion ---")
    let prompt = "What is Swift programming language? Answer in one sentence."
    let messages: [Chat.Message] = [
        .system("You are a helpful assistant. Be concise."),
        .user(prompt),
    ]

    let input = UserInput(chat: messages, additionalContext: ["enable_thinking": false])
    let lmInput = try await container.prepare(input: input)

    let params = GenerateParameters(maxTokens: 200, temperature: 0.6)
    let stream = try await container.generate(input: lmInput, parameters: params)

    var fullText = ""
    for await generation in stream {
        switch generation {
        case .chunk(let text):
            print(text, terminator: "")
            fullText += text
        case .info(let info):
            print("\n\n[Info] Tokens: \(info.promptTokenCount) prompt, \(info.generationTokenCount) generated")
            print("[Info] Speed: \(String(format: "%.1f", info.tokensPerSecond)) tokens/sec")
        case .toolCall(let call):
            print("\n[Unexpected tool call: \(call.function.name)]")
        }
    }
    print("\n")

    // --- Test 2: Streaming ---
    print("--- Test 2: Streaming response ---")
    let streamMessages: [Chat.Message] = [
        .system("You are a helpful assistant. Be concise."),
        .user("List 3 benefits of type safety. Keep each to one line."),
    ]

    let streamInput = UserInput(chat: streamMessages, additionalContext: ["enable_thinking": false])
    let streamLmInput = try await container.prepare(input: streamInput)
    let stream2 = try await container.generate(input: streamLmInput, parameters: params)

    var chunkCount = 0
    for await generation in stream2 {
        if case .chunk(let text) = generation {
            print(text, terminator: "")
            chunkCount += 1
        }
        if case .info(let info) = generation {
            print("\n\n[Info] \(chunkCount) chunks, \(info.generationTokenCount) tokens")
        }
    }
    print("\n")

    print("=== Phase 1 Complete ===\n")
}

// MARK: - Phase 2: Tool Calling

func phase2ToolCalling() async throws {
    print("=== Phase 2: Tool Calling ===\n")
    print("Loading model: \(qwen3ModelId)...")

    let container = try await LLMModelFactory.shared.loadContainer(
        configuration: ModelConfiguration(id: qwen3ModelId)
    ) { progress in
        let pct = Int(progress.fractionCompleted * 100)
        if pct % 25 == 0 { print("  Loading: \(pct)%") }
    }

    print("Model loaded.\n")

    // Define a weather tool as ToolSpec (OpenAI function-calling format)
    let weatherTool: ToolSpec = [
        "type": "function",
        "function": [
            "name": "get_weather",
            "description": "Get the current weather for a city",
            "parameters": [
                "type": "object",
                "properties": [
                    "city": [
                        "type": "string",
                        "description": "The city name, e.g. Prague",
                    ] as [String: any Sendable],
                    "unit": [
                        "type": "string",
                        "enum": ["celsius", "fahrenheit"],
                        "description": "Temperature unit",
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["city"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    // --- Test: Ask about weather (should trigger tool call) ---
    print("--- Test: Tool calling ---")
    let messages: [Chat.Message] = [
        .system("You are a helpful assistant. Use tools when available."),
        .user("What is the weather like in Prague right now?"),
    ]

    let input = UserInput(
        chat: messages,
        tools: [weatherTool],
        additionalContext: ["enable_thinking": false]
    )
    let lmInput = try await container.prepare(input: input)
    let params = GenerateParameters(maxTokens: 500, temperature: 0.1)
    let stream = try await container.generate(input: lmInput, parameters: params)

    var textOutput = ""
    var toolCalls: [MLXLMCommon.ToolCall] = []

    for await generation in stream {
        switch generation {
        case .chunk(let text):
            print("[chunk] \(text.debugDescription)")
            textOutput += text
        case .toolCall(let call):
            print("\n[TOOL CALL] name: \(call.function.name)")
            print("[TOOL CALL] arguments: \(call.function.arguments)")
            toolCalls.append(call)
        case .info(let info):
            print("\n[Info] \(info.generationTokenCount) tokens generated")
        }
    }

    if toolCalls.isEmpty {
        print("\nNo tool calls detected. Raw text output:")
        print(textOutput)
    } else {
        print("\n\(toolCalls.count) tool call(s) detected.")

        // --- Test: Feed tool result back ---
        print("\n--- Test: Multi-turn with tool result ---")
        var multiTurnMessages: [Chat.Message] = [
            .system("You are a helpful assistant. Use tools when available."),
            .user("What is the weather like in Prague right now?"),
        ]
        multiTurnMessages.append(.assistant(textOutput))
        multiTurnMessages.append(.tool("{\"temperature\": 22, \"condition\": \"partly cloudy\", \"humidity\": 65}"))

        let resultInput = UserInput(
            chat: multiTurnMessages,
            tools: [weatherTool],
            additionalContext: ["enable_thinking": false]
        )
        let resultLmInput = try await container.prepare(input: resultInput)
        let resultStream = try await container.generate(input: resultLmInput, parameters: params)

        for await generation in resultStream {
            if case .chunk(let text) = generation {
                print(text, terminator: "")
            }
        }
        print("\n")
    }

    print("=== Phase 2 Complete ===\n")
}

// MARK: - Phase 3: Thinking & Template Introspection

func phase3Thinking() async throws {
    print("=== Phase 3: Thinking & Template Introspection ===\n")

    // --- Test: Template parameter discovery ---
    print("--- Test: Template introspection for \(qwen3ModelId) ---")

    // Download model config to read the chat template
    let hub = HubApi()
    let modelId = qwen3ModelId
    let repo = Hub.Repo(id: modelId)

    // Download tokenizer_config.json
    let configURL = try await hub.snapshot(from: repo, matching: ["tokenizer_config.json"])
    let configPath = configURL.appending(path: "tokenizer_config.json")
    let configData = try Data(contentsOf: configPath)

    guard let configDict = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
          let chatTemplate = configDict["chat_template"] as? String else {
        print("ERROR: Could not read chat_template from tokenizer_config.json")
        return
    }

    print("Chat template length: \(chatTemplate.count) characters")
    print("First 200 chars: \(String(chatTemplate.prefix(200)))...\n")

    // Parse template with swift-jinja AST
    let discoveredParams = discoverTemplateParameters(template: chatTemplate)
    print("Discovered template parameters: \(discoveredParams.sorted())")
    print()

    // --- Test: Thinking mode ---
    print("--- Test: Thinking mode (enable_thinking: true) ---")

    let container = try await LLMModelFactory.shared.loadContainer(
        configuration: ModelConfiguration(id: qwen3ModelId)
    ) { progress in
        let pct = Int(progress.fractionCompleted * 100)
        if pct % 25 == 0 { print("  Loading: \(pct)%") }
    }

    let thinkMessages: [Chat.Message] = [
        .user("What is 15 * 37? Think step by step."),
    ]

    // With thinking enabled
    let thinkInput = UserInput(
        chat: thinkMessages,
        additionalContext: ["enable_thinking": true]
    )
    let lmInput = try await container.prepare(input: thinkInput)
    let params = GenerateParameters(maxTokens: 1000, temperature: 0.6)
    let stream = try await container.generate(input: lmInput, parameters: params)

    var rawOutput = ""
    for await generation in stream {
        if case .chunk(let text) = generation {
            rawOutput += text
        }
        if case .info(let info) = generation {
            print("[Info] \(info.generationTokenCount) tokens")
        }
    }

    // Check for <think> tags
    let hasThinkOpen = rawOutput.contains("<think>")
    let hasThinkClose = rawOutput.contains("</think>")
    print("Contains <think>: \(hasThinkOpen)")
    print("Contains </think>: \(hasThinkClose)")

    if hasThinkOpen, let thinkStart = rawOutput.range(of: "<think>"),
       let thinkEnd = rawOutput.range(of: "</think>") {
        let thinkContent = String(rawOutput[thinkStart.upperBound..<thinkEnd.lowerBound])
        let responseContent = String(rawOutput[thinkEnd.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        print("\nThinking content (\(thinkContent.count) chars):")
        print("  \(String(thinkContent.prefix(300)))...")
        print("\nResponse content:")
        print("  \(responseContent)")
    } else {
        print("\nRaw output (first 500 chars):")
        print(String(rawOutput.prefix(500)))
    }

    print("\n=== Phase 3 Complete ===\n")
}

// MARK: - Template Parameter Discovery

/// Discovers model-specific template parameters by parsing the Jinja chat template AST.
///
/// Parses the template, walks the AST to find all referenced identifiers,
/// then subtracts loop variables, set variables, and well-known framework variables.
func discoverTemplateParameters(template: String) -> Set<String> {
    // Well-known framework variables that are always provided by the system
    let frameworkVars: Set<String> = [
        "messages", "tools", "add_generation_prompt", "bos_token", "eos_token",
        "sep_token", "pad_token", "unk_token", "chat_template",
        "true", "false", "none", "True", "False", "None",
        "loop", "caller", "range", "namespace", "cycler", "joiner",
        "raise_exception", "strftime_now",
    ]

    // String/object methods and message fields that appear as identifiers
    // but are accessed via member expressions (e.g. message.role, text.strip())
    let memberNames: Set<String> = [
        // Jinja string methods
        "strip", "lstrip", "rstrip", "split", "startswith", "endswith",
        "upper", "lower", "trim", "replace", "join", "length",
        // Message/tool fields (accessed via member expressions)
        "role", "content", "name", "arguments", "function", "tool_calls",
        "tool_call_id", "type", "parameters",
        // Jinja loop variables
        "index0", "index", "first", "last", "length", "revindex",
    ]

    do {
        let tokens = try Lexer.tokenize(template)
        let nodes = try Parser.parse(tokens)

        var identifiers = Set<String>()
        var definedNames = Set<String>()
        var testedNames = Set<String>() // Names in "is defined" tests = external params

        walkNodes(nodes, identifiers: &identifiers, definedNames: &definedNames, testedNames: &testedNames)

        // Variables tested with "is defined" are external parameters even if later set
        let discovered = identifiers
            .subtracting(definedNames)
            .subtracting(frameworkVars)
            .subtracting(memberNames)
            .union(testedNames.subtracting(frameworkVars))

        return discovered
    } catch {
        print("Template parse error: \(error)")
        // Fallback: regex-based detection for common parameters
        return regexFallbackDiscovery(template: template)
    }
}

private func walkNodes(_ nodes: [Node], identifiers: inout Set<String>, definedNames: inout Set<String>, testedNames: inout Set<String>) {
    for node in nodes {
        switch node {
        case .expression(let expr):
            walkExpression(expr, identifiers: &identifiers, testedNames: &testedNames)
        case .statement(let stmt):
            walkStatement(stmt, identifiers: &identifiers, definedNames: &definedNames, testedNames: &testedNames)
        case .text, .comment:
            break
        }
    }
}

private func walkExpression(_ expr: Jinja.Expression, identifiers: inout Set<String>, testedNames: inout Set<String>) {
    switch expr {
    case .identifier(let name):
        identifiers.insert(name)
    case .binary(_, let lhs, let rhs):
        walkExpression(lhs, identifiers: &identifiers, testedNames: &testedNames)
        walkExpression(rhs, identifiers: &identifiers, testedNames: &testedNames)
    case .unary(_, let operand):
        walkExpression(operand, identifiers: &identifiers, testedNames: &testedNames)
    case .call(let callee, let args, let kwargs):
        walkExpression(callee, identifiers: &identifiers, testedNames: &testedNames)
        for arg in args { walkExpression(arg, identifiers: &identifiers, testedNames: &testedNames) }
        for (_, val) in kwargs { walkExpression(val, identifiers: &identifiers, testedNames: &testedNames) }
    case .member(let obj, _, _):
        walkExpression(obj, identifiers: &identifiers, testedNames: &testedNames)
    case .filter(let expr, _, let args, let kwargs):
        walkExpression(expr, identifiers: &identifiers, testedNames: &testedNames)
        for arg in args { walkExpression(arg, identifiers: &identifiers, testedNames: &testedNames) }
        for (_, val) in kwargs { walkExpression(val, identifiers: &identifiers, testedNames: &testedNames) }
    case .test(let expr, let testName, let args, _):
        walkExpression(expr, identifiers: &identifiers, testedNames: &testedNames)
        for arg in args { walkExpression(arg, identifiers: &identifiers, testedNames: &testedNames) }
        // "X is defined" means X is an external parameter
        if testName == "defined", case .identifier(let name) = expr {
            testedNames.insert(name)
        }
    case .ternary(let value, let test, let alt):
        walkExpression(value, identifiers: &identifiers, testedNames: &testedNames)
        walkExpression(test, identifiers: &identifiers, testedNames: &testedNames)
        if let alt { walkExpression(alt, identifiers: &identifiers, testedNames: &testedNames) }
    case .slice(let expr, let start, let stop, let step):
        walkExpression(expr, identifiers: &identifiers, testedNames: &testedNames)
        if let start { walkExpression(start, identifiers: &identifiers, testedNames: &testedNames) }
        if let stop { walkExpression(stop, identifiers: &identifiers, testedNames: &testedNames) }
        if let step { walkExpression(step, identifiers: &identifiers, testedNames: &testedNames) }
    case .array(let exprs), .tuple(let exprs):
        for e in exprs { walkExpression(e, identifiers: &identifiers, testedNames: &testedNames) }
    case .object(let dict):
        for (_, val) in dict { walkExpression(val, identifiers: &identifiers, testedNames: &testedNames) }
    default:
        break // literals: .string, .number, .integer, .boolean, .null
    }
}

private func walkStatement(_ stmt: Statement, identifiers: inout Set<String>, definedNames: inout Set<String>, testedNames: inout Set<String>) {
    switch stmt {
    case .program(let body):
        walkNodes(body, identifiers: &identifiers, definedNames: &definedNames, testedNames: &testedNames)
    case .set(let target, let value, let body):
        walkExpression(target, identifiers: &identifiers, testedNames: &testedNames)
        if let value { walkExpression(value, identifiers: &identifiers, testedNames: &testedNames) }
        walkNodes(body, identifiers: &identifiers, definedNames: &definedNames, testedNames: &testedNames)
        if case .identifier(let name) = target {
            definedNames.insert(name)
        }
    case .if(let test, let body, let alt):
        walkExpression(test, identifiers: &identifiers, testedNames: &testedNames)
        walkNodes(body, identifiers: &identifiers, definedNames: &definedNames, testedNames: &testedNames)
        walkNodes(alt, identifiers: &identifiers, definedNames: &definedNames, testedNames: &testedNames)
    case .for(let loopVar, let iterable, let body, let elseBody, let test):
        walkExpression(iterable, identifiers: &identifiers, testedNames: &testedNames)
        if let test { walkExpression(test, identifiers: &identifiers, testedNames: &testedNames) }
        switch loopVar {
        case .single(let name): definedNames.insert(name)
        case .tuple(let names): for name in names { definedNames.insert(name) }
        }
        walkNodes(body, identifiers: &identifiers, definedNames: &definedNames, testedNames: &testedNames)
        walkNodes(elseBody, identifiers: &identifiers, definedNames: &definedNames, testedNames: &testedNames)
    case .macro(let name, _, _, let body):
        definedNames.insert(name)
        walkNodes(body, identifiers: &identifiers, definedNames: &definedNames, testedNames: &testedNames)
    case .filter(let filterExpr, let body):
        walkExpression(filterExpr, identifiers: &identifiers, testedNames: &testedNames)
        walkNodes(body, identifiers: &identifiers, definedNames: &definedNames, testedNames: &testedNames)
    case .call(let callable, let args, let body):
        walkExpression(callable, identifiers: &identifiers, testedNames: &testedNames)
        if let args { for a in args { walkExpression(a, identifiers: &identifiers, testedNames: &testedNames) } }
        walkNodes(body, identifiers: &identifiers, definedNames: &definedNames, testedNames: &testedNames)
    case .generation(let body):
        walkNodes(body, identifiers: &identifiers, definedNames: &definedNames, testedNames: &testedNames)
    case .break, .continue:
        break
    }
}

/// Fallback regex-based discovery for common template parameters.
private func regexFallbackDiscovery(template: String) -> Set<String> {
    var params = Set<String>()
    // Look for {% if PARAM is defined %} or {% if PARAM %}
    let pattern = #"\{%[-\s]*if\s+(\w+)\s+is\s+defined"#
    if let regex = try? NSRegularExpression(pattern: pattern) {
        let matches = regex.matches(in: template, range: NSRange(template.startIndex..., in: template))
        for match in matches {
            if let range = Range(match.range(at: 1), in: template) {
                params.insert(String(template[range]))
            }
        }
    }
    let frameworkVars: Set<String> = ["messages", "tools", "add_generation_prompt"]
    return params.subtracting(frameworkVars)
}

// MARK: - Phase 4: Vision

let qwen3VLModelId = "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit"

func phase4Vision() async throws {
    print("=== Phase 4: Vision ===\n")
    print("Loading VLM: \(qwen3VLModelId)...")

    let container = try await VLMModelFactory.shared.loadContainer(
        configuration: ModelConfiguration(id: qwen3VLModelId)
    ) { progress in
        let pct = Int(progress.fractionCompleted * 100)
        if pct % 25 == 0 { print("  Loading: \(pct)%") }
    }

    print("VLM loaded.\n")

    // Create a simple test image (solid red 100x100)
    let redColor = CIColor(red: 1.0, green: 0.0, blue: 0.0)
    let redImage = CIImage(color: redColor).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))

    // --- Test 1: Describe image ---
    print("--- Test 1: Image description ---")
    let messages: [Chat.Message] = [
        .system("You are a helpful assistant. Be concise."),
        .user("What color is this image? Answer in one word.", images: [.ciImage(redImage)]),
    ]

    let input = UserInput(chat: messages)
    let lmInput = try await container.prepare(input: input)
    let params = GenerateParameters(maxTokens: 50, temperature: 0.1)
    let stream = try await container.generate(input: lmInput, parameters: params)

    var responseText = ""
    for await generation in stream {
        switch generation {
        case .chunk(let text):
            print(text, terminator: "")
            responseText += text
        case .info(let info):
            print("\n[Info] \(info.generationTokenCount) tokens, \(String(format: "%.1f", info.tokensPerSecond)) tok/s")
        case .toolCall(let call):
            print("\n[Tool call: \(call.function.name)]")
        }
    }
    print("\n")

    // --- Test 2: Vision + tool calling ---
    print("--- Test 2: Vision + tool calling ---")
    let analysisTool: ToolSpec = [
        "type": "function",
        "function": [
            "name": "log_color",
            "description": "Log the detected color of an image",
            "parameters": [
                "type": "object",
                "properties": [
                    "color": [
                        "type": "string",
                        "description": "The detected color name",
                    ] as [String: any Sendable],
                    "confidence": [
                        "type": "number",
                        "description": "Confidence score 0-1",
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["color"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    let toolMessages: [Chat.Message] = [
        .system("You are a helpful assistant. Use tools when available."),
        .user("Analyze this image and log its color using the log_color tool.", images: [.ciImage(redImage)]),
    ]

    let toolInput = UserInput(chat: toolMessages, tools: [analysisTool])
    let toolLmInput = try await container.prepare(input: toolInput)
    let toolStream = try await container.generate(input: toolLmInput, parameters: params)

    var visionToolCalls: [MLXLMCommon.ToolCall] = []
    for await generation in toolStream {
        switch generation {
        case .chunk(let text):
            print(text, terminator: "")
        case .toolCall(let call):
            print("\n[TOOL CALL] \(call.function.name): \(call.function.arguments)")
            visionToolCalls.append(call)
        case .info(let info):
            print("\n[Info] \(info.generationTokenCount) tokens")
        }
    }

    if visionToolCalls.isEmpty {
        print("\nNo tool calls detected in vision+tool test.")
    } else {
        print("\n\(visionToolCalls.count) tool call(s) from vision model.")
    }

    print("\n=== Phase 4 Complete ===\n")
}

// MARK: - Phase 5: GPT-OSS Template Introspection

let gptOSSModelId = "mlx-community/gpt-oss-20b-MXFP4-Q8"

func phase5GptOSS() async throws {
    print("=== Phase 5: GPT-OSS 20B Template Introspection ===\n")

    // Download tokenizer config to read the chat template
    let hub = HubApi()
    let repo = Hub.Repo(id: gptOSSModelId)

    print("Downloading tokenizer config for \(gptOSSModelId)...")
    let configURL = try await hub.snapshot(from: repo, matching: ["tokenizer_config.json"])
    let configPath = configURL.appending(path: "tokenizer_config.json")
    let configData = try Data(contentsOf: configPath)

    guard let configDict = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
          let chatTemplate = configDict["chat_template"] as? String else {
        print("ERROR: Could not read chat_template from tokenizer_config.json")
        return
    }

    print("Chat template length: \(chatTemplate.count) characters")
    print("First 300 chars:\n\(String(chatTemplate.prefix(300)))...\n")

    // Discover template parameters
    let params = discoverTemplateParameters(template: chatTemplate)
    print("Discovered template parameters: \(params.sorted())")

    // Check for reasoning-related parameters
    let reasoningParams = params.filter { p in
        p.lowercased().contains("reason") ||
        p.lowercased().contains("think") ||
        p.lowercased().contains("effort")
    }
    if !reasoningParams.isEmpty {
        print("\nReasoning-related parameters found: \(reasoningParams.sorted())")
    } else {
        print("\nNo reasoning-related parameters found via AST.")
        print("Checking raw template for reasoning keywords...")

        let keywords = ["reason", "think", "effort", "chain_of_thought", "cot"]
        for kw in keywords {
            if chatTemplate.lowercased().contains(kw) {
                print("  Found keyword '\(kw)' in template text")
            }
        }
    }

    // Also compare with Qwen3's parameters
    print("\n--- Comparison with Qwen3-8B ---")
    let qwenHub = HubApi()
    let qwenRepo = Hub.Repo(id: qwen3ModelId)
    let qwenConfigURL = try await qwenHub.snapshot(from: qwenRepo, matching: ["tokenizer_config.json"])
    let qwenConfigPath = qwenConfigURL.appending(path: "tokenizer_config.json")
    let qwenConfigData = try Data(contentsOf: qwenConfigPath)

    if let qwenDict = try JSONSerialization.jsonObject(with: qwenConfigData) as? [String: Any],
       let qwenTemplate = qwenDict["chat_template"] as? String {
        let qwenParams = discoverTemplateParameters(template: qwenTemplate)
        print("Qwen3-8B params:  \(qwenParams.sorted())")
        print("GPT-OSS params:   \(params.sorted())")
        print("Unique to GPT-OSS: \(params.subtracting(qwenParams).sorted())")
        print("Unique to Qwen3:   \(qwenParams.subtracting(params).sorted())")
    }

    print("\n=== Phase 5 Complete ===\n")
}

// MARK: - Phase 6: Multi-Model Testing

/// Tests a model with basic completion and optional tool calling.
/// Returns (success: Bool, modelType: String?, templateParams: Set<String>)
func testModel(
    id: String,
    factory: String = "llm",
    testTools: Bool = true
) async throws -> (success: Bool, modelType: String?, templateParams: Set<String>) {
    print("--- Testing model: \(id) ---")

    // 1. Discover model type from config.json
    let hub = HubApi()
    let repo = Hub.Repo(id: id)

    var modelType: String?
    var templateParams = Set<String>()

    // Download config.json to read model_type
    do {
        let configURL = try await hub.snapshot(from: repo, matching: ["config.json"])
        let configPath = configURL.appending(path: "config.json")
        let configData = try Data(contentsOf: configPath)
        if let configDict = try JSONSerialization.jsonObject(with: configData) as? [String: Any] {
            modelType = configDict["model_type"] as? String
            print("  model_type: \(modelType ?? "unknown")")
        }
    } catch {
        print("  config.json read error: \(error)")
    }

    // Download tokenizer_config.json for template introspection
    do {
        let tokURL = try await hub.snapshot(from: repo, matching: ["tokenizer_config.json"])
        let tokPath = tokURL.appending(path: "tokenizer_config.json")
        let tokData = try Data(contentsOf: tokPath)
        if let tokDict = try JSONSerialization.jsonObject(with: tokData) as? [String: Any],
           let chatTemplate = tokDict["chat_template"] as? String {
            templateParams = discoverTemplateParameters(template: chatTemplate)
            let paramTypes = discoverParameterTypes(template: chatTemplate, params: templateParams)
            print("  template params: \(templateParams.sorted())")
            for (name, info) in paramTypes.sorted(by: { $0.key < $1.key }) {
                print("    \(name): \(info)")
            }
        }
    } catch {
        print("  tokenizer_config.json read error: \(error)")
    }

    // 2. Load model
    print("  Loading...")
    let container: ModelContainer
    if factory == "vlm" {
        container = try await VLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(id: id)
        ) { progress in
            let pct = Int(progress.fractionCompleted * 100)
            if pct % 50 == 0 { print("  Loading: \(pct)%") }
        }
    } else {
        container = try await LLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(id: id)
        ) { progress in
            let pct = Int(progress.fractionCompleted * 100)
            if pct % 50 == 0 { print("  Loading: \(pct)%") }
        }
    }

    // 3. Basic completion test
    print("  Testing basic completion...")
    let messages: [Chat.Message] = [
        .system("You are a helpful assistant. Be concise."),
        .user("What is 2 + 2? Answer with just the number."),
    ]

    // Build additionalContext based on discovered template params
    var additionalContext: [String: any Sendable] = [:]
    if templateParams.contains("enable_thinking") {
        additionalContext["enable_thinking"] = false
    }

    let input = UserInput(
        chat: messages,
        additionalContext: additionalContext.isEmpty ? nil : additionalContext
    )
    let lmInput = try await container.prepare(input: input)
    let params = GenerateParameters(maxTokens: 100, temperature: 0.1)
    let stream = try await container.generate(input: lmInput, parameters: params)

    var responseText = ""
    var tokenCount = 0
    var tokensPerSec = 0.0
    for await generation in stream {
        switch generation {
        case .chunk(let text):
            responseText += text
        case .info(let info):
            tokenCount = info.generationTokenCount
            tokensPerSec = info.tokensPerSecond
        case .toolCall(let call):
            print("  [Unexpected tool call: \(call.function.name)]")
        }
    }

    let has4 = responseText.contains("4")
    print("  Response: \(responseText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))")
    print("  Contains '4': \(has4), \(tokenCount) tokens, \(String(format: "%.1f", tokensPerSec)) tok/s")

    // 4. Tool calling test
    if testTools {
        print("  Testing tool calling...")
        let weatherTool: ToolSpec = [
            "type": "function",
            "function": [
                "name": "get_weather",
                "description": "Get current weather for a city",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "city": ["type": "string", "description": "City name"] as [String: any Sendable],
                    ] as [String: any Sendable],
                    "required": ["city"],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]

        let toolMessages: [Chat.Message] = [
            .system("You are a helpful assistant. Use tools when available."),
            .user("What is the weather in Tokyo?"),
        ]
        let toolInput = UserInput(
            chat: toolMessages,
            tools: [weatherTool],
            additionalContext: additionalContext.isEmpty ? nil : additionalContext
        )
        let toolLmInput = try await container.prepare(input: toolInput)
        let toolStream = try await container.generate(input: toolLmInput, parameters: params)

        var toolCalls: [MLXLMCommon.ToolCall] = []
        for await generation in toolStream {
            if case .toolCall(let call) = generation {
                toolCalls.append(call)
            }
        }
        print("  Tool calls detected: \(toolCalls.count)")
        for call in toolCalls {
            print("    \(call.function.name)(\(call.function.arguments))")
        }
    }

    print("  DONE: \(id)\n")
    return (has4, modelType, templateParams)
}

func phase6MultiModel() async throws {
    print("=== Phase 6: Multi-Model Testing ===\n")

    let models = [
        ("mlx-community/gemma-3-1b-it-qat-4bit", "llm"),
        ("mlx-community/Llama-3.2-1B-Instruct-4bit", "llm"),
        ("mlx-community/gpt-oss-20b-MXFP4-Q8", "llm"),
    ]

    var results: [(id: String, success: Bool, modelType: String?, params: Set<String>)] = []

    for (modelId, factory) in models {
        do {
            let (success, modelType, params) = try await testModel(id: modelId, factory: factory)
            results.append((modelId, success, modelType, params))
        } catch {
            print("  ERROR: \(error)\n")
            results.append((modelId, false, nil, []))
        }
    }

    print("\n--- Multi-Model Summary ---")
    for r in results {
        let name = String(r.id.suffix(45))
        let type = r.modelType ?? "?"
        let status = r.success ? "PASS" : "FAIL"
        let params = r.params.sorted().joined(separator: ", ")
        print("  \(name)  type=\(type)  basic=\(status)  params=[\(params)]")
    }

    print("\n=== Phase 6 Complete ===\n")
}

// MARK: - Phase 7: Working VLM

func phase7WorkingVLM() async throws {
    print("=== Phase 7: Working VLM ===\n")

    // SmolVLM is a different architecture from Qwen3-VL
    let vlmModels = [
        "mlx-community/SmolVLM-Instruct-4bit",
        "mlx-community/gemma-3-4b-it-qat-4bit",
    ]

    let redColor = CIColor(red: 1.0, green: 0.0, blue: 0.0)
    let redImage = CIImage(color: redColor).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))

    for vlmId in vlmModels {
        print("--- Testing VLM: \(vlmId) ---")

        // Read model_type from config
        do {
            let hub = HubApi()
            let repo = Hub.Repo(id: vlmId)
            let configURL = try await hub.snapshot(from: repo, matching: ["config.json"])
            let configPath = configURL.appending(path: "config.json")
            let configData = try Data(contentsOf: configPath)
            if let configDict = try JSONSerialization.jsonObject(with: configData) as? [String: Any] {
                let modelType = configDict["model_type"] as? String ?? "unknown"
                print("  model_type: \(modelType)")
            }
        } catch {
            print("  config read error: \(error)")
        }

        do {
            print("  Loading VLM...")
            let container = try await VLMModelFactory.shared.loadContainer(
                configuration: ModelConfiguration(id: vlmId)
            ) { progress in
                let pct = Int(progress.fractionCompleted * 100)
                if pct % 50 == 0 { print("  Loading: \(pct)%") }
            }

            // Test: describe image color
            let messages: [Chat.Message] = [
                .system("You are a helpful assistant. Be concise."),
                .user("What color is this image? Answer with just the color name.", images: [.ciImage(redImage)]),
            ]
            let input = UserInput(chat: messages)
            let lmInput = try await container.prepare(input: input)
            let params = GenerateParameters(maxTokens: 50, temperature: 0.1)
            let stream = try await container.generate(input: lmInput, parameters: params)

            var responseText = ""
            for await generation in stream {
                switch generation {
                case .chunk(let text):
                    responseText += text
                case .info(let info):
                    print("  \(info.generationTokenCount) tokens, \(String(format: "%.1f", info.tokensPerSecond)) tok/s")
                case .toolCall(let call):
                    print("  [Tool call: \(call.function.name)]")
                }
            }

            let containsRed = responseText.lowercased().contains("red")
            print("  Response: \(responseText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))")
            print("  Contains 'red': \(containsRed)")
            print("  RESULT: \(containsRed ? "PASS" : "FAIL")\n")
        } catch {
            print("  ERROR: \(error)\n")
        }
    }

    print("=== Phase 7 Complete ===\n")
}

// MARK: - Parameter Type Discovery

/// Infers parameter types and valid values from template usage patterns.
struct ParamInfo: CustomStringConvertible {
    var inferredType: String = "unknown"
    var defaultValue: String?
    var validValues: [String]?

    var description: String {
        var parts = [inferredType]
        if let def = defaultValue { parts.append("default=\(def)") }
        if let vals = validValues { parts.append("values=\(vals)") }
        return parts.joined(separator: ", ")
    }
}

func discoverParameterTypes(template: String, params: Set<String>) -> [String: ParamInfo] {
    var result: [String: ParamInfo] = [:]
    for p in params { result[p] = ParamInfo() }

    do {
        let tokens = try Lexer.tokenize(template)
        let nodes = try Parser.parse(tokens)
        inferTypes(nodes: nodes, result: &result)
    } catch {
        // Fallback: check for common patterns via regex
    }

    return result
}

private func inferTypes(nodes: [Node], result: inout [String: ParamInfo]) {
    for node in nodes {
        switch node {
        case .expression(let expr):
            inferTypesFromExpr(expr, result: &result)
        case .statement(let stmt):
            inferTypesFromStmt(stmt, result: &result)
        case .text, .comment:
            break
        }
    }
}

private func inferTypesFromExpr(_ expr: Jinja.Expression, result: inout [String: ParamInfo]) {
    switch expr {
    case .test(let operand, let testName, _, _):
        // "X is false" or "X is true" → boolean
        if case .identifier(let name) = operand, result[name] != nil {
            if testName == "true" || testName == "false" {
                result[name]?.inferredType = "bool"
                result[name]?.validValues = ["true", "false"]
            } else if testName == "string" {
                result[name]?.inferredType = "string"
            } else if testName == "number" || testName == "integer" {
                result[name]?.inferredType = "number"
            } else if testName == "iterable" || testName == "sequence" {
                result[name]?.inferredType = "array"
            }
        }
        inferTypesFromExpr(operand, result: &result)

    case .binary(let op, let lhs, let rhs):
        // "X == 'value'" → string enum with known value
        if case .identifier(let name) = lhs, result[name] != nil {
            if op == .equal {
                if case .string(let val) = rhs {
                    result[name]?.inferredType = "string"
                    var vals = result[name]?.validValues ?? []
                    if !vals.contains(val) { vals.append(val) }
                    result[name]?.validValues = vals
                }
            }
        }
        // Also check reversed: "'value' == X"
        if case .identifier(let name) = rhs, result[name] != nil {
            if op == .equal {
                if case .string(let val) = lhs {
                    result[name]?.inferredType = "string"
                    var vals = result[name]?.validValues ?? []
                    if !vals.contains(val) { vals.append(val) }
                    result[name]?.validValues = vals
                }
            }
        }
        inferTypesFromExpr(lhs, result: &result)
        inferTypesFromExpr(rhs, result: &result)

    case .call(let callee, let args, let kwargs):
        inferTypesFromExpr(callee, result: &result)
        for a in args { inferTypesFromExpr(a, result: &result) }
        for (_, v) in kwargs { inferTypesFromExpr(v, result: &result) }

    case .member(let obj, _, _):
        inferTypesFromExpr(obj, result: &result)

    case .filter(let expr, _, let args, let kwargs):
        inferTypesFromExpr(expr, result: &result)
        for a in args { inferTypesFromExpr(a, result: &result) }
        for (_, v) in kwargs { inferTypesFromExpr(v, result: &result) }

    case .ternary(let v, let t, let a):
        inferTypesFromExpr(v, result: &result)
        inferTypesFromExpr(t, result: &result)
        if let a { inferTypesFromExpr(a, result: &result) }

    case .unary(_, let operand):
        inferTypesFromExpr(operand, result: &result)

    case .array(let exprs), .tuple(let exprs):
        for e in exprs { inferTypesFromExpr(e, result: &result) }

    default:
        break
    }
}

private func inferTypesFromStmt(_ stmt: Statement, result: inout [String: ParamInfo]) {
    switch stmt {
    case .program(let body):
        inferTypes(nodes: body, result: &result)

    case .set(let target, let value, let body):
        // "set X = 'default'" → extract default value
        if case .identifier(let name) = target, result[name] != nil {
            if let value {
                switch value {
                case .string(let s):
                    result[name]?.defaultValue = "\"\(s)\""
                    if result[name]?.inferredType == "unknown" {
                        result[name]?.inferredType = "string"
                    }
                case .boolean(let b):
                    result[name]?.defaultValue = String(b)
                    result[name]?.inferredType = "bool"
                case .integer(let i):
                    result[name]?.defaultValue = String(i)
                    result[name]?.inferredType = "number"
                case .number(let d):
                    result[name]?.defaultValue = String(d)
                    result[name]?.inferredType = "number"
                default:
                    break
                }
            }
        }
        if let value { inferTypesFromExpr(value, result: &result) }
        inferTypes(nodes: body, result: &result)

    case .if(let test, let body, let alt):
        inferTypesFromExpr(test, result: &result)
        inferTypes(nodes: body, result: &result)
        inferTypes(nodes: alt, result: &result)

    case .for(let loopVar, let iterable, let body, let elseBody, let test):
        // "for item in X" → X is array
        if case .identifier(let name) = iterable, result[name] != nil {
            result[name]?.inferredType = "array"
            // Collect string comparisons on loop variable within body
            let loopVarName: String? = {
                switch loopVar {
                case .single(let n): return n
                default: return nil
                }
            }()
            if let lvName = loopVarName {
                collectEnumValues(nodes: body, loopVar: lvName, param: name, result: &result)
            }
        }
        inferTypesFromExpr(iterable, result: &result)
        if let test { inferTypesFromExpr(test, result: &result) }
        inferTypes(nodes: body, result: &result)
        inferTypes(nodes: elseBody, result: &result)

    case .macro(_, _, _, let body):
        inferTypes(nodes: body, result: &result)
    case .filter(let expr, let body):
        inferTypesFromExpr(expr, result: &result)
        inferTypes(nodes: body, result: &result)
    case .call(let callable, let args, let body):
        inferTypesFromExpr(callable, result: &result)
        if let args { for a in args { inferTypesFromExpr(a, result: &result) } }
        inferTypes(nodes: body, result: &result)
    case .generation(let body):
        inferTypes(nodes: body, result: &result)
    case .break, .continue:
        break
    }
}

/// When we see `for item in param`, collect `item == "value"` comparisons to discover enum values.
private func collectEnumValues(nodes: [Node], loopVar: String, param: String, result: inout [String: ParamInfo]) {
    for node in nodes {
        switch node {
        case .expression(let expr):
            collectEnumFromExpr(expr, loopVar: loopVar, param: param, result: &result)
        case .statement(let stmt):
            switch stmt {
            case .if(let test, let body, let alt):
                collectEnumFromExpr(test, loopVar: loopVar, param: param, result: &result)
                collectEnumValues(nodes: body, loopVar: loopVar, param: param, result: &result)
                collectEnumValues(nodes: alt, loopVar: loopVar, param: param, result: &result)
            default:
                break
            }
        default:
            break
        }
    }
}

private func collectEnumFromExpr(_ expr: Jinja.Expression, loopVar: String, param: String, result: inout [String: ParamInfo]) {
    switch expr {
    case .binary(let op, let lhs, let rhs):
        if op == .equal {
            if case .identifier(let name) = lhs, name == loopVar,
               case .string(let val) = rhs {
                var vals = result[param]?.validValues ?? []
                if !vals.contains(val) { vals.append(val) }
                result[param]?.validValues = vals
            }
            if case .identifier(let name) = rhs, name == loopVar,
               case .string(let val) = lhs {
                var vals = result[param]?.validValues ?? []
                if !vals.contains(val) { vals.append(val) }
                result[param]?.validValues = vals
            }
        }
        collectEnumFromExpr(lhs, loopVar: loopVar, param: param, result: &result)
        collectEnumFromExpr(rhs, loopVar: loopVar, param: param, result: &result)
    default:
        break
    }
}

// MARK: - Phase 8: Multi-Format Tool Call Parsing

/// Represents a parsed tool call from raw model output.
struct ParsedToolCall: CustomStringConvertible {
    let name: String
    let arguments: String
    let format: ToolCallFormat

    var description: String {
        "[\(format)] \(name)(\(arguments))"
    }
}

enum ToolCallFormat: String, CustomStringConvertible {
    case qwen       // <tool_call>{JSON}</tool_call>
    case harmony    // <|start|>assistant<|channel|>commentary to=functions.NAME <|constrain|>json<|message|>ARGS<|call|>

    var description: String { rawValue }
}

/// Parses tool calls from raw text in Qwen/Hermes format.
/// Format: <tool_call>\n{"name": "func", "arguments": {...}}\n</tool_call>
func parseQwenToolCalls(from text: String) -> [ParsedToolCall] {
    let pattern = #"<tool_call>\s*(\{.*?\})\s*</tool_call>"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else {
        return []
    }

    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

    return matches.compactMap { match -> ParsedToolCall? in
        guard let jsonRange = Range(match.range(at: 1), in: text) else { return nil }
        let jsonStr = String(text[jsonRange])

        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else {
            return nil
        }

        // Arguments can be a nested object or a string
        let argsStr: String
        if let args = obj["arguments"] {
            if let argsDict = args as? [String: Any],
               let argsData = try? JSONSerialization.data(withJSONObject: argsDict),
               let s = String(data: argsData, encoding: .utf8) {
                argsStr = s
            } else if let s = args as? String {
                argsStr = s
            } else {
                argsStr = "\(args)"
            }
        } else {
            argsStr = "{}"
        }

        return ParsedToolCall(name: name, arguments: argsStr, format: .qwen)
    }
}

/// Parses tool calls from raw text in GPT-OSS Harmony format.
///
/// Correct format (per OpenAI Cookbook):
///   <|start|>assistant<|channel|>commentary to=functions.NAME <|constrain|>json<|message|>ARGS_JSON<|call|>
///
/// Note: <|call|> is consumed as EOS token and may not appear in text output.
/// Also handles the buggy chat template variant where to= appears before <|channel|>.
func parseHarmonyToolCalls(from text: String) -> [ParsedToolCall] {
    var results: [ParsedToolCall] = []

    // Pattern 1 (correct format): <|start|>assistant<|channel|>commentary to=functions.NAME <|constrain|>json<|message|>ARGS
    // The <|call|> may or may not be present (consumed as stop token)
    let correctPattern = #"<\|start\|>assistant<\|channel\|>commentary\s+to=functions\.([.\w]+)\s*<\|constrain\|>\s*json\s*<\|message\|>(.*?)(?:<\|call\|>|<\|start\|>|$)"#

    // Pattern 2 (buggy template): <|start|>assistant to=functions.NAME<|channel|>commentary json<|message|>ARGS
    let buggyPattern = #"<\|start\|>assistant\s+to=functions\.([.\w]+)\s*<\|channel\|>commentary\s+(?:json)?\s*<\|message\|>(.*?)(?:<\|call\|>|<\|start\|>|$)"#

    for pattern in [correctPattern, buggyPattern] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else {
            continue
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let argsRange = Range(match.range(at: 2), in: text) else {
                continue
            }

            let name = String(text[nameRange])
            let args = String(text[argsRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Avoid duplicates if both patterns match
            if !results.contains(where: { $0.name == name && $0.arguments == args }) {
                results.append(ParsedToolCall(name: name, arguments: args, format: .harmony))
            }
        }
    }

    return results
}

/// Auto-detects format and parses all tool calls from raw text.
func parseToolCalls(from text: String) -> [ParsedToolCall] {
    var results: [ParsedToolCall] = []

    // Try both formats — they won't overlap
    results.append(contentsOf: parseQwenToolCalls(from: text))
    results.append(contentsOf: parseHarmonyToolCalls(from: text))

    return results
}

/// Extracts analysis/thinking content from Harmony channel output.
/// Handles both `<|start|>assistant<|channel|>analysis` and bare `<|channel|>analysis` (first turn).
func parseHarmonyAnalysis(from text: String) -> String? {
    let pattern = #"(?:<\|start\|>assistant)?<\|channel\|>analysis<\|message\|>(.*?)<\|end\|>"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else {
        return nil
    }

    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

    let analyses = matches.compactMap { match -> String? in
        guard let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return analyses.isEmpty ? nil : analyses.joined(separator: "\n")
}

/// Extracts final response from Harmony channel output.
func parseHarmonyFinalResponse(from text: String) -> String? {
    let pattern = #"<\|start\|>assistant<\|channel\|>final<\|message\|>(.*?)(?:<\|return\|>|<\|end\|>|$)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else {
        return nil
    }

    let nsText = text as NSString
    guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
          let range = Range(match.range(at: 1), in: text) else {
        return nil
    }

    return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
}

func phase8ToolCallParsing() async throws {
    print("=== Phase 8: Multi-Format Tool Call Parsing ===\n")

    // --- Part 1: Unit test the parsers with known strings ---
    print("--- Part 1: Parser unit tests ---\n")

    // Test Qwen format
    let qwenSample = """
    I'll check the weather for you.

    <tool_call>
    {"name": "get_weather", "arguments": {"city": "Prague"}}
    </tool_call>
    """
    let qwenCalls = parseToolCalls(from: qwenSample)
    print("Qwen sample: \(qwenCalls.count) call(s)")
    for call in qwenCalls {
        print("  \(call)")
    }
    assert(qwenCalls.count == 1, "Expected 1 Qwen tool call")
    assert(qwenCalls[0].name == "get_weather", "Expected get_weather")
    assert(qwenCalls[0].format == .qwen)
    print("  PASS\n")

    // Test Harmony format (correct spec: to= after <|channel|>commentary)
    let harmonySample = """
    <|start|>assistant<|channel|>analysis<|message|>I need to check the weather for Prague.<|end|>\
    <|start|>assistant<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>{"city": "Prague"}<|call|>
    """
    let harmonyCalls = parseToolCalls(from: harmonySample)
    print("Harmony sample (correct format): \(harmonyCalls.count) call(s)")
    for call in harmonyCalls {
        print("  \(call)")
    }
    assert(harmonyCalls.count == 1, "Expected 1 Harmony tool call")
    assert(harmonyCalls[0].name == "get_weather", "Expected get_weather")
    assert(harmonyCalls[0].format == .harmony)
    print("  PASS\n")

    // Test Harmony format (buggy template: to= before <|channel|>)
    let harmonyBuggySample = """
    <|start|>assistant to=functions.get_weather<|channel|>commentary json<|message|>{"city": "Paris"}<|call|>
    """
    let harmonyBuggyCalls = parseToolCalls(from: harmonyBuggySample)
    print("Harmony sample (buggy template): \(harmonyBuggyCalls.count) call(s)")
    for call in harmonyBuggyCalls {
        print("  \(call)")
    }
    assert(harmonyBuggyCalls.count == 1, "Expected 1 Harmony tool call (buggy)")
    print("  PASS\n")

    // Test Harmony format WITHOUT <|call|> (consumed as stop token)
    let harmonyNoCallSample = """
    <|channel|>analysis<|message|>We need weather data.<|end|>\
    <|start|>assistant<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>{"city": "Prague"}
    """
    let harmonyNoCallCalls = parseToolCalls(from: harmonyNoCallSample)
    print("Harmony sample (no <|call|>, EOS consumed): \(harmonyNoCallCalls.count) call(s)")
    for call in harmonyNoCallCalls {
        print("  \(call)")
    }
    assert(harmonyNoCallCalls.count == 1, "Expected 1 Harmony tool call without <|call|>")
    print("  PASS\n")

    // Test analysis extraction (bare <|channel|> without <|start|>assistant prefix)
    let analysis = parseHarmonyAnalysis(from: harmonyNoCallSample)
    print("Analysis from bare channel: \(analysis ?? "none")")
    assert(analysis != nil, "Expected analysis block")
    print("  PASS\n")

    // Test multi-call
    let multiSample = """
    <|start|>assistant<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>{"city": "Prague"}<|call|>\
    <|start|>assistant<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>{"city": "Tokyo"}<|call|>
    """
    let multiCalls = parseToolCalls(from: multiSample)
    print("Multi-call sample: \(multiCalls.count) call(s)")
    for call in multiCalls {
        print("  \(call)")
    }
    assert(multiCalls.count == 2, "Expected 2 Harmony tool calls")
    print("  PASS\n")

    // --- Part 2: Capture raw GPT-OSS output with tools ---
    print("--- Part 2: GPT-OSS raw tool call capture ---\n")

    var parsedCalls: [ParsedToolCall] = []
    let modelId = gptOSSModelId
    print("Loading \(modelId)...")

    let container = try await LLMModelFactory.shared.loadContainer(
        configuration: ModelConfiguration(id: modelId)
    ) { progress in
        let pct = Int(progress.fractionCompleted * 100)
        if pct % 25 == 0 { print("  Loading: \(pct)%") }
    }

    do {
        let gptMessages: [Chat.Message] = [
            .system("You are a helpful assistant. Use tools when available."),
            .user("What is the weather in Prague?"),
        ]

        let gptTool: ToolSpec = [
            "type": "function",
            "function": [
                "name": "get_weather",
                "description": "Get the current weather for a city",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "city": [
                            "type": "string",
                            "description": "The city name",
                        ] as [String: any Sendable],
                    ] as [String: any Sendable],
                    "required": ["city"],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]

        let input = UserInput(chat: gptMessages, tools: [gptTool])
        let lmInput = try await container.prepare(input: input)

        // Use generous maxTokens since GPT-OSS might not stop at <|call|>
        let params = GenerateParameters(maxTokens: 500, temperature: 0.1)
        let stream = try await container.generate(input: lmInput, parameters: params)

        var rawText = ""
        var mlxToolCalls: [MLXLMCommon.ToolCall] = []

        for await generation in stream {
            switch generation {
            case .chunk(let text):
                rawText += text
            case .toolCall(let call):
                mlxToolCalls.append(call)
            case .info(let info):
                print("  \(info.generationTokenCount) tokens, \(String(format: "%.1f", info.tokensPerSecond)) tok/s")
            }
        }

        print("\nmlx-swift-lm detected: \(mlxToolCalls.count) tool call(s)")
        for call in mlxToolCalls {
            print("  \(call.function.name)(\(call.function.arguments))")
        }

        print("\nRaw text output (\(rawText.count) chars):")
        print("---BEGIN---")
        print(rawText)
        print("---END---\n")

        // Now try our parser on the raw text
        parsedCalls = parseToolCalls(from: rawText)
        print("Our parser detected: \(parsedCalls.count) tool call(s)")
        for call in parsedCalls {
            print("  \(call)")
        }

        // Also check for analysis blocks
        if let analysis = parseHarmonyAnalysis(from: rawText) {
            print("\nAnalysis/thinking extracted:")
            print("  \(String(analysis.prefix(300)))")
        }

        // Check for final response
        if let finalResp = parseHarmonyFinalResponse(from: rawText) {
            print("\nFinal response extracted:")
            print("  \(String(finalResp.prefix(300)))")
        }
    }

    // --- Part 3: Cross-check with Qwen3 ---
    print("\n--- Part 3: Qwen3 tool call cross-check ---\n")

    print("Loading \(qwen3ModelId)...")
    let qwenContainer = try await LLMModelFactory.shared.loadContainer(
        configuration: ModelConfiguration(id: qwen3ModelId)
    ) { progress in
        let pct = Int(progress.fractionCompleted * 100)
        if pct % 25 == 0 { print("  Loading: \(pct)%") }
    }

    let qwenMessages: [Chat.Message] = [
        .system("You are a helpful assistant. Use tools when available."),
        .user("What is the weather in Prague?"),
    ]

    let qwenTool: ToolSpec = [
        "type": "function",
        "function": [
            "name": "get_weather",
            "description": "Get the current weather for a city",
            "parameters": [
                "type": "object",
                "properties": [
                    "city": [
                        "type": "string",
                        "description": "The city name",
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["city"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    let qwenInput = UserInput(
        chat: qwenMessages,
        tools: [qwenTool],
        additionalContext: ["enable_thinking": false]
    )
    let qwenLmInput = try await qwenContainer.prepare(input: qwenInput)
    let params = GenerateParameters(maxTokens: 500, temperature: 0.1)
    let qwenStream = try await qwenContainer.generate(input: qwenLmInput, parameters: params)

    var qwenRawText = ""
    var qwenMlxCalls: [MLXLMCommon.ToolCall] = []

    for await generation in qwenStream {
        switch generation {
        case .chunk(let text):
            qwenRawText += text
        case .toolCall(let call):
            qwenMlxCalls.append(call)
        case .info(let info):
            print("  \(info.generationTokenCount) tokens, \(String(format: "%.1f", info.tokensPerSecond)) tok/s")
        }
    }

    print("\nQwen3 mlx-swift-lm detected: \(qwenMlxCalls.count) tool call(s)")
    for call in qwenMlxCalls {
        print("  \(call.function.name)(\(call.function.arguments))")
    }

    print("\nQwen3 raw text (\(qwenRawText.count) chars):")
    print("---BEGIN---")
    print(qwenRawText)
    print("---END---\n")

    let qwenParsed = parseToolCalls(from: qwenRawText)
    print("Our parser on Qwen3: \(qwenParsed.count) tool call(s)")
    for call in qwenParsed {
        print("  \(call)")
    }

    // --- Summary ---
    print("\n--- Phase 8 Summary ---")
    print("Qwen format parser:   \(qwenCalls.count > 0 ? "PASS" : "FAIL") (unit test)")
    print("Harmony format parser: \(harmonyCalls.count > 0 ? "PASS" : "FAIL") (unit test)")

    let gptOssResult = !parsedCalls.isEmpty ? "PASS" : "NO TOOL CALL DETECTED"
    print("GPT-OSS live test:    \(gptOssResult)")

    let qwenResult = !qwenParsed.isEmpty || !qwenMlxCalls.isEmpty ? "PASS" : "FAIL"
    print("Qwen3 live test:      \(qwenResult)")

    print("\n=== Phase 8 Complete ===\n")
}

// MARK: - Main

let args = CommandLine.arguments
let phase = args.count > 1 ? Int(args[1]) ?? 1 : 1

do {
    switch phase {
    case 1:
        try await phase1BasicCompletion()
    case 2:
        try await phase2ToolCalling()
    case 3:
        try await phase3Thinking()
    case 4:
        try await phase4Vision()
    case 5:
        try await phase5GptOSS()
    case 6:
        try await phase6MultiModel()
    case 7:
        try await phase7WorkingVLM()
    case 8:
        try await phase8ToolCallParsing()
    default:
        print("Unknown phase: \(phase). Use 1-8.")
    }
} catch {
    print("ERROR: \(error)")
}
