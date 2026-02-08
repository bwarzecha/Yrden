/// AgentCLI — Non-interactive coding agent for stress-testing.
///
/// Runs a single prompt to completion with streaming output, auto-approved tools,
/// and scoped write permissions. Designed for testing long-running agentic tasks.
///
/// Usage:
///   swift run AgentCLI "Explore ~/dev and describe each project"
///   swift run AgentCLI --max-iterations 50 --verbose "Analyze this codebase"
///
/// Environment:
///   ANTHROPIC_API_KEY or OPENAI_API_KEY must be set.

import Foundation
import Yrden

// MARK: - Configuration

struct Config {
    let prompt: String
    let provider: String        // "anthropic" or "openai"
    let model: String
    let maxIterations: Int
    let workingDir: String
    let outputDir: String
    let verbose: Bool
}

func parseArgs() -> Config? {
    let args = CommandLine.arguments.dropFirst()

    if args.contains("--help") || args.contains("-h") {
        printUsage()
        exit(0)
    }

    var provider: String?
    var model: String?
    var maxIterations = 50
    var workingDir = FileManager.default.currentDirectoryPath
    var outputDir = "/tmp/yrden-agent"
    var verbose = false
    var positionalArgs: [String] = []

    var iter = args.makeIterator()
    while let arg = iter.next() {
        switch arg {
        case "--provider":
            provider = iter.next()
        case "--model":
            model = iter.next()
        case "--max-iterations":
            if let val = iter.next(), let n = Int(val) { maxIterations = n }
        case "--working-dir":
            if let val = iter.next() { workingDir = NSString(string: val).expandingTildeInPath }
        case "--output-dir":
            if let val = iter.next() { outputDir = NSString(string: val).expandingTildeInPath }
        case "--verbose":
            verbose = true
        default:
            if !arg.hasPrefix("-") {
                positionalArgs.append(arg)
            }
        }
    }

    guard !positionalArgs.isEmpty else {
        printError("No prompt provided. Run with --help for usage.")
        return nil
    }

    let resolvedProvider = provider ?? autoDetectProvider()
    guard let resolvedProvider else {
        printError("No API key found. Set ANTHROPIC_API_KEY or OPENAI_API_KEY.")
        return nil
    }

    let defaultModel = resolvedProvider == "anthropic" ? "claude-sonnet-4-5-20250929" : "gpt-4o"

    return Config(
        prompt: positionalArgs.joined(separator: " "),
        provider: resolvedProvider,
        model: model ?? defaultModel,
        maxIterations: maxIterations,
        workingDir: workingDir,
        outputDir: outputDir,
        verbose: verbose
    )
}

func autoDetectProvider() -> String? {
    let env = ProcessInfo.processInfo.environment
    if env["ANTHROPIC_API_KEY"] != nil { return "anthropic" }
    if env["OPENAI_API_KEY"] != nil { return "openai" }
    return nil
}

func printUsage() {
    print("""
    AgentCLI — Non-interactive coding agent for stress-testing Yrden.

    USAGE:
      swift run AgentCLI [OPTIONS] "Your prompt here"

    OPTIONS:
      --provider <name>        anthropic or openai (auto-detected from env)
      --model <name>           Model name (default: claude-sonnet-4-5-20250929 / gpt-4o)
      --max-iterations <n>     Max agent iterations (default: 50)
      --working-dir <path>     Working directory (default: cwd)
      --output-dir <path>      Writable output directory (default: /tmp/yrden-agent)
      --verbose                Show full tool results
      --help                   Show this help

    ENVIRONMENT:
      ANTHROPIC_API_KEY        Required for Anthropic provider
      OPENAI_API_KEY           Required for OpenAI provider
    """)
}

// MARK: - Model Factory

func createModel(config: Config) throws -> any Model {
    let env = ProcessInfo.processInfo.environment

    switch config.provider {
    case "anthropic":
        guard let apiKey = env["ANTHROPIC_API_KEY"] else {
            throw CLIError.missingKey("ANTHROPIC_API_KEY")
        }
        return AnthropicModel(name: config.model, provider: AnthropicProvider(apiKey: apiKey))

    case "openai":
        guard let apiKey = env["OPENAI_API_KEY"] else {
            throw CLIError.missingKey("OPENAI_API_KEY")
        }
        return OpenAIModel(name: config.model, provider: OpenAIProvider(apiKey: apiKey))

    default:
        throw CLIError.unknownProvider(config.provider)
    }
}

