import Foundation

public struct BotMemoryCard: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let source: String
    public init(_ row: JSON) throws {
        guard let id = row["id"].string, Self.isMemoryID(id), let label = row["label"].string,
              let source = row["memorySource"].string, ["memory", "profile"].contains(source) else {
            throw GatewayError.message("The gateway returned an incomplete memory card.")
        }
        self.id = id; self.label = label; self.source = source
    }
    private static func isMemoryID(_ id: String) -> Bool {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "memory" && ["memory", "profile"].contains(String(parts[1]))
            && Int(parts[2]).map { $0 >= 0 } == true && parts[3].count == 12
            && parts[3].allSatisfy { "0123456789abcdef".contains($0) }
    }
}

@MainActor public struct BotMemoryClient {
    public typealias Read = (String, String, [URLQueryItem]) async throws -> JSON
    public let profile: String
    private let read: Read
    public init(profile: String, read: @escaping Read) { self.profile = profile; self.read = read }
    public func cards() async throws -> [BotMemoryCard] {
        let result = try await read("api/learning/graph", profile, [])
        guard case .array(let nodes) = result["nodes"] else { throw GatewayError.message("The gateway did not return memory cards.") }
        let cards = try nodes.filter { $0["kind"] == .string("memory") }.map(BotMemoryCard.init)
        guard Set(cards.map(\.id)).count == cards.count else { throw GatewayError.message("The gateway returned duplicate memory cards.") }
        return cards
    }
    public func content(card: BotMemoryCard) async throws -> String {
        guard try await cards().contains(card) else { throw GatewayError.message("This memory card changed. Refresh the list before opening it.") }
        let result = try await read("api/learning/node", profile, [.init(name: "id", value: card.id)])
        guard result["ok"] == .bool(true), result["kind"] == .string("memory"), let content = result["content"].string else {
            throw GatewayError.message("The gateway did not return this memory card.")
        }
        return content
    }
}
