/// GGML Exploration - POC for local model inference via llama.cpp (GGUF)
///
/// Tests basic completion, tool calling, thinking blocks, template
/// introspection, and multi-model testing with GGUF models on Apple Silicon.
///
/// Usage:
///   swift run GGMLExploration [phase]
///
/// Phases:
///   1 - Basic completion with Qwen3-4B (default)
///   2 - Tool calling
///   3 - Thinking & template introspection
///   4 - Multi-model testing
///   5 - Tool call parsing
///   6 - Chat template comparison (C API vs Jinja)
///   7 - GPT-OSS (Harmony tool calls & reasoning effort)

import Foundation
import LlamaSwift
import Jinja
import Hub

// MARK: - Configuration

let qwen3ModelRepo = "Qwen/Qwen3-4B-GGUF"
let qwen3ModelFile = "Qwen3-4B-Q4_K_M.gguf"

let llama3ModelRepo = "bartowski/Llama-3.2-1B-Instruct-GGUF"
let llama3ModelFile = "Llama-3.2-1B-Instruct-Q4_K_M.gguf"

let gemmaModelRepo = "ggml-org/gemma-3-1b-it-GGUF"
let gemmaModelFile = "gemma-3-1b-it-Q4_K_M.gguf"

let gptOSSModelRepo = "unsloth/gpt-oss-20b-GGUF"
let gptOSSModelFile = "gpt-oss-20b-Q4_K_M.gguf"

// MARK: - Error Types

enum GGMLError: Error, CustomStringConvertible {
    case modelLoadFailed(String)
    case vocabLoadFailed
    case contextCreateFailed
    case decodeFailed
    case emptyPrompt
    case templateNotFound
    case templateRenderFailed(String)

    var description: String {
        switch self {
        case .modelLoadFailed(let path): return "Failed to load model: \(path)"
        case .vocabLoadFailed: return "Failed to get vocab from model"
        case .contextCreateFailed: return "Failed to create context"
        case .decodeFailed: return "llama_decode failed"
        case .emptyPrompt: return "Prompt tokenized to empty"
        case .templateNotFound: return "Chat template not found in model metadata"
        case .templateRenderFailed(let msg): return "Template render failed: \(msg)"
        }
    }
}

// MARK: - GGUF Download Helper

/// Downloads a specific GGUF file from HuggingFace and returns the local file path.
/// Checks for existing files first (supports both Hub cache and manual downloads).
func downloadGGUF(repo: String, filename: String) async throws -> String {
    // Check if file already exists in Hub cache location
    let hubCachePath = NSHomeDirectory() + "/Documents/huggingface/models/\(repo)/\(filename)"
    if FileManager.default.fileExists(atPath: hubCachePath) {
        print("  Found cached: \(hubCachePath)")
        return hubCachePath
    }

    print("  Downloading \(filename) from \(repo)...")
    let hub = HubApi()
    let hubRepo = Hub.Repo(id: repo)
    let baseURL = try await hub.snapshot(from: hubRepo, matching: [filename]) { progress in
        let pct = Int(progress.fractionCompleted * 100)
        if pct % 25 == 0 {
            print("    Download: \(pct)%")
        }
    }
    let path = baseURL.appending(path: filename).path
    print("  Model path: \(path)")
    return path
}

// MARK: - LlamaModel Wrapper

/// Swift wrapper around llama.cpp model + context lifecycle.
final class LlamaModel {
    let model: OpaquePointer
    let context: OpaquePointer
    let vocab: OpaquePointer
    let eosToken: llama_token
    let bosToken: llama_token

    init(path: String, contextSize: UInt32 = 4096, gpuLayers: Int32 = 99) throws {
        llama_backend_init()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = gpuLayers

        guard let model = llama_model_load_from_file(path, modelParams) else {
            throw GGMLError.modelLoadFailed(path)
        }
        self.model = model

        guard let vocab = llama_model_get_vocab(model) else {
            throw GGMLError.vocabLoadFailed
        }
        self.vocab = vocab

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = contextSize
        ctxParams.n_batch = 512

        guard let context = llama_init_from_model(model, ctxParams) else {
            llama_model_free(model)
            throw GGMLError.contextCreateFailed
        }
        self.context = context
        self.eosToken = llama_vocab_eos(vocab)
        self.bosToken = llama_vocab_bos(vocab)
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
        llama_backend_free()
    }

