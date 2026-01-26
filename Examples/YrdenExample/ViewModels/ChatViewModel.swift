/// Chat view model - binds to Agent with minimal logic.
import Foundation
import Yrden

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isProcessing = false
    @Published var pendingApproval: PendingApprovalInfo?
    @Published var error: Error?
    @Published var logs: [LogEntry] = []

    private let deps: AppDependencies
    private var agent: Agent<AppDependencies, String>?
    private var pausedRun: PausedAgentRun?
    private var messageHistory: [Message] = []  // Conversation history for multi-turn

    // MCP - supports multiple servers
    private var mcpToolsCache: [UUID: [AnyAgentTool<AppDependencies>]] = [:]

    init(deps: AppDependencies = .default()) { self.deps = deps }

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
        log(.info, "Configured agent", details: "Model: \(model.name), Tools: \(mcpTools.map { $0.name }.joined(separator: ", "))")
    }

    // MARK: - MCP (Multi-Server Support)

    /// Connect to an MCP server via stdio and return the connection + tool names.
    /// The connection is NOT stored - caller is responsible for tracking it.
    func connectMCPStdioRaw(commandLine: String) async throws -> (MCPServerConnection, [String]) {
        log(.info, "Connecting MCP stdio", details: commandLine)
        do {
            let server = try await mcpConnect(commandLine)
            let tools: [AnyAgentTool<AppDependencies>] = try await server.discoverTools()
            log(.info, "MCP connected", details: "Tools: \(tools.map { $0.name }.joined(separator: ", "))")
            return (server, tools.map { $0.name })
        } catch {
            log(.error, "MCP connection failed", details: String(describing: error))
            throw error
        }
    }

    /// Connect to an MCP server via OAuth and return the connection + tool names.
    /// The connection is NOT stored - caller is responsible for tracking it.
    func connectMCPOAuthRaw(
        url: URL,
        redirectScheme: String,
        onProgress: @escaping @Sendable (MCPOAuthProgress) -> Void
    ) async throws -> (MCPServerConnection, [String]) {
        log(.info, "Connecting MCP OAuth", details: url.absoluteString)
        do {
            let server = try await mcpConnect(
                url: url,
                redirectScheme: redirectScheme,
                onProgress: onProgress
            )
            let tools: [AnyAgentTool<AppDependencies>] = try await server.discoverTools()
            log(.info, "MCP OAuth connected", details: "Tools: \(tools.map { $0.name }.joined(separator: ", "))")
            return (server, tools.map { $0.name })
        } catch {
            log(.error, "MCP OAuth failed", details: String(describing: error))
            throw error
        }
    }

    /// Register tools from a connected server (by server ID).
    func registerMCPTools(serverId: UUID, connection: MCPServerConnection) async throws {
        let tools: [AnyAgentTool<AppDependencies>] = try await connection.discoverTools()
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
                    log(.debug, "Usage update", details: "Input: \(usage.inputTokens), Output: \(usage.outputTokens)")
                case .result(let r):
                    log(.info, "Agent result", details: "Output: \(r.output.prefix(200))..., Usage: \(r.usage)")
                    messageHistory = r.messages  // Save for multi-turn
                    if messages.last?.content.isEmpty == true {
                        messages[messages.count - 1].appendText(r.output)
                    }
                }
            }
        } catch let e as AgentError {
            log(.error, "AgentError", details: String(describing: e))
            if case .hasDeferredTools(let paused) = e {
                pausedRun = paused
                if let p = paused.pendingCalls.first {
                    pendingApproval = PendingApprovalInfo(id: p.deferral.id, toolName: p.toolCall.name,
                                                          arguments: p.toolCall.arguments, reason: p.deferral.reason)
                }
            } else { error = e; messages.append(.error(e.localizedDescription)) }
        } catch {
            log(.error, "Error", details: String(describing: error))
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

    func clearConversation() {
        messages.removeAll()
        messageHistory.removeAll()  // Clear agent history too
        error = nil
        pausedRun = nil
        pendingApproval = nil
    }

    func clearError() {
        error = nil
    }
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
