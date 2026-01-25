import SwiftUI
import Yrden
import MCP

struct ContentView: View {
    @ObservedObject var viewModel: OAuthViewModel

    var body: some View {
        NavigationSplitView {
            // Sidebar - Configuration & Tools
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 400)
        } detail: {
            // Detail - Results & Logs
            detailView
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    // MARK: - Sidebar

    var sidebar: some View {
        List {
            // Connection Section
            Section("Connection") {
                // Mode picker
                Picker("Mode", selection: $viewModel.connectionMode) {
                    ForEach(ConnectionMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                // Quick presets
                Menu("Apply Preset") {
                    ForEach(viewModel.presets) { preset in
                        Button(preset.name) {
                            viewModel.applyPreset(preset)
                        }
                    }
                }

                // Mode-specific config
                modeConfig

                // Action buttons
                HStack {
                    Button(action: {
                        Task { await connect() }
                    }) {
                        if viewModel.isLoading {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        } else {
                            Text("Connect")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isLoading || !canConnect)

                    Button("Disconnect") {
                        Task { await viewModel.disconnect() }
                    }
                    .disabled(!isConnected && !viewModel.isLoading)
                }
            }

            // Status
            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            // Tools Section
            Section("Tools (\(viewModel.tools.count))") {
                if viewModel.tools.isEmpty {
                    Text("Connect to see tools")
                        .foregroundColor(.secondary)
                        .font(.caption)
                } else {
                    ForEach(viewModel.tools) { tool in
                        Button(action: { viewModel.selectTool(tool) }) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(tool.name)
                                        .font(.system(.body, design: .monospaced))
                                    if viewModel.selectedTool?.id == tool.id {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                if let desc = tool.description {
                                    Text(desc)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Mode-specific Configuration

    @ViewBuilder
    var modeConfig: some View {
        switch viewModel.connectionMode {
        case .httpAutoDiscovery:
            TextField("MCP Server URL", text: $viewModel.mcpServerURL)
                .textFieldStyle(.roundedBorder)
            TextField("Redirect Scheme", text: $viewModel.redirectScheme)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

        case .httpManual:
            TextField("Client ID", text: $viewModel.clientId)
                .textFieldStyle(.roundedBorder)
            SecureField("Client Secret", text: $viewModel.clientSecret)
                .textFieldStyle(.roundedBorder)
            TextField("Auth URL", text: $viewModel.authURL)
                .textFieldStyle(.roundedBorder)
            TextField("Token URL", text: $viewModel.tokenURL)
                .textFieldStyle(.roundedBorder)
            TextField("MCP Server URL", text: $viewModel.mcpServerURL)
                .textFieldStyle(.roundedBorder)
            TextField("Scopes", text: $viewModel.scopes)
                .textFieldStyle(.roundedBorder)

        case .stdio:
            TextField("Command (e.g., uvx, npx)", text: $viewModel.stdioCommand)
                .textFieldStyle(.roundedBorder)
            TextField("Arguments", text: $viewModel.stdioArguments)
                .textFieldStyle(.roundedBorder)
            if !viewModel.stdioEnvironment.isEmpty {
                Text("Env: \(viewModel.stdioEnvironment.prefix(30))...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Detail View

    var detailView: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(viewModel.status)
                    .font(.headline)
                Spacer()
                if let tokens = viewModel.tokens {
                    Label("Authenticated", systemImage: "checkmark.shield.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("(\(tokens.isExpired ? "expired" : "valid"))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Main content
            if let tool = viewModel.selectedTool {
                // Tool invocation view
                toolInvocationView(tool: tool)
            } else {
                // Logs view
                logsView
            }
        }
    }

    // MARK: - Tool Invocation

    func toolInvocationView(tool: ToolInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text(tool.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                    if let desc = tool.description {
                        Text(desc)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button("Clear") {
                    viewModel.selectedTool = nil
                    viewModel.toolResult = nil
                }
                .buttonStyle(.borderless)
            }

            Divider()

            // Parameters
            let params = extractParameters(from: tool.inputSchema)
            if params.isEmpty {
                Text("No parameters required")
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(params, id: \.name) { param in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Text(param.name)
                                        .fontWeight(.medium)
                                    if param.required {
                                        Text("*").foregroundColor(.red)
                                    }
                                    Text("(\(param.type))")
                                        .foregroundColor(.secondary)
                                }
                                .font(.caption)

                                if let desc = param.description {
                                    Text(desc)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                TextField(placeholderFor(param.type), text: Binding(
                                    get: { viewModel.toolParameters[param.name] ?? "" },
                                    set: { viewModel.toolParameters[param.name] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            // Execute button
            Button(action: {
                Task { await viewModel.executeTool() }
            }) {
                HStack {
                    if viewModel.isExecutingTool {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    }
                    Text("Execute Tool")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isExecutingTool)
            .controlSize(.large)

            // Result
            if let result = viewModel.toolResult {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Result")
                        .font(.headline)
                    ScrollView {
                        Text(result)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Logs View

    var logsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Logs")
                    .font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.logs.joined(separator: "\n"), forType: .string)
                }
                .buttonStyle(.borderless)
                Button("Clear") {
                    viewModel.clearLogs()
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.top)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(viewModel.logs.enumerated()), id: \.offset) { index, log in
                            Text(log)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: viewModel.logs.count) { _, _ in
                    if let lastIndex = viewModel.logs.indices.last {
                        withAnimation {
                            proxy.scrollTo(lastIndex, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Helpers

    var canConnect: Bool {
        switch viewModel.connectionMode {
        case .httpAutoDiscovery:
            return !viewModel.mcpServerURL.isEmpty
        case .httpManual:
            return !viewModel.authURL.isEmpty && !viewModel.tokenURL.isEmpty
        case .stdio:
            return !viewModel.stdioCommand.isEmpty
        }
    }

    var isConnected: Bool {
        !viewModel.tools.isEmpty || viewModel.tokens != nil
    }

    var statusColor: Color {
        switch viewModel.status {
        case "Ready", "Disconnected":
            return .gray
        case let s where s.contains("successful") || s.contains("Connected"):
            return .green
        case let s where s.contains("failed") || s.contains("Error"):
            return .red
        default:
            return .orange
        }
    }

    func connect() async {
        switch viewModel.connectionMode {
        case .httpAutoDiscovery:
            await viewModel.connectWithAutoDiscovery()
        case .httpManual:
            await viewModel.startOAuthFlow()
        case .stdio:
            await viewModel.connectWithStdio()
        }
    }

    func placeholderFor(_ type: String) -> String {
        switch type {
        case "integer", "number": return "0"
        case "boolean": return "true / false"
        case "array": return "[\"item1\", \"item2\"]"
        case "object": return "{\"key\": \"value\"}"
        default: return "value"
        }
    }
}

// MARK: - Parameter Extraction (uses library utility)

// Type alias for backwards compatibility with existing UI code
typealias ParameterInfo = MCPParameterInfo

extension MCPParameterInfo {
    // Backwards compatibility property
    var required: Bool { isRequired }
}

func extractParameters(from schema: Value) -> [MCPParameterInfo] {
    extractMCPParameters(from: schema)
}

// MARK: - Value Extension

extension Value {
    func prettyPrinted() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

#Preview {
    ContentView(viewModel: OAuthViewModel())
}
