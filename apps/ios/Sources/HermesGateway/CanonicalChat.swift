import Foundation

public enum CanonicalChat {
    @MainActor public static func open(profile: String, request: (String, [String: JSON]) async throws -> JSON) async throws -> JSON {
        func lookup() async throws -> JSON? {
            let result = try await request("session.list", ["profile": .string(profile), "title": .string("Bot Chat"), "include_hidden": .bool(true), "limit": .number(200)])
            return result["sessions"].array.first { $0["title"].string == "Bot Chat" || $0["root_title"].string == "Bot Chat" }
        }
        func resume(_ row: JSON) async throws -> JSON {
            guard let id = row["resolved_id"].string ?? row["id"].string else { throw GatewayError.message("The bot registry returned no conversation ID.") }
            return try await request("session.resume", ["profile": .string(profile), "session_id": .string(id), "close_on_disconnect": .bool(false), "inline_images": .bool(false)])
        }
        if let row = try await lookup() { return try await resume(row) }
        let created = try await request("session.create", ["profile": .string(profile), "title": .string("Bot Chat"), "hidden": .bool(true), "follow_profile_config": .bool(true), "close_on_disconnect": .bool(false), "idempotency_key": .string("iphone-bot-chat-\(profile)")])
        guard let runtime = created["session_id"].string else { throw GatewayError.message("Gateway returned no runtime session.") }
        do {
            _ = try await request("session.title", ["profile": .string(profile), "session_id": .string(runtime), "title": .string("Bot Chat")])
            return created
        } catch {
            // A concurrent Desktop open may win the title registry; adopt it before any send.
            if let winner = try await lookup() { return try await resume(winner) }
            throw error
        }
    }
}
