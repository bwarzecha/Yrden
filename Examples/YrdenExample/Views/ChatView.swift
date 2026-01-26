/// Main chat interface.

import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var settingsStore: SettingsStore
    @State private var inputText = ""
    @State private var showSettings = false
    @State private var showLogs = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Error banner at top
            if let error = viewModel.error {
                ErrorBanner(error: error, onDismiss: { viewModel.clearError() })
            }

            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let lastMessage = viewModel.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Approval banner
            if let approval = viewModel.pendingApproval {
                ApprovalBanner(
                    approval: approval,
                    onApprove: { Task { await viewModel.approveToolCall() } },
                    onReject: { viewModel.rejectToolCall() }
                )
            }

            // Input area
            inputArea
        }
        .navigationTitle("Yrden Example")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { showLogs = true }) {
                    Image(systemName: "doc.text")
                }
                .badge(viewModel.logs.filter { $0.level == .error }.count)
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { viewModel.clearConversation() }) {
                    Image(systemName: "trash")
                }
                .disabled(viewModel.messages.isEmpty)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: settingsStore, viewModel: viewModel)
        }
        .sheet(isPresented: $showLogs) {
            LogsView(viewModel: viewModel)
        }
    }

    private var inputArea: some View {
        HStack(spacing: 12) {
            TextField("Type a message...", text: $inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .onSubmit { sendMessage() }
                .disabled(viewModel.isProcessing)
                .task {
                    try? await Task.sleep(for: .milliseconds(100))
                    isInputFocused = true
                }

            Button(action: sendMessage) {
                if viewModel.isProcessing {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
            }
            .buttonStyle(.borderless)
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isProcessing)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        Task { await viewModel.send(text) }
    }
}

// MARK: - Error Banner

struct ErrorBanner: View {
    let error: Error
    let onDismiss: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundColor(.red)
                Text("Error")
                    .font(.headline)
                Spacer()
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(error.localizedDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(isExpanded ? nil : 2)

            if isExpanded {
                // Show full error details
                Text(String(describing: error))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.black.opacity(0.05))
                    .cornerRadius(4)
            }
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Approval Banner

struct ApprovalBanner: View {
    let approval: PendingApprovalInfo
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Tool requires approval")
                    .font(.headline)
                Spacer()
            }

            Text("\(approval.toolName): \(approval.reason)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack {
                Button("Reject", role: .destructive, action: onReject)
                    .buttonStyle(.bordered)
                Button("Approve", action: onApprove)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Logs View

struct LogsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var copiedToClipboard = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text("Logs (\(viewModel.logs.count))")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    viewModel.clearLogs()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.logs.isEmpty)
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.exportLogs(), forType: .string)
                    copiedToClipboard = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedToClipboard = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.logs.isEmpty)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            if copiedToClipboard {
                Text("Copied to clipboard!")
                    .font(.caption)
                    .foregroundColor(.green)
                    .padding(.bottom, 4)
            }

            Divider()

            // Log list
            if viewModel.logs.isEmpty {
                Spacer()
                Text("No logs yet")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.logs) { entry in
                            LogEntryRow(entry: entry)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 700, height: 500)
    }
}

struct LogEntryRow: View {
    let entry: LogEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 8) {
                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)

                Text(entry.level.rawValue.uppercased())
                    .font(.caption.bold())
                    .foregroundColor(colorForLevel(entry.level))
                    .frame(width: 50, alignment: .leading)

                Text(entry.message)
                    .font(.caption)

                Spacer()

                if entry.details != nil {
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isExpanded, let details = entry.details {
                Text(details)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(6)
                    .background(Color.black.opacity(0.05))
                    .cornerRadius(4)
                    .padding(.leading, 90)
            }
        }
        .padding(.vertical, 2)
    }

    func colorForLevel(_ level: LogEntry.Level) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

#Preview {
    NavigationStack {
        ChatView(viewModel: ChatViewModel(), settingsStore: SettingsStore())
    }
    .frame(width: 600, height: 500)
}
