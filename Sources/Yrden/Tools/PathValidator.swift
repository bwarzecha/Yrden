/// Application-level path validation for file tools.
///
/// Resolves paths to absolute, resolves symlinks via `realpath(3)`,
/// normalizes macOS aliases (`/var` → `/private/var`), then checks
/// against allowed and denied directory lists.
///
/// Denied directories take priority over allowed directories.

import Foundation

public struct PathValidator: Sendable {

    public let allowedReadDirectories: [String]
    public let allowedWriteDirectories: [String]
    public let deniedReadDirectories: [String]

    /// Working directory for resolving relative paths.
    /// When nil, falls back to process CWD (via URL(fileURLWithPath:)).
    public let workingDirectory: String?

    public init(
        allowedReadDirectories: [String] = ["/"],
        allowedWriteDirectories: [String],
        deniedReadDirectories: [String] = [],
        workingDirectory: String? = nil
    ) {
        self.allowedReadDirectories = allowedReadDirectories.map(Self.normalizeDirectory)
        self.allowedWriteDirectories = allowedWriteDirectories.map(Self.normalizeDirectory)
        self.deniedReadDirectories = deniedReadDirectories.map(Self.normalizeDirectory)
        self.workingDirectory = workingDirectory
    }

    /// Resolve and validate a path for reading.
    public func validateRead(_ path: String) throws -> String {
        let resolved = try resolvePath(path)

        if isWithin(resolved, directories: deniedReadDirectories) {
            throw PathValidationError.pathDenied(
                path: resolved,
                reason: "Path is in a denied directory"
            )
        }

        guard isWithin(resolved, directories: allowedReadDirectories) else {
            throw PathValidationError.pathOutsideAllowed(
                path: resolved,
                allowedDirectories: allowedReadDirectories
            )
        }

        return resolved
    }

    /// Resolve and validate a path for writing.
    public func validateWrite(_ path: String) throws -> String {
        let resolved = try resolvePath(path)

        guard isWithin(resolved, directories: allowedWriteDirectories) else {
            throw PathValidationError.pathOutsideAllowed(
                path: resolved,
                allowedDirectories: allowedWriteDirectories
            )
        }

        return resolved
    }

    // MARK: - Private

    private func resolvePath(_ path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath

        // Make absolute: relative paths resolve against workingDirectory (not process CWD)
        let absolutePath: String
        if expanded.hasPrefix("/") {
            absolutePath = URL(fileURLWithPath: expanded).standardized.path
        } else if let wd = workingDirectory {
            absolutePath = URL(fileURLWithPath: wd)
                .appendingPathComponent(expanded).standardized.path
        } else {
            absolutePath = URL(fileURLWithPath: expanded).standardized.path
        }

        // Resolve symlinks via realpath(3) if the path exists
        if let resolved = realpath(absolutePath, nil) {
            let result = String(cString: resolved)
            free(resolved)
            return result
        }

        // Path doesn't exist — resolve the nearest existing ancestor
        // to handle symlinks like /tmp → /private/tmp
        return resolveViaAncestor(absolutePath)
    }

    /// For non-existent paths, walk up to the nearest existing ancestor,
    /// resolve it via realpath, then append the remaining components.
    private func resolveViaAncestor(_ path: String) -> String {
        var url = URL(fileURLWithPath: path)
        var trailing: [String] = []

        while url.path != "/" {
            if let resolved = realpath(url.path, nil) {
                let base = String(cString: resolved)
                free(resolved)
                let result = trailing.reversed().reduce(base) { $0 + "/" + $1 }
                return result
            }
            trailing.append(url.lastPathComponent)
            url = url.deletingLastPathComponent()
        }

        // Nothing resolved — return the original path
        return path
    }

    private func isWithin(_ path: String, directories: [String]) -> Bool {
        directories.contains { dir in
            if dir == "/" { return true }
            return path == dir || path.hasPrefix(dir + "/")
        }
    }

    /// Normalize a directory path: expand tilde, resolve symlinks, apply /var fix.
    private static func normalizeDirectory(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var normalized = URL(fileURLWithPath: expanded).standardized.path

        if let resolved = realpath(normalized, nil) {
            normalized = String(cString: resolved)
            free(resolved)
        }

        if normalized.hasPrefix("/var/") || normalized == "/var" {
            normalized = "/private" + normalized
        }

        return normalized
    }
}

// MARK: - Errors

public enum PathValidationError: Error, Sendable, Equatable {
    case pathDenied(path: String, reason: String)
    case pathOutsideAllowed(path: String, allowedDirectories: [String])
}

extension PathValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .pathDenied(let path, let reason):
            return "Path denied: \(path) — \(reason)"
        case .pathOutsideAllowed(let path, let dirs):
            return "Path \(path) is outside allowed directories: \(dirs.joined(separator: ", "))"
        }
    }
}
