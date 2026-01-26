/// Model selection section for settings.

import SwiftUI
import Yrden

struct ModelSettingsSection: View {
    @ObservedObject var store: SettingsStore
    @State private var modelSearchText = ""

    private var filteredModels: [ModelInfo] {
        if modelSearchText.isEmpty {
            return store.availableModels
        }
        return store.availableModels.filter {
            $0.displayName.localizedCaseInsensitiveContains(modelSearchText) ||
            $0.id.localizedCaseInsensitiveContains(modelSearchText)
        }
    }

    var body: some View {
        GroupBox("Model") {
            VStack(alignment: .leading, spacing: 12) {
                if store.availableModels.isEmpty {
                    emptyState
                } else {
                    modelList
                }

                if let error = store.modelError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        HStack {
            Text("Load models to select")
                .foregroundColor(.secondary)
            Spacer()
            Button(action: { Task { await store.loadModels() } }) {
                if store.isLoadingModels {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Text("Load Models")
                }
            }
            .disabled(store.isLoadingModels || !store.canLoadModels)
        }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                Button(action: { Task { await store.loadModels() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isLoadingModels)
            }

            Picker("Model", selection: $store.selectedModelId) {
                Text("Select a model").tag("")
                ForEach(filteredModels, id: \.id) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .labelsHidden()

            if !modelSearchText.isEmpty {
                Text("\(filteredModels.count) of \(store.availableModels.count) models")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
