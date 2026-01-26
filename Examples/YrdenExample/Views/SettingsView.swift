/// Settings sheet for provider and model configuration.

import SwiftUI
import Yrden

struct SettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProvider = ProviderType.anthropic
    @State private var apiKey = ""
    @State private var modelName = "claude-sonnet-4-20250514"
    @State private var isConfigured = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            // Content
            Form {
                Section("Provider") {
                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(ProviderType.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedProvider) { _, newValue in
                        modelName = newValue.defaultModel
                    }
                }

                Section("Authentication") {
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    if apiKey.isEmpty {
                        Text("Enter your \(selectedProvider.displayName) API key")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Model") {
                    TextField("Model Name", text: $modelName)
                        .textFieldStyle(.roundedBorder)

                    Text("Examples: \(selectedProvider.modelExamples)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
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
                    .disabled(apiKey.isEmpty || modelName.isEmpty)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 450, height: 400)
        .onAppear {
            loadFromEnvironment()
        }
    }

    private func loadFromEnvironment() {
        // Try to load API keys from environment
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            apiKey = key
            selectedProvider = .anthropic
        } else if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            apiKey = key
            selectedProvider = .openai
        }
    }

    private func configure() {
        let model: any Model

        switch selectedProvider {
        case .anthropic:
            let provider = AnthropicProvider(apiKey: apiKey)
            model = AnthropicModel(name: modelName, provider: provider)
        case .openai:
            let provider = OpenAIProvider(apiKey: apiKey)
            model = OpenAIModel(name: modelName, provider: provider)
        }

        viewModel.configure(model: model)
        isConfigured = true
    }
}

// MARK: - Provider Type

enum ProviderType: String, CaseIterable {
    case anthropic
    case openai

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-20250514"
        case .openai: return "gpt-4o"
        }
    }

    var modelExamples: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-20250514, claude-3-5-haiku-20241022"
        case .openai: return "gpt-4o, gpt-4o-mini, o1-mini"
        }
    }
}

#Preview {
    SettingsView(viewModel: ChatViewModel())
}
