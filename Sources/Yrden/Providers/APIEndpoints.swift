/// API endpoint path constants for each provider.
///
/// Centralizes endpoint paths to avoid typos and ensure consistency.

import Foundation

// MARK: - Anthropic Endpoints

/// API endpoint paths for the Anthropic API.
enum AnthropicEndpoint {
    /// Messages API endpoint for chat completions.
    static let messages = "messages"
    /// Models API endpoint for listing available models.
    static let models = "models"
}

// MARK: - OpenAI Endpoints

/// API endpoint paths for the OpenAI API.
enum OpenAIEndpoint {
    /// Chat Completions API endpoint.
    static let chatCompletions = "chat/completions"
    /// Responses API endpoint (for GPT-5 family).
    static let responses = "responses"
    /// Models API endpoint for listing available models.
    static let models = "models"
}
