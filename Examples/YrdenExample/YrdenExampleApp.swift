/// Yrden Example App
///
/// A macOS SwiftUI app demonstrating Yrden capabilities.

import SwiftUI
import Yrden

@main
struct YrdenExampleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var settingsStore = SettingsStore()

    var body: some Scene {
        Window("Yrden Example", id: "main") {
            ChatView(viewModel: viewModel, settingsStore: settingsStore)
                .frame(minWidth: 600, minHeight: 500)
                .onAppear {
                    configureFromSettings()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    private func configureFromSettings() {
        // Auto-configure if we have persisted settings
        guard settingsStore.canConfigure else { return }

        do {
            let model = try settingsStore.createModel()
            viewModel.configure(model: model)
            settingsStore.isConfigured = true
        } catch {
            // Silent failure on auto-configure - user can configure manually
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bring window to front after launch
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = sender.windows.first {
            window.makeKeyAndOrderFront(self)
        }
        return false
    }
}
