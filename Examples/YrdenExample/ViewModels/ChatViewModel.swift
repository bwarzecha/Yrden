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

    private var agent: Agent<String>?
    private var currentModel: (any Model)?  // Store model for reconfiguration
    private var messageHistory: [Message] = []  // Conversation history for multi-turn

    // MCP - supports multiple servers
    private var mcpToolsCache: [UUID: [any Tool]] = [:]

    // Paused agent run (for tool approval or iteration limits)
    private var pausedRun: AgentRun<String>?

    // Approval continuation - pauses send() while waiting for user decision
    // Returns nil for approval, or rejection reason string for rejection
    private var approvalContinuation: CheckedContinuation<String?, Never>?

    init() {}

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

    func configure(model: any Model, mcpTools: [any Tool] = []) {
        currentModel = model  // Store for reconfiguration
        do {
            agent = try Agent(
                model: model,
                systemPrompt: "You are a helpful assistant. Use tools when appropriate.",
                tools: mcpTools,
                maxIterations: 10
            )
        } catch {
            log(.error, "Failed to configure agent", details: error.localizedDescription)
            self.error = error
            return
        }
        // Store model's context window size for usage indicator
        maxContextTokens = model.capabilities.maxContextTokens
        log(.info, "Configured agent", details: "Model: \(model.name), Context: \(maxContextTokens.map { "\($0)" } ?? "unknown"), Tools: \(mcpTools.map { $0.name }.joined(separator: ", "))")
    }

    // MARK: - MCP (Multi-Server Support)

    /// Connect to an MCP server via stdio and return the connection, tools, and tool names.
    func connectMCPStdioRaw(commandLine: String) async throws -> (MCPServerConnection, [any Tool], [String]) {
        log(.info, "Connecting MCP stdio", details: commandLine)
        do {
            let server = try await mcpConnect(commandLine)
            let tools: [any Tool] = try await server.discoverTools()
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
    ) async throws -> (MCPServerConnection, [any Tool], [String]) {
        log(.info, "Connecting MCP OAuth", details: url.absoluteString)
        do {
            let server = try await mcpConnect(
                url: url,
                redirectScheme: redirectScheme,
                onProgress: onProgress
            )
            let tools: [any Tool] = try await server.discoverTools()
            log(.info, "MCP OAuth connected", details: "Tools: \(tools.map { $0.name }.joined(separator: ", "))")
            return (server, tools, tools.map { $0.name })
        } catch {
            log(.error, "MCP OAuth failed", details: String(describing: error))
            throw error
        }
    }

    /// Register tools from a connected server (by server ID).
    func registerMCPTools(serverId: UUID, tools: [any Tool]) {
        mcpToolsCache[serverId] = tools
    }

    /// Unregister tools from a disconnected server.
    func unregisterMCPTools(serverId: UUID) {
        mcpToolsCache.removeValue(forKey: serverId)
    }

    /// Get all MCP tools from all connected servers.
    func getAllMCPTools() -> [any Tool] {
        mcpToolsCache.values.flatMap { $0 }
    }

    /// Reconfigure the agent with current model and all MCP tools.
    /// Call this after MCP tools change (connect/disconnect).
    func reconfigureTools() {
        guard let model = currentModel else { return }
        let mcpTools = getAllMCPTools()
        do {
            agent = try Agent(
                model: model,
                systemPrompt: "You are a helpful assistant. Use tools when appropriate.",
                tools: mcpTools,
                maxIterations: 10
            )
        } catch {
            log(.error, "Failed to reconfigure agent", details: error.localizedDescription)
            self.error = error
            return
        }
        log(.info, "Reconfigured agent with tools", details: mcpTools.map { $0.name }.joined(separator: ", "))
    }

    // MARK: - Chat

    func send(_ text: String) async {
        guard let agent, !text.isEmpty else { return }
        log(.info, "User message", details: text)
        isProcessing = true
        error = nil
        messages.append(.user(text))
        messages.append(.assistant("", isStreaming: true))

        // Track paused run for approval loop
        var currentPausedRun: AgentRun<String>? = nil

        // Main processing loop - handles initial run and approval resumes
        processingLoop: while true {
            do {
                let stream: AsyncThrowingStream<AgentStreamEvent<String>, Error>

                if let paused = currentPausedRun {
                    // Resuming after approval
                    let approvalIds = paused.toolsRequiringApproval.map { $0.call.id }
                    log(.info, "Resuming after approval", details: approvalIds.joined(separator: ", "))
                    stream = agent.resumeStream(from: paused, with: .approve(approvalIds))
                } else {
                    // Initial streaming run
                    stream = agent.runStream(text, messageHistory: messageHistory)
                }

                var finishedRun: AgentRun<String>? = nil

                for try await event in stream {
                    switch event {
                    case .contentDelta(let t, _):
                        messages[messages.count - 1].appendText(t)
                    case .toolCallStart(let id, let name):
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
                    case .finished(let run):
                        finishedRun = run
                    }
                }

                guard let run = finishedRun else {
                    log(.error, "Stream ended without finished event")
                    break processingLoop
                }

                switch run.status {
                case .completed(let output):
                    let contextAfter = run.usage.inputTokens + run.usage.outputTokens
                    let maxCtx = maxContextTokens ?? 0
                    let pct = maxCtx > 0 ? Double(contextAfter) / Double(maxCtx) * 100 : 0
                    log(.info, "Turn complete", details: "Input: \(run.usage.inputTokens), Output: \(run.usage.outputTokens), Context: \(contextAfter)/\(maxCtx) (\(String(format: "%.1f", pct))%)")
                    messageHistory = run.messages
                    updateTotalUsage(with: run.usage)
                    currentTurnUsage = nil
                    if messages.last?.content.isEmpty == true {
                        messages[messages.count - 1].appendText(output)
                    }
                    break processingLoop

                case .needsApproval(let pending):
                    // Tool needs approval - show UI and wait for user decision
                    let approvalRequired = pending.filter { $0.requiresApproval }
                    if !approvalRequired.isEmpty {
                        let tools = approvalRequired.map { p in
                            PendingToolInfo(
                                id: p.call.id,
                                toolName: p.call.name,
                                arguments: p.call.arguments
                            )
                        }
                        pendingApproval = PendingApprovalInfo(
                            id: approvalRequired.first!.call.id,
                            tools: tools,
                            reason: "Tool requires approval"
                        )

                        // Update tool status to needsApproval in the UI
                        for p in approvalRequired {
                            messages[messages.count - 1].updateToolCall(id: p.call.id) { info in
                                info.status = .needsApproval
                            }
                        }

                        let toolNames = tools.map { $0.toolName }.joined(separator: ", ")
                        log(.info, "Waiting for approval", details: "Tools: \(toolNames)")
                    }

                    // Pause processing while waiting for user
                    isProcessing = false

                    // Wait for user decision via continuation
                    let rejectionReason = await withCheckedContinuation { continuation in
                        self.approvalContinuation = continuation
                    }

                    if rejectionReason == nil {
                        // User approved - update status and resume
                        log(.info, "User approved tool call")
                        for p in (pending.filter { $0.requiresApproval }) {
                            messages[messages.count - 1].updateToolCall(id: p.call.id) { info in
                                info.status = .running
                            }
                        }
                        currentPausedRun = run
                        pendingApproval = nil
                        isProcessing = true
                        continue processingLoop
                    } else {
                        // User rejected - mark as failed and send rejection to LLM
                        let reason = rejectionReason!
                        log(.info, "User rejected tool call", details: reason)
                        let approvalIds = pending.filter { $0.requiresApproval }.map { $0.call.id }
                        for p in (pending.filter { $0.requiresApproval }) {
                            messages[messages.count - 1].updateToolCall(id: p.call.id) { info in
                                info.status = .failed
                                info.result = "Rejected: \(reason)"
                            }
                        }
                        pendingApproval = nil
                        isProcessing = true

                        // Send rejection to LLM via resumeStream so it can adjust
                        currentPausedRun = nil
                        let rejectionStream = agent.resumeStream(
                            from: run,
                            with: .deny(approvalIds, message: reason)
                        )

                        var rejectionFinishedRun: AgentRun<String>? = nil
                        do {
                            for try await event in rejectionStream {
                                switch event {
                                case .contentDelta(let t, _):
                                    messages[messages.count - 1].appendText(t)
                                case .toolCallStart(let id, let name):
                                    log(.info, "Tool call start", details: "[\(id)] \(name)")
                                    messages[messages.count - 1].appendToolCall(ToolCallInfo(id: id, name: name, status: .running))
                                case .toolResult(let id, let result):
                                    log(.info, "Tool result", details: "[\(id)] \(result.prefix(200))")
                                    messages[messages.count - 1].updateToolCall(id: id) { info in
                                        info.result = result
                                        info.status = .completed
                                    }
                                case .finished(let r):
                                    rejectionFinishedRun = r
                                default:
                                    break
                                }
                            }

                            if let rejRun = rejectionFinishedRun {
                                switch rejRun.status {
                                case .completed(let output):
                                    log(.info, "Resume after rejection completed", details: "Output: \(output.prefix(100))")
                                    messageHistory = rejRun.messages
                                    updateTotalUsage(with: rejRun.usage)
                                    if messages.last?.content.isEmpty == true {
                                        messages[messages.count - 1].appendText(output)
                                    }
                                    break processingLoop

                                case .needsApproval:
                                    // Model called another tool needing approval after rejection
                                    log(.info, "Model called another tool after rejection")
                                    currentPausedRun = rejRun
                                    continue processingLoop

                                case .iterationLimitReached(let limit):
                                    pausedRun = rejRun
                                    pausedForIterations = PausedIterationInfo(
                                        iterationsUsed: rejRun.requestCount,
                                        iterationLimit: limit,
                                        tokensUsed: rejRun.usage.totalTokens,
                                        toolCallsUsed: rejRun.toolCallCount
                                    )
                                    break processingLoop

                                case .usageLimitReached:
                                    log(.error, "Usage limit reached after rejection")
                                    break processingLoop
                                }
                            } else {
                                break processingLoop
                            }
                        } catch {
                            log(.error, "Error resuming after rejection", details: error.localizedDescription)
                            break processingLoop
                        }
                    }

                case .iterationLimitReached(let limit):
                    // Agent hit iteration limit - allow user to continue
                    pausedRun = run
                    pausedForIterations = PausedIterationInfo(
                        iterationsUsed: run.requestCount,
                        iterationLimit: limit,
                        tokensUsed: run.usage.totalTokens,
                        toolCallsUsed: run.toolCallCount
                    )
                    log(.warning, "Max iterations reached", details: "Used \(run.requestCount) iterations, \(run.usage.totalTokens) tokens")
                    break processingLoop

                case .usageLimitReached(let limit):
                    log(.error, "Usage limit reached", details: String(describing: limit))
                    error = AgentError<String>.usageLimitReached(run)
                    messages.append(.error("Usage limit reached: \(limit)"))
                    break processingLoop
                }
            } catch {
                log(.error, "Error", details: String(describing: error))
                if let streamingUsage = currentTurnUsage {
                    updateTotalUsage(with: streamingUsage)
                }
                currentTurnUsage = nil
                self.error = error
                messages.append(.error(error.localizedDescription))
                break processingLoop
            }
        }

        isProcessing = false
        if !messages.isEmpty { messages[messages.count - 1].isStreaming = false }
    }

    func approveToolCall() {
        // Resume with nil = approved
        approvalContinuation?.resume(returning: nil)
        approvalContinuation = nil
    }

    func rejectToolCall(reason: String) {
        // Resume with reason string = rejected
        approvalContinuation?.resume(returning: reason)
        approvalContinuation = nil
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
            var finishedRun: AgentRun<String>? = nil

            for try await event in agent.resumeStream(
                from: paused,
                with: .additionalIterations(additionalIterations)
            ) {
                switch event {
                case .contentDelta(let t, _):
                    messages[messages.count - 1].appendText(t)
                case .toolCallStart(let id, let name):
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
                case .finished(let run):
                    finishedRun = run
                }
            }

            if let run = finishedRun {
                switch run.status {
                case .completed(let output):
                    log(.info, "Continuation complete", details: "Output length: \(output.count)")
                    messageHistory = run.messages
                    updateTotalUsage(with: run.usage)
                    currentTurnUsage = nil
                    if messages.last?.content.isEmpty == true {
                        messages[messages.count - 1].appendText(output)
                    }
                    pausedRun = nil

                case .iterationLimitReached(let limit):
                    // Still not done - show pause UI again
                    pausedRun = run
                    pausedForIterations = PausedIterationInfo(
                        iterationsUsed: run.requestCount,
                        iterationLimit: limit,
                        tokensUsed: run.usage.totalTokens,
                        toolCallsUsed: run.toolCallCount
                    )
                    log(.warning, "Max iterations reached again", details: "Used \(run.requestCount) total iterations")

                case .needsApproval:
                    // Unexpected during iteration continuation, but handle gracefully
                    pausedRun = run
                    log(.warning, "Approval needed during continuation")

                case .usageLimitReached(let limit):
                    pausedRun = nil
                    log(.error, "Usage limit reached during continuation", details: String(describing: limit))
                    error = AgentError<String>.usageLimitReached(run)
                    messages.append(.error("Usage limit reached: \(limit)"))
                }
            } else {
                pausedRun = nil
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
