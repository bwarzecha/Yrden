/// Environment capture for shell tool execution.
///
/// When a Swift process is launched from Xcode, Finder, or launchd,
/// the PATH is minimal (`/usr/bin:/bin:/usr/sbin:/sbin`). Tools installed
/// via Homebrew, nvm, pyenv, cargo, etc. are unavailable.
///
/// `captureUserEnvironment()` spawns the user's login shell once,
/// captures its environment variables, and caches the result.

import Foundation

public struct ShellEnvironment: Sendable {
    public let variables: [String: String]
    public let shellPath: String

    /// Capture the user's interactive login shell environment.
    /// Spawns `$SHELL -l -i -c "env"` once and parses the output.
    public static func captureUserEnvironment() async throws -> ShellEnvironment {
        let shell = detectShellPath()
        let env = try await captureEnvironment(shellPath: shell)
        return ShellEnvironment(variables: env, shellPath: shell)
    }

    /// Use the current process environment as-is.
    /// Works when launched from a terminal, breaks from Xcode/Finder.
    public static func inherited() -> ShellEnvironment {
        ShellEnvironment(
            variables: ProcessInfo.processInfo.environment,
            shellPath: detectShellPath()
        )
    }

    /// Use caller-provided environment variables.
    public static func explicit(
        _ variables: [String: String],
        shellPath: String = "/bin/zsh"
    ) -> ShellEnvironment {
        ShellEnvironment(variables: variables, shellPath: shellPath)
    }

    // MARK: - Shell Detection

    /// Detect the user's shell: $SHELL → getpwuid → /bin/zsh fallback.
    /// Fish is not supported (incompatible syntax); falls back to /bin/zsh.
    static func detectShellPath() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"] {
            if shell.hasSuffix("/fish") {
                return "/bin/zsh"
            }
            return shell
        }

        // Try getpwuid
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if path.hasSuffix("/fish") {
                return "/bin/zsh"
            }
            return path
        }

        return "/bin/zsh"
    }

    // MARK: - Environment Capture

    private static func captureEnvironment(shellPath: String) async throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l", "-i", "-c", "env"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            throw ShellEnvironmentError.invalidOutput
        }

        return parseEnvironment(output)
    }

    /// Parse `KEY=VALUE\n` output from `env`.
    /// Handles values containing `=` by splitting on first `=` only.
    static func parseEnvironment(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentKey: String?
        var currentValue: String?

        for line in output.split(separator: "\n") {
            if let eqIndex = line.firstIndex(of: "=") {
                // Save previous entry if exists
                if let key = currentKey, let value = currentValue {
                    result[key] = value
                }

                let key = String(line[line.startIndex..<eqIndex])
                let value = String(line[line.index(after: eqIndex)...])

                // Only accept keys that look like env var names
                if !key.isEmpty && !key.contains(" ") {
                    currentKey = key
                    currentValue = value
                } else {
                    // Likely a continuation of previous value
                    if let prev = currentValue {
                        currentValue = prev + "\n" + String(line)
                    }
                }
            } else if currentKey != nil {
                // Continuation of multi-line value
                if let prev = currentValue {
                    currentValue = prev + "\n" + String(line)
                }
            }
        }

        // Save last entry
        if let key = currentKey, let value = currentValue {
            result[key] = value
        }

        return result
    }
}

public enum ShellEnvironmentError: Error, Sendable {
    case invalidOutput
}
