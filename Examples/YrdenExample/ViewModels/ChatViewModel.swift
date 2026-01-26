/// Chat view model - binds to Agent with minimal logic.
import Foundation
import Yrden

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isProcessing = false
    @Published var pendingApproval: PendingApprovalInfo?
    @Published var pausedForIterations: PausedIterationInfo?  // When max iterations reached
    @Published var error: Error?
    @Published var logs: [LogEntry] = []

    // Usage tracking
    @Published var currentTurnUsage: Usage?       // Usage for current streaming turn
    @Published var totalUsage: Usage?             // Accumulated usage for conversation
    @Published var maxContextTokens: Int?         // Model's context window size

    private let deps: AppDependencies
    private var agent: Agent<AppDependencies, String>?
    private var pausedRun: PausedAgentRun?
    private var messageHistory: [Message] = []  // Conversation history for multi-turn

    // MCP - supports multiple servers
    private var mcpToolsCache: [UUID: [AnyAgentTool<AppDependencies>]] = [:]

    init(deps: AppDependencies = .default()) { self.deps = deps }

    /// Context usage as a percentage (0.0 to 1.0), or nil if unknown
    var contextUsagePercent: Double? {
        guard let maxContext = maxContextTokens, maxContext > 0,
              let total = totalUsage else { return nil }
        return Double(total.inputTokens) / Double(maxContext)
    }

    // MARK: - Logging

    func log(_ level: LogEntry.Level, _ message: String, details: String? = nil) {
        logs.append(LogEntry(level: level, message: message, details: details))
    }

    func exportLogs() -> String {
        let header = "=== YrdenExample Logs ===\nExported: \(ISO8601DateFormatter().string(from: Date()))\n\n"
        let logText = logs.map { entry in
            let timestamp = entry.timestamp.formatted(date: .omitted, time: .standard)
            let detailText = entry.details.map { "\n  Details: \($0)" } ?? ""
            return "[\(timestamp)] [\(entry.level.rawValue.uppercased())] \(entry.message)\(detailText)"
        }.joined(separator: "\n")
        return header + logText
    }

    func clearLogs() {
        logs.removeAll()
    }

    func configure(model: any Model, mcpTools: [AnyAgentTool<AppDependencies>] = []) {
        agent = Agent(
            model: model,
            systemPrompt: "You are a helpful assistant. Use tools when appropriate.",
            tools: mcpTools,
            maxIterations: 10
        )
        // Store model's context window size for usage indicator
        maxContextTokens = model.capabilities.maxContextTokens
        log(.info, "Configured agent", details: "Model: \(model.name), Context: \(maxContextTokens.map { "\($0)" } ?? "unknown"), Tools: \(mcpTools.map { $0.name }.joined(separator: ", "))")
    }

    // MARK: - MCP (Multi-Server Support)

    /// Connect to an MCP server via stdio and return the connection, tools, and tool names.
    func connectMCPStdioRaw(commandLine: String) async throws -> (MCPServerConnection, [AnyAgentTool<AppDependencies>], [String]) {
        log(.info, "Connecting MCP stdio", details: commandLine)
        do {
            let server = try await mcpConnect(commandLine)
            let tools: [AnyAgentTool<AppDependencies>] = try await server.discoverTools()
            log(.info, "MCP connected", details: "Tools: \(tools.map { $0.name }.joined(separator: ", "))")
            return (server, tools, tools.map { $0.name })
        } catch {
            log(.error, "MCP connection failed", details: String(describing: error))
            throw error
        }
    }

    /// Connect to an MCP server via OAuth and return the connection, tools, and tool names.
    func connectMCPOAuthRaw(
        url: URL,
        redirectScheme: String,
        onProgress: @escaping @Sendable (MCPOAuthProgress) -> Void
    ) async throws -> (MCPServerConnection, [AnyAgentTool<AppDependencies>], [String]) {
        log(.info, "Connecting MCP OAuth", details: url.absoluteString)
        do {
            let server = try await mcpConnect(
                url: url,
                redirectScheme: redirectScheme,
                onProgress: onProgress
            )
            let tools: [AnyAgentTool<AppDependencies>] = try await server.discoverTools()
            log(.info, "MCP OAuth connected", details: "Tools: \(tools.map { $0.name }.joined(separator: ", "))")
            return (server, tools, tools.map { $0.name })
        } catch {
            log(.error, "MCP OAuth failed", details: String(describing: error))
            throw error
        }
    }

    /// Register tools from a connected server (by server ID).
    func registerMCPTools(serverId: UUID, tools: [AnyAgentTool<AppDependencies>]) {
        mcpToolsCache[serverId] = tools
    }

    /// Unregister tools from a disconnected server.
    func unregisterMCPTools(serverId: UUID) {
        mcpToolsCache.removeValue(forKey: serverId)
    }

    /// Get all MCP tools from all connected servers.
    func getAllMCPTools() -> [AnyAgentTool<AppDependencies>] {
        mcpToolsCache.values.flatMap { $0 }
    }

    // MARK: - Chat

    func send(_ text: String) async {
        guard let agent, !text.isEmpty else { return }
        log(.info, "User message", details: text)
        isProcessing = true
        error = nil
        messages.append(.user(text))
        messages.append(.assistant("", isStreaming: true))

        do {
            for try await event in agent.runStream(text, deps: deps, messageHistory: messageHistory) {
                switch event {
                case .contentDelta(let t):
                    messages[messages.count - 1].appendText(t)
                case .toolCallStart(let name, let id):
                    log(.info, "Tool call start", details: "[\(id)] \(name)")
                    messages[messages.count - 1].appendToolCall(ToolCallInfo(id: id, name: name, status: .running))
                case .toolCallDelta(let id, let delta):
                    log(.debug, "Tool args delta", details: "[\(id)] \(delta)")
                case .toolCallEnd(let id):
                    log(.info, "Tool call end", details: "[\(id)]")
                case .toolResult(let id, let result):
                    let resultStr = String(describing: result)
                    log(.info, "Tool result", details: "[\(id)] \(resultStr.prefix(1000))\(resultStr.count > 1000 ? "..." : "")")
                    messages[messages.count - 1].updateToolCall(id: id) { info in
                        info.result = result
                        info.status = .completed
                    }
                case .usage(let usage):
                    currentTurnUsage = usage
                    log(.debug, "Usage (streaming)", details: "Input: \(usage.inputTokens), Output: \(usage.outputTokens), Cached: \(usage.cachedTokens ?? 0)")
                case .result(let r):
                    let contextAfter = r.usage.inputTokens + r.usage.outputTokens
                    let maxCtx = maxContextTokens ?? 0
                    let pct = maxCtx > 0 ? Double(contextAfter) / Double(maxCtx) * 100 : 0
                    log(.info, "Turn complete", details: "Input: \(r.usage.inputTokens), Output: \(r.usage.outputTokens), Context: \(contextAfter)/\(maxCtx) (\(String(format: "%.1f", pct))%)")
                    messageHistory = r.messages  // Save for multi-turn
                    // Update total usage
                    updateTotalUsage(with: r.usage)
                    currentTurnUsage = nil
                    if messages.last?.content.isEmpty == true {
                        messages[messages.count - 1].appendText(r.output)
                    }
                }
            }
        } catch let e as AgentError {
            log(.error, "AgentError", details: String(describing: e))
            // Preserve any streaming usage we captured before the error
            if let streamingUsage = currentTurnUsage {
                updateTotalUsage(with: streamingUsage)
            }
            currentTurnUsage = nil

            switch e {
            case .hasDeferredTools(let paused):
                pausedRun = paused
                if let p = paused.pendingCalls.first {
                    pendingApproval = PendingApprovalInfo(id: p.deferral.id, toolName: p.toolCall.name,
                                                          arguments: p.toolCall.arguments, reason: p.deferral.reason)
                }

            case .maxIterationsExceeded(let paused):
                // Agent hit iteration limit - allow user to continue
                pausedRun = paused
                pausedForIterations = PausedIterationInfo(
                    iterationsUsed: paused.requestCount,
                    iterationLimit: paused.reason.iterationLimit ?? paused.requestCount,
                    tokensUsed: paused.usage.totalTokens,
                    toolCallsUsed: paused.toolCallCount
                )
                log(.warning, "Max iterations reached", details: "Used \(paused.requestCount) iterations, \(paused.usage.totalTokens) tokens")

            default:
                error = e
                messages.append(.error(e.localizedDescription))
            }
        } catch {
            log(.error, "Error", details: String(describing: error))
            // Preserve any streaming usage we captured before the error
            if let streamingUsage = currentTurnUsage {
                updateTotalUsage(with: streamingUsage)
            }
            currentTurnUsage = nil
            self.error = error; messages.append(.error(error.localizedDescription))
        }

        isProcessing = false
        if !messages.isEmpty { messages[messages.count - 1].isStreaming = false }
    }

    func approveToolCall() async {
        guard let paused = pausedRun, let agent else { return }
        log(.info, "Tool approved", details: paused.pendingCalls.map { $0.toolCall.name }.joined(separator: ", "))
        let resolutions = paused.pendingCalls.map { ResolvedTool(id: $0.deferral.id, resolution: .approved) }
        pendingApproval = nil
        isProcessing = true
        do {
            let result = try await agent.resume(paused: paused, resolutions: resolutions, deps: deps)
            log(.info, "Resume completed", details: "Output length: \(result.output.count)")
            messageHistory = result.messages  // Save for multi-turn
            updateTotalUsage(with: result.usage)
            if messages.last?.content.isEmpty == true {
                messages[messages.count - 1].appendText(result.output)
            }
        } catch {
            log(.error, "Resume failed", details: String(describing: error))
            self.error = error; messages.append(.error(error.localizedDescription))
        }
        pausedRun = nil
        isProcessing = false
    }

    func rejectToolCall() {
        pausedRun = nil
        pendingApproval = nil
        if !messages.isEmpty {
            messages[messages.count - 1].appendText("\n\n[Tool call rejected by user]")
            messages[messages.count - 1].isStreaming = false
        }
    }

    // MARK: - Iteration Continuation

    /// Continue agent run with additional iterations after max iterations was reached.
    func continueWithIterations(_ additionalIterations: Int) async {
        guard let paused = pausedRun, let agent else { return }

        log(.info, "Continuing run", details: "Adding \(additionalIterations) iterations")
        pausedForIterations = nil
        isProcessing = true

        // Mark message as streaming again
        if !messages.isEmpty {
            messages[messages.count - 1].isStreaming = true
        }

        do {
            for try await event in agent.continueRunStream(
                paused: paused,
                additionalIterations: additionalIterations,
                deps: deps
            ) {
                switch event {
                case .contentDelta(let t):
                    messages[messages.count - 1].appendText(t)
                case .toolCallStart(let name, let id):
                    log(.info, "Tool call start", details: "[\(id)] \(name)")
                    messages[messages.count - 1].appendToolCall(ToolCallInfo(id: id, name: name, status: .running))
                case .toolCallDelta(let id, let delta):
                    log(.debug, "Tool args delta", details: "[\(id)] \(delta)")
                case .toolCallEnd(let id):
                    log(.info, "Tool call end", details: "[\(id)]")
                case .toolResult(let id, let result):
                    let resultStr = String(describing: result)
                    log(.info, "Tool result", details: "[\(id)] \(resultStr.prefix(1000))\(resultStr.count > 1000 ? "..." : "")")
                    messages[messages.count - 1].updateToolCall(id: id) { info in
                        info.result = result
                        info.status = .completed
                    }
                case .usage(let usage):
                    currentTurnUsage = usage
                    log(.debug, "Usage (streaming)", details: "Input: \(usage.inputTokens), Output: \(usage.outputTokens)")
                case .result(let r):
                    log(.info, "Continuation complete", details: "Output length: \(r.output.count)")
                    messageHistory = r.messages
                    updateTotalUsage(with: r.usage)
                    currentTurnUsage = nil
                    if messages.last?.content.isEmpty == true {
                        messages[messages.count - 1].appendText(r.output)
                    }
                }
            }
            pausedRun = nil
        } catch let e as AgentError {
            log(.error, "Continuation error", details: String(describing: e))
            if let streamingUsage = currentTurnUsage {
                updateTotalUsage(with: streamingUsage)
            }
            currentTurnUsage = nil

            if case .maxIterationsExceeded(let newPaused) = e {
                // Still not done - show pause UI again
                pausedRun = newPaused
                pausedForIterations = PausedIterationInfo(
                    iterationsUsed: newPaused.requestCount,
                    iterationLimit: newPaused.reason.iterationLimit ?? newPaused.requestCount,
                    tokensUsed: newPaused.usage.totalTokens,
                    toolCallsUsed: newPaused.toolCallCount
                )
                log(.warning, "Max iterations reached again", details: "Used \(newPaused.requestCount) total iterations")
            } else {
                pausedRun = nil
                error = e
                messages.append(.error(e.localizedDescription))
            }
        } catch {
            log(.error, "Continuation failed", details: String(describing: error))
            if let streamingUsage = currentTurnUsage {
                updateTotalUsage(with: streamingUsage)
            }
            currentTurnUsage = nil
            pausedRun = nil
            self.error = error
            messages.append(.error(error.localizedDescription))
        }

        isProcessing = false
        if !messages.isEmpty { messages[messages.count - 1].isStreaming = false }
    }

    /// Cancel a paused run without continuing.
    func cancelPausedRun() {
        pausedRun = nil
        pausedForIterations = nil
        if !messages.isEmpty {
            messages[messages.count - 1].appendText("\n\n[Run stopped by user after reaching iteration limit]")
            messages[messages.count - 1].isStreaming = false
        }
        log(.info, "Paused run cancelled by user")
    }

    func clearConversation() {
        messages.removeAll()
        messageHistory.removeAll()  // Clear agent history too
        error = nil
        pausedRun = nil
        pendingApproval = nil
        pausedForIterations = nil
        // Reset usage tracking
        currentTurnUsage = nil
        totalUsage = nil
    }

    // MARK: - Usage Tracking

    private func updateTotalUsage(with usage: Usage) {
        if let existing = totalUsage {
            // Accumulate totals - input tokens represent the growing context
            totalUsage = Usage(
                inputTokens: usage.inputTokens,  // Latest input reflects full context
                outputTokens: existing.outputTokens + usage.outputTokens,
                cachedTokens: usage.cachedTokens,
                reasoningTokens: (existing.reasoningTokens ?? 0) + (usage.reasoningTokens ?? 0)
            )
        } else {
            totalUsage = usage
        }
    }

    func clearError() {
        error = nil
    }
}

// MARK: - PausedIterationInfo

/// Information about a paused agent run due to max iterations.
struct PausedIterationInfo {
    let iterationsUsed: Int
    let iterationLimit: Int
    let tokensUsed: Int
    let toolCallsUsed: Int
}

// MARK: - LogEntry

struct LogEntry: Identifiable {
    enum Level: String {
        case debug, info, warning, error
    }

    let id = UUID()
    let timestamp = Date()
    let level: Level
    let message: String
    let details: String?
}
