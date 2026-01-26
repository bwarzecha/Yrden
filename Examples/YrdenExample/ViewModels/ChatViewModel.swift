/// Chat view model - binds to Agent with minimal logic.
import Foundation
import Yrden

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isProcessing = false
    @Published var pendingApproval: PendingApprovalInfo?
    @Published var error: Error?

    private let deps: AppDependencies
    private var agent: Agent<AppDependencies, String>?
    private var pausedRun: PausedAgentRun?

    init(deps: AppDependencies = .default()) { self.deps = deps }

    func configure(model: any Model) {
        agent = Agent(
            model: model,
            systemPrompt: "You are a helpful assistant. Use tools when appropriate.",
            tools: [AnyAgentTool(CalculatorTool()), AnyAgentTool(WebSearchTool()), AnyAgentTool(FileWriteTool())],
            maxIterations: 10
        )
    }

    func send(_ text: String) async {
        guard let agent, !text.isEmpty else { return }
        isProcessing = true
        error = nil
        messages.append(.user(text))
        messages.append(.assistant("", isStreaming: true))

        do {
            for try await event in agent.runStream(text, deps: deps) {
                switch event {
                case .contentDelta(let t): messages[messages.count - 1].content += t
                case .toolCallStart(let name, let id):
                    messages[messages.count - 1].toolCalls.append(ToolCallInfo(id: id, name: name, status: .running))
                case .toolResult(let id, let result):
                    if let i = messages[messages.count - 1].toolCalls.firstIndex(where: { $0.id == id }) {
                        messages[messages.count - 1].toolCalls[i].result = result
                        messages[messages.count - 1].toolCalls[i].status = .completed
                    }
                case .result(let r):
                    if messages.last?.content.isEmpty == true { messages[messages.count - 1].content = r.output }
                default: break
                }
            }
        } catch let e as AgentError {
            if case .hasDeferredTools(let paused) = e {
                pausedRun = paused
                if let p = paused.pendingCalls.first {
                    pendingApproval = PendingApprovalInfo(id: p.deferral.id, toolName: p.toolCall.name,
                                                          arguments: p.toolCall.arguments, reason: p.deferral.reason)
                }
            } else { error = e; messages.append(.error(e.localizedDescription)) }
        } catch { self.error = error; messages.append(.error(error.localizedDescription)) }

        isProcessing = false
        messages[messages.count - 1].isStreaming = false
    }

    func approveToolCall() async {
        guard let paused = pausedRun, let agent else { return }
        let resolutions = paused.pendingCalls.map { ResolvedTool(id: $0.deferral.id, resolution: .approved) }
        pendingApproval = nil
        isProcessing = true
        do {
            let result = try await agent.resume(paused: paused, resolutions: resolutions, deps: deps)
            if messages.last?.content.isEmpty == true { messages[messages.count - 1].content = result.output }
        } catch { self.error = error; messages.append(.error(error.localizedDescription)) }
        pausedRun = nil
        isProcessing = false
    }

    func rejectToolCall() {
        pausedRun = nil
        pendingApproval = nil
        messages[messages.count - 1].content += "\n\n[Tool call rejected by user]"
        messages[messages.count - 1].isStreaming = false
    }

    func clearConversation() {
        messages.removeAll()
        error = nil
        pausedRun = nil
        pendingApproval = nil
    }
}
