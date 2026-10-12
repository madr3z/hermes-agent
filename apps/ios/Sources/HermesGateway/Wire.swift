import Foundation

public enum JSON: Codable, Hashable, Sendable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSON].self) { self = .object(v) }
        else { self = .array(try c.decode([JSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var array: [JSON] { if case .array(let v) = self { return v }; return [] }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var bool: Bool { if case .bool(let v) = self { return v }; return false }
}

public struct GatewayEndpoint: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var baseURL: URL
    public init(id: UUID = UUID(), label: String, baseURL: URL) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil,
              baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw GatewayError.message("Enter an HTTPS gateway URL without credentials or query parameters.")
        }
        self.id = id; self.label = label; self.baseURL = baseURL
    }
    public func url(path: String, profile: String? = nil, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = "/" + ([parts.path, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))].filter { !$0.isEmpty }.joined(separator: "/"))
        let items = query.filter { $0.name != "profile" } + (profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? [])
        parts.queryItems = items.isEmpty ? nil : items
        return parts.url!
    }
    public func provisionedGateway(_ row: JSON) throws -> GatewayEndpoint {
        let gateway = row["gateway"]
        guard let path = gateway["base_url"].string,
              path.hasPrefix("/api/plugins/bot-provisioning/v1/gateways/"),
              !path.contains(".."),
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host, url.port == baseURL.port else {
            throw GatewayError.message("Provisioner returned an invalid gateway route.")
        }
        return try GatewayEndpoint(label: gateway["label"].string ?? row["name"].string ?? "Bot", baseURL: url)
    }
    public func webSocketURL(token: String) -> URL {
        var parts = URLComponents(url: url(path: "api/ws"), resolvingAgainstBaseURL: false)!
        parts.scheme = "wss"
        // Current serve protocol requires a WS query token. Never log this URL.
        parts.queryItems = [URLQueryItem(name: "token", value: token)]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }
}

public enum GatewayError: LocalizedError {
    case message(String)
    case rpc(code: Int, message: String)
    case http(status: Int, message: String)
    public var errorDescription: String? {
        switch self { case .message(let text), .rpc(_, let text), .http(_, let text): return text }
    }
    public var rejectsClientTurnID: Bool {
        if case .rpc(let code, let message) = self {
            return code == 4000 && message.hasPrefix("invalid params for prompt.submit: client_turn_id:")
        }
        return false
    }
}

public struct Bot: Identifiable, Hashable {
    public let endpointID: UUID
    public let profile: String
    public let name: String
    public let preview: String
    public let conversationPreview: String
    public let lastActive: Double
    public var id: String { "\(endpointID.uuidString):\(profile)" }
    public init(endpointID: UUID, row: JSON) {
        self.endpointID = endpointID; profile = row["name"].string ?? "default"
        let display = row["display_name"].string ?? ""
        name = display.isEmpty ? profile : display
        preview = row["canonical_session"]["preview"].string ?? row["description"].string ?? ""
        conversationPreview = row["canonical_session"]["preview"].string ?? ""
        lastActive = row["canonical_session"]["last_active"].number ?? 0
    }
}

public struct ChatMessage: Identifiable, Equatable {
    public let id: String
    public let role: String
    public var text: String
    public let voice: Bool
    public let toolName: String?
    public var toolRunning: Bool
    public init(id: String, role: String, text: String, voice: Bool = false, toolName: String? = nil, toolRunning: Bool = false) {
        self.id = id; self.role = role; self.text = text; self.voice = voice; self.toolName = toolName; self.toolRunning = toolRunning
    }
    public static func upserting(_ row: JSON, into messages: [ChatMessage]) -> [ChatMessage] {
        guard let message = project([row]).first else { return messages }
        var result = messages
        if let index = result.firstIndex(where: { $0.id == message.id }) { result[index] = message }
        else { result.append(message) }
        return result
    }
    public static func project(_ rows: [JSON]) -> [ChatMessage] {
        rows.enumerated().compactMap { index, row in
            guard row["display_kind"].string != "hidden" else { return nil }
            if row["role"].string == "tool", let name = row["name"].string {
                return ChatMessage(id: "tool-" + (row["tool_call_id"].string ?? "history-\(index)"), role: "tool", text: row["context"].string ?? "Completed", toolName: name)
            }
            guard ["user", "assistant"].contains(row["role"].string ?? "") else { return nil }
            let text = row["text"].string ?? row["content"].string ?? ""
            guard !text.isEmpty else { return nil }
            return ChatMessage(id: row["display_metadata"]["voice_message_id"].string ?? row["display_metadata"]["mobile_message_id"].string ?? row["row_id"].number.map { "row-\(Int($0))" } ?? "history-\(index)", role: row["role"].string!, text: text, voice: row["display_kind"].string == "voice_live")
        }
    }
}

public enum ChatEventRoute: Equatable {
    case session, refreshCanonical, reclaimed, ignore
    public static func route(_ event: JSON, runtimeID: String?, profile: String) -> ChatEventRoute {
        if let owner = event["profile"].string, owner != profile { return .ignore }
        switch event["type"].string {
        case "session.reclaimed":
            return runtimeID != nil && event["payload"]["session_id"].string == runtimeID ? .reclaimed : .ignore
        case "sessions.changed":
            // Older broadcasts carry no profile. Recheck only this client's owner on this gateway.
            return .refreshCanonical
        default:
            return runtimeID != nil && event["session_id"].string == runtimeID ? .session : .ignore
        }
    }
}
