/// Web search tool using mock search client.

import Foundation
import Yrden

/// Web search tool for finding information.
///
/// Demonstrates an async tool that uses injected dependencies.
struct WebSearchTool: AgentTool {
    typealias Deps = AppDependencies
    typealias Args = SearchArgs
    typealias Output = String

    var name: String { "web_search" }
    var description: String {
        "Search the web for information. Returns relevant search results with titles and snippets."
    }

    func call(
        context: AgentContext<AppDependencies>,
        arguments: Args
    ) async throws -> ToolResult<String> {
        guard !arguments.query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .retry(message: "Query cannot be empty. Please provide a search query.")
        }

        let results = try await context.deps.searchClient.search(arguments.query)

        if results.isEmpty {
            return .success("No results found for: \(arguments.query)")
        }

        var output = "Search results for '\(arguments.query)':\n\n"
        for (index, result) in results.prefix(arguments.limit).enumerated() {
            output += "\(index + 1). \(result.title)\n"
            output += "   \(result.snippet)\n"
            output += "   URL: \(result.url)\n\n"
        }

        return .success(output)
    }
}

/// Arguments for web search.
@Schema(description: "Web search parameters")
struct SearchArgs {
    @Guide(description: "Search query terms")
    let query: String

    @Guide(description: "Maximum number of results to return (1-10)")
    let limit: Int
}

extension SearchArgs {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.query = try container.decode(String.self, forKey: .query)
        // Default to 5 if not provided
        self.limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 5
    }

    enum CodingKeys: String, CodingKey {
        case query, limit
    }
}
