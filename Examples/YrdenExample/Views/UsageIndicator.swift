/// Token usage and context fullness indicator.

import SwiftUI
import Yrden

struct UsageIndicator: View {
    let currentTurnUsage: Usage?
    let totalUsage: Usage?
    let maxContextTokens: Int?
    let isProcessing: Bool

    private var contextPercent: Double? {
        guard let maxContext = maxContextTokens, maxContext > 0,
              let total = totalUsage else { return nil }
        return Double(total.inputTokens) / Double(maxContext)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Context fullness indicator
            if let percent = contextPercent {
                ContextBar(percent: percent, maxTokens: maxContextTokens ?? 0)
            }

            // Token counts
            if let usage = isProcessing ? currentTurnUsage : totalUsage {
                TokenCounts(usage: usage, isStreaming: isProcessing)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }
}

// MARK: - Context Bar

private struct ContextBar: View {
    let percent: Double
    let maxTokens: Int

    private var barColor: Color {
        if percent > 0.9 { return .red }
        if percent > 0.75 { return .orange }
        return .blue
    }

    private var formattedMax: String {
        if maxTokens >= 1_000_000 {
            return String(format: "%.1fM", Double(maxTokens) / 1_000_000)
        } else if maxTokens >= 1_000 {
            return "\(maxTokens / 1_000)K"
        }
        return "\(maxTokens)"
    }

    var body: some View {
        HStack(spacing: 4) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: geo.size.width * min(percent, 1.0))
                }
            }
            .frame(width: 40, height: 6)

            // Percentage and max
            Text("\(Int(percent * 100))%")
                .monospacedDigit()

            Text("of \(formattedMax)")
                .foregroundColor(.secondary.opacity(0.7))
        }
        .help("Context window: \(Int(percent * 100))% used of \(formattedMax) tokens")
    }
}

// MARK: - Token Counts

private struct TokenCounts: View {
    let usage: Usage
    let isStreaming: Bool

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 10_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    var body: some View {
        HStack(spacing: 8) {
            // Input tokens
            HStack(spacing: 2) {
                Image(systemName: "arrow.down.circle")
                    .font(.caption2)
                Text(formatTokens(usage.inputTokens))
                    .monospacedDigit()
            }
            .help("Input tokens: \(usage.inputTokens)")

            // Output tokens
            HStack(spacing: 2) {
                Image(systemName: "arrow.up.circle")
                    .font(.caption2)
                Text(formatTokens(usage.outputTokens))
                    .monospacedDigit()
                if isStreaming {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                }
            }
            .help("Output tokens: \(usage.outputTokens)")

            // Cached tokens (if any)
            if let cached = usage.cachedTokens, cached > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "bolt.circle")
                        .font(.caption2)
                        .foregroundColor(.green)
                    Text(formatTokens(cached))
                        .monospacedDigit()
                        .foregroundColor(.green)
                }
                .help("Cached tokens: \(cached) (reduced cost)")
            }

            // Reasoning tokens (if any)
            if let reasoning = usage.reasoningTokens, reasoning > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "brain")
                        .font(.caption2)
                        .foregroundColor(.purple)
                    Text(formatTokens(reasoning))
                        .monospacedDigit()
                        .foregroundColor(.purple)
                }
                .help("Reasoning tokens: \(reasoning)")
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        // Minimal usage
        UsageIndicator(
            currentTurnUsage: nil,
            totalUsage: Usage(inputTokens: 1500, outputTokens: 500),
            maxContextTokens: 200_000,
            isProcessing: false
        )

        // High usage
        UsageIndicator(
            currentTurnUsage: nil,
            totalUsage: Usage(inputTokens: 180_000, outputTokens: 15_000),
            maxContextTokens: 200_000,
            isProcessing: false
        )

        // Streaming with cache
        UsageIndicator(
            currentTurnUsage: Usage(inputTokens: 5000, outputTokens: 234, cachedTokens: 3000),
            totalUsage: nil,
            maxContextTokens: 128_000,
            isProcessing: true
        )

        // With reasoning tokens
        UsageIndicator(
            currentTurnUsage: nil,
            totalUsage: Usage(inputTokens: 10_000, outputTokens: 5_000, cachedTokens: nil, reasoningTokens: 2_500),
            maxContextTokens: 200_000,
            isProcessing: false
        )
    }
    .padding()
    .frame(width: 400)
}
