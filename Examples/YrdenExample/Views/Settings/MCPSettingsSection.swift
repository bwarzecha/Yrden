/// MCP server configuration section with multi-server support.

import SwiftUI
import Yrden

struct MCPSettingsSection: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var viewModel: ChatViewModel

    @State private var showingAddServer = false
    @State private var editingServer: MCPServerConfig?
    @State private var connectingServerId: UUID?
    @State private var connectionError: String?
    @State private var connectionStatus: String = ""

    var body: some View {
        GroupBox("MCP Servers") {
            VStack(alignment: .leading, spacing: 12) {
                serverList
                addButton
                presetsSection
                if let error = connectionError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showingAddServer) {
            MCPServerEditor(
                store: store,
                server: nil,
                onSave: { config in
                    store.addMCPServer(config)
                    showingAddServer = false
                },
                onCancel: { showingAddServer = false }
            )
        }
        .sheet(item: $editingServer) { server in
            MCPServerEditor(
                store: store,
                server: server,
                onSave: { config in
                    store.updateMCPServer(config)
                    editingServer = nil
                },
                onCancel: { editingServer = nil }
            )
        }
    }

    @ViewBuilder
    private var serverList: some View {
        if store.savedMCPServers.isEmpty {
            Text("No MCP servers configured")
                .foregroundColor(.secondary)
                .font(.caption)
        } else {
            ForEach(store.savedMCPServers) { server in
                serverRow(server)
            }
        }
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .fontWeight(.medium)
                Text(serverDescription(server))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if store.isServerConnected(id: server.id) {
                if let connected = store.connectedServers.first(where: { $0.id == server.id }) {
                    Label("\(connected.tools.count) tools", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
                Button("Disconnect") {
                    Task { await disconnect(server) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if connectingServerId == server.id {
                ProgressView()
                    .scaleEffect(0.7)
                if !connectionStatus.isEmpty {
                    Text(connectionStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Button("Connect") {
                    Task { await connect(server) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Menu {
                Button("Edit") { editingServer = server }
                Button("Delete", role: .destructive) {
                    store.deleteMCPServer(id: server.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.vertical, 4)
    }

    private func serverDescription(_ server: MCPServerConfig) -> String {
        switch server.mode {
        case .stdio:
            let cmd = server.command ?? ""
            let args = server.arguments ?? ""
            return "\(cmd) \(args)".trimmingCharacters(in: .whitespaces)
        case .oauth:
            return server.serverURL ?? "OAuth"
        }
    }

    private var addButton: some View {
        Button(action: { showingAddServer = true }) {
            Label("Add Server", systemImage: "plus")
        }
        .buttonStyle(.bordered)
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Add Presets:")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Button("Fetch") {
                    addPreset(.stdioPreset(name: "Fetch", command: "uvx", arguments: "mcp-server-fetch"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Filesystem") {
                    addPreset(.stdioPreset(name: "Filesystem", command: "npx", arguments: "-y @modelcontextprotocol/server-filesystem /tmp"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Todoist") {
                    addPreset(.oauthPreset(name: "Todoist", serverURL: "https://mcp.todoist.com/mcp"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func addPreset(_ config: MCPServerConfig) {
        // Check if a server with the same name already exists
        if !store.savedMCPServers.contains(where: { $0.name == config.name }) {
            store.addMCPServer(config)
        }
    }

    private func connect(_ server: MCPServerConfig) async {
        connectingServerId = server.id
        connectionError = nil
        connectionStatus = ""

        do {
            let toolNames: [String]
            let agentTools: [AnyAgentTool<AppDependencies>]
            let connection: MCPServerConnection

            switch server.mode {
            case .stdio:
                let commandLine = [server.command, server.arguments]
                    .compactMap { $0 }
                    .joined(separator: " ")
                (connection, agentTools, toolNames) = try await viewModel.connectMCPStdioRaw(commandLine: commandLine)

            case .oauth:
                guard let urlString = server.serverURL, let url = URL(string: urlString) else {
                    throw NSError(domain: "MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
                }
                (connection, agentTools, toolNames) = try await viewModel.connectMCPOAuthRaw(
                    url: url,
                    redirectScheme: server.redirectScheme ?? "yrden-example"
                ) { progress in
                    Task { @MainActor in
                        connectionStatus = progress.description
                    }
                }
            }

            // Register tools with viewModel (pass the already-discovered tools)
            viewModel.registerMCPTools(serverId: server.id, tools: agentTools)

            let connectedServer = ConnectedMCPServer(config: server, connection: connection, tools: toolNames)
            store.addConnectedServer(connectedServer)
            connectingServerId = nil
            connectionStatus = ""
        } catch {
            connectionError = error.localizedDescription
            connectingServerId = nil
            connectionStatus = ""
        }
    }

    private func disconnect(_ server: MCPServerConfig) async {
        viewModel.unregisterMCPTools(serverId: server.id)
        await store.removeConnectedServer(id: server.id)
    }
}

// MARK: - MCP Server Editor

struct MCPServerEditor: View {
    let store: SettingsStore
    let server: MCPServerConfig?
    let onSave: (MCPServerConfig) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var mode: MCPConnectionMode = .stdio
    @State private var command: String = ""
    @State private var arguments: String = ""
    @State private var serverURL: String = ""
    @State private var redirectScheme: String = "yrden-example"

    var body: some View {
        VStack(spacing: 16) {
            Text(server == nil ? "Add MCP Server" : "Edit MCP Server")
                .font(.headline)

            Form {
                TextField("Name", text: $name)

                Picker("Mode", selection: $mode) {
                    Text("Stdio (Local)").tag(MCPConnectionMode.stdio)
                    Text("HTTP + OAuth").tag(MCPConnectionMode.oauth)
                }
                .pickerStyle(.segmented)

                if mode == .stdio {
                    TextField("Command (e.g., uvx, npx)", text: $command)
                    TextField("Arguments", text: $arguments)
                } else {
                    TextField("Server URL", text: $serverURL)
                    TextField("Redirect Scheme", text: $redirectScheme)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    let config = MCPServerConfig(
                        id: server?.id ?? UUID(),
                        name: name,
                        mode: mode,
                        command: mode == .stdio ? command : nil,
                        arguments: mode == .stdio ? arguments : nil,
                        serverURL: mode == .oauth ? serverURL : nil,
                        redirectScheme: mode == .oauth ? redirectScheme : nil
                    )
                    onSave(config)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || !isValid)
            }
        }
        .padding()
        .frame(width: 400, height: 300)
        .onAppear {
            if let server {
                name = server.name
                mode = server.mode
                command = server.command ?? ""
                arguments = server.arguments ?? ""
                serverURL = server.serverURL ?? ""
                redirectScheme = server.redirectScheme ?? "yrden-example"
            }
        }
    }

    private var isValid: Bool {
        switch mode {
        case .stdio:
            return !command.isEmpty
        case .oauth:
            return !serverURL.isEmpty && URL(string: serverURL) != nil
        }
    }
}

// MARK: - OAuth Progress Extension

extension MCPOAuthProgress {
    var description: String {
        switch self {
        case .openingBrowser: return "Opening browser..."
        case .waitingForUser: return "Waiting for authorization..."
        case .exchangingCode: return "Exchanging code..."
        case .refreshingTokens: return "Refreshing tokens..."
        case .complete: return "Complete"
        case .failed(let error): return "Failed: \(error)"
        }
    }
}
