/// BugBash Runner — Runs scenario JSON files against an Agent to find tool bugs.
///
/// Each scenario describes a natural-language task for the agent to complete
/// against a pinned commit of the Yrden repo. The runner checks postconditions
/// and saves a full AgentRun trace (all messages, tool calls, tool results)
/// for analysis.
///
/// Usage:
///   swift run BugBash                           # Run all scenarios
///   swift run BugBash 01 07 15                  # Run specific scenarios by number
///   swift run BugBash --model claude-haiku-4-5-20251001
///   swift run BugBash --keep-dirs               # Keep temp dirs for debugging
///   swift run BugBash --output-dir ./my-results
///   swift run BugBash --verbose                  # Detailed progress to stderr

import Foundation
import Yrden

// MARK: - Scenario Model

struct Scenario: Codable {
    let name: String
    let description: String
    let setup: String
    let task: String
    let maxIterations: Int
    let postconditions: PostconditionSpec
    let extra_files: [String: String]
    let denied_commands: [String]?
}

struct PostconditionSpec: Codable {
    let completed: Bool?
    let file_exists: [String]?
    let file_contains: [String: [String]]?
    let file_not_contains: [String: [String]]?
}

// MARK: - Report Types

struct ScenarioReport: Codable {
    let scenario: String
    let result: String
    let traceFile: String
    let iterations: Int
    let toolCalls: Int
    let totalTokens: Int
    let durationSeconds: Double
    let failures: [String]
}

struct ResultCounts: Codable {
    let pass: Int
    let fail: Int
    let error: Int
}

struct RunSummary: Codable {
    let provider: String
    let model: String
    let timestamp: String
    let results: [ScenarioReport]
    let summary: ResultCounts
}

// MARK: - Config

struct Config {
    let provider: String
    let model: String
    let scenarioDir: String
    let baseDir: String
    let selectedScenarios: [String]
    let keepDirs: Bool
    let outputDir: String?
    let verbose: Bool
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

func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}

// MARK: - Progress Logger

/// Writes JSONL progress events to a file for real-time monitoring.
/// Use `tail -f <scenario>.progress.jsonl` to watch a running scenario.
final class ProgressLogger {
    private let fileHandle: FileHandle
    private let start: Date
    private let encoder: JSONEncoder

    struct Entry: Codable {
        let t: String
        let elapsed: Double
        let iter: Int
        let event: String
        let detail: String
    }

    init(path: String, start: Date) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        self.start = start
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = .sortedKeys
    }

    func log(iteration: Int, event: String, detail: String) {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entry = Entry(
            t: formatter.string(from: now),
            elapsed: round(now.timeIntervalSince(start) * 100) / 100,
            iter: iteration,
            event: event,
            detail: String(detail.prefix(500))
        )
        guard let data = try? encoder.encode(entry),
              let json = String(data: data, encoding: .utf8) else { return }
        fileHandle.write(Data((json + "\n").utf8))
    }

    func close() {
        try? fileHandle.close()
    }
}

// MARK: - Shell Command Filter

/// Wraps the shell tool to auto-deny commands matching forbidden patterns.
/// Used to prevent expensive commands like `swift build` during bug bash.
struct FilteredShellTool: Tool {
    let inner: any Tool
    let deniedPatterns: [NSRegularExpression]

    var name: String { inner.name }
    var description: String { inner.description }
    var definition: ToolDefinition { inner.definition }
    var requiresApproval: Bool { inner.requiresApproval }

    func call(context: ToolContext, argumentsJSON: String) async throws -> AnyToolResult {
        if let data = argumentsJSON.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let command = json["command"] as? String {
            for pattern in deniedPatterns {
                let range = NSRange(command.startIndex..<command.endIndex, in: command)
                if pattern.firstMatch(in: command, range: range) != nil {
                    return .denied("Command denied by scenario policy. Matching pattern: \(pattern.pattern). Do not retry this command.")
                }
            }
        }
        return try await inner.call(context: context, argumentsJSON: argumentsJSON)
    }
}

// MARK: - Arg Parsing

