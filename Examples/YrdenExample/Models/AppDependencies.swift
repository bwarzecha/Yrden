/// App dependencies for tool execution.

import Foundation

/// Dependencies injected into agent tools.
///
/// This struct provides access to services that tools need:
/// - SearchClient for web searches (mock implementation)
/// - Base directory for file operations
struct AppDependencies: Sendable {
    /// Search client for web searches.
    let searchClient: SearchClient

    /// Base directory for file operations.
    let baseDirectory: URL

    /// Create default dependencies.
    static func `default`() -> AppDependencies {
        let documentsPath = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        return AppDependencies(
            searchClient: MockSearchClient(),
            baseDirectory: documentsPath.appendingPathComponent("YrdenExample")
        )
    }
}

// MARK: - Search Client

/// Protocol for search operations.
protocol SearchClient: Sendable {
    func search(_ query: String) async throws -> [SearchResult]
}

/// A search result item.
struct SearchResult: Sendable {
    let title: String
    let snippet: String
    let url: String
}

/// Mock search client for demonstration.
struct MockSearchClient: SearchClient, Sendable {
    func search(_ query: String) async throws -> [SearchResult] {
        // Simulate network delay
        try await Task.sleep(for: .milliseconds(500))

        // Return mock results based on query
        let lowercased = query.lowercased()

        if lowercased.contains("swift") {
            return [
                SearchResult(
                    title: "Swift Programming Language",
                    snippet: "Swift is a powerful and intuitive programming language for iOS, macOS, and more.",
                    url: "https://swift.org"
                ),
                SearchResult(
                    title: "SwiftUI Documentation",
                    snippet: "Build user interfaces across all Apple platforms with Swift.",
                    url: "https://developer.apple.com/documentation/swiftui"
                ),
                SearchResult(
                    title: "The Swift Programming Language Book",
                    snippet: "The definitive guide to Swift, the modern programming language.",
                    url: "https://docs.swift.org/swift-book/"
                ),
            ]
        } else if lowercased.contains("weather") {
            return [
                SearchResult(
                    title: "Current Weather Conditions",
                    snippet: "Partly cloudy with a high of 72°F (22°C).",
                    url: "https://weather.example.com"
                ),
            ]
        } else {
            return [
                SearchResult(
                    title: "Search Results for: \(query)",
                    snippet: "Mock search results for demonstration purposes.",
                    url: "https://example.com/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
                ),
            ]
        }
    }
}
