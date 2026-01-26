/// Single message display with markdown rendering.

import SwiftUI

struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar
            avatar
                .frame(width: 32, height: 32)

            // Content
            VStack(alignment: .leading, spacing: 8) {
                // Role label
                Text(roleLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Render blocks in order
                ForEach(message.blocks) { block in
                    switch block {
                    case .text(_, let content):
                        if !content.isEmpty {
                            Text(LocalizedStringKey(content))
                                .textSelection(.enabled)
                        }
                    case .toolCall(let toolCall):
                        ToolCallView(toolCall: toolCall)
                    }
                }

                // Streaming indicator when no content yet
                if message.isStreaming && message.blocks.isEmpty {
                    TypingIndicator()
                }
            }

            Spacer(minLength: 40)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var avatar: some View {
        switch message.role {
        case .user:
            Circle()
                .fill(Color.blue)
                .overlay(
                    Image(systemName: "person.fill")
                        .foregroundColor(.white)
                        .font(.caption)
                )
        case .assistant:
            Circle()
                .fill(Color.purple)
                .overlay(
                    Image(systemName: "sparkles")
                        .foregroundColor(.white)
                        .font(.caption)
                )
        case .error:
            Circle()
                .fill(Color.red)
                .overlay(
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.white)
                        .font(.caption)
                )
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .error: return "Error"
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 8, height: 8)
                    .scaleEffect(phase == index ? 1.2 : 0.8)
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever()
                        .delay(Double(index) * 0.15),
                        value: phase
                    )
            }
        }
        .onAppear {
            phase = 2
        }
    }
}

#Preview("User Message") {
    MessageView(message: .user("Hello, how can you help me today?"))
        .padding()
}

#Preview("Assistant Message") {
    MessageView(message: .assistant("I can help you with calculations, web searches, and file operations."))
        .padding()
}

#Preview("Streaming") {
    MessageView(message: .assistant("", isStreaming: true))
        .padding()
}
