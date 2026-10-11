import Foundation

public struct BotSkill: Identifiable, Equatable, Sendable {
    public let name: String
    public let category: String
    public var id: String { category + ":" + name }
}

public struct BotModelInventory: Equatable, Sendable {
    public let model: String
    public let provider: String
    public let providers: [JSON]
    public init(_ result: JSON) {
        model = result["model"].string ?? ""
        provider = result["provider"].string ?? ""
        providers = result["providers"].array
    }
    public var currentProvider: JSON? { providers.first { $0["slug"].string == provider } }
    public var availableModels: [String] {
        guard let currentProvider, currentProvider["authenticated"] != .bool(false) else { return [] }
        let unavailable = Set(currentProvider["unavailable_models"].array.compactMap(\.string))
        return currentProvider["models"].array.compactMap(\.string).filter { !unavailable.contains($0) }
    }
}

@MainActor public struct BotCapabilitiesClient {
    public let profile: String
    public let runtimeID: String?
    private let request: (String, [String: JSON]) async throws -> JSON
    public init(profile: String, runtimeID: String? = nil, request: @escaping (String, [String: JSON]) async throws -> JSON) {
        self.profile = profile; self.runtimeID = runtimeID; self.request = request
    }
    public func skills() async throws -> [BotSkill] {
        let result = try await request("skills.manage", ["profile": .string(profile), "action": .string("list")])
        guard case .object(let categories) = result["skills"] else { throw GatewayError.message("The gateway did not return its installed skills.") }
        return categories.keys.sorted().flatMap { category in
            categories[category]!.array.compactMap(\.string).sorted().map { BotSkill(name: $0, category: category) }
        }
    }
    public func models() async throws -> BotModelInventory {
        var params: [String: JSON] = ["profile": .string(profile), "include_unconfigured": .bool(false)]
        if let runtimeID { params["session_id"] = .string(runtimeID) }
        return BotModelInventory(try await request("model.options", params))
    }
    public func readiness() async throws -> JSON {
        try await request("setup.runtime_check", ["profile": .string(profile)])
    }
    /// Select only a model in the existing provider. The backend retains its price confirmation gate.
    public func selectModel(_ model: String, provider: String, confirmed: Bool = false) async throws -> JSON {
        guard let runtimeID, !runtimeID.isEmpty else { throw GatewayError.message("Open Bot Chat before changing its model.") }
        let inventory = try await models()
        guard inventory.provider == provider, inventory.availableModels.contains(model) else {
            throw GatewayError.message("The current provider or model list changed. Refresh before selecting a model.")
        }
        // These are words in the existing /model grammar, not arbitrary slash arguments.
        let safeWord: (String) -> Bool = { !$0.isEmpty && !$0.hasPrefix("-") && $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil && !$0.contains("'") && !$0.contains("\"") && !$0.contains("\\") }
        guard safeWord(model), safeWord(provider) else { throw GatewayError.message("Choose this model from your Mac.") }
        return try await request("config.set", ["profile": .string(profile), "session_id": .string(runtimeID),
            "key": .string("model"), "value": .string("\(model) --provider \(provider) --session"), "confirm_expensive_model": .bool(confirmed)])
    }
}
