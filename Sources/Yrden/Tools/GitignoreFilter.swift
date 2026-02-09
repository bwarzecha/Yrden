/// Pattern matching for .gitignore rules.
///
/// Supports standard gitignore patterns: wildcards, double-star, negation,
/// directory-only, and rooted patterns. Always excludes `.git/` and `.DS_Store`.

import Foundation

public final class GitignoreFilter: Sendable {

    private let rules: [GitignoreRule]
    private let parentFilter: GitignoreFilter?

    private static let alwaysExcluded = [".git", ".DS_Store"]

    /// Create a filter from an array of pattern strings (as in a .gitignore file).
    public init(patterns: [String]) {
        self.rules = patterns.compactMap { GitignoreRule(pattern: $0) }
        self.parentFilter = nil
    }

    /// Create a filter by reading a `.gitignore` file from a directory.
    /// If no `.gitignore` exists, creates an empty filter.
    public init(directory: String, parentFilter: GitignoreFilter? = nil) throws {
        self.parentFilter = parentFilter
        let gitignorePath = (directory as NSString).appendingPathComponent(".gitignore")
        if FileManager.default.fileExists(atPath: gitignorePath) {
            let content = try String(contentsOfFile: gitignorePath, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            self.rules = lines.compactMap { GitignoreRule(pattern: $0) }
        } else {
            self.rules = []
        }
    }

    /// Check if a path should be ignored.
    public func isIgnored(path: String, isDirectory: Bool) -> Bool {
        // Always exclude .git and .DS_Store
        for name in Self.alwaysExcluded {
            let basename = (path as NSString).lastPathComponent
            if basename == name { return true }
            if path == name || path.hasPrefix(name + "/") { return true }
        }

        if let parent = parentFilter {
            // Start with parent's verdict, then apply local rules (last match wins)
            var result = parent.isIgnored(path: path, isDirectory: isDirectory)
            for rule in rules {
                if rule.matches(path: path, isDirectory: isDirectory) {
                    result = !rule.isNegation
                }
            }
            return result
        }

        // Evaluate rules in order — last match wins
        var ignored = false
        for rule in rules {
            if rule.matches(path: path, isDirectory: isDirectory) {
                ignored = !rule.isNegation
            }
        }
        return ignored
    }
}

// MARK: - GitignoreRule

struct GitignoreRule: Sendable {
    let isNegation: Bool
    let isDirectoryOnly: Bool
    let isRooted: Bool
    let cleanPattern: String

    init?(pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        var p = trimmed
        self.isNegation = p.hasPrefix("!")
        if isNegation { p = String(p.dropFirst()) }

        self.isDirectoryOnly = p.hasSuffix("/")
        if isDirectoryOnly { p = String(p.dropLast()) }

        // Patterns with "/" in the middle (or leading /) are rooted
        let hasSlash = p.hasPrefix("/") || (p.contains("/") && !p.hasPrefix("**/"))
        self.isRooted = hasSlash
        if p.hasPrefix("/") { p = String(p.dropFirst()) }

        self.cleanPattern = p
    }

    func matches(path: String, isDirectory: Bool) -> Bool {
        if isDirectoryOnly && !isDirectory { return false }

        if isRooted {
            return matchGlob(cleanPattern, path)
        }

        // Non-rooted: try matching basename, then full path
        if !cleanPattern.contains("/") {
            let basename = (path as NSString).lastPathComponent
            if matchGlob(cleanPattern, basename) { return true }
        }

        // Try full path match
        if matchGlob(cleanPattern, path) { return true }

        // Try with ** prefix for nested matching
        if !cleanPattern.contains("**") {
            return matchGlob("**/" + cleanPattern, path)
        }

        return false
    }

    private func matchGlob(_ pattern: String, _ path: String) -> Bool {
        if pattern.contains("**") {
            return matchDoubleStar(pattern, path)
        }
        return fnmatch(pattern, path, FNM_PATHNAME) == 0
    }

    private func matchDoubleStar(_ pattern: String, _ path: String) -> Bool {
        let parts = pattern.components(separatedBy: "**/")
        guard parts.count >= 2 else {
            return fnmatch(pattern, path, 0) == 0
        }

        let prefix = parts[0]
        let suffix = parts[1...].joined(separator: "**/")

        if prefix.isEmpty {
            // ** at start: match suffix against path or any subpath
            if fnmatch(suffix, path, FNM_PATHNAME) == 0 { return true }
            let components = path.components(separatedBy: "/")
            for i in 0..<components.count {
                let subpath = components[i...].joined(separator: "/")
                if fnmatch(suffix, subpath, FNM_PATHNAME) == 0 { return true }
            }
            return false
        }

        return fnmatch(pattern.replacingOccurrences(of: "**", with: "*"), path, 0) == 0
    }
}
