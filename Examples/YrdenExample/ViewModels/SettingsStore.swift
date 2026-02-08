/// Centralized settings store with persistence via @AppStorage.

import SwiftUI
import Yrden

// MARK: - Data Models

enum ProviderType: String, CaseIterable, Codable {
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

enum MCPConnectionMode: String, Codable {
    case stdio
    case oauth
}

struct MCPServerConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var mode: MCPConnectionMode
    var command: String?
    var arguments: String?
    var serverURL: String?
    var redirectScheme: String?
    var requiresApproval: Bool

    init(
        id: UUID = UUID(),
        name: String,
        mode: MCPConnectionMode,
        command: String? = nil,
        arguments: String? = nil,
        serverURL: String? = nil,
        redirectScheme: String? = nil,
        requiresApproval: Bool = false
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.command = command
        self.arguments = arguments
        self.serverURL = serverURL
        self.redirectScheme = redirectScheme
        self.requiresApproval = requiresApproval
    }

    static func stdioPreset(name: String, command: String, arguments: String) -> MCPServerConfig {
        MCPServerConfig(name: name, mode: .stdio, command: command, arguments: arguments)
    }

    static func oauthPreset(name: String, serverURL: String, redirectScheme: String = "yrden-example") -> MCPServerConfig {
        MCPServerConfig(name: name, mode: .oauth, serverURL: serverURL, redirectScheme: redirectScheme)
    }
}

struct ConnectedMCPServer: Identifiable {
    let id: UUID
    let config: MCPServerConfig
    let connection: MCPServerConnection
    let tools: [String]

    init(config: MCPServerConfig, connection: MCPServerConnection, tools: [String]) {
        self.id = config.id
        self.config = config
        self.connection = connection
        self.tools = tools
    }
}

// MARK: - Settings Store

@MainActor
class SettingsStore: ObservableObject {
    // MARK: - Provider Settings (Persisted)

    @AppStorage("selectedProvider") var selectedProvider: ProviderType = .anthropic
    @AppStorage("selectedModelId") var selectedModelId: String = ""
    @AppStorage("awsRegion") var awsRegion: String = "us-east-1"
    @AppStorage("awsProfile") var awsProfile: String = "default"
    @AppStorage("useAwsProfile") var useAwsProfile: Bool = true

    // MARK: - API Keys (Persisted - UserDefaults for demo app simplicity)

    @AppStorage("anthropicApiKey") var anthropicApiKey: String = ""
    @AppStorage("openaiApiKey") var openaiApiKey: String = ""
    @AppStorage("awsAccessKey") var awsAccessKey: String = ""
    @AppStorage("awsSecretKey") var awsSecretKey: String = ""

    // MARK: - Built-in Tools (Persisted)

    @AppStorage("builtInToolsEnabled") var builtInToolsEnabled: Bool = false
    @AppStorage("builtInToolsWorkingDirectory") var builtInToolsWorkingDirectory: String = "~/Desktop"
    @AppStorage("builtInToolsShellApproval") var builtInToolsShellApproval: Bool = true

    // MARK: - MCP Servers (Persisted as JSON)

    @AppStorage("savedMCPServersData") private var savedMCPServersData: Data = Data()

    var savedMCPServers: [MCPServerConfig] {
        get {
            guard !savedMCPServersData.isEmpty else { return [] }
            return (try? JSONDecoder().decode([MCPServerConfig].self, from: savedMCPServersData)) ?? []
        }
        set {
            savedMCPServersData = (try? JSONEncoder().encode(newValue)) ?? Data()
            objectWillChange.send()
        }
    }

    // MARK: - Runtime State (Not Persisted)

    @Published var connectedServers: [ConnectedMCPServer] = []
    @Published var availableModels: [ModelInfo] = []
    @Published var isLoadingModels = false
    @Published var modelError: String?
    @Published var isConfigured = false

    // MARK: - Computed Properties

    var currentApiKey: String {
        get {
            switch selectedProvider {
            case .anthropic: return anthropicApiKey
            case .openai: return openaiApiKey
            case .bedrock: return ""
            }
        }
        set {
            switch selectedProvider {
            case .anthropic: anthropicApiKey = newValue
            case .openai: openaiApiKey = newValue
            case .bedrock: break
            }
        }
    }

    var canLoadModels: Bool {
        switch selectedProvider {
        case .anthropic:
            return !anthropicApiKey.isEmpty
        case .openai:
            return !openaiApiKey.isEmpty
        case .bedrock:
            if useAwsProfile {
                return !awsRegion.isEmpty && !awsProfile.isEmpty
            } else {
                return !awsRegion.isEmpty && !awsAccessKey.isEmpty && !awsSecretKey.isEmpty
            }
        }
    }

    var canConfigure: Bool {
        canLoadModels && !selectedModelId.isEmpty
    }

