/// Tool call visualization.

import SwiftUI

struct ToolCallView: View {
    let toolCall: ToolCallInfo
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    statusIcon
                        .frame(width: 16, height: 16)

                    Text(toolCall.name)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)

                    Spacer()

                    if let duration = toolCall.duration {
                        Text(formatDuration(duration))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Arguments
                    if !toolCall.arguments.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Arguments")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(formatJSON(toolCall.arguments))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }

                    // Result
                    if let result = toolCall.result {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Result")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(result)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(10)
                        }
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(10)
        .background(backgroundColor)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch toolCall.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
        case .running:
            ProgressView()
                .scaleEffect(0.6)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        case .needsApproval:
            Image(systemName: "hand.raised.fill")
                .foregroundColor(.orange)
        }
    }

    private var backgroundColor: Color {
        switch toolCall.status {
        case .running: return Color.blue.opacity(0.05)
        case .completed: return Color.green.opacity(0.05)
        case .failed: return Color.red.opacity(0.05)
        case .needsApproval: return Color.orange.opacity(0.05)
        default: return Color(nsColor: .controlBackgroundColor)
        }
    }

    private var borderColor: Color {
        switch toolCall.status {
        case .running: return Color.blue.opacity(0.3)
        case .completed: return Color.green.opacity(0.3)
        case .failed: return Color.red.opacity(0.3)
        case .needsApproval: return Color.orange.opacity(0.3)
        default: return Color.secondary.opacity(0.2)
        }
    }

    private func formatDuration(_ duration: Duration) -> String {
        let ms = duration.components.seconds * 1000 +
                 duration.components.attoseconds / 1_000_000_000_000_000
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }

    private func formatJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: .prettyPrinted),
              let formatted = String(data: pretty, encoding: .utf8)
        else { return json }
        return formatted
    }
}

#Preview("Running") {
    ToolCallView(toolCall: ToolCallInfo(
        id: "1",
        name: "calculator",
        arguments: "{\"a\": 5, \"b\": 3, \"operation\": \"add\"}",
        status: .running
    ))
    .padding()
    .frame(width: 400)
}

#Preview("Completed") {
    ToolCallView(toolCall: ToolCallInfo(
        id: "2",
        name: "web_search",
        arguments: "{\"query\": \"Swift programming\"}",
        result: "Found 3 results...",
        duration: .milliseconds(450),
        status: .completed
    ))
    .padding()
    .frame(width: 400)
}
