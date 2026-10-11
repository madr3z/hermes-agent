import Foundation

public struct MCPConnection: Identifiable, Sendable {
    public let name: String
    public let transport: String
    public let target: String
    public let auth: String
    public let authorized: Bool
    public let enabled: Bool
    public let plugin: String?
    public let accountInstanceID: String?
    public let provider: String
    public let label: String
    public let requestedIdentity: String
    public let verifiedIdentity: String?
    public let status: String
    public var id: String { accountInstanceID ?? name }
    public init(_ row: JSON) {
        name = row["name"].string ?? ""
        accountInstanceID = row["account_instance_id"].string
        provider = row["provider"].string ?? "custom-mcp"
        label = row["label"].string ?? name
        requestedIdentity = row["requested_identity"].string ?? ""
        verifiedIdentity = row["verified_identity"].string
        status = row["runtime_status"].string ?? "configured"
        transport = row["transport"].string ?? "unknown"
        target = row["url"].string ?? row["command"].string ?? ""
        auth = row["auth"].string ?? "none"
        authorized = row["oauth_tokens_present"].bool
        enabled = row["enabled"].bool
        plugin = row["source"].string == "plugin" ? row["plugin"].string : nil
    }
}

public struct HostedConnection: Identifiable, Sendable {
    public let id: String
    public let connector: String
    public let label: String
    public let alias: String?
    public let status: String
    public let active: Bool
    public init(_ row: JSON) {
        id = row["connection_id"].string ?? ""
        connector = row["connector"].string ?? ""
        label = row["label"].string ?? connector
        alias = row["alias"].string
        status = row["status"].string ?? "unknown"
        active = row["active"].bool
    }
}

public struct InstalledPlugin: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let status: String
    public let source: String
    public let settings: [JSON]
    public init(_ row: JSON) {
        id = row["key"].string ?? row["name"].string ?? ""
        name = row["name"].string ?? ""
        description = row["description"].string ?? ""
        status = row["status"].string ?? "unknown"
        source = row["source"].string ?? "unknown"
        settings = row["settings_schema"].array
    }
}

public struct CatalogPlugin: Identifiable, Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let repo: String
    public let sha: String
    public let tier: String
    public let platforms: [String]
    public let installed: Bool
    public let capabilities: String
    public var id: String { name }
    public init(_ row: JSON) {
        name = row["name"].string ?? ""
        title = row["title"].string.flatMap { $0.isEmpty ? nil : $0 } ?? name
        description = row["description"].string ?? ""
        repo = row["repo"].string ?? ""
        sha = row["sha"].string ?? ""
        tier = row["tier"].string ?? "community"
        platforms = row["platforms"].array.compactMap(\.string)
        installed = row["installed"].bool
        capabilities = row["capability_summary"].string ?? ""
    }
}

public struct MCPConnectionDraft: Sendable {
    public var name = ""
    public let accountInstanceID: UUID
    public var provider = "custom-mcp"
    public var requestedIdentity = ""
    public var serverName: String { "account-" + accountInstanceID.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    public var transport = "http"
    public var target = ""
    public var arguments = ""
    public var bearer = ""
    public var oauth = false
    public init(accountInstanceID: UUID = UUID()) { self.accountInstanceID = accountInstanceID }
    public func parameters(existingNames: [String] = []) throws -> [String: JSON] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw GatewayError.message("Enter an account label of 1 to 120 printable characters.")
        }
        guard provider.range(of: "^[a-z0-9][a-z0-9._-]{0,95}$", options: .regularExpression) != nil else {
            throw GatewayError.message("Use a provider ID with lowercase letters, digits, dots, underscores or hyphens.")
        }
        guard !existingNames.contains(serverName) else {
            throw GatewayError.message("This account was already saved. Refresh before starting another setup.")
        }
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw GatewayError.message("Enter the server URL or command.") }
        var config: [String: JSON]
        if transport == "http" {
            guard let url = URL(string: target), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil else {
                throw GatewayError.message("Enter an HTTPS MCP URL without credentials or a fragment.")
            }
            config = ["url": .string(target)]
            if oauth { config["auth"] = .string("oauth") }
        } else {
            config = ["command": .string(target), "args": .array(arguments.components(separatedBy: .newlines).filter { !$0.isEmpty }.map(JSON.string))]
        }
        config["account_instance"] = .object([
            "id": .string(accountInstanceID.uuidString.lowercased()), "provider": .string(provider),
            "label": .string(name), "requested_identity": .string(requestedIdentity.trimmingCharacters(in: .whitespacesAndNewlines))
        ])
        var params: [String: JSON] = ["name": .string(serverName), "config": .object(config)]
        if transport == "http", !oauth, !bearer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["bearer_token"] = .string(bearer.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return params
    }
}

