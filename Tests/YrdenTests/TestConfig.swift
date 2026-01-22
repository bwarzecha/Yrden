import Foundation

/// Configuration for integration tests.
/// Loads API keys from environment variables or .env file.
enum TestConfig {

    /// Load an API key by name.
    /// Checks environment variables first, then falls back to .env file.
    static func apiKey(_ name: String) -> String? {
        // Try environment variable first
        if let key = ProcessInfo.processInfo.environment[name], !key.isEmpty {
            return key
        }

        // Try .env file in project root
        if let key = loadFromEnvFile(name) {
            return key
        }

        return nil
    }

    /// Require an API key, failing with a clear message if not found.
    static func requireAPIKey(_ name: String) -> String {
        guard let key = apiKey(name), !key.isEmpty else {
            fatalError("""

                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                Missing required API key: \(name)

                Set it via environment variable:
                    export \(name)=your-key-here

                Or create a .env file in the project root:
                    cp .env.template .env
                    # Edit .env with your keys
                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                """)
        }

        // Sanity check: not the template value
        guard !key.hasPrefix("your-") else {
            fatalError("""

                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                API key \(name) contains template placeholder value.

                Please edit your .env file with a real API key.
                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                """)
        }

        return key
    }

    // MARK: - Convenience accessors (all require explicit call)

    static var anthropicAPIKey: String { requireAPIKey("ANTHROPIC_API_KEY") }
    static var openAIAPIKey: String { requireAPIKey("OPENAI_API_KEY") }
    static var openRouterAPIKey: String { requireAPIKey("OPENROUTER_API_KEY") }

    // MARK: - Check availability (for conditional test setup, not skipping)

    static var hasAnthropicAPIKey: Bool { apiKey("ANTHROPIC_API_KEY") != nil }
    static var hasOpenAIAPIKey: Bool { apiKey("OPENAI_API_KEY") != nil }
    static var hasOpenRouterAPIKey: Bool { apiKey("OPENROUTER_API_KEY") != nil }

    // MARK: - Private

    private static func loadFromEnvFile(_ name: String) -> String? {
        // Find .env file - check current directory and parent directories
        let fileManager = FileManager.default
        var currentPath = fileManager.currentDirectoryPath

        for _ in 0..<5 {  // Check up to 5 levels up
            let envPath = (currentPath as NSString).appendingPathComponent(".env")
            if let contents = try? String(contentsOfFile: envPath, encoding: .utf8) {
                if let value = parseEnvFile(contents, key: name) {
                    return value
                }
            }
            currentPath = (currentPath as NSString).deletingLastPathComponent
        }

        return nil
    }

    private static func parseEnvFile(_ contents: String, key: String) -> String? {
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Parse KEY=value
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let envKey = String(parts[0]).trimmingCharacters(in: .whitespaces)
                var envValue = String(parts[1]).trimmingCharacters(in: .whitespaces)

                // Remove surrounding quotes if present
                if (envValue.hasPrefix("\"") && envValue.hasSuffix("\"")) ||
                   (envValue.hasPrefix("'") && envValue.hasSuffix("'")) {
                    envValue = String(envValue.dropFirst().dropLast())
                }

                if envKey == key {
                    return envValue
                }
            }
        }
        return nil
    }
}
