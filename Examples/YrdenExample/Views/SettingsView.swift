/// Settings sheet for provider, model, and MCP configuration.

import SwiftUI
import Yrden

struct SettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    // Provider settings
    @State private var selectedProvider = ProviderType.anthropic
    @State private var apiKey = ""
    @State private var awsRegion = "us-east-1"
    @State private var awsProfile = "default"
    @State private var awsAccessKey = ""
    @State private var awsSecretKey = ""
    @State private var useAwsProfile = true

    // Model selection
    @State private var availableModels: [ModelInfo] = []
    @State private var selectedModelId = ""
    @State private var isLoadingModels = false
    @State private var modelError: String?
    @State private var modelSearchText = ""

    // MCP settings
    @State private var mcpMode = MCPConnectionMode.stdio
    @State private var mcpCommand = ""
    @State private var mcpArguments = ""
    @State private var mcpServerURL = ""
    @State private var mcpRedirectScheme = "yrden-example"
    @State private var mcpConnected = false
    @State private var mcpTools: [String] = []
    @State private var isConnectingMCP = false
    @State private var mcpError: String?
    @State private var mcpStatus = ""

    // Status
    @State private var isConfigured = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 20) {
                    providerSection
                    modelSection
                    mcpSection
                    applySection
                }
                .padding()
            }
        }
        .frame(width: 520, height: 650)
        .onAppear { loadFromEnvironment() }
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

    // MARK: - Provider Section

    private var providerSection: some View {
        GroupBox("Provider") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(ProviderType.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedProvider) { _, _ in
                    availableModels = []
                    selectedModelId = ""
                    modelSearchText = ""
                    isConfigured = false
                }

                switch selectedProvider {
                case .anthropic, .openai:
                    apiKeyField
                case .bedrock:
                    bedrockFields
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API Key")
                .font(.caption)
                .foregroundColor(.secondary)
            SecureField("Enter API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var bedrockFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Authentication", selection: $useAwsProfile) {
                Text("AWS Profile").tag(true)
                Text("Access Keys").tag(false)
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Region")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)
                TextField("us-east-1", text: $awsRegion)
                    .textFieldStyle(.roundedBorder)
            }

            if useAwsProfile {
                HStack {
                    Text("Profile")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .leading)
                    TextField("default", text: $awsProfile)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                HStack {
                    Text("Access Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .leading)
                    TextField("AKIA...", text: $awsAccessKey)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Secret Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .leading)
                    SecureField("Secret", text: $awsSecretKey)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    // MARK: - Model Section

    private var filteredModels: [ModelInfo] {
        if modelSearchText.isEmpty {
            return availableModels
        }
        return availableModels.filter {
            $0.displayName.localizedCaseInsensitiveContains(modelSearchText) ||
            $0.id.localizedCaseInsensitiveContains(modelSearchText)
        }
    }

    private var modelSection: some View {
        GroupBox("Model") {
            VStack(alignment: .leading, spacing: 12) {
                if availableModels.isEmpty {
                    HStack {
                        Text("Load models to select")
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: loadModels) {
                            if isLoadingModels {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Text("Load Models")
                            }
                        }
                        .disabled(isLoadingModels || !canLoadModels)
                    }
                } else {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Filter models...", text: $modelSearchText)
                            .textFieldStyle(.plain)
                        if !modelSearchText.isEmpty {
                            Button(action: { modelSearchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Button(action: loadModels) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isLoadingModels)
                    }

                    Picker("Model", selection: $selectedModelId) {
                        Text("Select a model").tag("")
                        ForEach(filteredModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()

                    if !modelSearchText.isEmpty {
                        Text("\(filteredModels.count) of \(availableModels.count) models")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let error = modelError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - MCP Section

    private var mcpSection: some View {
        GroupBox("MCP Server (Optional)") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Connection", selection: $mcpMode) {
                    Text("Stdio (Local)").tag(MCPConnectionMode.stdio)
                    Text("HTTP + OAuth").tag(MCPConnectionMode.oauth)
                }
                .pickerStyle(.segmented)
                .onChange(of: mcpMode) { _, _ in
                    mcpError = nil
                    mcpStatus = ""
                }

                switch mcpMode {
                case .stdio:
                    stdioFields
                case .oauth:
                    oauthFields
                }

                // Status and connect button
                HStack {
                    if mcpConnected {
                        Label("\(mcpTools.count) tools", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    } else if !mcpStatus.isEmpty {
                        Text(mcpStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if mcpConnected {
                        Button("Disconnect") {
                            Task { await disconnectMCP() }
                        }
                    } else {
                        Button(action: { Task { await connectMCP() } }) {
                            if isConnectingMCP {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Text("Connect")
                            }
                        }
                        .disabled(!canConnectMCP || isConnectingMCP)
                    }
                }

                if let error = mcpError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                // Presets
                presetsRow
            }
            .padding(.vertical, 8)
        }
    }

    private var stdioFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Command")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)
                TextField("uvx, npx, etc.", text: $mcpCommand)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Arguments")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)
                TextField("mcp-server-fetch", text: $mcpArguments)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var oauthFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Server URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)
                TextField("https://...", text: $mcpServerURL)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Redirect")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)
                TextField("yrden-example", text: $mcpRedirectScheme)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var presetsRow: some View {
        HStack {
            Text("Presets:")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Fetch") {
                mcpMode = .stdio
                mcpCommand = "uvx"
                mcpArguments = "mcp-server-fetch"
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button("Filesystem") {
                mcpMode = .stdio
                mcpCommand = "npx"
                mcpArguments = "-y @modelcontextprotocol/server-filesystem /tmp"
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button("Todoist") {
                mcpMode = .oauth
                mcpServerURL = "https://mcp.todoist.com/mcp"
                mcpRedirectScheme = "yrden-example"
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Apply Section

    private var applySection: some View {
        VStack(spacing: 12) {
            Button(action: configure) {
                HStack {
                    if isConfigured {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    Text(isConfigured ? "Configured" : "Apply Configuration")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canConfigure)
        }
    }

    // MARK: - Computed Properties

    private var canLoadModels: Bool {
        switch selectedProvider {
        case .anthropic, .openai:
            return !apiKey.isEmpty
        case .bedrock:
            if useAwsProfile {
                return !awsRegion.isEmpty && !awsProfile.isEmpty
            } else {
                return !awsRegion.isEmpty && !awsAccessKey.isEmpty && !awsSecretKey.isEmpty
            }
        }
    }

    private var canConfigure: Bool {
        canLoadModels && !selectedModelId.isEmpty
    }

    private var canConnectMCP: Bool {
        switch mcpMode {
        case .stdio:
            return !mcpCommand.isEmpty
        case .oauth:
            return !mcpServerURL.isEmpty && URL(string: mcpServerURL) != nil
        }
    }

    // MARK: - Actions

    private func loadFromEnvironment() {
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            apiKey = key
            selectedProvider = .anthropic
        } else if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            apiKey = key
            selectedProvider = .openai
        } else if let region = ProcessInfo.processInfo.environment["AWS_REGION"] {
            awsRegion = region
            selectedProvider = .bedrock
            if let profile = ProcessInfo.processInfo.environment["AWS_PROFILE"] {
                awsProfile = profile
                useAwsProfile = true
            }
        }
    }

    private func loadModels() {
        isLoadingModels = true
        modelError = nil
        availableModels = []

        Task {
            do {
                let provider = try createProvider()
                var models: [ModelInfo] = []

                for try await model in provider.listModels() {
                    models.append(model)
                }

                await MainActor.run {
                    availableModels = models
                        .filter { filterModel($0) }
                        .sorted { $0.displayName < $1.displayName }
                    isLoadingModels = false

                    if selectedModelId.isEmpty, let first = availableModels.first {
                        selectedModelId = first.id
                    }
                }
            } catch {
                await MainActor.run {
                    modelError = error.localizedDescription
                    isLoadingModels = false
                }
            }
        }
    }

    private func filterModel(_ model: ModelInfo) -> Bool {
        switch selectedProvider {
        case .anthropic:
            return model.id.contains("claude")
        case .openai:
            let validPrefixes = ["gpt-4", "gpt-3.5", "o1", "o3"]
            return validPrefixes.contains { model.id.hasPrefix($0) }
        case .bedrock:
            let isClaudeModel = model.id.contains("claude") || model.id.contains("anthropic")
            let isInferenceProfile = model.metadata?["type"]?.stringValue == "inference_profile"
            return isClaudeModel || isInferenceProfile
        }
    }

    private func createProvider() throws -> any Provider {
        switch selectedProvider {
        case .anthropic:
            return AnthropicProvider(apiKey: apiKey)
        case .openai:
            return OpenAIProvider(apiKey: apiKey)
        case .bedrock:
            if useAwsProfile {
                return try BedrockProvider(region: awsRegion, profile: awsProfile)
            } else {
                return try BedrockProvider(
                    region: awsRegion,
                    accessKeyId: awsAccessKey,
                    secretAccessKey: awsSecretKey
                )
            }
        }
    }

    private func configure() {
        do {
            let model: any Model

            switch selectedProvider {
            case .anthropic:
                let provider = AnthropicProvider(apiKey: apiKey)
                model = AnthropicModel(name: selectedModelId, provider: provider)
            case .openai:
                let provider = OpenAIProvider(apiKey: apiKey)
                model = OpenAIModel(name: selectedModelId, provider: provider)
            case .bedrock:
                let provider: BedrockProvider
                if useAwsProfile {
                    provider = try BedrockProvider(region: awsRegion, profile: awsProfile)
                } else {
                    provider = try BedrockProvider(
                        region: awsRegion,
                        accessKeyId: awsAccessKey,
                        secretAccessKey: awsSecretKey
                    )
                }
                model = BedrockModel(name: selectedModelId, provider: provider)
            }

            let mcpToolsList = mcpConnected ? viewModel.getMCPTools() : []
            viewModel.configure(model: model, mcpTools: mcpToolsList)
            isConfigured = true
        } catch {
            modelError = error.localizedDescription
        }
    }

    private func connectMCP() async {
        isConnectingMCP = true
        mcpError = nil
        mcpStatus = ""

        do {
            let tools: [String]

            switch mcpMode {
            case .stdio:
                let commandLine = mcpArguments.isEmpty ? mcpCommand : "\(mcpCommand) \(mcpArguments)"
                tools = try await viewModel.connectMCPStdio(commandLine: commandLine)

            case .oauth:
                guard let url = URL(string: mcpServerURL) else {
                    throw NSError(domain: "Settings", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
                }
                tools = try await viewModel.connectMCPOAuth(
                    url: url,
                    redirectScheme: mcpRedirectScheme
                ) { progress in
                    Task { @MainActor in
                        mcpStatus = progress.description
                    }
                }
            }

            await MainActor.run {
                mcpTools = tools
                mcpConnected = true
                isConnectingMCP = false
                mcpStatus = ""
            }
        } catch {
            await MainActor.run {
                mcpError = error.localizedDescription
                isConnectingMCP = false
                mcpStatus = ""
            }
        }
    }

    private func disconnectMCP() async {
        await viewModel.disconnectMCP()
        mcpConnected = false
        mcpTools = []
    }
}

// MARK: - Types

enum ProviderType: String, CaseIterable {
    case anthropic
    case openai
    case bedrock

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .bedrock: return "Bedrock"
        }
    }
}

enum MCPConnectionMode: String {
    case stdio
    case oauth
}

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

extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

#Preview {
    SettingsView(viewModel: ChatViewModel())
}