public struct PluginInstallReview: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let description: String
    public let repo: String
    public let sha: String
    public let catalogName: String?
    public init(catalog: CatalogPlugin) {
        title = catalog.title; description = catalog.description + (catalog.capabilities.isEmpty ? "" : "\n\n" + catalog.capabilities)
        repo = catalog.repo; sha = catalog.sha; catalogName = catalog.name
    }
    public init(repo: String, sha: String) throws {
        let repo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let sha = sha.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let url = URL(string: repo), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw GatewayError.message("Enter the HTTPS Git repository URL without credentials, query parameters or a fragment.")
        }
        guard sha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw GatewayError.message("Enter a full 40-character commit SHA to pin the custom plugin.")
        }
        self.repo = repo; self.sha = sha; catalogName = nil
        title = url.lastPathComponent
        description = "Custom source. This plugin can run code and access this bot's files and credentials. It is not reviewed by the Hermes catalog."
    }
    public var parameters: [String: JSON] {
        var params: [String: JSON] = ["action": .string("install"), "enable": .bool(true), "force": .bool(false), "ref": .string(sha)]
        if let catalogName { params["catalog_name"] = .string(catalogName) }
        else { params["identifier"] = .string(repo) }
        return params
    }
}

@MainActor public final class BotConnectorsClient {
    public typealias Request = (String, [String: JSON]) async throws -> JSON
    private let profile: String
    private let request: Request
    public init(profile: String, request: @escaping Request) {
        self.profile = profile; self.request = request
    }
    public func call(_ method: String, _ params: [String: JSON] = [:]) async throws -> JSON {
        var params = params; params["profile"] = .string(profile)
        return try await request(method, params)
    }
    public func mcpServers() async throws -> [MCPConnection] {
        let rows = try await call("mcp.servers.list")["servers"].array
        let statuses = try await call("mcp.servers.status")["servers"].array
        return rows.map { row in
            guard case .object(var fields) = row else { return MCPConnection(row) }
            fields["runtime_status"] = statuses.first { $0["name"] == row["name"] }?["status"]
            return MCPConnection(.object(fields))
        }
    }
    public func plugins() async throws -> [InstalledPlugin] {
        try await call("plugins.manage", ["action": .string("list")])["plugins"].array.map(InstalledPlugin.init)
    }
    public func catalog() async throws -> [CatalogPlugin] {
        try await call("plugins.catalog")["entries"].array.map(CatalogPlugin.init)
    }
    public func hostedAccounts() async throws -> [HostedConnection] {
        let list = try await call("connectors.list", ["owner": .object(["type": .string("account")])])
        guard list["available"].bool else { throw GatewayError.message("Hosted connectors are not available for this bot's account.") }
        return try await call("connectors.accounts")["accounts"].array.map(HostedConnection.init)
    }
    public func addMCP(_ draft: MCPConnectionDraft) async throws -> JSON {
        let existing = try await mcpServers().map(\.name)
        return try await call("mcp.servers.add", draft.parameters(existingNames: existing))
    }
    public func install(_ review: PluginInstallReview) async throws -> JSON {
        try await call("plugins.manage", review.parameters)
    }
}
