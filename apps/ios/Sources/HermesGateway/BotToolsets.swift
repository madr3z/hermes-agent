import Foundation

public struct BotToolset: Identifiable, Equatable, Sendable {
    public let name: String
    public let label: String
    public let description: String
    public let enabled: Bool
    public let configured: Bool?
    public let tools: [String]
    public var id: String { name }

    public init(_ row: JSON) throws {
        guard let name = row["name"].string, !name.isEmpty, case .bool(let enabled) = row["enabled"] else {
            throw GatewayError.message("The gateway returned an incomplete toolset.")
        }
        self.name = name
        label = row["label"].string ?? name
        description = row["description"].string ?? ""
        self.enabled = enabled
        if case .bool(let configured) = row["configured"] { self.configured = configured } else { configured = nil }
        tools = row["tools"].array.compactMap(\.string)
    }
}

public struct BotToolsetsSnapshot: Equatable, Sendable {
    public let toolsets: [BotToolset]
    public let currentTools: Set<String>?
    public let currentError: String?
}

@MainActor public struct BotToolsetsClient {
    public typealias Request = (String, [String: JSON]) async throws -> JSON
    public typealias HTTP = (String, String, JSON?, String) async throws -> JSON
    public let profile: String
    public let runtimeID: String?
    private let request: Request
    private let http: HTTP

    public init(profile: String, runtimeID: String?, request: @escaping Request, http: @escaping HTTP) {
        self.profile = profile; self.runtimeID = runtimeID; self.request = request; self.http = http
    }

    private func scopedHTTP(_ path: String, body: JSON? = nil, method: String = "GET") async throws -> JSON {
        do { return try await http(path, profile, body, method) }
        catch GatewayError.http(let status, _) where status == 404 {
            throw GatewayError.message("Toolset settings are not available through this gateway yet. Update the controller and bot runtime, then refresh.")
        }
    }

    public func configured() async throws -> [BotToolset] {
        let result = try await scopedHTTP("api/tools/toolsets")
        guard case .array(let rows) = result else { throw GatewayError.message("The gateway did not return its toolsets.") }
        let toolsets = try rows.map(BotToolset.init)
        guard Set(toolsets.map(\.id)).count == toolsets.count else { throw GatewayError.message("The gateway returned duplicate toolset IDs.") }
        return toolsets
    }

    public func snapshot() async throws -> BotToolsetsSnapshot {
        let toolsets = try await configured()
        guard let runtimeID, !runtimeID.isEmpty else {
            return BotToolsetsSnapshot(toolsets: toolsets, currentTools: nil, currentError: nil)
        }
        do {
            let result = try await request("tools.show", ["profile": .string(profile), "session_id": .string(runtimeID)])
            guard case .array(let sections) = result["sections"] else {
                throw GatewayError.message("The gateway did not report the current chat's tools.")
            }
            let names = sections.flatMap { $0["tools"].array.compactMap { $0["name"].string } }
            return BotToolsetsSnapshot(toolsets: toolsets, currentTools: Set(names), currentError: nil)
        } catch is CancellationError { throw CancellationError() }
        catch { return BotToolsetsSnapshot(toolsets: toolsets, currentTools: nil, currentError: error.localizedDescription) }
    }

    public func setEnabled(name: String, enabled: Bool) async throws -> JSON {
        let rows = try await configured()
        guard let row = rows.first(where: { $0.name == name }) else {
            throw GatewayError.message("This toolset is no longer available. Refresh before changing it.")
        }
        if row.enabled == enabled { return .object(["ok": .bool(true), "unchanged": .bool(true)]) }
        guard !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
            throw GatewayError.message("The toolset has an invalid name.")
        }
        let result = try await scopedHTTP("api/tools/toolsets/" + name, body: .object(["enabled": .bool(enabled)]), method: "PUT")
        guard result["ok"] == .bool(true), result["name"] == .string(name), result["enabled"] == .bool(enabled) else {
            throw GatewayError.message("The gateway did not confirm this toolset change. Refresh before another change.")
        }
        return result
    }
}
