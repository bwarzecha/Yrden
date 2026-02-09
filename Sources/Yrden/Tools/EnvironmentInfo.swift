/// Discover host environment info for shell tool descriptions.
///
/// Probes the OS and available development tools once at init time via a
/// single batched shell command. The result is appended to ShellTool's
/// description so LLMs know what platform and tools they're working with.

import Foundation

public struct EnvironmentInfo: Sendable, Equatable {
    public struct ToolInfo: Sendable, Equatable {
        public let name: String
        public let version: String
    }

    /// Operating system name (e.g., "macOS", "Linux").
    public let osName: String

    /// OS version (e.g., "15.2", "6.5.0-44-generic").
    public let osVersion: String

    /// CPU architecture (e.g., "arm64", "x86_64").
    public let architecture: String

    /// Tools found with their version strings.
    public let availableTools: [ToolInfo]

    /// Tools that were checked but not found.
    public let missingTools: [String]

    // MARK: - Default Tool List

    /// Default tools to probe. Covers text processing, search, network,
    /// languages, build tools, and system utils with known BSD/GNU differences.
    public static let defaultTools: [String] = [
        // Text processing (BSD vs GNU differences are a major pitfall)
        "sed", "awk", "grep", "rg",
        "sort", "cut", "tr", "xargs", "jq",
        // Search/find
        "find", "fd",
        // Network
        "curl", "wget",
        // Archive
        "tar", "zip", "unzip",
        // System (BSD vs GNU gotchas: readlink -f, date flags)
        "readlink", "date", "realpath",
        // Languages/runtimes
        "python3", "python", "node", "npm", "git",
        "ruby", "perl", "go", "java", "swift", "cargo",
        // Build
        "make", "cmake", "gcc", "clang",
        // Package managers / containers
        "brew", "docker",
    ]

    // MARK: - Discovery

    /// Discover environment info by running a single batched shell command.
    ///
    /// - Parameters:
    ///   - shellPath: Path to the shell (e.g., "/bin/zsh").
    ///   - environment: Environment variables for the subprocess.
    ///   - tools: Tools to probe. Defaults to ``defaultTools``.
    ///   - timeout: Maximum time to wait for discovery (default: 10s).
    public static func discover(
        shellPath: String,
        environment: [String: String],
        tools: [String]? = nil,
        timeout: TimeInterval = 10
    ) async throws -> EnvironmentInfo {
        let toolList = tools ?? defaultTools
        let command = buildDiscoveryCommand(tools: toolList)

        let output = try await runCommand(
            command,
            shellPath: shellPath,
            environment: environment,
            timeout: timeout
        )

        return parseDiscoveryOutput(output, requestedTools: toolList)
    }

    /// Format as text suitable for appending to a tool description.
    public var descriptionSuffix: String {
        var parts: [String] = []

        // Platform line with BSD warning for macOS
        var envLine = "Environment: \(osName) \(osVersion) (\(architecture))."
        if osName == "macOS" {
            envLine += " This is NOT Linux — BSD userland tools differ from GNU"
                + " (e.g. sed -i requires '' argument, grep has no -P flag,"
                + " date flags differ from GNU date)."
        }
        parts.append(envLine)

        // Available tools
        if !availableTools.isEmpty {
            let toolStrings = availableTools.map { tool in
                tool.version.isEmpty ? tool.name : "\(tool.name) (\(tool.version))"
            }
            parts.append("Available: \(toolStrings.joined(separator: ", "))")
        }

        // Missing tools
        if !missingTools.isEmpty {
            parts.append("Not found: \(missingTools.joined(separator: ", "))")
        }

        return "\n\n" + parts.joined(separator: "\n")
    }

    // MARK: - Internal

