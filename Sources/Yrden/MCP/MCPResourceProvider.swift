/// MCP Resource Provider for context injection.
///
/// Fetches resources from MCP servers and formats them for inclusion
/// in agent system prompts or message context.
///
/// ## Usage
/// ```swift
/// let resourceProvider = MCPResourceProvider(manager: mcpManager)
///
/// // Fetch specific resources
/// let context = try await resourceProvider.fetchContext(uris: [
///     "file:///path/to/config.json",
///     "db://users/schema"
/// ])
///
/// // Use in agent system prompt
/// let agent = Agent<Void, String>(
///     model: model,
///     systemPrompt: """
///     You have access to the following context:
///     \(context)
///     """
/// )
/// ```

import Foundation
import MCP

// MARK: - MCPResourceProvider

/// Provides MCP resources as context for agent runs.
///
/// Fetches resources from connected MCP servers and formats them
/// for injection into system prompts or messages.
public actor MCPResourceProvider {
    /// The MCP manager providing server connections.
    private let manager: MCPManager

    /// Create a resource provider.
    ///
    /// - Parameter manager: MCP manager with server connections
    public init(manager: MCPManager) {
        self.manager = manager
    }

    // MARK: - Resource Fetching

    /// Fetch resources and format as context string.
    ///
    /// - Parameters:
    ///   - uris: Resource URIs to fetch
    ///   - format: Output format (default: markdown)
    /// - Returns: Formatted context string
    /// - Throws: If resource fetching fails
    public func fetchContext(
        uris: [String],
        format: ContextFormat = .markdown
    ) async throws -> String {
        // Find which server has each resource
        let allResources = try await manager.allResources()
        let resourceMap = Dictionary(
            allResources.map { ($0.resource.uri, $0.serverID) },
            uniquingKeysWith: { first, _ in first }
        )

        var contents: [FetchedResource] = []

        for uri in uris {
            guard let serverID = resourceMap[uri] else {
                contents.append(FetchedResource(
                    uri: uri,
                    serverID: nil,
                    content: nil,
                    error: "Resource not found"
                ))
                continue
            }

            do {
                let resourceContents = try await manager.readResource(uri: uri, from: serverID)
                let text = resourceContents.compactMap { content -> String? in
                    if let text = content.text {
                        return text
                    } else if let blob = content.blob {
                        return "[Binary data: \(blob.count) bytes]"
                    }
                    return nil
                }.joined(separator: "\n")

                contents.append(FetchedResource(
                    uri: uri,
                    serverID: serverID,
                    content: text,
                    error: nil
                ))
            } catch {
                contents.append(FetchedResource(
                    uri: uri,
                    serverID: serverID,
                    content: nil,
                    error: error.localizedDescription
                ))
            }
        }

        return format.render(contents)
    }

    /// Fetch all resources from a server as context.
    ///
    /// - Parameters:
    ///   - serverID: Server to fetch from
    ///   - format: Output format
    /// - Returns: Formatted context string
    public func fetchAllContext(
        from serverID: String,
        format: ContextFormat = .markdown
    ) async throws -> String {
        guard let server = await manager.server(serverID) else {
            throw MCPManagerError.serverNotFound(serverID)
        }

        let resources = try await server.listResources()
        var contents: [FetchedResource] = []

        for resource in resources {
            do {
                let resourceContents = try await server.readResource(uri: resource.uri)
                let text = resourceContents.compactMap { content -> String? in
                    if let text = content.text {
                        return text
                    }
                    return nil
                }.joined(separator: "\n")

                contents.append(FetchedResource(
                    uri: resource.uri,
                    serverID: serverID,
                    content: text,
                    error: nil,
                    name: resource.name,
                    mimeType: resource.mimeType
                ))
            } catch {
                contents.append(FetchedResource(
                    uri: resource.uri,
                    serverID: serverID,
                    content: nil,
                    error: error.localizedDescription,
                    name: resource.name
                ))
            }
        }

        return format.render(contents)
    }

    /// List available resources without fetching content.
    ///
    /// - Returns: Array of resource info with server IDs
    public func listAvailableResources() async throws -> [ResourceInfo] {
        let allResources = try await manager.allResources()
        return allResources.map { serverID, resource in
            ResourceInfo(
                uri: resource.uri,
                name: resource.name,
                description: resource.description,
                mimeType: resource.mimeType,
                serverID: serverID
            )
        }
    }
}

