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
    private var currentModel: (any Model)?  // Store model for reconfiguration
    private var messageHistory: [Message] = []  // Conversation history for multi-turn

    // MCP - supports multiple servers
    private var mcpToolsCache: [UUID: [AnyAgentTool<AppDependencies>]] = [:]

    // Paused agent run (for tool approval or iteration limits)
    private var pausedRun: PausedAgentRun?

    // Approval continuation - pauses send() while waiting for user decision
    // Returns nil for approval, or rejection reason string for rejection
    private var approvalContinuation: CheckedContinuation<String?, Never>?

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
        currentModel = model  // Store for reconfiguration
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

    /// Reconfigure the agent with current model and all MCP tools.
    /// Call this after MCP tools change (connect/disconnect).
    func reconfigureTools() {
        guard let model = currentModel else { return }
        let mcpTools = getAllMCPTools()
        agent = Agent(
            model: model,
            systemPrompt: "You are a helpful assistant. Use tools when appropriate.",
            tools: mcpTools,
            maxIterations: 10
        )
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

        // Track paused state for approval loop
        var currentPaused: PausedAgentRun? = nil

        // Main processing loop - handles initial run and approval resumes
        processingLoop: while true {
            do {
                if let paused = currentPaused {
                    // Resuming after approval - use streaming to get UI updates
                    log(.info, "Resuming after approval", details: paused.pendingCalls.map { $0.toolCall.name }.joined(separator: ", "))
                    let resolutions = paused.pendingCalls.map { ResolvedTool(id: $0.deferral.id, resolution: .approved) }

                    for try await event in agent.resumeStream(paused: paused, resolutions: resolutions, deps: deps) {
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
                            log(.info, "Resume completed", details: "Output length: \(r.output.count)")
                            messageHistory = r.messages
                            updateTotalUsage(with: r.usage)
                            currentTurnUsage = nil
                            if messages.last?.content.isEmpty == true {
                                messages[messages.count - 1].appendText(r.output)
                            }
                        }
                    }
                    break processingLoop  // Success - exit loop
                } else {
                    // Initial streaming run
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
                            messageHistory = r.messages
                            updateTotalUsage(with: r.usage)
                            currentTurnUsage = nil
                            if messages.last?.content.isEmpty == true {
                                messages[messages.count - 1].appendText(r.output)
                            }
                        }
                    }
                    break processingLoop  // Success - exit loop
                }
            } catch let e as AgentError<String> {
                log(.error, "AgentError", details: String(describing: e))
                if let streamingUsage = currentTurnUsage {
                    updateTotalUsage(with: streamingUsage)
                }
                currentTurnUsage = nil

                switch e {
                case .hasDeferredTools(let paused):
                    // Tool needs approval - show UI and wait for user decision
                    if !paused.pendingCalls.isEmpty {
                        let tools = paused.pendingCalls.map { pending in
                            PendingToolInfo(
                                id: pending.deferral.id,
                                toolName: pending.toolCall.name,
                                arguments: pending.toolCall.arguments
                            )
                        }
                        pendingApproval = PendingApprovalInfo(
                            id: paused.pendingCalls.first!.deferral.id,
                            tools: tools,
                            reason: paused.pendingCalls.first!.deferral.reason
                        )

                        // Update tool status to needsApproval in the UI
                        for pending in paused.pendingCalls {
                            messages[messages.count - 1].updateToolCall(id: pending.toolCall.id) { info in
                                info.status = .needsApproval
                            }
                        }

                        let toolNames = tools.map { $0.toolName }.joined(separator: ", ")
                        log(.info, "Waiting for approval", details: "Tools: \(toolNames)")
                    }

                    // Pause processing while waiting for user
                    isProcessing = false

                    // Wait for user decision via continuation
                    // Returns nil for approval, or rejection reason string
                    let rejectionReason = await withCheckedContinuation { continuation in
                        self.approvalContinuation = continuation
                    }

                    if rejectionReason == nil {
                        // User approved - update status and resume
                        log(.info, "User approved tool call")
                        for pending in paused.pendingCalls {
                            messages[messages.count - 1].updateToolCall(id: pending.toolCall.id) { info in
                                info.status = .running
                            }
                        }
                        currentPaused = paused
                        pendingApproval = nil
                        isProcessing = true
                        continue processingLoop
                    } else {
                        // User rejected - mark as failed and send rejection to LLM
                        let reason = rejectionReason!
                        log(.info, "User rejected tool call", details: reason)
                        for pending in paused.pendingCalls {
                            messages[messages.count - 1].updateToolCall(id: pending.toolCall.id) { info in
                                info.status = .failed
                                info.result = "Rejected: \(reason)"
                            }
                        }
                        pendingApproval = nil
                        isProcessing = true

                        // Send rejection to LLM via resumeStream so it can adjust
                        let resolutions = paused.pendingCalls.map {
                            ResolvedTool(id: $0.deferral.id, resolution: .denied(reason: reason))
                        }
                        do {
                            for try await event in agent.resumeStream(paused: paused, resolutions: resolutions, deps: deps) {
                                switch event {
                                case .contentDelta(let t):
                                    messages[messages.count - 1].appendText(t)
                                case .toolCallStart(let name, let id):
                                    log(.info, "Tool call start", details: "[\(id)] \(name)")
                                    messages[messages.count - 1].appendToolCall(ToolCallInfo(id: id, name: name, status: .running))
                                case .toolResult(let id, let result):
                                    log(.info, "Tool result", details: "[\(id)] \(result.prefix(200))")
                                    messages[messages.count - 1].updateToolCall(id: id) { info in
                                        info.result = result
                                        info.status = .completed
                                    }
                                case .result(let r):
                                    log(.info, "Resume after rejection completed", details: "Output: \(r.output.prefix(100))")
                                    messageHistory = r.messages
                                    updateTotalUsage(with: r.usage)
                                    if messages.last?.content.isEmpty == true {
                                        messages[messages.count - 1].appendText(r.output)
                                    }
                                default:
                                    break
                                }
                            }
                            break processingLoop  // Success - exit loop
                        } catch let rejectionError as AgentError<String> {
                            // If model calls another tool that needs approval, set up for next iteration
                            if case .hasDeferredTools(let newPaused) = rejectionError {
                                log(.info, "Model called another tool after rejection", details: newPaused.pendingCalls.map { $0.toolCall.name }.joined(separator: ", "))
                                // Set up the new pending approval and continue loop
                                let newTools = newPaused.pendingCalls.map { pending in
                                    PendingToolInfo(
                                        id: pending.deferral.id,
                                        toolName: pending.toolCall.name,
                                        arguments: pending.toolCall.arguments
                                    )
                                }
                                pendingApproval = PendingApprovalInfo(
                                    id: newPaused.pendingCalls.first!.deferral.id,
                                    tools: newTools,
                                    reason: newPaused.pendingCalls.first!.deferral.reason
                                )
                                for pending in newPaused.pendingCalls {
                                    messages[messages.count - 1].updateToolCall(id: pending.toolCall.id) { info in
                                        info.status = .needsApproval
                                    }
                                }
                                isProcessing = false
                                // Continue the loop - will wait for approval at the top
                                currentPaused = nil  // Clear so we use the new paused state via pendingApproval flow
                                // Need to actually wait for approval here too
                                let newRejectionReason = await withCheckedContinuation { continuation in
                                    self.approvalContinuation = continuation
                                }
                                if newRejectionReason == nil {
                                    // Approved - set up for resume
                                    for pending in newPaused.pendingCalls {
                                        messages[messages.count - 1].updateToolCall(id: pending.toolCall.id) { info in
                                            info.status = .running
                                        }
                                    }
                                    currentPaused = newPaused
                                    pendingApproval = nil
                                    isProcessing = true
                                    continue processingLoop
                                } else {
                                    // Rejected again - recurse (will be handled in next iteration)
                                    for pending in newPaused.pendingCalls {
                                        messages[messages.count - 1].updateToolCall(id: pending.toolCall.id) { info in
                                            info.status = .failed
                                            info.result = "Rejected: \(newRejectionReason!)"
                                        }
                                    }
                                    pendingApproval = nil
                                    isProcessing = true
                                    // Need to send this rejection too - but this gets complex
                                    // For now, just break and let user retry
                                    break processingLoop
                                }
                            } else {
                                log(.error, "Error resuming after rejection", details: rejectionError.localizedDescription)
                                error = rejectionError
                                break processingLoop
                            }
                        } catch {
                            log(.error, "Error resuming after rejection", details: error.localizedDescription)
                            break processingLoop
                        }
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
                    break processingLoop

                default:
                    error = e
                    messages.append(.error(e.localizedDescription))
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
        } catch let e as AgentError<String> {
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
