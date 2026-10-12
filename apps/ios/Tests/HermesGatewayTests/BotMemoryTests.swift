import XCTest
@testable import HermesGateway

@MainActor final class BotMemoryTests: XCTestCase {
    private let id = "memory:profile:0:abcdef012345"
    private func graph(_ id: String) -> JSON {
        .object(["nodes": .array([.object(["id": .string("skill"), "kind": .string("skill")]), .object(["id": .string(id), "kind": .string("memory"), "label": .string("Synthetic note"), "memorySource": .string("profile")])])])
    }
    func testOnlyMemoryCardsAndScopedReadOnlyDetail() async throws {
        var paths: [String] = []
        let api = BotMemoryClient(profile: "writer") { path, profile, query in
            XCTAssertEqual(profile, "writer"); paths.append(path)
            if path == "api/learning/graph" { XCTAssertTrue(query.isEmpty); return self.graph(self.id) }
            XCTAssertEqual(path, "api/learning/node"); XCTAssertEqual(query, [.init(name: "id", value: self.id)])
            return .object(["ok": .bool(true), "kind": .string("memory"), "content": .string("Synthetic private note")])
        }
        let cards = try await api.cards(); XCTAssertEqual(cards.count, 1)
        let content = try await api.content(card: cards[0]); XCTAssertEqual(content, "Synthetic private note")
        XCTAssertEqual(paths, ["api/learning/graph", "api/learning/graph", "api/learning/node"])
    }
    func testStaleCardCannotOpenAnotherEntry() async throws {
        var stale = false
        var details = 0
        let api = BotMemoryClient(profile: "writer") { path, _, _ in
            if path == "api/learning/graph" { return self.graph(stale ? "memory:profile:0:111111111111" : self.id) }
            details += 1; return .null
        }
        let card = try await api.cards()[0]; stale = true
        do { _ = try await api.content(card: card); XCTFail("Changed memory") } catch { XCTAssertEqual(details, 0) }
    }
    func testMissingRoutesAndLegacyIDsDoNotFallBack() async {
        var calls = 0
        let missing = BotMemoryClient(profile: "missing") { _, profile, _ in
            calls += 1; XCTAssertEqual(profile, "missing"); throw GatewayError.http(status: 404, message: "Not found")
        }
        do { _ = try await missing.cards(); XCTFail("Missing cannot become empty") } catch { XCTAssertEqual(calls, 1) }
        let legacy = BotMemoryClient(profile: "writer") { _, _, _ in self.graph("memory:profile:0") }
        do { _ = try await legacy.cards(); XCTFail("Legacy position ID") } catch {}
    }
}
