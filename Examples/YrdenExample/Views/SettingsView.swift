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
                    if store.isConfigured {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    Text(store.isConfigured ? "Configured" : "Apply Configuration")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!store.canConfigure)

            if !store.connectedServers.isEmpty {
                Text("\(store.connectedServers.count) MCP server(s) connected with \(totalToolCount) tools")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var totalToolCount: Int {
        store.connectedServers.reduce(0) { $0 + $1.tools.count }
    }

    // MARK: - Actions

    private func configure() {
        let mcpTools = viewModel.getAllMCPTools()
        do {
            let model = try store.createModel()
            viewModel.configure(model: model, mcpTools: mcpTools)
            store.isConfigured = true
        } catch {
            store.modelError = error.localizedDescription
        }
    }
}

#Preview {
    SettingsView(store: SettingsStore(), viewModel: ChatViewModel())
}
