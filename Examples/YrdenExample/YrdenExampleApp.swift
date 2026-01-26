/// Yrden Example App
///
/// A macOS SwiftUI app demonstrating Yrden capabilities.

import SwiftUI
import Yrden

@main
struct YrdenExampleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = ChatViewModel()

    var body: some Scene {
        Window("Yrden Example", id: "main") {
            ChatView(viewModel: viewModel)
                .frame(minWidth: 600, minHeight: 500)
                .onAppear {
                    configureFromEnvironment()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    private func configureFromEnvironment() {
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            let provider = AnthropicProvider(apiKey: key)
            let model = AnthropicModel(name: "claude-sonnet-4-20250514", provider: provider)
            viewModel.configure(model: model)
            return
        }
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            let provider = OpenAIProvider(apiKey: key)
            let model = OpenAIModel(name: "gpt-4o", provider: provider)
            viewModel.configure(model: model)
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