enum CLIError: Error, CustomStringConvertible {
    case missingKey(String)
    case unknownProvider(String)

    var description: String {
        switch self {
        case .missingKey(let key): return "Missing environment variable: \(key)"
        case .unknownProvider(let p): return "Unknown provider: \(p). Use 'anthropic' or 'openai'."
        }
    }
}

// MARK: - ANSI Helpers

let useColor = isatty(STDOUT_FILENO) != 0

func dim(_ text: String) -> String { useColor ? "\u{1b}[2m\(text)\u{1b}[0m" : text }
func green(_ text: String) -> String { useColor ? "\u{1b}[32m\(text)\u{1b}[0m" : text }
func yellow(_ text: String) -> String { useColor ? "\u{1b}[33m\(text)\u{1b}[0m" : text }
func red(_ text: String) -> String { useColor ? "\u{1b}[31m\(text)\u{1b}[0m" : text }
func bold(_ text: String) -> String { useColor ? "\u{1b}[1m\(text)\u{1b}[0m" : text }

func printError(_ msg: String) {
    fputs(red("Error: \(msg)") + "\n", stderr)
}

// MARK: - Usage Formatting

func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}

func printUsageSummary(_ run: AgentRun<String>, maxContext: Int?) {
    let u = run.usage
    let cached = u.cachedTokens ?? 0
    var parts = [
        "In: \(formatTokens(u.inputTokens))",
        "Out: \(formatTokens(u.outputTokens))",
    ]
    if cached > 0 { parts.append("Cached: \(formatTokens(cached))") }
    parts.append("Total: \(formatTokens(u.totalTokens))")

    if let max = maxContext, max > 0 {
        let pct = Double(u.inputTokens) / Double(max) * 100
        parts.append("Context: \(String(format: "%.0f", pct))% (\(formatTokens(u.inputTokens))/\(formatTokens(max)))")
    }

    let line = parts.joined(separator: " | ")
    let iterInfo = "Iterations: \(run.iteration) | Tool calls: \(run.toolCallCount)"

    print("")
    print(dim("--- \(line) | \(iterInfo) ---"))

    if let max = maxContext, max > 0 {
        let pct = Double(u.inputTokens) / Double(max) * 100
        if pct > 90 {
            print(red("WARNING: Context nearly full (\(String(format: "%.0f", pct))%)"))
        } else if pct > 70 {
            print(yellow("Note: Context getting full (\(String(format: "%.0f", pct))%)"))
        }
    }
}

// MARK: - Iter Runner (with context management)

func runAgent(
    prompt: String,
    agent: Agent<String>,
    verbose: Bool,
    maxContext: Int?
) async throws -> AgentRun<String> {
    let model = await agent.model
    var toolArgs: [String: String] = [:]

    do {
        for try await node in agent.iter(prompt) {
            switch node {
            case .beforeModel(let ctx):
                // Apply context management before each model call
                if let max = maxContext {
                    await ContextManagement.apply(
                        to: &ctx.state.messages,
                        maxContextTokens: max,
                        model: model
                    )
                }

                // Stream model response
                for try await event in ctx.stream() {
                    switch event {
                    case .contentDelta(let text, let kind):
                        if kind == .thinking {
                            print(dim(text), terminator: "")
                        } else {
                            print(text, terminator: "")
                        }
                        fflush(stdout)
                    case .toolCallStart(let id, let name):
                        toolArgs[id] = ""
                        print(dim("\n[\(name)] "), terminator: "")
                        fflush(stdout)
                    case .toolCallDelta(let id, let delta):
                        toolArgs[id, default: ""] += delta
                    case .toolCallEnd(let id):
                        if let args = toolArgs[id] {
                            print(dim(truncateArgs(args)))
                        }
                    }
                }

            case .afterModel:
                break

            case .beforeTools(let ctx):
                // Stream tool execution (all tools auto-approved via .pending)
                for try await event in ctx.stream() {
                    switch event {
                    case .toolCompleted(_, let result, _):
                        let display = verbose ? result : truncateResult(result, maxLines: 3)
                        print(dim("  -> \(display)"))
                        fflush(stdout)
                    case .toolFailed(_, let error, _):
                        let display = verbose ? error : truncateResult(error, maxLines: 3)
                        print(dim("  -> \(display)"))
                        fflush(stdout)
                    case .toolStarted, .toolDenied, .toolProgress:
                        break
                    }
                }

            case .afterTools(let ctx):
                // Print per-iteration context usage
                let u = ctx.state.usage
                if let max = maxContext, max > 0 {
                    let estimated = TokenEstimator.estimate(ctx.state.messages)
                    let pct = Double(estimated) / Double(max) * 100
                    print(dim("  [iter \(ctx.state.iteration) | context: ~\(String(format: "%.0f", pct))% | in: \(formatTokens(u.inputTokens)) out: \(formatTokens(u.outputTokens))]"))
                }

            case .finished(let ctx):
                print("")
                return AgentRun(state: ctx.state, status: .completed(ctx.output))
            }
        }

        printError("Iterator ended without finishing")
        exit(1)

    } catch let error as AgentError<String> {
        print("")
        switch error {
        case .maxIterationsReached(let state):
            return AgentRun(
                state: state,
                status: .iterationLimitReached(limit: await agent.maxIterations)
            )
        case .usageLimitExceeded(let state, let limit):
            return AgentRun(state: state, status: .usageLimitReached(limit))
        default:
            throw error
        }
    }
}

