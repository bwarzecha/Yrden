/// Directory traversal with glob filtering, gitignore support, and binary detection.
///
/// Used by GlobTool to enumerate files matching patterns. Results include
/// relative paths and modification dates for sorting.

import Foundation

public struct FileEntry: Sendable {
    public let relativePath: String
    public let modificationDate: Date
}

public struct FileEnumerator: Sendable {

    public let rootDirectory: String
    public let pathValidator: PathValidator
    public let respectGitignore: Bool
    public let globPattern: String?
    public let maxResults: Int?
    public let skipBinaryFiles: Bool

    public init(
        rootDirectory: String,
        pathValidator: PathValidator,
        respectGitignore: Bool,
        globPattern: String? = nil,
        maxResults: Int? = nil,
        skipBinaryFiles: Bool = false
    ) {
        self.rootDirectory = rootDirectory
        self.pathValidator = pathValidator
        self.respectGitignore = respectGitignore
        self.globPattern = globPattern
        self.maxResults = maxResults
        self.skipBinaryFiles = skipBinaryFiles
    }

    public func enumerate() throws -> [FileEntry] {
        // Validate root directory
        _ = try pathValidator.validateRead(rootDirectory)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootDirectory, isDirectory: &isDir), isDir.boolValue else {
            throw FileEnumeratorError.directoryNotFound(rootDirectory)
        }

        // Resolve symlinks so enumerated paths match the root path.
        // macOS: NSTemporaryDirectory() = /var/... but FileManager resolves to /private/var/...
        let rootURL = URL(fileURLWithPath: rootDirectory).resolvingSymlinksInPath()
        let resolvedRoot = rootURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles.subtracting(.skipsHiddenFiles)] // Include hidden files
        ) else {
            return []
        }

        // Load gitignore filter if needed
        let gitignoreFilter: GitignoreFilter?
        if respectGitignore {
            gitignoreFilter = try? GitignoreFilter(directory: resolvedRoot)
        } else {
            gitignoreFilter = nil
        }

        // Always-skip filter for .git
        let alwaysSkipFilter = GitignoreFilter(patterns: [])

        var results: [FileEntry] = []

        for case let url as URL in enumerator {
            let resourceValues = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = resourceValues?.isDirectory ?? false
            let isFile = resourceValues?.isRegularFile ?? false

            // Compute relative path using resolved root
            let fullPath = url.resolvingSymlinksInPath().path
            let relativePath: String
            if fullPath.hasPrefix(resolvedRoot + "/") {
                relativePath = String(fullPath.dropFirst(resolvedRoot.count + 1))
            } else if fullPath == resolvedRoot {
                continue
            } else {
                relativePath = fullPath
            }

            // Always skip .git directory
            if alwaysSkipFilter.isIgnored(path: relativePath, isDirectory: isDirectory) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            // Gitignore filtering
            if let filter = gitignoreFilter, filter.isIgnored(path: relativePath, isDirectory: isDirectory) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            // Only include files, not directories
            guard isFile else { continue }

            // Binary filtering
            if skipBinaryFiles, isBinary(url: url) {
                continue
            }

            // Glob pattern matching
            if let pattern = globPattern {
                if !matchGlob(pattern: pattern, path: relativePath) {
                    continue
                }
            }

            let modDate = resourceValues?.contentModificationDate ?? Date.distantPast
            results.append(FileEntry(relativePath: relativePath, modificationDate: modDate))

            if let max = maxResults, results.count >= max {
                break
            }
        }

        return results
    }

    // MARK: - Private

    private func isBinary(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }
        guard let data = try? handle.read(upToCount: 8192) else { return false }
        return data.contains(0)
    }

    private func matchGlob(pattern: String, path: String) -> Bool {
        // Handle ** patterns
        if pattern.contains("**") {
            return matchDoubleStar(pattern: pattern, path: path)
        }

        // Handle brace expansion {a,b}
        if pattern.contains("{") {
            let expanded = expandBraces(pattern)
            return expanded.contains { fnmatch($0, path, FNM_PATHNAME) == 0 }
        }

        return fnmatch(pattern, path, FNM_PATHNAME) == 0
    }

    private func matchDoubleStar(pattern: String, path: String) -> Bool {
        let parts = pattern.components(separatedBy: "**/")
        guard parts.count >= 2 else {
            return fnmatch(pattern, path, 0) == 0
        }

        let prefix = parts[0]
        let suffix = parts[1...].joined(separator: "**/")

        // Handle brace expansion in suffix
        let suffixes = suffix.contains("{") ? expandBraces(suffix) : [suffix]

        for s in suffixes {
            if prefix.isEmpty {
                // **/ at start: match suffix against any subpath
                if fnmatch(s, path, FNM_PATHNAME) == 0 { return true }
                let components = path.components(separatedBy: "/")
                for i in 0..<components.count {
                    let subpath = components[i...].joined(separator: "/")
                    if fnmatch(s, subpath, FNM_PATHNAME) == 0 { return true }
                }
            } else {
                // Prefix before **: check path starts with prefix, then match
                // suffix against subpaths of the remainder
                guard path.hasPrefix(prefix) else { continue }
                let remainder = String(path.dropFirst(prefix.count))
                if fnmatch(s, remainder, FNM_PATHNAME) == 0 { return true }
                let components = remainder.components(separatedBy: "/")
                for i in 1..<components.count {
                    let subpath = components[i...].joined(separator: "/")
                    if fnmatch(s, subpath, FNM_PATHNAME) == 0 { return true }
                }
            }
        }

        return false
    }

    private func expandBraces(_ pattern: String) -> [String] {
        guard let openBrace = pattern.firstIndex(of: "{"),
              let closeBrace = pattern[openBrace...].firstIndex(of: "}") else {
            return [pattern]
        }

        let prefix = String(pattern[pattern.startIndex..<openBrace])
        let braceContent = String(pattern[pattern.index(after: openBrace)..<closeBrace])
        let suffix = String(pattern[pattern.index(after: closeBrace)...])

        let alternatives = braceContent.components(separatedBy: ",")
        return alternatives.flatMap { alt in
            expandBraces(prefix + alt + suffix)
        }
    }
}

// MARK: - Errors

public enum FileEnumeratorError: Error, LocalizedError {
    case directoryNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .directoryNotFound(let path):
            return "Directory not found: \(path)"
        }
    }
}
