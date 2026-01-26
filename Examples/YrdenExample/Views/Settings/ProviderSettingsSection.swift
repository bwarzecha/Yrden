/// Provider configuration section for settings.

import SwiftUI

struct ProviderSettingsSection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        GroupBox("Provider") {
            VStack(alignment: .leading, spacing: 12) {
                providerPicker
                providerFields
            }
            .padding(.vertical, 8)
        }
    }

    private var providerPicker: some View {
        Picker("Provider", selection: $store.selectedProvider) {
            ForEach(ProviderType.allCases, id: \.self) { provider in
                Text(provider.displayName).tag(provider)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: store.selectedProvider) { _, _ in
            store.onProviderChange()
        }
    }

    @ViewBuilder
    private var providerFields: some View {
        switch store.selectedProvider {
        case .anthropic, .openai:
            apiKeyField
        case .bedrock:
            bedrockFields
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(store.selectedProvider.displayName) API Key")
                .font(.caption)
                .foregroundColor(.secondary)
            SecureField("Enter API key", text: $store.currentApiKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var bedrockFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Authentication", selection: $store.useAwsProfile) {
                Text("AWS Profile").tag(true)
                Text("Access Keys").tag(false)
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Region")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)
                TextField("us-east-1", text: $store.awsRegion)
                    .textFieldStyle(.roundedBorder)
            }

            if store.useAwsProfile {
                HStack {
                    Text("Profile")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .leading)
                    TextField("default", text: $store.awsProfile)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                HStack {
                    Text("Access Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .leading)
                    TextField("AKIA...", text: $store.awsAccessKey)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Secret Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .leading)
                    SecureField("Secret", text: $store.awsSecretKey)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }
}
