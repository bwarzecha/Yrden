import Foundation

/// Configuration for integration tests.
/// Loads API keys from environment variables or .env file.
public enum TestConfig {

    /// Load an API key by name.
    /// Checks environment variables first, then falls back to .env file.
    public static func apiKey(_ name: String) -> String? {
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
    public static func requireAPIKey(_ name: String) -> String {
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

    public static var anthropicAPIKey: String { requireAPIKey("ANTHROPIC_API_KEY") }
    public static var openAIAPIKey: String { requireAPIKey("OPENAI_API_KEY") }
    public static var openRouterAPIKey: String { requireAPIKey("OPENROUTER_API_KEY") }

    // MARK: - AWS Bedrock Configuration

    /// AWS region for Bedrock (defaults to "us-east-1")
    public static var awsRegion: String {
        apiKey("AWS_REGION") ?? apiKey("AWS_DEFAULT_REGION") ?? "us-east-1"
    }

    /// AWS access key ID (optional if using profile)
    public static var awsAccessKeyId: String? { apiKey("AWS_ACCESS_KEY_ID") }

    /// AWS secret access key (optional if using profile)
    public static var awsSecretAccessKey: String? { apiKey("AWS_SECRET_ACCESS_KEY") }

    /// AWS session token for temporary credentials (optional)
    public static var awsSessionToken: String? { apiKey("AWS_SESSION_TOKEN") }

    /// AWS profile name (optional, used if no explicit credentials)
    public static var awsProfile: String { apiKey("AWS_PROFILE") ?? "default" }

    /// Whether AWS credentials are available (either explicit or profile)
    public static var hasAWSCredentials: Bool {
        // Either explicit credentials or profile-based
        if let accessKey = awsAccessKeyId, let secretKey = awsSecretAccessKey,
           !accessKey.isEmpty && !secretKey.isEmpty {
            return true
        }
        // Profile-based: check if credentials file exists
        let credentialsPath = ("~/.aws/credentials" as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: credentialsPath)
    }

    // MARK: - Ollama / Local LLM Configuration

    /// Default model for local integration tests.
    public static let ollamaTestModel = "qwen3:4b"

    /// Ollama port (default: 11434).
    public static var ollamaPort: Int {
        if let portStr = apiKey("OLLAMA_PORT"), let port = Int(portStr) {
            return port
        }
        return 11434
    }

    /// Whether Ollama is reachable at the expected port.
    public static var isOllamaRunning: Bool {
        let url = URL(string: "http://localhost:\(ollamaPort)/api/tags")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                reachable = true
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return reachable
    }

    /// Whether a model is available locally in Ollama.
    public static func ollamaHasModel(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ollama", "list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            // Model names in `ollama list` appear as first column, e.g. "qwen3:4b"
            return output.contains(name)
        } catch {
            return false
        }
    }

    /// Pull a model via `ollama pull`. Blocks until complete.
    /// Returns true on success.
    @discardableResult
    public static func ollamaPull(_ name: String) -> Bool {
        print("Pulling Ollama model '\(name)'... (this may take a while on first run)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ollama", "pull", name]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            print("Failed to pull model '\(name)': \(error)")
            return false
        }
    }

    /// Ensure a model is available, pulling if needed. Crashes if Ollama is not running.
    public static func requireOllamaModel(_ name: String) {
        guard isOllamaRunning else {
            fatalError("""

                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                Ollama is not running.

                Start it with:
                    ollama serve

                Or install from:
                    https://ollama.com
                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                """)
        }

        if !ollamaHasModel(name) {
            guard ollamaPull(name) else {
                fatalError("""

                    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    Failed to pull Ollama model: \(name)

                    Try pulling manually:
                        ollama pull \(name)
                    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    """)
            }
        }
    }

    // MARK: - LM Studio Configuration

    /// Default model for LM Studio tests (overridable via LM_STUDIO_MODEL env var).
    public static var lmStudioTestModel: String {
        apiKey("LM_STUDIO_MODEL") ?? "qwen/qwen3-4b-2507"
    }

    /// LM Studio port (default: 1234).
    public static var lmStudioPort: Int {
        if let portStr = apiKey("LM_STUDIO_PORT"), let port = Int(portStr) {
            return port
        }
        return 1234
    }

    /// Whether LM Studio is reachable at the expected port.
    public static var isLMStudioRunning: Bool {
        isOpenAICompatibleServerRunning(port: lmStudioPort)
    }

    /// Whether a model is loaded in LM Studio (checks /v1/models endpoint).
    public static func lmStudioHasModel(_ name: String) -> Bool {
        let url = URL(string: "http://localhost:\(lmStudioPort)/v1/models")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let semaphore = DispatchSemaphore(value: 0)
        var found = false

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["data"] as? [[String: Any]] {
                found = models.contains { ($0["id"] as? String)?.contains(name) == true }
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return found
    }

    /// Verify LM Studio is running and has the expected model. Crashes with guidance if not.
    public static func requireLMStudioModel(_ name: String) {
        guard isLMStudioRunning else {
            fatalError("""

                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                LM Studio is not running on port \(lmStudioPort).

                Start LM Studio and load a model, or set LM_STUDIO_PORT
                if running on a non-default port.
                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                """)
        }

        guard lmStudioHasModel(name) else {
            fatalError("""

                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                LM Studio model '\(name)' not found.

                Load it in LM Studio, or set LM_STUDIO_MODEL to a loaded model.
                ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                """)
        }
    }

    // MARK: - Shared Helpers

    /// Whether an OpenAI-compatible server is reachable at the given port.
    public static func isOpenAICompatibleServerRunning(port: Int) -> Bool {
        let url = URL(string: "http://localhost:\(port)/v1/models")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false

        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                reachable = true
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return reachable
    }

    // MARK: - Check availability (for conditional test setup, not skipping)

    public static var hasAnthropicAPIKey: Bool { apiKey("ANTHROPIC_API_KEY") != nil }
    public static var hasOpenAIAPIKey: Bool { apiKey("OPENAI_API_KEY") != nil }
    public static var hasOpenRouterAPIKey: Bool { apiKey("OPENROUTER_API_KEY") != nil }

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
