/// Subprocess-based stdio transport for MCP servers.
///
/// Spawns and manages a subprocess that communicates via stdin/stdout
/// using the MCP JSON-RPC protocol.

import Foundation
import MCP
import Logging

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

#if canImport(Darwin)
    import Darwin.POSIX
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

// MARK: - Environment Utilities

/// Augment PATH with common binary locations for MCP servers.
///
/// GUI apps don't inherit the shell's PATH, so we add common locations
/// for package managers and binary directories.
///
/// - Parameter baseEnvironment: Starting environment (defaults to process environment)
/// - Returns: Environment dictionary with augmented PATH
public func augmentedEnvironment(
    from baseEnvironment: [String: String]? = nil
) -> [String: String] {
    var env = baseEnvironment ?? ProcessInfo.processInfo.environment

    let home = env["HOME"] ?? NSHomeDirectory()
    let additionalPaths = [
        "/opt/homebrew/bin",              // Homebrew on Apple Silicon
        "/usr/local/bin",                 // Homebrew on Intel / traditional
        "\(home)/.local/bin",             // pip/pipx installed (uvx)
        "\(home)/.nvm/current/bin",       // nvm managed node
        "/usr/local/share/npm/bin",       // npm global installs
        "\(home)/.npm-global/bin",        // npm global prefix
        "\(home)/.volta/bin",             // Volta node manager
        "/usr/bin",
        "/bin"
    ]

    let currentPath = env["PATH"] ?? "/usr/bin:/bin"
    env["PATH"] = (additionalPaths + [currentPath]).joined(separator: ":")

    return env
}

// MARK: - SubprocessStdioTransport

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)

/// A stdio transport that spawns and manages a subprocess.
///
/// Uses non-blocking I/O with proper async/await integration.
actor SubprocessStdioTransport: Transport {
    nonisolated let logger: Logger

    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let stdinFD: FileDescriptor
    private let stdoutFD: FileDescriptor

    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    /// Optional callback for logging (stderr and debug messages)
    private let logCallback: (@Sendable (String) -> Void)?

    init(
        command: String,
        arguments: [String],
        environment: [String: String]?,
        logCallback: (@Sendable (String) -> Void)? = nil
    ) throws {
        self.logCallback = logCallback
        self.logger = Logger(
            label: "mcp.transport.subprocess",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
        self.process = Process()
        self.stdinPipe = Pipe()
        self.stdoutPipe = Pipe()
        self.stderrPipe = Pipe()

        // Get file descriptors from pipes
        self.stdinFD = FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        self.stdoutFD = FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor)

        // Configure process
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Use augmented environment
        var env = augmentedEnvironment()
        if let additional = environment {
            env.merge(additional) { _, new in new }
        }
        process.environment = env

        // Create message stream
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    /// Helper to log messages via callback
    private func debugLog(_ message: String) {
        logger.debug("\(message)")
        logCallback?(message)
    }

    func connect() async throws {
        guard !isConnected else { return }

        debugLog("[Subprocess] Starting process...")

        // Start the process
        try process.run()

        // Start stderr reading (non-blocking via readabilityHandler)
        startStderrReader()

        // Give the subprocess time to initialize
        // uvx/npx may need to download packages on first run
        debugLog("[Subprocess] Waiting for initialization...")
        try await Task.sleep(for: .milliseconds(500))

        // Check if process is still running
        guard process.isRunning else {
            // Try to read stderr for error message
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
            debugLog("[Subprocess] FAILED: \(stderrText)")
            throw MCPError.internalError("Subprocess exited immediately: \(stderrText)")
        }

        // Set non-blocking mode on stdout for reading
        try setNonBlocking(fileDescriptor: stdoutFD)

        isConnected = true
        debugLog("[Subprocess] Transport connected, starting read loop")

        // Start reading loop in background
        Task {
            await readLoop()
        }
    }

    /// Read stderr and log it (runs in background)
    /// Uses readabilityHandler to avoid blocking the actor
    private func startStderrReader() {
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return
            }
            // Log via callback (can't access actor from here, so use callback directly)
            self?.logCallback?("[Subprocess stderr] \(text)")
        }
    }

    /// Stop stderr reader
    private func stopStderrReader() {
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    private func setNonBlocking(fileDescriptor: FileDescriptor) throws {
        let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
        guard flags >= 0 else {
            throw MCPError.transportError(Errno(rawValue: CInt(errno)))
        }

        let result = fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK)
        guard result >= 0 else {
            throw MCPError.transportError(Errno(rawValue: CInt(errno)))
        }
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false

        // Stop stderr reader
        stopStderrReader()

        // Finish the message stream first
        messageContinuation.finish()

        // Close the write end of stdin to signal EOF to the process
        try? stdinPipe.fileHandleForWriting.close()

        // Give the process a moment to exit gracefully
        try? await Task.sleep(for: .milliseconds(100))

        // Terminate the process if still running
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        logger.debug("Subprocess transport disconnected")
    }

    func send(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.transportError(Errno(rawValue: ENOTCONN))
        }

        // Add newline as delimiter
        var messageWithNewline = data
        messageWithNewline.append(UInt8(ascii: "\n"))

        // Write to stdin using byte array copy to avoid closure issues
        var remaining = Array(messageWithNewline)
        while !remaining.isEmpty {
            do {
                let written = try remaining.withUnsafeBytes { buffer in
                    try stdinFD.write(UnsafeRawBufferPointer(buffer))
                }
                if written > 0 {
                    remaining.removeFirst(written)
                }
            } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                // EAGAIN/EWOULDBLOCK - sleep and retry
                try await Task.sleep(for: .milliseconds(10))
                continue
            } catch {
                throw MCPError.transportError(error)
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return messageStream
    }

    private func readLoop() async {
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var pendingData = Data()

        while isConnected && !Task.isCancelled {
            // Check if process is still running
            if !process.isRunning {
                // Process died - read any remaining stderr and report error
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No error message"
                logger.error("Subprocess exited unexpectedly", metadata: ["stderr": "\(stderrText)"])
                messageContinuation.finish(throwing: MCPError.internalError("Subprocess exited: \(stderrText)"))
                return
            }

            do {
                let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
                    try stdoutFD.read(into: UnsafeMutableRawBufferPointer(pointer))
                }

                if bytesRead == 0 {
                    logger.notice("EOF received from subprocess")
                    // Check stderr for error message
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !stderrText.isEmpty {
                        messageContinuation.finish(throwing: MCPError.internalError("Subprocess closed: \(stderrText)"))
                    } else {
                        messageContinuation.finish(throwing: MCPError.internalError("Subprocess closed connection"))
                    }
                    return
                }

                pendingData.append(Data(buffer[..<bytesRead]))

                // Process complete messages (newline-delimited)
                while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                    let messageData = pendingData[..<newlineIndex]
                    pendingData = Data(pendingData[(newlineIndex + 1)...])

                    if !messageData.isEmpty {
                        logger.trace("Message received", metadata: ["size": "\(messageData.count)"])
                        messageContinuation.yield(Data(messageData))
                    }
                }
            } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                // EAGAIN/EWOULDBLOCK - no data available, sleep briefly and retry
                try? await Task.sleep(for: .milliseconds(10))
                continue
            } catch {
                if !Task.isCancelled {
                    logger.error("Read error occurred", metadata: ["error": "\(error)"])
                    messageContinuation.finish(throwing: MCPError.transportError(error))
                } else {
                    messageContinuation.finish()
                }
                return
            }
        }

        messageContinuation.finish()
    }
}

#endif
