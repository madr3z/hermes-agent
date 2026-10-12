import Foundation

public struct AgentPluginRecord: Identifiable, Sendable {
    public let plugin: InstalledPlugin
    public let key: String?
    public let version: String
    public let installedSHA: String?
    public let pinnedSHA: String?
    public let catalogSHA: String?
    public let catalogName: String?
    public let updateAvailable: Bool
    public let hasDesktopHalf: Bool
    public var id: String { plugin.id }
    public var enabled: Bool { plugin.status == "enabled" }
    public var canToggle: Bool { key?.isEmpty == false && ["enabled", "disabled", "not enabled"].contains(plugin.status) }
    public var canRemove: Bool { ["user", "git"].contains(plugin.source) }
    public var canUpdate: Bool { canRemove && catalogName?.isEmpty == false && updateAvailable }

    public init(_ row: JSON) {
        plugin = InstalledPlugin(row); key = row["key"].string
        version = row["version"].string ?? ""
        installedSHA = row["installed_sha"].string; pinnedSHA = row["pinned_sha"].string
        catalogSHA = row["catalog_sha"].string; catalogName = row["catalog_name"].string
        updateAvailable = row["update_available"].bool; hasDesktopHalf = row["has_desktop_half"].bool
    }
}

public enum AgentPluginAction: String, Identifiable, Sendable {
    case enable, disable, update, remove
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .enable: return "Enable agent plugin"
        case .disable: return "Disable agent plugin"
        case .update: return "Update catalog plugin"
        case .remove: return "Remove agent plugin"
        }
    }
}

public struct AgentPluginUpdateReview: Identifiable, Sendable {
    public let sha: String
    public let lines: [String]
    public let binding: JSON?
    public var id: String { sha }
}

public enum AgentPluginOutcome: Sendable {
    case applied(JSON)
    case requiresBoundConsent(AgentPluginUpdateReview)
}

@MainActor public struct AgentPluginLifecycleClient {
    private let api: BotConnectorsClient
    public init(api: BotConnectorsClient) { self.api = api }

    public func list() async throws -> [AgentPluginRecord] {
        let result = try await api.call("plugins.manage", ["action": .string("list")])
        guard case .array(let rows) = result["plugins"] else { throw GatewayError.message("The gateway did not report installed plugins.") }
        let records = rows.map(AgentPluginRecord.init)
        guard records.allSatisfy({ !$0.id.isEmpty && !$0.plugin.name.isEmpty }), Set(records.map(\.id)).count == records.count else {
            throw GatewayError.message("The gateway returned incomplete or duplicate plugin identities.")
        }
        return records
    }

    public func perform(_ action: AgentPluginAction, reviewed: AgentPluginRecord, updateConsent: AgentPluginUpdateReview? = nil) async throws -> AgentPluginOutcome {
        guard let current = try await list().first(where: { $0.id == reviewed.id }),
              current.plugin.name == reviewed.plugin.name, current.plugin.source == reviewed.plugin.source,
              current.installedSHA == reviewed.installedSHA, current.pinnedSHA == reviewed.pinnedSHA else {
            throw GatewayError.message("This plugin changed since review. Refresh and review it again.")
        }
        var params: [String: JSON] = ["action": .string(action == .enable || action == .disable ? "toggle" : action.rawValue)]
        switch action {
        case .enable, .disable:
            guard current.canToggle, let key = current.key else { throw GatewayError.message("This gateway does not report a canonical plugin key or supported state.") }
            if current.enabled == (action == .enable) { return .applied(.object(["ok": .bool(true), "unchanged": .bool(true)])) }
            params["key"] = .string(key); params["enable"] = .bool(action == .enable)
        case .remove:
            guard current.canRemove else { throw GatewayError.message("Only user-installed plugins can be removed here.") }
            params["name"] = .string(current.plugin.name)
        case .update:
            guard current.canUpdate else { throw GatewayError.message("Only an available catalog update can be applied here. Custom sources update through the CLI.") }
            params["name"] = .string(current.plugin.name)
            if let consent = updateConsent {
                guard let binding = consent.binding,
                      binding["installed_name"].string == current.plugin.name,
                      binding["catalog_name"].string == current.catalogName,
                      binding["installed_sha"].string == current.installedSHA,
                      binding["target_sha"].string == consent.sha else {
                    throw GatewayError.message("This update review no longer matches the installed plugin. Refresh and review again.")
                }
                params["accept_capabilities"] = .bool(true); params["reviewed_update"] = binding
            }
        }
        let result = try await api.call("plugins.manage", params)
        if action == .update, result["consent_required"] == .bool(true) {
            guard let sha = result["sha"].string, !sha.isEmpty else { throw GatewayError.message("The gateway did not identify the update requiring consent.") }
            guard updateConsent == nil else { throw GatewayError.message("The reviewed update changed and was not applied. Refresh and review again.") }
            let candidate = result["update_review"]
            let binding: JSON? = candidate["installed_name"].string == current.plugin.name &&
                candidate["catalog_name"].string == current.catalogName &&
                candidate["installed_sha"].string == current.installedSHA &&
                candidate["target_sha"].string == sha && candidate["delta"] == result["delta"] &&
                candidate["delta"] != .null ? candidate : nil
            return .requiresBoundConsent(AgentPluginUpdateReview(sha: sha, lines: result["delta_lines"].array.compactMap(\.string), binding: binding))
        }
        guard result["ok"] == .bool(true) else { throw GatewayError.message(result["error"].string ?? "The gateway did not confirm this plugin action.") }
        if action == .enable || action == .disable {
            guard result["name"].string == current.key else { throw GatewayError.message("The gateway confirmed a different plugin. Refresh before another action.") }
        } else if action == .remove {
            guard result["name"].string == current.plugin.name else { throw GatewayError.message("The gateway confirmed removal of a different plugin.") }
        }
        if action == .update {
            guard result["sha"].string?.isEmpty == false, result["name"].string?.isEmpty == false,
                  updateConsent == nil || result["sha"].string == updateConsent?.sha else {
                throw GatewayError.message("The gateway did not identify the installed update. Refresh before another action.")
            }
        }
        return .applied(result)
    }
}