    static func buildDiscoveryCommand(tools: [String]) -> String {
        var lines: [String] = [
            "echo \"OS:$(uname -s)\"",
            "echo \"OSVERSION:$(sw_vers -productVersion 2>/dev/null || uname -r)\"",
            "echo \"ARCH:$(uname -m)\"",
        ]

        for tool in tools {
            // Use --version for most tools; special cases for those that differ.
            let versionFlag: String
            switch tool {
            case "go":
                versionFlag = "version"
            case "java":
                // java -version writes to stderr
                versionFlag = "-version"
            default:
                versionFlag = "--version"
            }
            lines.append(
                "echo \"TOOL:\(tool):$(\(tool) \(versionFlag) 2>&1 | head -1)\""
                + " 2>/dev/null || echo \"TOOL:\(tool):NOT_FOUND\""
            )
        }

        return lines.joined(separator: "\n")
    }

    static func parseDiscoveryOutput(
        _ output: String,
        requestedTools: [String]
    ) -> EnvironmentInfo {
        var osName = "Unknown"
        var osVersion = ""
        var architecture = ""
        var foundTools: [ToolInfo] = []
        var foundToolNames: Set<String> = []

        for line in output.split(separator: "\n") {
            let str = String(line)

            if str.hasPrefix("OS:") {
                let raw = String(str.dropFirst(3))
                osName = raw == "Darwin" ? "macOS" : raw
            } else if str.hasPrefix("OSVERSION:") {
                osVersion = String(str.dropFirst(10))
            } else if str.hasPrefix("ARCH:") {
                architecture = String(str.dropFirst(5))
            } else if str.hasPrefix("TOOL:") {
                let remainder = String(str.dropFirst(5))
                guard let colonIdx = remainder.firstIndex(of: ":") else { continue }
                let name = String(remainder[remainder.startIndex..<colonIdx])
                let rawVersion = String(remainder[remainder.index(after: colonIdx)...])

                // Skip tools that weren't found
                if rawVersion.contains("NOT_FOUND")
                    || rawVersion.contains("not found")
                    || rawVersion.contains("No such file")
                {
                    continue
                }

                let version = cleanVersionString(rawVersion, toolName: name)
                foundTools.append(ToolInfo(name: name, version: version))
                foundToolNames.insert(name)
            }
        }

        let missing = requestedTools.filter { !foundToolNames.contains($0) }

        return EnvironmentInfo(
            osName: osName,
            osVersion: osVersion,
            architecture: architecture,
            availableTools: foundTools,
            missingTools: missing
        )
    }

    /// Extract just the version number from verbose tool output.
    static func cleanVersionString(_ raw: String, toolName: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Match common patterns like "Python 3.12.1", "git version 2.43.0",
        // "go version go1.22.0 darwin/arm64", "rustc 1.75.0", etc.
        // Look for a version-like pattern: digits.digits[.digits...]
        let pattern = #"(\d+\.\d+(?:\.\d+)?(?:-[a-zA-Z0-9.]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: trimmed,
                  range: NSRange(trimmed.startIndex..., in: trimmed)
              ),
              let range = Range(match.range(at: 1), in: trimmed)
        else {
            // No version pattern found — return empty rather than garbage
            return ""
        }

        return String(trimmed[range])
    }

    // MARK: - Process Execution

    /// Run a shell command and return stdout. Uses the same GCD pattern
    /// as ShellEnvironment.captureEnvironment() to avoid blocking
    /// the Swift concurrency cooperative thread pool.
    private static func runCommand(
        _ command: String,
        shellPath: String,
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: shellPath)
                    process.arguments = ["-l", "-c", command]
                    process.environment = environment
                    process.standardInput = FileHandle.nullDevice

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    try process.run()

                    let deadline = Date().addingTimeInterval(timeout)
                    while process.isRunning && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }

                    if process.isRunning {
                        process.terminate()
                        continuation.resume(throwing: EnvironmentInfoError.timeout)
                        return
                    }

                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    guard let output = String(data: data, encoding: .utf8) else {
                        continuation.resume(throwing: EnvironmentInfoError.invalidOutput)
                        return
                    }

                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

public enum EnvironmentInfoError: Error, Sendable {
    case timeout
    case invalidOutput
}
