import XCTest
@testable import HermesGateway

@MainActor final class BotSkillsTests: XCTestCase {
    private func rows(_ enabled: Bool) -> JSON {
        .array([.object(["name": .string("write & review"), "enabled": .bool(enabled), "provenance": .string("hub")])])
    }
    func testProfileScopedContentAndToggleReadEffectiveState() async throws {
        var enabled = false
        var writes = 0
        let api = BotSkillsClient(profile: "writer", request: { _, _ in XCTFail("No reload RPC"); return .null }, http: { path, profile, body, method, query in
            XCTAssertEqual(profile, "writer")
            if path == "api/skills/content" {
                XCTAssertEqual(query, [.init(name: "name", value: "write & review")])
                return .object(["name": .string("write & review"), "content": .string("Synthetic content")])
            }
            if method == "PUT" {
                XCTAssertEqual(path, "api/skills/toggle")
                XCTAssertEqual(body, .object(["name": .string("write & review"), "enabled": .bool(true)]))
                writes += 1; enabled = true
                return .object(["ok": .bool(true), "name": .string("write & review")])
            }
            XCTAssertEqual(path, "api/skills"); return self.rows(enabled)
        })
        let content = try await api.content(name: "write & review")
        XCTAssertEqual(content, "Synthetic content")
        let after = try await api.setEnabled(name: "write & review", enabled: true)
        XCTAssertEqual(after.first?.enabled, true); XCTAssertEqual(writes, 1)
    }
    func testEssentialSkillReceiptCannotReportFalseDisable() async {
        var writes = 0
        let api = BotSkillsClient(profile: "writer", request: { _, _ in .null }, http: { _, _, _, method, _ in
            if method == "PUT" { writes += 1; return .object(["ok": .bool(true), "name": .string("write & review"), "enabled": .bool(false)]) }
            return self.rows(true)
        })
        do { _ = try await api.setEnabled(name: "write & review", enabled: false); XCTFail("Required skill stays enabled") }
        catch { XCTAssertTrue(error.localizedDescription.contains("saved state did not change")) }
        XCTAssertEqual(writes, 1)
    }
    func testInstallRequiresCapabilityAndNextSessionReceipt() async throws {
        var available = false
        var validReceipt = false
        var installs = 0
        let api = BotSkillsClient(profile: "writer", request: { method, params in
            XCTAssertEqual(params["profile"], .string("writer"))
            if method == "gateway.capabilities" { return .object(["skills_install_next_session": .bool(available)]) }
            XCTAssertEqual(method, "skills.manage")
            XCTAssertEqual(params, ["profile": .string("writer"), "action": .string("install"), "query": .string("hub/example"), "next_session": .bool(true)])
            installs += 1
            return .object(["installed": .bool(true), "name": .string("hub/example"), "activation": .string(validReceipt ? "next_session" : "now")])
        }, http: { _, _, _, _, _ in XCTFail("No alternate install API"); return .null })
        do { try await api.install(identifier: "hub/example"); XCTFail("Old server") } catch { XCTAssertEqual(installs, 0) }
        available = true
        do { try await api.install(identifier: "hub/example"); XCTFail("Wrong activation") } catch { XCTAssertEqual(installs, 1) }
        validReceipt = true; try await api.install(identifier: "hub/example"); XCTAssertEqual(installs, 2)
    }
    func testHubUsesScopedReadOnlyBrowseAndPreview() async throws {
        let api = BotSkillsClient(profile: "writer", request: { method, params in
            XCTAssertEqual(method, "skills.manage"); XCTAssertEqual(params["profile"], .string("writer"))
            if params["action"] == .string("browse") {
                XCTAssertEqual(params["page"], .number(2))
                return .object(["page": .number(2), "total_pages": .number(3), "items": .array([.object(["identifier": .string("hub/example"), "source": .string("hub")])])])
            }
            XCTAssertEqual(params["action"], .string("inspect"))
            return .object(["info": .object(["identifier": .string("hub/example"), "skill_md_preview": .string("Synthetic preview")])])
        }, http: { _, _, _, _, _ in .null })
        let page = try await api.browse(page: 2)
        XCTAssertTrue(page.hasMore); XCTAssertEqual(page.skills.first?.source, "hub")
        let preview = try await api.preview(identifier: "hub/example"); XCTAssertEqual(preview, "Synthetic preview")
    }
}