func truncateArgs(_ args: String) -> String {
    let clean = args.trimmingCharacters(in: .whitespacesAndNewlines)
    if clean.count <= 200 { return clean }
    return String(clean.prefix(200)) + "..."
}

func truncateResult(_ result: String, maxLines: Int) -> String {
    let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.count <= maxLines {
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let kept = lines.prefix(maxLines).joined(separator: "\n")
    return kept + "\n  ... (\(lines.count - maxLines) more lines)"
}

// MARK: - Main

guard let config = parseArgs() else { exit(1) }

do {
    let model = try createModel(config: config)

    // Create output directory
    try FileManager.default.createDirectory(
        atPath: config.outputDir,
        withIntermediateDirectories: true
    )

    // Set up tools with scoped write permissions
    let tools = try await BuiltInTools(
        workingDirectory: config.workingDir,
        allowedWriteDirectories: [config.outputDir],
        environment: .inherited(),
        shellApprovalRequired: false
    )

    let systemPrompt = """
        You are a coding agent with access to shell, read_file, and write_file tools.
        Work autonomously to complete the user's task. Use tools proactively.
        You can read files anywhere but can only write files to: \(config.outputDir)
        If you need to save results, write them to that directory.
        """

    let agent = try Agent<String>(
        model: model,
        systemPrompt: systemPrompt,
        tools: tools.all,
        maxIterations: config.maxIterations
    )

    let maxContext = model.capabilities.maxContextTokens

    // Print config banner
    print(bold("AgentCLI"))
    print(dim("Provider: \(config.provider) | Model: \(config.model)"))
    print(dim("Max iterations: \(config.maxIterations) | Working dir: \(config.workingDir)"))
    print(dim("Output dir: \(config.outputDir)"))
    if let max = maxContext { print(dim("Context window: \(formatTokens(max))")) }
    print(dim(String(repeating: "-", count: 60)))
    print("")

    let run = try await runAgent(
        prompt: config.prompt,
        agent: agent,
        verbose: config.verbose,
        maxContext: maxContext
    )

    // Print final status
    switch run.status {
    case .completed:
        printUsageSummary(run, maxContext: maxContext)
        print(green("Completed successfully."))

    case .iterationLimitReached(let limit):
        printUsageSummary(run, maxContext: maxContext)
        print(yellow("Stopped: iteration limit reached (\(limit))"))

    case .usageLimitReached(let limit):
        printUsageSummary(run, maxContext: maxContext)
        print(yellow("Stopped: usage limit reached — \(limit)"))

    case .needsApproval(let pending):
        printUsageSummary(run, maxContext: maxContext)
        let names = pending.filter { $0.requiresApproval }.map { $0.call.name }
        print(yellow("Stopped: tools need approval — \(names.joined(separator: ", "))"))
    }

} catch {
    printError("\(error)")
    exit(1)
}
