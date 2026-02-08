/// Settings sheet composing provider, model, and MCP sections.

import SwiftUI
import Yrden

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 20) {
                    ProviderSettingsSection(store: store)
                    ModelSettingsSection(store: store)
                    BuiltInToolsSection(store: store, viewModel: viewModel)
                    MCPSettingsSection(store: store, viewModel: viewModel)
                    applySection
                }
                .padding()
            }
        }
        .frame(width: 520, height: 700)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Apply Section

    private var applySection: some View {
        VStack(spacing: 12) {
            Button(action: configure) {
                HStack {
                    if isApplying {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else if store.isConfigured {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    Text(isApplying ? "Applying..." : store.isConfigured ? "Configured" : "Apply Configuration")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!store.canConfigure || isApplying)

            toolsSummary
        }
    }

    @ViewBuilder
    private var toolsSummary: some View {
        let mcpCount = store.connectedServers.reduce(0) { $0 + $1.tools.count }
        let builtInCount = store.builtInToolsEnabled ? 3 : 0
        let total = mcpCount + builtInCount

        if total > 0 {
            Text(toolsSummaryText(builtIn: builtInCount, mcp: mcpCount))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func toolsSummaryText(builtIn: Int, mcp: Int) -> String {
        var parts: [String] = []
        if builtIn > 0 { parts.append("\(builtIn) built-in") }
        if mcp > 0 { parts.append("\(mcp) MCP") }
        return "\(builtIn + mcp) tools (\(parts.joined(separator: ", ")))"
    }

    // MARK: - Actions

    @State private var isApplying = false

    private func configure() {
        isApplying = true
        Task {
            // Set up built-in tools if enabled
            if store.builtInToolsEnabled {
                await viewModel.configureBuiltInTools(
                    workingDirectory: store.builtInToolsWorkingDirectory,
                    shellApprovalRequired: store.builtInToolsShellApproval
                )
            } else {
                viewModel.disableBuiltInTools()
            }

            let mcpTools = viewModel.getAllMCPTools()
            do {
                let model = try store.createModel()
                viewModel.configure(model: model, mcpTools: mcpTools)
                store.isConfigured = true
            } catch {
                store.modelError = error.localizedDescription
            }
            isApplying = false
        }
    }
}

#Preview {
    SettingsView(store: SettingsStore(), viewModel: ChatViewModel())
}
