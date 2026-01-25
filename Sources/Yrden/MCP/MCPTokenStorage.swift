/// Token storage for MCP OAuth credentials.
///
/// Provides secure storage for OAuth tokens using the system Keychain
/// on Apple platforms.

import Foundation

#if canImport(Security)
import Security
#endif

// MARK: - MCPTokenStorage Protocol

/// Protocol for secure OAuth token storage.
public protocol MCPTokenStorage: Sendable {
    /// Store tokens for a server.
    func store(tokens: MCPOAuthTokens, for serverID: String) async throws

    /// Retrieve tokens for a server.
    func retrieve(for serverID: String) async throws -> MCPOAuthTokens?

    /// Delete tokens for a server.
    func delete(for serverID: String) async throws

    /// List all server IDs with stored tokens.
    func listServerIDs() async throws -> [String]
}

// MARK: - KeychainTokenStorage

#if canImport(Security)

/// Token storage using the system Keychain.
///
/// Stores OAuth tokens securely in the macOS/iOS Keychain.
/// Tokens are stored as JSON data under a service identifier.
public actor KeychainTokenStorage: MCPTokenStorage {
    /// Service identifier for Keychain items.
    private let service: String

    /// Access group for shared Keychain access (optional).
    private let accessGroup: String?

    /// Default service identifier for MCP tokens.
    public static let defaultService = "com.yrden.mcp-tokens"

    /// Create a Keychain token storage with default service.
    ///
    /// Uses "com.yrden.mcp-tokens" as the service identifier.
    public init() {
        self.service = Self.defaultService
        self.accessGroup = nil
    }

    /// Create a Keychain token storage.
    ///
    /// - Parameters:
    ///   - service: Service identifier (e.g., "com.myapp.mcp-tokens")
    ///   - accessGroup: Optional access group for sharing between apps
    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func store(tokens: MCPOAuthTokens, for serverID: String) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(tokens)

        // Delete existing item first
        try? await delete(for: serverID)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MCPOAuthError.storageError("Keychain store failed: \(status)")
        }
    }

    public func retrieve(for serverID: String) async throws -> MCPOAuthTokens? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            throw MCPOAuthError.storageError("Keychain retrieve failed: \(status)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MCPOAuthTokens.self, from: data)
    }

    public func delete(for serverID: String) async throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MCPOAuthError.storageError("Keychain delete failed: \(status)")
        }
    }

    public func listServerIDs() async throws -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw MCPOAuthError.storageError("Keychain list failed: \(status)")
        }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

#endif

// MARK: - InMemoryTokenStorage

/// In-memory token storage for testing.
///
/// Tokens are not persisted and will be lost when the app terminates.
public actor InMemoryTokenStorage: MCPTokenStorage {
    private var tokens: [String: MCPOAuthTokens] = [:]

    public init() {}

    public func store(tokens: MCPOAuthTokens, for serverID: String) async throws {
        self.tokens[serverID] = tokens
    }

    public func retrieve(for serverID: String) async throws -> MCPOAuthTokens? {
        tokens[serverID]
    }

    public func delete(for serverID: String) async throws {
        tokens.removeValue(forKey: serverID)
    }

    public func listServerIDs() async throws -> [String] {
        Array(tokens.keys)
    }
}

// MARK: - FileTokenStorage

/// File-based token storage (for Linux or testing).
///
/// Stores tokens as JSON files in a directory. Not encrypted by default.
public actor FileTokenStorage: MCPTokenStorage {
    /// Directory to store token files.
    private let directory: URL

    /// Create a file-based token storage.
    ///
    /// - Parameter directory: Directory to store token files
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func tokenFile(for serverID: String) -> URL {
        // Sanitize server ID for filename
        let safe = serverID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? serverID
        return directory.appendingPathComponent("\(safe).json")
    }

    public func store(tokens: MCPOAuthTokens, for serverID: String) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(tokens)
        try data.write(to: tokenFile(for: serverID))
    }

    public func retrieve(for serverID: String) async throws -> MCPOAuthTokens? {
        let file = tokenFile(for: serverID)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }

        let data = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MCPOAuthTokens.self, from: data)
    }

    public func delete(for serverID: String) async throws {
        let file = tokenFile(for: serverID)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    public func listServerIDs() async throws -> [String] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .compactMap { $0.removingPercentEncoding }
    }
}