func parseArgs() -> Config? {
    let args = Array(CommandLine.arguments.dropFirst())

    if args.contains("--help") || args.contains("-h") {
        print("""
        BugBash Runner — Run scenarios against an agent to find tool bugs.

        USAGE:
          swift run BugBash [OPTIONS] [SCENARIO_NUMBERS...]

        OPTIONS:
          --provider <name>        anthropic, openai, ollama, or lmstudio
                                   (auto-detected from env for cloud providers)
          --model <name>           Model name (default varies by provider)
          --keep-dirs              Keep temp working directories for debugging
          --output-dir <path>      Custom results directory
          --verbose                Print detailed iteration progress to stderr
          --help                   Show this help

        EXAMPLES:
          swift run BugBash                    Run all scenarios (auto-detect provider)
          swift run BugBash 01 07 15           Run specific scenarios
          swift run BugBash --model claude-haiku-4-5-20251001 05
          swift run BugBash --provider ollama --model qwen/qwen3-coder-next
        """)
        exit(0)
    }

    var provider: String?
    var model: String?
    var keepDirs = false
    var outputDir: String?
    var verbose = false
    var positionalArgs: [String] = []

    var iter = args.makeIterator()
    while let arg = iter.next() {
        switch arg {
        case "--provider":
            provider = iter.next()
        case "--model":
            model = iter.next()
        case "--keep-dirs":
            keepDirs = true
        case "--output-dir":
            outputDir = iter.next()
        case "--verbose", "-v":
            verbose = true
        default:
            if !arg.hasPrefix("-") {
                positionalArgs.append(arg)
            }
        }
    }

    let resolvedProvider = provider ?? autoDetectProvider()
    guard let resolvedProvider else {
        printError("No API key found. Set ANTHROPIC_API_KEY or OPENAI_API_KEY, or use --provider ollama/lmstudio.")
        return nil
    }

    let defaultModel: String
    switch resolvedProvider {
    case "anthropic": defaultModel = "claude-sonnet-4-5-20250929"
    case "openai": defaultModel = "gpt-5.2-mini"
    case "ollama", "lmstudio": defaultModel = "qwen/qwen3-coder-next"
    default: defaultModel = "gpt-5.2-mini"
    }

    // Resolve paths relative to the executable's BugBash directory
    let execPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    let baseDir = FileManager.default.fileExists(atPath: execPath + "/scenarios")
        ? execPath
        : FileManager.default.currentDirectoryPath

    return Config(
        provider: resolvedProvider,
        model: model ?? defaultModel,
        scenarioDir: baseDir + "/scenarios",
        baseDir: baseDir,
        selectedScenarios: positionalArgs,
        keepDirs: keepDirs,
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

// MARK: - Model Factory

func createModel(config: Config) throws -> any Model {
    let env = ProcessInfo.processInfo.environment

    switch config.provider {
    case "anthropic":
        guard let apiKey = env["ANTHROPIC_API_KEY"] else {
            throw RunnerError.missingKey("ANTHROPIC_API_KEY")
        }
        return AnthropicModel(name: config.model, provider: AnthropicProvider(apiKey: apiKey))
    case "openai":
        guard let apiKey = env["OPENAI_API_KEY"] else {
            throw RunnerError.missingKey("OPENAI_API_KEY")
        }
        return OpenAIModel(name: config.model, provider: OpenAIProvider(apiKey: apiKey))
    case "ollama":
        return LocalModel(name: config.model, provider: LocalProvider.ollama())
    case "lmstudio":
        return LocalModel(name: config.model, provider: LocalProvider.lmStudio())
    default:
        throw RunnerError.unknownProvider(config.provider)
    }
}

enum RunnerError: Error, CustomStringConvertible {
    case missingKey(String)
    case unknownProvider(String)
    case setupFailed(Int32)

    var description: String {
        switch self {
        case .missingKey(let key): return "Missing environment variable: \(key)"
        case .unknownProvider(let p): return "Unknown provider: \(p)"
        case .setupFailed(let code): return "setup.sh exited with code \(code)"
        }
    }
}

// MARK: - Setup

func runSetup(baseDir: String, repoPath: String) throws -> String {
    let scriptPath = baseDir + "/scripts/setup.sh"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [scriptPath, repoPath]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RunnerError.setupFailed(process.terminationStatus)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
}

func writeExtraFiles(_ files: [String: String], to dir: String) throws {
    let fm = FileManager.default
    for (filename, content) in files {
        let fullPath = (dir as NSString).appendingPathComponent(filename)
        let parent = (fullPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try content.write(toFile: fullPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Scenario Loading

func loadScenarios(from dir: String, filter: [String]) throws -> [Scenario] {
    let fm = FileManager.default
    let files = try fm.contentsOfDirectory(atPath: dir)
        .filter { $0.hasSuffix(".json") }
        .sorted()

    let filtered: [String]
    if filter.isEmpty {
        filtered = files
    } else {
        filtered = files.filter { filename in
            filter.contains { prefix in filename.hasPrefix(prefix) }
        }
    }

    return try filtered.map { filename in
        let path = (dir as NSString).appendingPathComponent(filename)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(Scenario.self, from: data)
    }
}

// MARK: - Postcondition Checking

func checkPostconditions(
    _ spec: PostconditionSpec,
    status: AgentRun<String>.Status,
    workingDir: String
) -> [String] {
    var failures: [String] = []

    if spec.completed == true {
        if case .completed = status {
            // pass
        } else {
            let statusDesc: String
            switch status {
            case .completed: statusDesc = "completed"
            case .iterationLimitReached(let limit): statusDesc = "iteration limit reached (\(limit))"
            case .usageLimitReached(let limit): statusDesc = "usage limit reached (\(limit))"
            case .needsApproval(let pending):
                let names = pending.filter { $0.requiresApproval }.map { $0.call.name }
                statusDesc = "needs approval (\(names.joined(separator: ", ")))"
            }
            failures.append("completed: agent status is \(statusDesc)")
        }
    }

    if let paths = spec.file_exists {
        for path in paths {
            let fullPath = (workingDir as NSString).appendingPathComponent(path)
            if !FileManager.default.fileExists(atPath: fullPath) {
                failures.append("file_exists: \(path) not found")
            }
        }
    }

    if let fileContains = spec.file_contains {
        for (path, strings) in fileContains {
            let fullPath = (workingDir as NSString).appendingPathComponent(path)
            do {
                let content = try String(contentsOfFile: fullPath, encoding: .utf8)
                for s in strings {
                    if !content.contains(s) {
                        failures.append("file_contains: \(path) missing \"\(s)\"")
                    }
                }
            } catch {
                failures.append("file_contains: \(path) could not be read (\(error.localizedDescription))")
            }
        }
    }

    if let fileNotContains = spec.file_not_contains {
        for (path, strings) in fileNotContains {
            let fullPath = (workingDir as NSString).appendingPathComponent(path)
            do {
                let content = try String(contentsOfFile: fullPath, encoding: .utf8)
                for s in strings {
                    if content.contains(s) {
                        failures.append("file_not_contains: \(path) still contains \"\(s)\"")
                    }
                }
            } catch {
                // File not existing is fine for file_not_contains
            }
        }
    }

    return failures
}

// MARK: - Trace Saving

struct BugBashTrace: Codable {
    let requests: [CompletionRequest]
    let run: AgentRun<String>
}

func saveTrace(_ run: AgentRun<String>, requests: [CompletionRequest], to path: String) throws {
    let trace = BugBashTrace(requests: requests, run: run)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(trace)
    try data.write(to: URL(fileURLWithPath: path))
}

func saveErrorTrace(_ error: String, to path: String) throws {
    let dict: [String: String] = ["error": error]
    let data = try JSONEncoder().encode(dict)
    try data.write(to: URL(fileURLWithPath: path))
}

// MARK: - Main

let systemPrompt = """
    You are a coding assistant with access to file and shell tools. \
    Complete the user's task thoroughly. \
    All file paths are relative to the current working directory unless otherwise specified.
    """

guard let config = parseArgs() else { exit(1) }

do {
    let model = try createModel(config: config)

    // Detect repo root for setup.sh
    let repoProcess = Process()
    repoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    repoProcess.arguments = ["rev-parse", "--show-toplevel"]
    let repoPipe = Pipe()
    repoProcess.standardOutput = repoPipe
    repoProcess.standardError = FileHandle.nullDevice
    try repoProcess.run()
    repoProcess.waitUntilExit()
    let repoData = repoPipe.fileHandleForReading.readDataToEndOfFile()
    let repoPath = String(data: repoData, encoding: .utf8)!
        .trimmingCharacters(in: .whitespacesAndNewlines)

    // Load scenarios
    let scenarios = try loadScenarios(from: config.scenarioDir, filter: config.selectedScenarios)
    guard !scenarios.isEmpty else {
        printError("No scenarios found matching filter: \(config.selectedScenarios)")
        exit(1)
    }

    // Create results directory
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
    let timestamp = dateFormatter.string(from: Date())

    let resultsBase = config.outputDir ?? (config.baseDir + "/results")
    let resultsDir = resultsBase + "/" + timestamp
    try FileManager.default.createDirectory(atPath: resultsDir, withIntermediateDirectories: true)

    // Banner
    print(bold("BugBash Runner") + " | \(config.provider) / \(config.model) | \(scenarios.count) scenarios")
    print("Results: \(resultsDir)")
    print("")

    // Run scenarios
    var reports: [ScenarioReport] = []

    for (index, scenario) in scenarios.enumerated() {
        let label = "[\(String(format: "%02d", index + 1))/\(String(format: "%02d", scenarios.count))] \(scenario.name)"
        let traceFilename = "\(scenario.name).trace.json"
        let tracePath = resultsDir + "/" + traceFilename
        let start = Date()

        print("\(label) ", terminator: "")
        fflush(stdout)

        var tempDir: String?

        do {
            // Setup
            let dir = try runSetup(baseDir: config.baseDir, repoPath: repoPath)
            tempDir = dir

            defer {
                if !config.keepDirs, let dir = tempDir {
                    try? FileManager.default.removeItem(atPath: dir)
                }
            }

            // Write extra files
            if !scenario.extra_files.isEmpty {
                try writeExtraFiles(scenario.extra_files, to: dir)
            }

            // Create tools scoped to temp dir
            let tools = try await BuiltInTools(
                workingDirectory: dir,
                allowedWriteDirectories: [dir],
                environment: .inherited(),
                shellApprovalRequired: false,
                discoverEnvironment: true
            )

            // Apply denied_commands filter to shell tool if configured
            var agentTools: [any Tool] = tools.all
            if let denied = scenario.denied_commands, !denied.isEmpty {
                let patterns = denied.compactMap { try? NSRegularExpression(pattern: $0) }
                if !patterns.isEmpty {
                    agentTools = agentTools.map { tool in
                        if tool.name == "shell" {
                            return FilteredShellTool(inner: tool, deniedPatterns: patterns)
                        }
                        return tool
                    }
                }
            }

            // Create agent
            let agent = try Agent<String>(
                model: model,
                systemPrompt: systemPrompt,
                tools: agentTools,
                maxIterations: scenario.maxIterations,
                backgroundTaskRegistry: tools.registry
            )

            // Run with streaming for progress visibility
            let progressPath = resultsDir + "/" + scenario.name + ".progress.jsonl"
            let progress = try ProgressLogger(path: progressPath, start: start)
            defer { progress.close() }

            var run: AgentRun<String>!
            var modelRequests: [CompletionRequest] = []
            var toolsInProgress = 0
            var currentIteration = 0
            var iterationToolCalls: [String] = []
            var iterationStart = Date()
            // Accumulate tool call args by id so we can log the full command
            var toolCallArgs: [String: String] = [:]
            var toolCallNames: [String: String] = [:]
            // Track whether we're waiting for the model to respond
            var waitingForModel = true
            var modelWaitStart = Date()

            progress.log(iteration: 0, event: "start", detail: scenario.task)
            if config.verbose {
                fputs(dim("  [scenario] \(scenario.name) maxIter=\(scenario.maxIterations)") + "\n", stderr)
            }

            for try await event in agent.runStream(scenario.task) {
                switch event {
                case .modelRequest(let request):
                    modelRequests.append(request)

                case .contentDelta(let text, let kind):
                    if waitingForModel {
                        let waitDur = Date().timeIntervalSince(modelWaitStart)
                        progress.log(
                            iteration: currentIteration,
                            event: "model_responding",
                            detail: String(format: "after %.1fs", waitDur)
                        )
                        if config.verbose {
                            fputs(dim("  [model responding after \(String(format: "%.1f", waitDur))s]") + "\n", stderr)
                        }
                        waitingForModel = false
                    }
                    let snippet = text
                        .replacingOccurrences(of: "\n", with: "\\n")
                    let label = kind == .thinking ? "thinking" : "text"
                    progress.log(iteration: currentIteration, event: label, detail: snippet)

                case .toolCallStart(let id, let name):
                    if waitingForModel {
                        let waitDur = Date().timeIntervalSince(modelWaitStart)
                        progress.log(
                            iteration: currentIteration,
                            event: "model_responding",
                            detail: String(format: "after %.1fs", waitDur)
                        )
                        if config.verbose {
                            fputs(dim("  [model responding after \(String(format: "%.1f", waitDur))s]") + "\n", stderr)
                        }
                        waitingForModel = false
                    }
                    toolsInProgress += 1
                    iterationToolCalls.append(name)
                    toolCallArgs[id] = ""
                    toolCallNames[id] = name
                    progress.log(iteration: currentIteration, event: "tool_start", detail: name)
                    if toolsInProgress == 1 {
                        print(dim(name), terminator: "")
                    } else {
                        print(dim(",\(name)"), terminator: "")
                    }
                    fflush(stdout)

                case .toolCallDelta(let id, let delta):
                    toolCallArgs[id, default: ""] += delta

                case .toolCallEnd(let id):
                    // Log the full tool call with args now that we have them
                    let name = toolCallNames[id] ?? "?"
                    let args = toolCallArgs[id] ?? ""
                    let argsSnippet = args
                        .replacingOccurrences(of: "\n", with: "\\n")
                    progress.log(
                        iteration: currentIteration,
                        event: "tool_call",
                        detail: "\(name): \(argsSnippet)"
                    )
                    if config.verbose {
                        fputs(dim("  [\(name)] \(String(argsSnippet.prefix(200)))") + "\n", stderr)
                    }
                    toolCallArgs.removeValue(forKey: id)
                    toolCallNames.removeValue(forKey: id)

                case .toolResult(_, let result):
                    let snippet = result
                        .replacingOccurrences(of: "\n", with: "\\n")
                    progress.log(iteration: currentIteration, event: "tool_result", detail: snippet)
                    toolsInProgress -= 1
                    if toolsInProgress == 0 {
                        let iterDur = Date().timeIntervalSince(iterationStart)
                        let tools = iterationToolCalls.joined(separator: ",")
                        progress.log(
                            iteration: currentIteration,
                            event: "iter_end",
                            detail: String(format: "%.1fs tools=[%@]", iterDur, tools)
                        )
                        if config.verbose {
                            fputs(dim("  [iter \(currentIteration)] \(tools) (\(String(format: "%.1f", iterDur))s)") + "\n", stderr)
                        }
                        currentIteration += 1
                        iterationToolCalls = []
                        iterationStart = Date()
                        print(" ", terminator: "")
                        fflush(stdout)
                    }

                case .usage(let usage):
                    progress.log(
                        iteration: currentIteration,
                        event: "usage",
                        detail: "in=\(usage.inputTokens) out=\(usage.outputTokens) total=\(usage.totalTokens)"
                    )
                    // After usage, the agent is about to call the model again
                    waitingForModel = true
                    modelWaitStart = Date()
                    progress.log(iteration: currentIteration, event: "waiting_for_model", detail: "")
                    if config.verbose {
                        fputs(dim("  [waiting for model...]") + "\n", stderr)
                    }

                case .backgroundTaskCompleted(let id, let exitCode, let summary):
                    progress.log(
                        iteration: currentIteration,
                        event: "bg_done",
                        detail: "id=\(id) exit=\(exitCode) \(summary)"
                    )
                    if config.verbose {
                        fputs(dim("  [bg] id=\(id) exit=\(exitCode)") + "\n", stderr)
                    }

                case .finished(let r):
                    let statusStr: String
                    switch r.status {
                    case .completed: statusStr = "completed"
                    case .iterationLimitReached(let l): statusStr = "iter_limit(\(l))"
                    case .usageLimitReached: statusStr = "usage_limit"
                    case .needsApproval: statusStr = "needs_approval"
                    }
                    progress.log(
                        iteration: currentIteration,
                        event: "finished",
                        detail: "status=\(statusStr) iters=\(r.iteration + 1) tools=\(r.toolCallCount) tokens=\(r.usage.totalTokens)"
                    )
                    run = r
                }
            }
            let duration = Date().timeIntervalSince(start)

            // Save full trace
            try saveTrace(run, requests: modelRequests, to: tracePath)

            // Check postconditions
            let failures = checkPostconditions(scenario.postconditions, status: run.status, workingDir: dir)

            let resultStr = failures.isEmpty ? "pass" : "fail"
            let report = ScenarioReport(
                scenario: scenario.name,
                result: resultStr,
                traceFile: traceFilename,
                iterations: run.iteration + 1,
                toolCalls: run.toolCallCount,
                totalTokens: run.usage.totalTokens,
                durationSeconds: round(duration * 10) / 10,
                failures: failures
            )
            reports.append(report)

            // Console output
            let stats = "\(report.iterations) iter, \(formatTokens(report.totalTokens)) tok, \(Int(duration))s"
            if failures.isEmpty {
                print(green("PASS") + dim(" (\(stats))"))
            } else {
                print(red("FAIL") + dim(" (\(stats))"))
                for f in failures {
                    print(red("  - \(f)"))
                }
            }

        } catch {
            let duration = Date().timeIntervalSince(start)

            // Save error trace
            try? saveErrorTrace("\(error)", to: tracePath)

            let report = ScenarioReport(
                scenario: scenario.name,
                result: "error",
                traceFile: traceFilename,
                iterations: 0,
                toolCalls: 0,
                totalTokens: 0,
                durationSeconds: round(duration * 10) / 10,
                failures: ["\(error)"]
            )
            reports.append(report)

            print(yellow("ERROR") + dim(": \(error)"))
        }
    }

    // Write summary
    let passCount = reports.filter { $0.result == "pass" }.count
    let failCount = reports.filter { $0.result == "fail" }.count
    let errorCount = reports.filter { $0.result == "error" }.count

    let summary = RunSummary(
        provider: config.provider,
        model: config.model,
        timestamp: timestamp,
        results: reports,
        summary: ResultCounts(pass: passCount, fail: failCount, error: errorCount)
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let summaryData = try encoder.encode(summary)
    try summaryData.write(to: URL(fileURLWithPath: resultsDir + "/summary.json"))

    // Generate findings template
    let findingsDir = config.baseDir + "/findings"
    try FileManager.default.createDirectory(atPath: findingsDir, withIntermediateDirectories: true)

    let dateOnlyFormatter = DateFormatter()
    dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
    let dateOnly = dateOnlyFormatter.string(from: Date())

    let findingsPath = findingsDir + "/\(dateOnly)-findings.md"
    if !FileManager.default.fileExists(atPath: findingsPath) {
        var findings = "# Bug Bash Findings Report\n\n"
        findings += "**Date:** \(dateOnly)\n"
        findings += "**Model:** \(config.model)\n"
        findings += "**Provider:** \(config.provider)\n"
        findings += "**Pass/Fail:** \(passCount) PASS / \(failCount) FAIL"
        if errorCount > 0 { findings += " / \(errorCount) ERROR" }
        findings += "\n\n"
        findings += "## Results Summary\n\n"
        findings += "| # | Scenario | Result | Iters | Tokens | Time |\n"
        findings += "|---|----------|--------|-------|--------|------|\n"
        for (i, report) in reports.enumerated() {
            let num = String(format: "%02d", i + 1)
            let result = report.result.uppercased()
            let duration = String(format: "%.0fs", report.durationSeconds)
            let tokens = String(report.totalTokens).replacingOccurrences(
                of: "(?<=\\d)(?=(\\d{3})+$)", with: ",",
                options: .regularExpression
            )
            findings += "| \(num) | \(report.scenario) | \(result) | \(report.iterations) | \(tokens) | \(duration) |\n"
        }
        findings += "\n---\n\n## Findings\n\n_Add findings here after reviewing traces._\n"
        try findings.write(toFile: findingsPath, atomically: true, encoding: .utf8)
        print(dim("Findings template: \(findingsPath)"))
    }

    // Final console summary
    print("")
    var parts: [String] = []
    if passCount > 0 { parts.append(green("\(passCount) PASS")) }
    if failCount > 0 { parts.append(red("\(failCount) FAIL")) }
    if errorCount > 0 { parts.append(yellow("\(errorCount) ERROR")) }
    print(parts.joined(separator: " | "))
    print(dim("Traces saved to: \(resultsDir)/"))

    exit(failCount > 0 || errorCount > 0 ? 1 : 0)

} catch {
    printError("\(error)")
    exit(1)
}