    /// Read a metadata string from the GGUF file.
    func metadataString(key: String) -> String? {
        var buf = [CChar](repeating: 0, count: 16384)
        let len = llama_model_meta_val_str(model, key, &buf, buf.count)
        guard len > 0 else { return nil }
        return String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Read the chat template embedded in the GGUF metadata.
    func chatTemplate() -> String? {
        metadataString(key: "tokenizer.chat_template")
    }

    /// Clear KV cache to prepare for a new independent generation.
    func clearCache() {
        let mem = llama_get_memory(context)
        llama_memory_clear(mem, true)
    }
}

// MARK: - Tokenization

/// Tokenize a string using llama.cpp's built-in tokenizer.
func tokenize(_ llamaModel: LlamaModel, text: String, addSpecial: Bool = false, parseSpecial: Bool = true) -> [llama_token] {
    let utf8Count = Int32(text.utf8.count)

    // First call to get required buffer size (returns negative count)
    let needed = llama_tokenize(llamaModel.vocab, text, utf8Count, nil, 0, addSpecial, parseSpecial)
    guard needed != 0 else { return [] }

    let bufSize = Int(abs(needed)) + 1
    var tokens = [llama_token](repeating: 0, count: bufSize)
    let actual = llama_tokenize(llamaModel.vocab, text, utf8Count, &tokens, Int32(bufSize), addSpecial, parseSpecial)
    guard actual > 0 else { return [] }

    return Array(tokens.prefix(Int(actual)))
}

/// Convert a single token to its string representation.
func tokenToString(_ llamaModel: LlamaModel, token: llama_token) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    let len = llama_token_to_piece(llamaModel.vocab, token, &buf, Int32(buf.count), 0, false)
    guard len > 0 else { return "" }
    return String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

// MARK: - Generation

struct GenerationResult {
    let text: String
    let tokenCount: Int
    let promptTokenCount: Int
    let tokensPerSecond: Double
}

/// Generate text from a prompt string, printing tokens as they stream.
func generate(
    llamaModel: LlamaModel,
    prompt: String,
    maxTokens: Int = 500,
    temperature: Float = 0.6,
    topP: Float = 0.9,
    stream: Bool = true
) throws -> GenerationResult {
    var promptTokens = tokenize(llamaModel, text: prompt, addSpecial: false, parseSpecial: true)
    guard !promptTokens.isEmpty else {
        throw GGMLError.emptyPrompt
    }

    llamaModel.clearCache()

    // Create sampler chain
    let chainParams = llama_sampler_chain_default_params()
    guard let sampler = llama_sampler_chain_init(chainParams) else {
        throw GGMLError.decodeFailed
    }

    if temperature <= 0.0 {
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
    } else {
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(topP, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
    }

    // Feed prompt tokens as a batch
    var batch = llama_batch_get_one(&promptTokens, Int32(promptTokens.count))
    guard llama_decode(llamaModel.context, batch) == 0 else {
        llama_sampler_free(sampler)
        throw GGMLError.decodeFailed
    }

    // Generate tokens
    let startTime = CFAbsoluteTimeGetCurrent()
    var generatedText = ""
    var generatedCount = 0

    for _ in 0..<maxTokens {
        let newToken = llama_sampler_sample(sampler, llamaModel.context, -1)

        if llama_vocab_is_eog(llamaModel.vocab, newToken) {
            break
        }

        let piece = tokenToString(llamaModel, token: newToken)
        generatedText += piece
        generatedCount += 1

        if stream {
            print(piece, terminator: "")
            fflush(stdout)
        }

        // Prepare next decode with the single new token
        var tokenArr = [newToken]
        batch = llama_batch_get_one(&tokenArr, 1)
        guard llama_decode(llamaModel.context, batch) == 0 else {
            llama_sampler_free(sampler)
            throw GGMLError.decodeFailed
        }
    }

    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
    let tokPerSec = elapsed > 0 ? Double(generatedCount) / elapsed : 0

    llama_sampler_free(sampler)

    return GenerationResult(
        text: generatedText,
        tokenCount: generatedCount,
        promptTokenCount: promptTokens.count,
        tokensPerSecond: tokPerSec
    )
}

// MARK: - Chat Template Helpers

/// Apply chat template using llama.cpp's built-in C API.
/// Returns nil if the template format is not recognized.
func applyChatTemplateC(
    templateStr: String?,
    messages: [(role: String, content: String)],
    addAssistant: Bool = true
) -> String? {
    // Build llama_chat_message array using strdup for C string ownership
    var cMessages = messages.map { msg in
        llama_chat_message(
            role: strdup(msg.role),
            content: strdup(msg.content)
        )
    }
    defer {
        for msg in cMessages {
            free(UnsafeMutablePointer(mutating: msg.role))
            free(UnsafeMutablePointer(mutating: msg.content))
        }
    }

    // First call to get required buffer size
    let needed = llama_chat_apply_template(
        templateStr, &cMessages, cMessages.count, addAssistant, nil, 0
    )
    guard needed > 0 else { return nil }

    var buf = [CChar](repeating: 0, count: Int(needed) + 1)
    let written = llama_chat_apply_template(
        templateStr, &cMessages, cMessages.count, addAssistant, &buf, Int32(buf.count)
    )
    guard written > 0 else { return nil }

    return String(decoding: buf.prefix(Int(written)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Render a Jinja chat template with full support for tools and model-specific parameters.
func renderJinjaTemplate(
    template: String,
    messages: [[String: Any]],
    tools: [[String: Any]]? = nil,
    addGenerationPrompt: Bool = true,
    bosToken: String = "",
    eosToken: String = "",
    additionalContext: [String: Any] = [:]
) throws -> String {
    var rawContext: [String: Any?] = [
        "messages": messages,
        "add_generation_prompt": addGenerationPrompt,
        "bos_token": bosToken,
        "eos_token": eosToken,
    ]
    if let tools { rawContext["tools"] = tools }
    for (k, v) in additionalContext { rawContext[k] = v }

    // Convert to Jinja Value types
    var context: [String: Value] = [:]
    for (k, v) in rawContext {
        context[k] = try Value(any: v)
    }

    let jinjaTemplate = try Template(template)
    return try jinjaTemplate.render(context)
}

/// Format messages for generation using the model's chat template.
/// Tries C API first, falls back to Jinja.
func formatMessages(
    llamaModel: LlamaModel,
    messages: [(role: String, content: String)],
    tools: [[String: Any]]? = nil,
    additionalContext: [String: Any] = [:]
) throws -> String {
    guard let templateStr = llamaModel.chatTemplate()?.replacingOccurrences(of: "\0", with: "") else {
        throw GGMLError.templateNotFound
    }

    // If no tools and no special context, try C API first (faster)
    if tools == nil && additionalContext.isEmpty {
        if let result = applyChatTemplateC(templateStr: templateStr, messages: messages) {
            return result
        }
    }

    // Fall back to Jinja rendering for full feature support
    let jinjaMessages = messages.map { msg -> [String: Any] in
        ["role": msg.role, "content": msg.content]
    }

    let bosStr = tokenToString(llamaModel, token: llamaModel.bosToken)
    let eosStr = tokenToString(llamaModel, token: llamaModel.eosToken)

    do {
        return try renderJinjaTemplate(
            template: templateStr,
            messages: jinjaMessages,
            tools: tools,
            bosToken: bosStr,
            eosToken: eosStr,
            additionalContext: additionalContext
        )
    } catch {
        throw GGMLError.templateRenderFailed("\(error)")
    }
}

// MARK: - Template Parameter Discovery (reused from MLXExploration)

/// Discovers model-specific template parameters by parsing the Jinja chat template AST.
func discoverTemplateParameters(template: String) -> Set<String> {
    let frameworkVars: Set<String> = [
        "messages", "tools", "add_generation_prompt", "bos_token", "eos_token",
        "sep_token", "pad_token", "unk_token", "chat_template",
        "true", "false", "none", "True", "False", "None",
        "loop", "caller", "range", "namespace", "cycler", "joiner",
        "raise_exception", "strftime_now",
    ]

    let memberNames: Set<String> = [
        "strip", "lstrip", "rstrip", "split", "startswith", "endswith",
        "upper", "lower", "trim", "replace", "join", "length",
        "role", "content", "name", "arguments", "function", "tool_calls",
        "tool_call_id", "type", "parameters",
        "index0", "index", "first", "last", "length", "revindex",
    ]

    do {
        let tokens = try Lexer.tokenize(template)
        let nodes = try Parser.parse(tokens)

        var identifiers = Set<String>()
        var definedNames = Set<String>()
        var testedNames = Set<String>()

        walkNodes(nodes, identifiers: &identifiers, definedNames: &definedNames, testedNames: &testedNames)

        let discovered = identifiers
            .subtracting(definedNames)
            .subtracting(frameworkVars)
            .subtracting(memberNames)
            .union(testedNames.subtracting(frameworkVars))

        return discovered
    } catch {
        print("Template parse error: \(error)")
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
        break
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

private func regexFallbackDiscovery(template: String) -> Set<String> {
    var params = Set<String>()
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

// MARK: - Parameter Type Discovery

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
        // Fallback: use defaults
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
        if case .identifier(let name) = lhs, result[name] != nil, op == .equal {
            if case .string(let val) = rhs {
                result[name]?.inferredType = "string"
                var vals = result[name]?.validValues ?? []
                if !vals.contains(val) { vals.append(val) }
                result[name]?.validValues = vals
            }
        }
        if case .identifier(let name) = rhs, result[name] != nil, op == .equal {
            if case .string(let val) = lhs {
                result[name]?.inferredType = "string"
                var vals = result[name]?.validValues ?? []
                if !vals.contains(val) { vals.append(val) }
                result[name]?.validValues = vals
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
        if case .identifier(let name) = target, result[name] != nil {
            if let value {
                switch value {
                case .string(let s):
                    result[name]?.defaultValue = "\"\(s)\""
                    if result[name]?.inferredType == "unknown" { result[name]?.inferredType = "string" }
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
    case .for(_, let iterable, let body, let elseBody, let test):
        if case .identifier(let name) = iterable, result[name] != nil {
            result[name]?.inferredType = "array"
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

// MARK: - Tool Call Parsing (reused from MLXExploration)

struct ParsedToolCall: CustomStringConvertible {
    let name: String
    let arguments: String
    let format: ToolCallFormat

    var description: String {
        "[\(format)] \(name)(\(arguments))"
    }
}

enum ToolCallFormat: String, CustomStringConvertible {
    case qwen
    case harmony

    var description: String { rawValue }
}

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

func parseHarmonyToolCalls(from text: String) -> [ParsedToolCall] {
    var results: [ParsedToolCall] = []

    let correctPattern = #"<\|start\|>assistant<\|channel\|>commentary\s+to=functions\.([.\w]+)\s*<\|constrain\|>\s*json\s*<\|message\|>(.*?)(?:<\|call\|>|<\|start\|>|$)"#
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

            if !results.contains(where: { $0.name == name && $0.arguments == args }) {
                results.append(ParsedToolCall(name: name, arguments: args, format: .harmony))
            }
        }
    }

    return results
}

func parseToolCalls(from text: String) -> [ParsedToolCall] {
    var results: [ParsedToolCall] = []
    results.append(contentsOf: parseQwenToolCalls(from: text))
    results.append(contentsOf: parseHarmonyToolCalls(from: text))
    return results
}

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

// MARK: - Weather Tool Definition (shared across phases)

func makeWeatherToolDef() -> [String: Any] {
    [
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
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["city"],
            ] as [String: Any],
        ] as [String: Any],
    ]
}

// MARK: - Phase 1: Basic Completion

func phase1BasicCompletion() async throws {
    print("=== Phase 1: Basic Completion ===\n")
    print("Loading model: \(qwen3ModelRepo)/\(qwen3ModelFile)...")

    let ggufPath = try await downloadGGUF(repo: qwen3ModelRepo, filename: qwen3ModelFile)
    print("  Loading into llama.cpp...")
    let llamaModel = try LlamaModel(path: ggufPath)

    // Show metadata
    let arch = llamaModel.metadataString(key: "general.architecture") ?? "unknown"
    let name = llamaModel.metadataString(key: "general.name") ?? "unknown"
    print("  Architecture: \(arch)")
    print("  Model name: \(name)")

    guard let chatTemplate = llamaModel.chatTemplate() else {
        throw GGMLError.templateNotFound
    }
    print("  Chat template: \(chatTemplate.count) chars")
    print("Model loaded.\n")

    // --- Test 1: Simple completion ---
    print("--- Test 1: Simple completion ---")
    let messages: [(role: String, content: String)] = [
        ("system", "You are a helpful assistant. Be concise."),
        ("user", "What is Swift programming language? Answer in one sentence."),
    ]

    let prompt = try formatMessages(
        llamaModel: llamaModel,
        messages: messages,
        additionalContext: ["enable_thinking": false]
    )

    let result = try generate(llamaModel: llamaModel, prompt: prompt, maxTokens: 200, temperature: 0.6)
    print("\n\n[Info] Tokens: \(result.promptTokenCount) prompt, \(result.tokenCount) generated")
    print("[Info] Speed: \(String(format: "%.1f", result.tokensPerSecond)) tokens/sec")
    print()

    // --- Test 2: Streaming ---
    print("--- Test 2: Streaming response ---")
    let messages2: [(role: String, content: String)] = [
        ("system", "You are a helpful assistant. Be concise."),
        ("user", "List 3 benefits of type safety. Keep each to one line."),
    ]

    let prompt2 = try formatMessages(
        llamaModel: llamaModel,
        messages: messages2,
        additionalContext: ["enable_thinking": false]
    )

    let result2 = try generate(llamaModel: llamaModel, prompt: prompt2, maxTokens: 200, temperature: 0.6)
    print("\n\n[Info] \(result2.tokenCount) tokens, \(String(format: "%.1f", result2.tokensPerSecond)) tok/s")
    print()

    print("=== Phase 1 Complete ===\n")
}

// MARK: - Phase 2: Tool Calling

func phase2ToolCalling() async throws {
    print("=== Phase 2: Tool Calling ===\n")
    print("Loading model: \(qwen3ModelRepo)/\(qwen3ModelFile)...")

    let ggufPath = try await downloadGGUF(repo: qwen3ModelRepo, filename: qwen3ModelFile)
    let llamaModel = try LlamaModel(path: ggufPath)
    print("Model loaded.\n")

    // --- Test: Ask about weather (should trigger tool call) ---
    print("--- Test: Tool calling ---")
    let messages: [(role: String, content: String)] = [
        ("system", "You are a helpful assistant. Use tools when available."),
        ("user", "What is the weather like in Prague right now?"),
    ]

    // Must use Jinja for tool-aware formatting
    let prompt = try formatMessages(
        llamaModel: llamaModel,
        messages: messages,
        tools: [makeWeatherToolDef()],
        additionalContext: ["enable_thinking": false]
    )

    print("Formatted prompt length: \(prompt.count) chars")
    print("Generating...\n")

    let result = try generate(llamaModel: llamaModel, prompt: prompt, maxTokens: 500, temperature: 0.1)

    print("\n\nRaw output (\(result.text.count) chars):")
    print("---BEGIN---")
    print(result.text)
    print("---END---\n")

    // Parse tool calls
    let toolCalls = parseToolCalls(from: result.text)
    print("Tool calls detected: \(toolCalls.count)")
    for call in toolCalls {
        print("  \(call)")
    }

    if !toolCalls.isEmpty {
        // --- Test: Feed tool result back ---
        print("\n--- Test: Multi-turn with tool result ---")

        // Build multi-turn messages
        let multiMessages: [(role: String, content: String)] = [
            ("system", "You are a helpful assistant. Use tools when available."),
            ("user", "What is the weather like in Prague right now?"),
            ("assistant", result.text),
            ("tool", "{\"temperature\": 22, \"condition\": \"partly cloudy\", \"humidity\": 65}"),
        ]

        let multiPrompt = try formatMessages(
            llamaModel: llamaModel,
            messages: multiMessages,
            tools: [makeWeatherToolDef()],
            additionalContext: ["enable_thinking": false]
        )

        let multiResult = try generate(llamaModel: llamaModel, prompt: multiPrompt, maxTokens: 300, temperature: 0.6)
        print("\n\n[Info] \(multiResult.tokenCount) tokens")
    }

    print("\n=== Phase 2 Complete ===\n")
}

// MARK: - Phase 3: Thinking & Template Introspection

func phase3Thinking() async throws {
    print("=== Phase 3: Thinking & Template Introspection ===\n")

    let ggufPath = try await downloadGGUF(repo: qwen3ModelRepo, filename: qwen3ModelFile)
    let llamaModel = try LlamaModel(path: ggufPath)

    // --- Test: Template introspection from GGUF metadata ---
    print("--- Test: Template introspection from GGUF metadata ---")
    guard let chatTemplate = llamaModel.chatTemplate() else {
        throw GGMLError.templateNotFound
    }

    print("Chat template length: \(chatTemplate.count) characters")
    print("First 200 chars: \(String(chatTemplate.prefix(200)))...\n")

    let discoveredParams = discoverTemplateParameters(template: chatTemplate)
    print("Discovered template parameters: \(discoveredParams.sorted())")

    let paramTypes = discoverParameterTypes(template: chatTemplate, params: discoveredParams)
    for (name, info) in paramTypes.sorted(by: { $0.key < $1.key }) {
        print("  \(name): \(info)")
    }
    print()

    // --- Test: Compare GGUF metadata template vs HuggingFace tokenizer_config ---
    print("--- Test: GGUF metadata vs HuggingFace config ---")
    let hub = HubApi()
    let repo = Hub.Repo(id: qwen3ModelRepo)
    do {
        let configURL = try await hub.snapshot(from: repo, matching: ["tokenizer_config.json"])
        let configPath = configURL.appending(path: "tokenizer_config.json")
        let configData = try Data(contentsOf: configPath)

        if let configDict = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
           let hfTemplate = configDict["chat_template"] as? String {
            let match = chatTemplate == hfTemplate
            print("Templates match: \(match)")
            if !match {
                print("GGUF template length: \(chatTemplate.count)")
                print("HF template length: \(hfTemplate.count)")
            }
        }
    } catch {
        print("Could not fetch HuggingFace config: \(error)")
    }
    print()

    // --- Test: Thinking mode ---
    print("--- Test: Thinking mode (enable_thinking: true) ---")
    let thinkMessages: [(role: String, content: String)] = [
        ("user", "What is 15 * 37? Think step by step."),
    ]

    let thinkPrompt = try formatMessages(
        llamaModel: llamaModel,
        messages: thinkMessages,
        additionalContext: ["enable_thinking": true]
    )

    let thinkResult = try generate(
        llamaModel: llamaModel,
        prompt: thinkPrompt,
        maxTokens: 1000,
        temperature: 0.6,
        stream: false
    )

    let rawOutput = thinkResult.text
    let hasThinkOpen = rawOutput.contains("<think>")
    let hasThinkClose = rawOutput.contains("</think>")
    print("Contains <think>: \(hasThinkOpen)")
    print("Contains </think>: \(hasThinkClose)")
    print("[Info] \(thinkResult.tokenCount) tokens")

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

// MARK: - Phase 4: Multi-Model Testing

func testGGUFModel(
    repo: String,
    filename: String,
    testTools: Bool = true
) async throws -> (success: Bool, architecture: String?, templateParams: Set<String>) {
    print("--- Testing model: \(repo)/\(filename) ---")

    let ggufPath = try await downloadGGUF(repo: repo, filename: filename)
    let llamaModel = try LlamaModel(path: ggufPath)

    let arch = llamaModel.metadataString(key: "general.architecture")
    let modelName = llamaModel.metadataString(key: "general.name")
    print("  architecture: \(arch ?? "unknown")")
    print("  name: \(modelName ?? "unknown")")

    // Template introspection
    var templateParams = Set<String>()
    if let chatTemplate = llamaModel.chatTemplate() {
        templateParams = discoverTemplateParameters(template: chatTemplate)
        let paramTypes = discoverParameterTypes(template: chatTemplate, params: templateParams)
        print("  template params: \(templateParams.sorted())")
        for (name, info) in paramTypes.sorted(by: { $0.key < $1.key }) {
            print("    \(name): \(info)")
        }
    } else {
        print("  No chat template in GGUF metadata")
    }

    // Basic completion test
    print("  Testing basic completion...")
    let messages: [(role: String, content: String)] = [
        ("system", "You are a helpful assistant. Be concise."),
        ("user", "What is 2 + 2? Answer with just the number."),
    ]

    var additionalContext: [String: Any] = [:]
    if templateParams.contains("enable_thinking") {
        additionalContext["enable_thinking"] = false
    }

    let prompt = try formatMessages(
        llamaModel: llamaModel,
        messages: messages,
        additionalContext: additionalContext
    )

    let result = try generate(
        llamaModel: llamaModel,
        prompt: prompt,
        maxTokens: 100,
        temperature: 0.1,
        stream: false
    )

    let has4 = result.text.contains("4")
    print("  Response: \(result.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))")
    print("  Contains '4': \(has4), \(result.tokenCount) tokens, \(String(format: "%.1f", result.tokensPerSecond)) tok/s")

    // Tool calling test
    if testTools {
        print("  Testing tool calling...")
        let toolMessages: [(role: String, content: String)] = [
            ("system", "You are a helpful assistant. Use tools when available."),
            ("user", "What is the weather in Tokyo?"),
        ]

        do {
            let toolPrompt = try formatMessages(
                llamaModel: llamaModel,
                messages: toolMessages,
                tools: [makeWeatherToolDef()],
                additionalContext: additionalContext
            )

            let toolResult = try generate(
                llamaModel: llamaModel,
                prompt: toolPrompt,
                maxTokens: 300,
                temperature: 0.1,
                stream: false
            )

            let toolCalls = parseToolCalls(from: toolResult.text)
            print("  Tool calls detected: \(toolCalls.count)")
            for call in toolCalls {
                print("    \(call)")
            }
        } catch {
            print("  Tool calling failed: \(error)")
        }
    }

    print("  DONE: \(repo)/\(filename)\n")
    return (has4, arch, templateParams)
}

func phase4MultiModel() async throws {
    print("=== Phase 4: Multi-Model Testing ===\n")

    let models: [(repo: String, file: String)] = [
        (qwen3ModelRepo, qwen3ModelFile),
        (llama3ModelRepo, llama3ModelFile),
        (gemmaModelRepo, gemmaModelFile),
    ]

    var results: [(id: String, success: Bool, arch: String?, params: Set<String>)] = []

    for (repo, file) in models {
        do {
            let (success, arch, params) = try await testGGUFModel(repo: repo, filename: file)
            results.append(("\(repo)/\(file)", success, arch, params))
        } catch {
            print("  ERROR: \(error)\n")
            results.append(("\(repo)/\(file)", false, nil, []))
        }
    }

    print("\n--- Multi-Model Summary ---")
    for r in results {
        let name = String(r.id.suffix(50))
        let arch = r.arch ?? "?"
        let status = r.success ? "PASS" : "FAIL"
        let params = r.params.sorted().joined(separator: ", ")
        print("  \(name)  arch=\(arch)  basic=\(status)  params=[\(params)]")
    }

    print("\n=== Phase 4 Complete ===\n")
}

// MARK: - Phase 5: Tool Call Parsing

func phase5ToolCallParsing() async throws {
    print("=== Phase 5: Tool Call Parsing ===\n")

    // --- Part 1: Unit test the parsers ---
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
    for call in qwenCalls { print("  \(call)") }
    assert(qwenCalls.count == 1, "Expected 1 Qwen tool call")
    assert(qwenCalls[0].name == "get_weather")
    assert(qwenCalls[0].format == .qwen)
    print("  PASS\n")

    // Test Harmony format (correct spec)
    let harmonySample = """
    <|start|>assistant<|channel|>analysis<|message|>I need to check the weather for Prague.<|end|>\
    <|start|>assistant<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>{"city": "Prague"}<|call|>
    """
    let harmonyCalls = parseToolCalls(from: harmonySample)
    print("Harmony sample (correct format): \(harmonyCalls.count) call(s)")
    for call in harmonyCalls { print("  \(call)") }
    assert(harmonyCalls.count == 1, "Expected 1 Harmony tool call")
    assert(harmonyCalls[0].format == .harmony)
    print("  PASS\n")

    // Test Harmony format (buggy template)
    let harmonyBuggySample = """
    <|start|>assistant to=functions.get_weather<|channel|>commentary json<|message|>{"city": "Paris"}<|call|>
    """
    let harmonyBuggyCalls = parseToolCalls(from: harmonyBuggySample)
    print("Harmony sample (buggy template): \(harmonyBuggyCalls.count) call(s)")
    for call in harmonyBuggyCalls { print("  \(call)") }
    assert(harmonyBuggyCalls.count == 1)
    print("  PASS\n")

    // Test without <|call|> (consumed as stop token)
    let harmonyNoCallSample = """
    <|channel|>analysis<|message|>We need weather data.<|end|>\
    <|start|>assistant<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>{"city": "Prague"}
    """
    let harmonyNoCallCalls = parseToolCalls(from: harmonyNoCallSample)
    print("Harmony sample (no <|call|>): \(harmonyNoCallCalls.count) call(s)")
    for call in harmonyNoCallCalls { print("  \(call)") }
    assert(harmonyNoCallCalls.count == 1)
    print("  PASS\n")

    // Test analysis extraction
    let analysis = parseHarmonyAnalysis(from: harmonyNoCallSample)
    print("Analysis from bare channel: \(analysis ?? "none")")
    assert(analysis != nil)
    print("  PASS\n")

    // Test multi-call
    let multiSample = """
    <|start|>assistant<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>{"city": "Prague"}<|call|>\
    <|start|>assistant<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>{"city": "Tokyo"}<|call|>
    """
    let multiCalls = parseToolCalls(from: multiSample)
    print("Multi-call sample: \(multiCalls.count) call(s)")
    for call in multiCalls { print("  \(call)") }
    assert(multiCalls.count == 2)
    print("  PASS\n")

    // --- Part 2: Capture raw GGUF output with tools ---
    print("--- Part 2: Qwen3 GGUF raw tool call capture ---\n")

    let ggufPath = try await downloadGGUF(repo: qwen3ModelRepo, filename: qwen3ModelFile)
    let llamaModel = try LlamaModel(path: ggufPath)

    let messages: [(role: String, content: String)] = [
        ("system", "You are a helpful assistant. Use tools when available."),
        ("user", "What is the weather in Prague?"),
    ]

    let prompt = try formatMessages(
        llamaModel: llamaModel,
        messages: messages,
        tools: [makeWeatherToolDef()],
        additionalContext: ["enable_thinking": false]
    )

    let result = try generate(
        llamaModel: llamaModel,
        prompt: prompt,
        maxTokens: 500,
        temperature: 0.1,
        stream: false
    )

    print("Raw text output (\(result.text.count) chars):")
    print("---BEGIN---")
    print(result.text)
    print("---END---\n")

    let parsedCalls = parseToolCalls(from: result.text)
    print("Our parser detected: \(parsedCalls.count) tool call(s)")
    for call in parsedCalls {
        print("  \(call)")
    }

    if let analysisBlock = parseHarmonyAnalysis(from: result.text) {
        print("\nAnalysis/thinking extracted:")
        print("  \(String(analysisBlock.prefix(300)))")
    }

    // --- Summary ---
    print("\n--- Phase 5 Summary ---")
    print("Qwen format parser:   \(qwenCalls.count > 0 ? "PASS" : "FAIL") (unit test)")
    print("Harmony format parser: \(harmonyCalls.count > 0 ? "PASS" : "FAIL") (unit test)")
    let ggufResult = !parsedCalls.isEmpty ? "PASS" : "NO TOOL CALL DETECTED"
    print("GGUF live test:       \(ggufResult)")

    print("\n=== Phase 5 Complete ===\n")
}

// MARK: - Phase 6: Chat Template Comparison

func phase6TemplateComparison() async throws {
    print("=== Phase 6: Chat Template Comparison (C API vs Jinja) ===\n")

    let ggufPath = try await downloadGGUF(repo: qwen3ModelRepo, filename: qwen3ModelFile)
    let llamaModel = try LlamaModel(path: ggufPath)

    guard let chatTemplate = llamaModel.chatTemplate() else {
        throw GGMLError.templateNotFound
    }

    let bosStr = tokenToString(llamaModel, token: llamaModel.bosToken)
    let eosStr = tokenToString(llamaModel, token: llamaModel.eosToken)
    print("BOS token string: \(bosStr.debugDescription)")
    print("EOS token string: \(eosStr.debugDescription)")
    print()

    let messages: [(role: String, content: String)] = [
        ("system", "You are helpful."),
        ("user", "Hello!"),
    ]

    // --- Test 1: Basic messages - compare C API vs Jinja ---
    print("--- Test 1: Basic messages ---\n")

    let cResult = applyChatTemplateC(templateStr: chatTemplate, messages: messages)
    print("C API result (\(cResult?.count ?? 0) chars):")
    if let cResult {
        print(cResult)
    } else {
        print("  [C API returned nil - template not recognized]")
    }
    print()

    let jinjaMessages = messages.map { ["role": $0.role, "content": $0.content] as [String: Any] }
    do {
        let jinjaResult = try renderJinjaTemplate(
            template: chatTemplate,
            messages: jinjaMessages,
            bosToken: bosStr,
            eosToken: eosStr,
            additionalContext: ["enable_thinking": false]
        )
        print("Jinja result (\(jinjaResult.count) chars):")
        print(jinjaResult)

        if let cResult {
            let match = cResult == jinjaResult
            print("\nC API == Jinja: \(match)")
            if !match {
                print("Diff: C API has \(cResult.count) chars, Jinja has \(jinjaResult.count) chars")
            }
        }
    } catch {
        print("Jinja rendering failed: \(error)")
    }
    print()

    // --- Test 2: With tools - C API vs Jinja ---
    print("--- Test 2: Messages with tools ---\n")

    let cResultTools = applyChatTemplateC(templateStr: chatTemplate, messages: messages)
    print("C API (no tool support): \(cResultTools != nil ? "rendered (ignores tools)" : "nil")")

    do {
        let jinjaResultTools = try renderJinjaTemplate(
            template: chatTemplate,
            messages: jinjaMessages,
            tools: [makeWeatherToolDef()],
            bosToken: bosStr,
            eosToken: eosStr,
            additionalContext: ["enable_thinking": false]
        )
        print("Jinja with tools (\(jinjaResultTools.count) chars):")
        print(String(jinjaResultTools.prefix(500)))
        if jinjaResultTools.count > 500 { print("...") }

        let hasToolDef = jinjaResultTools.contains("get_weather")
        print("\nJinja includes tool definition: \(hasToolDef)")
    } catch {
        print("Jinja with tools failed: \(error)")
    }
    print()

    // --- Test 3: With thinking enabled ---
    print("--- Test 3: With enable_thinking ---\n")
    do {
        let thinkResult = try renderJinjaTemplate(
            template: chatTemplate,
            messages: jinjaMessages,
            bosToken: bosStr,
            eosToken: eosStr,
            additionalContext: ["enable_thinking": true]
        )
        let noThinkResult = try renderJinjaTemplate(
            template: chatTemplate,
            messages: jinjaMessages,
            bosToken: bosStr,
            eosToken: eosStr,
            additionalContext: ["enable_thinking": false]
        )

        print("With thinking (\(thinkResult.count) chars):")
        print(String(thinkResult.suffix(200)))
        print("\nWithout thinking (\(noThinkResult.count) chars):")
        print(String(noThinkResult.suffix(200)))
        print("\nDifference: \(thinkResult.count - noThinkResult.count) chars")
    } catch {
        print("Thinking template test failed: \(error)")
    }

    // --- Test 4: Model metadata dump ---
    print("\n--- Test 4: GGUF metadata keys ---")
    let metadataKeys = [
        "general.name", "general.architecture", "general.file_type",
        "general.quantization_version",
        "tokenizer.ggml.model", "tokenizer.ggml.pre",
        "tokenizer.ggml.bos_token_id", "tokenizer.ggml.eos_token_id",
    ]
    for key in metadataKeys {
        let val = llamaModel.metadataString(key: key) ?? "(not found)"
        print("  \(key): \(val)")
    }

    print("\n=== Phase 6 Complete ===\n")
}

// MARK: - Phase 7: GPT-OSS (Harmony Format Tool Calls & Reasoning Effort)

func phase7GPTOSS() async throws {
    print("=== Phase 7: GPT-OSS (Harmony Tool Calls & Reasoning Effort) ===\n")
    print("Loading model: \(gptOSSModelRepo)/\(gptOSSModelFile)...")

    let ggufPath = try await downloadGGUF(repo: gptOSSModelRepo, filename: gptOSSModelFile)
    let llamaModel = try LlamaModel(path: ggufPath, contextSize: 4096)

    let arch = llamaModel.metadataString(key: "general.architecture") ?? "unknown"
    let name = llamaModel.metadataString(key: "general.name") ?? "unknown"
    print("Architecture: \(arch)")
    print("Name: \(name)")

    // --- Test 1: Template introspection ---
    print("\n--- Test 1: Template Introspection ---\n")

    guard let chatTemplate = llamaModel.chatTemplate()?.replacingOccurrences(of: "\0", with: "") else {
        print("ERROR: No chat template found in GGUF metadata")
        return
    }
    print("Chat template length: \(chatTemplate.count) chars")
    print("Template preview: \(String(chatTemplate.prefix(300)))...")

    let discoveredParams = discoverTemplateParameters(template: chatTemplate)
    print("\nDiscovered template parameters: \(discoveredParams.sorted())")

    // Check for reasoning_effort or similar params
    let reasoningParams = discoveredParams.filter {
        $0.lowercased().contains("reason") || $0.lowercased().contains("effort") || $0.lowercased().contains("think")
    }
    if !reasoningParams.isEmpty {
        print("Reasoning-related params: \(reasoningParams.sorted())")
    } else {
        print("No reasoning-specific params discovered (may use a different mechanism)")
    }

    // --- Test 2: Basic completion ---
    print("\n--- Test 2: Basic Completion ---\n")

    let basicMessages: [(role: String, content: String)] = [
        ("system", "You are a helpful assistant."),
        ("user", "What is 2 + 2? Answer briefly."),
    ]

    let basicPrompt = try formatMessages(
        llamaModel: llamaModel,
        messages: basicMessages
    )
    print("Prompt length: \(basicPrompt.count) chars")
    print("Generating...\n")

    let basicResult = try generate(llamaModel: llamaModel, prompt: basicPrompt, maxTokens: 200, temperature: 0.1)
    print("\n\n[Info] \(basicResult.tokenCount) tokens, \(String(format: "%.1f", basicResult.tokensPerSecond)) tok/s")

    // --- Test 3: Tool calling (Harmony format) ---
    // GPT-OSS Jinja template is too complex for swift-jinja (16K chars, advanced syntax).
    // Build the Harmony tool prompt manually following the GPT-OSS format spec.
    print("\n--- Test 3: Tool Calling (Harmony Format) ---\n")
    print("Note: GPT-OSS template too complex for swift-jinja, building prompt manually\n")

    let toolJson = """
    [{"type":"function","function":{"name":"get_weather","description":"Get the current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string","description":"The city name"}},"required":["city"]}}}]
    """

    let toolPrompt = """
    <|start|>system<|message|>You are a helpful assistant. Use tools when available.

    # Tools

    You have access to the following tools:

    \(toolJson)
    <|end|><|start|>user<|message|>What is the weather like in Prague right now?<|end|><|start|>assistant
    """

    print("Tool prompt length: \(toolPrompt.count) chars")
    print("Generating...\n")

    let toolResult = try generate(llamaModel: llamaModel, prompt: toolPrompt, maxTokens: 500, temperature: 0.1)
    print("\n\n[Info] \(toolResult.tokenCount) tokens, \(String(format: "%.1f", toolResult.tokensPerSecond)) tok/s")

    // Parse tool calls - try both formats
    let qwenCalls = parseQwenToolCalls(from: toolResult.text)
    let harmonyCalls = parseHarmonyToolCalls(from: toolResult.text)
    let allCalls = parseToolCalls(from: toolResult.text)

    print("\nTool call parsing:")
    print("  Qwen format:    \(qwenCalls.count) calls")
    print("  Harmony format: \(harmonyCalls.count) calls")
    print("  Total:          \(allCalls.count) calls")
    for call in allCalls {
        print("  -> \(call)")
    }

    // Check for Harmony analysis/commentary
    if let analysis = parseHarmonyAnalysis(from: toolResult.text) {
        print("\nHarmony analysis: \(analysis)")
    }

    // --- Test 4: Multi-turn with tool result ---
    if !allCalls.isEmpty {
        print("\n--- Test 4: Multi-Turn with Tool Result ---\n")

        let multiPrompt = """
        <|start|>system<|message|>You are a helpful assistant. Use tools when available.

        # Tools

        You have access to the following tools:

        \(toolJson)
        <|end|><|start|>user<|message|>What is the weather like in Prague right now?<|end|><|start|>assistant\(toolResult.text)<|end|><|start|>tool<|message|>{"temperature": 22, "condition": "partly cloudy", "humidity": 65}<|end|><|start|>assistant
        """

        let multiResult = try generate(llamaModel: llamaModel, prompt: multiPrompt, maxTokens: 300, temperature: 0.6)
        print("\n\n[Info] \(multiResult.tokenCount) tokens")

        if let finalResponse = parseHarmonyFinalResponse(from: multiResult.text) {
            print("Harmony final response: \(finalResponse)")
        }
    } else {
        print("\n--- Test 4: Skipped (no tool calls detected) ---")
    }

    // --- Test 5: Reasoning effort comparison ---
    // GPT-OSS supports reasoning_effort via the system prompt / template parameters.
    // Since Jinja won't parse, we test by varying the system prompt instruction.
    print("\n--- Test 5: Reasoning Effort ---\n")

    let reasoningQuestion = "Explain why the sky is blue in one sentence."

    // Baseline (no effort instruction)
    print("  Reasoning effort: (default)")
    let defaultPrompt = """
    <|start|>system<|message|>You are a helpful assistant.<|end|><|start|>user<|message|>\(reasoningQuestion)<|end|><|start|>assistant
    """
    let defaultResult = try generate(llamaModel: llamaModel, prompt: defaultPrompt, maxTokens: 300, temperature: 0.1, stream: false)
    print("    -> \(defaultResult.tokenCount) tokens, \(String(format: "%.1f", defaultResult.tokensPerSecond)) tok/s")
    print("    -> \(defaultResult.text.prefix(300))")
    print()

    // With reasoning_effort hint in system prompt
    for effort in ["low", "medium", "high"] {
        print("  Reasoning effort: \(effort)")

        let effortPrompt = """
        <|start|>system<|message|>You are a helpful assistant. reasoning_effort=\(effort)<|end|><|start|>user<|message|>\(reasoningQuestion)<|end|><|start|>assistant
        """

        let effortResult = try generate(
            llamaModel: llamaModel,
            prompt: effortPrompt,
            maxTokens: 300,
            temperature: 0.1,
            stream: false
        )
        print("    -> \(effortResult.tokenCount) tokens, \(String(format: "%.1f", effortResult.tokensPerSecond)) tok/s")
        print("    -> \(effortResult.text.prefix(300))")
        print()
    }

    print("\n=== Phase 7 Complete ===\n")
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
        try await phase4MultiModel()
    case 5:
        try await phase5ToolCallParsing()
    case 6:
        try await phase6TemplateComparison()
    case 7:
        try await phase7GPTOSS()
    default:
        print("Unknown phase: \(phase). Use 1-7.")
    }
} catch {
    print("ERROR: \(error)")
}
