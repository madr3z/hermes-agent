import XCTest
@testable import HermesGateway

@MainActor final class ConnectorsTests: XCTestCase {
    func testSeparateMCPNamesPreserveCredentialsAndAlwaysUseSelectedProfile() async throws {
        var calls: [(String, [String: JSON])] = []
        let client = BotConnectorsClient(profile: "writer") { method, params in
            calls.append((method, params))
            return .object(["ok": .bool(true), "servers": .array([])])
        }
        _ = try await client.mcpServers()
        XCTAssertEqual(calls.map(\.0), ["mcp.servers.list"])
        for (name, token) in [("gmail-personal", "personal-token"), ("gmail-work", "work-token"), ("gmail-third", "third-token")] {
            var draft = MCPConnectionDraft(); draft.name = name; draft.target = "https://mail.example/mcp"; draft.bearer = token
            _ = try await client.addMCP(draft)
        }
        XCTAssertTrue(calls.allSatisfy { $0.1["profile"] == .string("writer") })
        let writes = calls.filter { $0.0 == "mcp.servers.add" }
        XCTAssertEqual(writes.map { $0.1["name"]?.string }, ["gmail-personal", "gmail-work", "gmail-third"])
        XCTAssertEqual(writes.map { $0.1["bearer_token"]?.string }, ["personal-token", "work-token", "third-token"])
        XCTAssertTrue(writes.allSatisfy { $0.1["config"]?["headers"] == .null })
    }
    func testCustomInstallRequiresPinnedHTTPSRepositoryAndDoesNotStartUntilSubmitted() async throws {
        for (repo, sha) in [("https://user:secret@example.com/repo", String(repeating: "a", count: 40)), ("https://example.com/repo", "main")] {
            XCTAssertThrowsError(try PluginInstallReview(repo: repo, sha: sha))
        }
        let review = try PluginInstallReview(repo: "https://example.com/repo", sha: String(repeating: "a", count: 40))
        var calls: [[String: JSON]] = []
        let client = BotConnectorsClient(profile: "bot") { _, params in calls.append(params); return .object(["ok": .bool(true)]) }
        XCTAssertTrue(calls.isEmpty)
        _ = try await client.install(review)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0]["profile"], .string("bot"))
        XCTAssertEqual(calls[0]["identifier"], .string("https://example.com/repo"))
        XCTAssertEqual(calls[0]["ref"], .string(String(repeating: "a", count: 40)))
        XCTAssertEqual(calls[0]["force"], .bool(false))
    }
    func testHostedInventoryRetainsAllAccountIdentitiesWithoutSelectingOne() async throws {
        var methods: [String] = []
        let client = BotConnectorsClient(profile: "bot") { method, _ in
            methods.append(method)
            if method == "connectors.list" { return .object(["available": .bool(true)]) }
            return .object(["accounts": .array((1...3).map { .object(["connection_id": .string("gmail-\($0)"), "connector": .string("gmail"), "label": .string("Account \($0)"), "status": .string("active"), "active": .bool($0 == 3)]) })])
        }
        let accounts = try await client.hostedAccounts()
        XCTAssertEqual(accounts.map(\.id), ["gmail-1", "gmail-2", "gmail-3"])
        XCTAssertEqual(methods, ["connectors.list", "connectors.accounts"])
    }
    func testMCPNamesAvoidExistingCredentialKeyCollisions() throws {
        var draft = MCPConnectionDraft(); draft.name = "gmail_work"; draft.target = "https://example.com/mcp"
        XCTAssertThrowsError(try draft.parameters())
        draft.name = "gmail-work"
        XCTAssertThrowsError(try draft.parameters(existingNames: ["gmail_work"]))
        XCTAssertThrowsError(try draft.parameters(existingNames: ["gmail.work"]))
    }
}
