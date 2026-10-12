import Foundation

public struct SavedChat: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let preview: String
    public let source: String
    public let startedAt: Date?
    public let messageCount: Int
    public init?(_ row: JSON, profile: String) {
        guard let id = row["id"].string ?? row["session_id"].string, !id.isEmpty,
              row["profile"].string == profile else { return nil }
        let source = row["source"].string ?? ""
        guard !["subagent", "kanban", "tool", "oneshot", "cron", "cron_output", "bot_room", "delegate"].contains(source),
              row["hidden"].bool == false else { return nil }
        self.id = id; self.source = source
        title = row["title"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled chat"
        preview = row["preview"].string ?? ""
        startedAt = row["started_at"].number.map { Date(timeIntervalSince1970: $0) }
        messageCount = Int(row["message_count"].number ?? 0)
    }
}

public struct SavedChatPage {
    public let messages: [ChatMessage]
    public let returned: Int
    public let sessionID: String
}

@MainActor public struct SavedChatsClient {
    public typealias Read = (String, String, [URLQueryItem]) async throws -> JSON
    public let profile: String
    private let read: Read
    public init(profile: String, read: @escaping Read) { self.profile = profile; self.read = read }
    public func list(offset: Int = 0) async throws -> (rows: [SavedChat], hasMore: Bool) {
        let result = try await read("api/sessions", profile, query(["limit": "100", "offset": String(offset), "order": "recent", "min_messages": "1", "exclude_sources": "cron,cron_output,kanban,tool,oneshot,bot_room,subagent,delegate"]))
        let rows = result["sessions"].array
        return (rows.compactMap { SavedChat($0, profile: profile) }, rows.count == 100)
    }
    public func search(_ text: String) async throws -> [SavedChat] {
        let result = try await read("api/sessions/search", profile, query(["q": text, "limit": "100", "exclude_sources": "cron,cron_output,kanban,tool,oneshot,bot_room,subagent,delegate"]))
        return result["results"].array.compactMap { SavedChat($0, profile: profile) }
    }
    public func messages(id: String, offset: Int = 0) async throws -> SavedChatPage {
        // IDs are route segments from a selected row, never paths or prefixes from user input.
        guard !id.isEmpty, id.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#%")) == nil, id != ".", id != ".." else {
            throw GatewayError.message("This saved chat has an invalid ID.")
        }
        let result = try await read("api/sessions/\(id)/messages", profile, query(["limit": "100", "offset": String(offset), "order": "latest", "include_compacted": "true", "inline_images": "false"]))
        guard result["profile"].string == profile, let resolvedID = result["session_id"].string, !resolvedID.isEmpty else {
            throw GatewayError.message("The saved transcript did not confirm its profile. Refresh this bot’s history.")
        }
        let returned = Int(result["pagination"]["returned"].number ?? -1)
        guard (0...100).contains(returned) else { throw GatewayError.message("The saved transcript returned an invalid page.") }
        return SavedChatPage(messages: Self.projectMessages(result["messages"].array, offset: offset), returned: returned, sessionID: resolvedID)
    }
    private static func projectMessages(_ rows: [JSON], offset: Int) -> [ChatMessage] {
        let normalized = rows.enumerated().map { index, row -> JSON in
            guard case .object(var values) = row else { return row }
            if let display = row["display_content"].string { values["text"] = .string(display) }
            if values["row_id"] == nil { values["row_id"] = row["id"].number.map(JSON.number) ?? row["_row_id"].number.map(JSON.number) }
            if values["row_id"] == nil, row["display_metadata"]["voice_message_id"].string == nil {
                values["display_metadata"] = .object(["mobile_message_id": .string("saved-page-\(offset)-\(index)")])
            }
            return .object(values)
        }
        return ChatMessage.project(normalized)
    }
    private func query(_ values: [String: String]) -> [URLQueryItem] {
        values.keys.sorted().map { URLQueryItem(name: $0, value: values[$0]) }
    }
    public static func markdown(chat: SavedChat, profile: String, messages: [ChatMessage], hasEarlier: Bool) -> String {
        let scope = hasEarlier ? "Loaded messages only; earlier messages may remain on the gateway." : "Loaded saved transcript."
        return "# \(chat.title)\n\nProfile: \(profile)\nChat: \(chat.id)\n\(scope)\n\n" + messages.filter { ["user", "assistant"].contains($0.role) }.map {
            "## \($0.role == "user" ? "You" : "Assistant")\n\n\($0.text)"
        }.joined(separator: "\n\n")
    }
}
