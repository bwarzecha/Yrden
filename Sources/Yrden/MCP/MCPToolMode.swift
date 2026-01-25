/// Tool Modes and Filters for MCP tool selection.
///
/// Tool modes define profiles of available tools. Filters provide
/// flexible criteria for selecting which tools to include.
///
/// ## Usage
/// ```swift
/// // Full access mode (all tools)
/// let allTools = manager.tools(for: .fullAccess)
///
/// // Custom mode with filter
/// let readOnlyMode = ToolMode(
///     id: "readonly",
///     name: "Read Only",
///     icon: "eye",
///     filter: .pattern("^(read|list|get)_.*")
/// )
/// let readTools = manager.tools(for: readOnlyMode)
///
/// // Combine filters
/// let filter: ToolFilter = .and([
///     .servers(["filesystem"]),
///     .not(.tools(["delete_file", "remove_directory"]))
/// ])
/// ```

import Foundation

// MARK: - ToolMode

/// A named profile defining which tools are available.
///
/// Tool modes enable UI selection of tool subsets. Each mode
/// has a filter that determines which tools are included.
public struct ToolMode: Identifiable, Codable, Sendable, Equatable {
    /// Unique identifier for this mode.
    public let id: String

    /// Display name for the mode.
    public let name: String

    /// SF Symbol name for the mode icon.
    public let icon: String

    /// Filter determining which tools are included.
    public let filter: ToolFilter

    public init(id: String, name: String, icon: String, filter: ToolFilter) {
        self.id = id
        self.name = name
        self.icon = icon
        self.filter = filter
    }
}

// MARK: - Predefined Modes

extension ToolMode {
    /// Full access mode - all tools from all servers.
    public static let fullAccess = ToolMode(
        id: "full",
        name: "Full Access",
        icon: "square.grid.3x3.fill",
        filter: .all
    )

    /// Read-only mode - tools matching read/list/get patterns.
    public static let readOnly = ToolMode(
        id: "readonly",
        name: "Read Only",
        icon: "eye",
        filter: .pattern("^(read|list|get|search|find|query)_")
    )

    /// No tools mode - empty tool set.
    public static let none = ToolMode(
        id: "none",
        name: "No Tools",
        icon: "xmark.circle",
        filter: .none
    )
}

// MARK: - ToolFilter

/// Filter criteria for selecting tools.
///
/// Filters can be combined with logical operators (.and, .or, .not)
/// to create complex selection criteria.
public enum ToolFilter: Codable, Sendable, Equatable {
    /// Include all tools.
    case all

    /// Include no tools.
    case none

    /// Include tools from specific servers.
    case servers([String])

    /// Include specific tools by name.
    case tools([String])

    /// Include specific tools by qualified ID (serverID.toolName).
    case toolIDs([String])

    /// Include tools matching regex pattern.
    case pattern(String)

    /// All filters must match.
    indirect case and([ToolFilter])

    /// Any filter must match.
    indirect case or([ToolFilter])

    /// Invert the filter.
    indirect case not(ToolFilter)

    /// Check if a tool entry matches this filter.
    ///
    /// - Parameter entry: Tool entry to check
    /// - Returns: True if the tool should be included
    public func matches(_ entry: ToolEntry) -> Bool {
        switch self {
        case .all:
            return true

        case .none:
            return false

        case .servers(let ids):
            return ids.contains(entry.serverID)

        case .tools(let names):
            return names.contains(entry.name)

        case .toolIDs(let ids):
            return ids.contains(entry.id)

        case .pattern(let regex):
            guard let regex = try? NSRegularExpression(pattern: regex, options: []) else {
                return false
            }
            let range = NSRange(entry.name.startIndex..., in: entry.name)
            return regex.firstMatch(in: entry.name, options: [], range: range) != nil

        case .and(let filters):
            return filters.allSatisfy { $0.matches(entry) }

        case .or(let filters):
            return filters.contains { $0.matches(entry) }

        case .not(let filter):
            return !filter.matches(entry)
        }
    }
}

// MARK: - ToolEntry

/// Entry representing a tool for filtering and display.
///
/// This is a lightweight view of a tool used for filtering
/// without holding the full tool implementation.
public struct ToolEntry: Identifiable, Sendable, Equatable {
    /// Qualified ID: "serverID.toolName".
    public var id: String { "\(serverID).\(name)" }

    /// Server this tool belongs to.
    public let serverID: String

    /// Tool name.
    public let name: String

    /// Tool description.
    public let description: String

    /// Tool definition (for creating proxies).
    public let definition: ToolDefinition

    public init(
        serverID: String,
        name: String,
        description: String,
        definition: ToolDefinition
    ) {
        self.serverID = serverID
        self.name = name
        self.description = description
        self.definition = definition
    }
}

// MARK: - Codable

extension ToolFilter {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum FilterType: String, Codable {
        case all
        case none
        case servers
        case tools
        case toolIDs
        case pattern
        case and
        case or
        case not
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(FilterType.self, forKey: .type)

        switch type {
        case .all:
            self = .all
        case .none:
            self = .none
        case .servers:
            let ids = try container.decode([String].self, forKey: .value)
            self = .servers(ids)
        case .tools:
            let names = try container.decode([String].self, forKey: .value)
            self = .tools(names)
        case .toolIDs:
            let ids = try container.decode([String].self, forKey: .value)
            self = .toolIDs(ids)
        case .pattern:
            let pattern = try container.decode(String.self, forKey: .value)
            self = .pattern(pattern)
        case .and:
            let filters = try container.decode([ToolFilter].self, forKey: .value)
            self = .and(filters)
        case .or:
            let filters = try container.decode([ToolFilter].self, forKey: .value)
            self = .or(filters)
        case .not:
            let filter = try container.decode(ToolFilter.self, forKey: .value)
            self = .not(filter)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .all:
            try container.encode(FilterType.all, forKey: .type)
        case .none:
            try container.encode(FilterType.none, forKey: .type)
        case .servers(let ids):
            try container.encode(FilterType.servers, forKey: .type)
            try container.encode(ids, forKey: .value)
        case .tools(let names):
            try container.encode(FilterType.tools, forKey: .type)
            try container.encode(names, forKey: .value)
        case .toolIDs(let ids):
            try container.encode(FilterType.toolIDs, forKey: .type)
            try container.encode(ids, forKey: .value)
        case .pattern(let pattern):
            try container.encode(FilterType.pattern, forKey: .type)
            try container.encode(pattern, forKey: .value)
        case .and(let filters):
            try container.encode(FilterType.and, forKey: .type)
            try container.encode(filters, forKey: .value)
        case .or(let filters):
            try container.encode(FilterType.or, forKey: .type)
            try container.encode(filters, forKey: .value)
        case .not(let filter):
            try container.encode(FilterType.not, forKey: .type)
            try container.encode(filter, forKey: .value)
        }
    }
}
