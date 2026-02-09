/// Content-based find-and-replace file editing.
///
/// Finds exact matches of `old_string` in a file and replaces them with `new_string`.
/// When `replace_all` is false, requires exactly one match (uniqueness enforcement).
/// Returns descriptive error messages for LLM self-correction.

import Foundation

@Schema(description: "Edit a file by replacing exact string matches")
public struct EditFileArgs {
    @Guide(description: "Absolute path to the file to edit")
    public let path: String

    @Guide(description: "The exact text to find in the file")
    public let oldString: String

    @Guide(description: "The text to replace it with")
    public let newString: String

    @Guide(description: "Replace all occurrences (default: false, requires unique match)")
    public let replaceAll: Bool

    private enum CodingKeys: String, CodingKey {
        case path
        case oldString = "old_string"
        case newString = "new_string"
        case replaceAll = "replace_all"
    }
}

public struct EditFileTool: TypedTool {
    public typealias Args = EditFileArgs

    public let name = "edit_file"
    public let description = "Edit a file by finding and replacing exact string matches. Supports ~ (tilde) and relative paths. When replace_all is false, the old_string must appear exactly once (for safety)."

    public let pathValidator: PathValidator
    public let maxFileSize: Int

    public init(
        pathValidator: PathValidator,
        maxFileSize: Int = 10_000_000
    ) {
        self.pathValidator = pathValidator
        self.maxFileSize = maxFileSize
    }

    public func execute(
        context: ToolContext,
        arguments: EditFileArgs
    ) async throws -> ToolResult<String> {
        // Validate old_string is not empty
        guard !arguments.oldString.isEmpty else {
            return .error("old_string is empty. A non-empty string is required.")
        }

        // Validate old != new
        guard arguments.oldString != arguments.newString else {
            return .error("old_string and new_string are the same. No edit needed.")
        }

        // Resolve path
        let resolvedPath: String
        do {
            resolvedPath = try pathValidator.validateWrite(arguments.path)
        } catch {
            return .failure(error)
        }

        // Check file exists
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return .error("File not found: \(arguments.path)")
        }

        // Check file size
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: resolvedPath)
            if let size = attrs[.size] as? UInt64, size > maxFileSize {
                return .error("File is too large (\(size) bytes). Maximum size is \(maxFileSize) bytes.")
            }
        } catch {
            return .error("Cannot read file attributes: \(error.localizedDescription)")
        }

        // Read content
        let content: String
        do {
            content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
        } catch {
            return .error("Failed to read file: \(error.localizedDescription)")
        }

        // Count occurrences
        let occurrences = countOccurrences(of: arguments.oldString, in: content)

        if occurrences == 0 {
            return .error("old_string not found in \(arguments.path). Make sure the string matches exactly, including whitespace and line endings.")
        }

        if !arguments.replaceAll && occurrences > 1 {
            return .error("Found \(occurrences) matches of old_string. Use replace_all: true to replace all, or provide more context to make the match unique.")
        }

        // Perform replacement
        let newContent: String
        if arguments.replaceAll {
            newContent = content.replacingOccurrences(of: arguments.oldString, with: arguments.newString)
        } else {
            // Replace only the first (and only) occurrence
            guard let range = content.range(of: arguments.oldString) else {
                return .error("old_string not found in \(arguments.path)")
            }
            newContent = content.replacingCharacters(in: range, with: arguments.newString)
        }

        // Write atomically
        do {
            try newContent.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
        } catch {
            return .error("Failed to write file: \(error.localizedDescription)")
        }

        if arguments.replaceAll && occurrences > 1 {
            return .success("Successfully replaced \(occurrences) occurrences in \(arguments.path)")
        }
        return .success("Successfully replaced 1 occurrence in \(arguments.path)")
    }

    private func countOccurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }
}