    var allConnectedTools: [any Tool] {
        // This will be populated by ChatViewModel when connecting
        []
    }

    // MARK: - Initialization

    init() {
        loadFromEnvironmentIfEmpty()
    }

    private func loadFromEnvironmentIfEmpty() {
        // Load from environment variables only if no persisted values
        if anthropicApiKey.isEmpty,
           let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            anthropicApiKey = key
        }
        if openaiApiKey.isEmpty,
           let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            openaiApiKey = key
        }
        if awsRegion == "us-east-1" {
            if let region = ProcessInfo.processInfo.environment["AWS_REGION"] {
                awsRegion = region
            }
        }
        if awsProfile == "default" {
            if let profile = ProcessInfo.processInfo.environment["AWS_PROFILE"] {
                awsProfile = profile
            }
        }

        // Auto-select provider based on available keys
        if selectedModelId.isEmpty {
            if !anthropicApiKey.isEmpty {
                selectedProvider = .anthropic
            } else if !openaiApiKey.isEmpty {
                selectedProvider = .openai
            } else if !awsRegion.isEmpty {
                selectedProvider = .bedrock
            }
        }
    }

    // MARK: - Provider Factory

    func createProvider() throws -> any Provider {
        switch selectedProvider {
        case .anthropic:
            return AnthropicProvider(apiKey: anthropicApiKey)
        case .openai:
            return OpenAIProvider(apiKey: openaiApiKey)
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

    func createModel() throws -> any Model {
        switch selectedProvider {
        case .anthropic:
            let provider = AnthropicProvider(apiKey: anthropicApiKey)
            return AnthropicModel(name: selectedModelId, provider: provider)
        case .openai:
            let provider = OpenAIProvider(apiKey: openaiApiKey)
            return OpenAIModel(name: selectedModelId, provider: provider)
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
            return BedrockModel(name: selectedModelId, provider: provider)
        }
    }

    // MARK: - Model Loading

    func loadModels() async {
        isLoadingModels = true
        modelError = nil
        availableModels = []

        do {
            let provider = try createProvider()
            var models: [ModelInfo] = []

            for try await model in provider.listModels() {
                models.append(model)
            }

            availableModels = models
                .filter { filterModel($0) }
                .sorted { $0.displayName < $1.displayName }
            isLoadingModels = false

            // Auto-select first model if none selected
            if selectedModelId.isEmpty, let first = availableModels.first {
                selectedModelId = first.id
            }
        } catch {
            modelError = error.localizedDescription
            isLoadingModels = false
        }
    }

    private func filterModel(_ model: ModelInfo) -> Bool {
        switch selectedProvider {
        case .anthropic:
            return model.id.contains("claude")
        case .openai:
            let validPrefixes = ["gpt-", "chatgpt-", "o1", "o3", "o4"]
            return validPrefixes.contains { model.id.hasPrefix($0) } || model.id.contains("chat")
        case .bedrock:
            let isClaudeModel = model.id.contains("claude") || model.id.contains("anthropic")
            let isInferenceProfile = model.metadata?["type"]?.stringValue == "inference_profile"
            return isClaudeModel || isInferenceProfile
        }
    }

    // MARK: - MCP Server Management

    func addMCPServer(_ config: MCPServerConfig) {
        var servers = savedMCPServers
        servers.append(config)
        savedMCPServers = servers
    }

    func updateMCPServer(_ config: MCPServerConfig) {
        var servers = savedMCPServers
        if let index = servers.firstIndex(where: { $0.id == config.id }) {
            servers[index] = config
            savedMCPServers = servers
        }
    }

    func deleteMCPServer(id: UUID) {
        var servers = savedMCPServers
        servers.removeAll { $0.id == id }
        savedMCPServers = servers

        // Also disconnect if connected
        if let index = connectedServers.firstIndex(where: { $0.id == id }) {
            Task {
                await connectedServers[index].connection.disconnect()
            }
            connectedServers.remove(at: index)
        }
    }

    func isServerConnected(id: UUID) -> Bool {
        connectedServers.contains { $0.id == id }
    }

    func addConnectedServer(_ server: ConnectedMCPServer) {
        connectedServers.append(server)
    }

    func removeConnectedServer(id: UUID) async {
        if let index = connectedServers.firstIndex(where: { $0.id == id }) {
            await connectedServers[index].connection.disconnect()
            connectedServers.remove(at: index)
        }
    }

    func disconnectAllServers() async {
        for server in connectedServers {
            await server.connection.disconnect()
        }
        connectedServers.removeAll()
    }

    // MARK: - Provider Change

    func onProviderChange() {
        availableModels = []
        selectedModelId = ""
        isConfigured = false
    }
}

// MARK: - JSONValue Extension

extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
