/// Built-in tools configuration section for settings.

import SwiftUI
import Yrden

struct BuiltInToolsSection: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        GroupBox("Built-in Tools") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable built-in tools", isOn: $store.builtInToolsEnabled)

                if store.builtInToolsEnabled {
                    toolsList
                    workingDirectoryField
                    shellApprovalToggle
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var toolsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Available tools:")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Label("shell", systemImage: "terminal")
                Label("read_file", systemImage: "doc")
                Label("write_file", systemImage: "doc.badge.plus")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private var workingDirectoryField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Working Directory")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("~/Desktop", text: $store.builtInToolsWorkingDirectory)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var shellApprovalToggle: some View {
        Toggle("Require approval for shell commands", isOn: $store.builtInToolsShellApproval)
            .help("When enabled, shell commands require your approval before execution")
    }
}
