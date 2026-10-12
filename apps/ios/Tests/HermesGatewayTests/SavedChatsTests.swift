import XCTest
@testable import HermesGateway

@MainActor final class SavedChatsTests: XCTestCase {
    func testHistoryReadsExactProfileAndOnlyDisplaysHumanRows() async throws {
        var calls: [(String, String, [String: String])] = []
        let api = SavedChatsClient(profile: "writer") { path, profile, query in
            calls.append((path, profile, Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })))
            if path == "api/sessions" {
                return .object(["sessions": .array([
                    Self.row("one", profile: "writer"), Self.row("foreign", profile: "other"), Self.row("child", profile: "writer", source: "subagent")
                ])])
            }
            if path.hasSuffix("search") { return .object(["results": .array([Self.row("hit", profile: "writer")])]) }
            return .object(["session_id": .string("tip"), "profile": .string(profile), "messages": .array([
                .object(["role": .string("system"), "content": .string("private scaffolding")]),
                .object(["role": .string("assistant"), "content": .string("private compaction wrapper"), "display_content": .string("Saved answer"), "id": .number(51)])
            ]), "pagination": .object(["returned": .number(2)])])
        }
        let list = try await api.list()
        XCTAssertEqual(list.rows.map(\.id), ["one"])
        let hits = try await api.search("a & b / ?")
        XCTAssertEqual(hits.map(\.id), ["hit"])
        XCTAssertEqual(hits[0].preview, "Safe preview")
        let page = try await api.messages(id: "one")
        XCTAssertEqual(page.messages.map(\.text), ["Saved answer"])
        XCTAssertEqual(page.messages.map(\.id), ["row-51"])
        XCTAssertEqual(page.sessionID, "tip")
        XCTAssertEqual(calls.map(\.1), ["writer", "writer", "writer"])
        XCTAssertEqual(calls[1].2["q"], "a & b / ?")
        XCTAssertEqual(calls[2].2["include_compacted"], "true")
        XCTAssertEqual(calls[2].2["inline_images"], "false")
        XCTAssertEqual(calls.map(\.0), ["api/sessions", "api/sessions/search", "api/sessions/one/messages"])
        let markdown = SavedChatsClient.markdown(chat: list.rows[0], profile: "writer", messages: page.messages, hasEarlier: true)
        XCTAssertTrue(markdown.contains("Loaded messages only"))
        XCTAssertFalse(markdown.contains("private scaffolding"))
    }
    func testUnsafeIDsAndForeignTranscriptAreRejectedAndQueryCannotReplaceProfile() async throws {
        var calls = 0
        let api = SavedChatsClient(profile: "writer") { _, _, _ in
            calls += 1
            return .object(["session_id": .string("one"), "profile": .string("other")])
        }
        for id in ["../secret", "a?x=1", "%2fetc", "a\\b", ".."] {
            do { _ = try await api.messages(id: id); XCTFail("Unsafe ID") } catch {}
        }
        XCTAssertEqual(calls, 0)
        do { _ = try await api.messages(id: "one"); XCTFail("Foreign profile") } catch {}
        XCTAssertEqual(calls, 1)
        let endpoint = try GatewayEndpoint(label: "VM", baseURL: URL(string: "https://example.test/proxy/bot")!)
        let url = endpoint.url(path: "api/sessions/search", profile: "writer", query: [URLQueryItem(name: "q", value: "a&b/?"), URLQueryItem(name: "profile", value: "wrong")])
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.path, "/proxy/bot/api/sessions/search")
        XCTAssertEqual(parts.queryItems?.filter { $0.name == "profile" }.map(\.value), ["writer"])
        XCTAssertEqual(parts.queryItems?.first { $0.name == "q" }?.value, "a&b/?")
    }
    static func row(_ id: String, profile: String, source: String = "cli") -> JSON {
        .object(["id": .string(id), "profile": .string(profile), "source": .string(source), "title": .string("Saved"), "preview": .string("Safe preview"), "snippet": .string("Private FTS scaffold")])
    }
}
