import Foundation

public struct InstalledBotSkill: Identifiable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let category: String
    public let provenance: String
    public let enabled: Bool
    public var id: String { name }
    public init(_ row: JSON) throws {
        guard let name = row["name"].string, !name.isEmpty, case .bool(let enabled) = row["enabled"] else {
            throw GatewayError.message("The gateway returned an incomplete skill.")
        }
        self.name = name; self.enabled = enabled
        description = row["description"].string ?? ""
        category = row["category"].string ?? "Skills"
        provenance = row["provenance"].string ?? "Unknown source"
    }
}

public struct HubBotSkill: Identifiable, Equatable, Sendable {
    public let identifier: String
    public let name: String
    public let description: String
    public let source: String
    public let trust: String
    public var id: String { identifier }
    public init(_ row: JSON) throws {
        guard let identifier = row["identifier"].string, !identifier.isEmpty else {
            throw GatewayError.message("The hub returned a skill without an identifier.")
        }
        self.identifier = identifier
        name = row["name"].string ?? identifier
        description = row["description"].string ?? ""
        source = row["source"].string ?? "Unknown source"
        trust = row["trust"].string ?? "Not reported"
    }
}

@MainActor public struct BotSkillsClient {
    public typealias Request = (String, [String: JSON]) async throws -> JSON
    public typealias HTTP = (String, String, JSON?, String, [URLQueryItem]) async throws -> JSON
    public let profile: String
    private let request: Request
    private let http: HTTP
    public init(profile: String, request: @escaping Request, http: @escaping HTTP) {
        self.profile = profile; self.request = request; self.http = http
    }
    private func read(_ path: String, query: [URLQueryItem] = []) async throws -> JSON {
        try await http(path, profile, nil, "GET", query)
    }
    private func rpc(_ action: String, query: String = "", page: Int = 1) async throws -> JSON {
        try await request("skills.manage", ["profile": .string(profile), "action": .string(action),
                                            "query": .string(query), "page": .number(Double(page))])
    }
    public func installed() async throws -> [InstalledBotSkill] {
        let result = try await read("api/skills")
        guard case .array(let rows) = result else { throw GatewayError.message("The gateway did not return installed skills.") }
        let skills = try rows.map(InstalledBotSkill.init)
        guard Set(skills.map(\.id)).count == skills.count else { throw GatewayError.message("The gateway returned duplicate skills.") }
        return skills
    }
    public func content(name: String) async throws -> String {
        guard try await installed().contains(where: { $0.name == name }) else {
            throw GatewayError.message("This skill is no longer installed. Refresh the list.")
        }
        let result = try await read("api/skills/content", query: [.init(name: "name", value: name)])
        guard result["name"].string == name, let content = result["content"].string else {
            throw GatewayError.message("The gateway did not return this skill's instructions.")
        }
        return content
    }
    public func setEnabled(name: String, enabled: Bool) async throws -> [InstalledBotSkill] {
        let before = try await installed()
        guard let row = before.first(where: { $0.name == name }) else {
            throw GatewayError.message("This skill is no longer installed. Refresh before changing it.")
        }
        if row.enabled == enabled { return before }
        let result = try await http("api/skills/toggle", profile, .object(["name": .string(name), "enabled": .bool(enabled)]), "PUT", [])
        guard result["ok"] == .bool(true), result["name"].string == name else {
            throw GatewayError.message("The gateway did not confirm this skill change. Refresh before another change.")
        }
        let after = try await installed()
        guard after.first(where: { $0.name == name })?.enabled == enabled else {
            throw GatewayError.message("The saved state did not change. This skill may be required by the bot. Refresh to see its effective state.")
        }
        return after
    }
    public func browse(page: Int) async throws -> (skills: [HubBotSkill], hasMore: Bool) {
        let result = try await rpc("browse", page: page)
        guard case .array(let rows) = result["items"] else { throw GatewayError.message("The gateway did not return the skill hub.") }
        return (try rows.map(HubBotSkill.init), (result["page"].number ?? Double(page)) < (result["total_pages"].number ?? Double(page)))
    }
    public func preview(identifier: String) async throws -> String {
        let result = try await rpc("inspect", query: identifier)
        guard result["info"]["identifier"].string == identifier,
              let content = result["info"]["skill_md_preview"].string else {
            throw GatewayError.message("This hub skill is no longer available for review.")
        }
        return content
    }
    public func supportsNextSessionInstall() async throws -> Bool {
        let result = try await request("gateway.capabilities", ["profile": .string(profile)])
        return result["skills_install_next_session"] == .bool(true)
    }
    public func install(identifier: String) async throws {
        guard try await supportsNextSessionInstall() else {
            throw GatewayError.message("This gateway cannot install skills without changing active chats. Update the bot runtime, then refresh.")
        }
        let result = try await request("skills.manage", ["profile": .string(profile), "action": .string("install"),
                                                       "query": .string(identifier), "next_session": .bool(true)])
        guard result["installed"] == .bool(true), result["name"] == .string(identifier),
              result["activation"] == .string("next_session") else {
            throw GatewayError.message("The gateway did not confirm a next-session install. Refresh before another change.")
        }
    }

}