// MARK: - Supporting Types

/// Information about an available resource.
public struct ResourceInfo: Sendable {
    /// Resource URI.
    public let uri: String
    /// Resource name.
    public let name: String
    /// Resource description.
    public let description: String?
    /// MIME type.
    public let mimeType: String?
    /// Server providing this resource.
    public let serverID: String
}

/// A fetched resource with content or error.
fileprivate struct FetchedResource {
    let uri: String
    let serverID: String?
    let content: String?
    let error: String?
    var name: String?
    var mimeType: String?
}

// MARK: - Context Format

/// Format for rendering resources as context.
public enum ContextFormat: Sendable {
    /// Markdown format with headers and code blocks.
    case markdown

    /// Plain text with simple separators.
    case plainText

    /// XML-style tags.
    case xml

    /// Custom format with template.
    case custom(@Sendable (String, String?, String?) -> String)

    /// Render fetched resources.
    fileprivate func render(_ resources: [FetchedResource]) -> String {
        switch self {
        case .markdown:
            return renderMarkdown(resources)
        case .plainText:
            return renderPlainText(resources)
        case .xml:
            return renderXML(resources)
        case .custom(let formatter):
            return resources.map { resource in
                if let error = resource.error {
                    return formatter(resource.uri, nil, error)
                }
                return formatter(resource.uri, resource.content, nil)
            }.joined(separator: "\n\n")
        }
    }

    private func renderMarkdown(_ resources: [FetchedResource]) -> String {
        resources.map { resource in
            var parts: [String] = []

            // Header
            let name = resource.name ?? resource.uri
            parts.append("## \(name)")

            if let error = resource.error {
                parts.append("> Error: \(error)")
            } else if let content = resource.content {
                // Determine code block language from mime type
                let lang = mimeTypeToLanguage(resource.mimeType)
                parts.append("```\(lang)")
                parts.append(content)
                parts.append("```")
            }

            return parts.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func renderPlainText(_ resources: [FetchedResource]) -> String {
        resources.map { resource in
            var parts: [String] = []

            let name = resource.name ?? resource.uri
            parts.append("=== \(name) ===")

            if let error = resource.error {
                parts.append("Error: \(error)")
            } else if let content = resource.content {
                parts.append(content)
            }

            return parts.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func renderXML(_ resources: [FetchedResource]) -> String {
        var xml = "<resources>\n"

        for resource in resources {
            xml += "  <resource uri=\"\(escapeXML(resource.uri))\">\n"

            if let error = resource.error {
                xml += "    <error>\(escapeXML(error))</error>\n"
            } else if let content = resource.content {
                xml += "    <content><![CDATA[\(content)]]></content>\n"
            }

            xml += "  </resource>\n"
        }

        xml += "</resources>"
        return xml
    }

    private func mimeTypeToLanguage(_ mimeType: String?) -> String {
        guard let mime = mimeType else { return "" }

        switch mime {
        case "application/json": return "json"
        case "application/xml", "text/xml": return "xml"
        case "text/html": return "html"
        case "text/css": return "css"
        case "text/javascript", "application/javascript": return "javascript"
        case "text/typescript": return "typescript"
        case "text/x-python": return "python"
        case "text/x-swift": return "swift"
        case "text/x-rust": return "rust"
        case "text/x-go": return "go"
        case "text/x-java": return "java"
        case "text/markdown": return "markdown"
        case "text/yaml", "application/yaml": return "yaml"
        case "text/x-sql": return "sql"
        default:
            if mime.hasPrefix("text/") {
                return ""
            }
            return ""
        }
    }

    private func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
