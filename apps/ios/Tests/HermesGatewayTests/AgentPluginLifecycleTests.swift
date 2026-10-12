import XCTest
@testable import HermesGateway

@MainActor final class AgentPluginLifecycleTests: XCTestCase {
    private func row(name: String = "same-name", key: String = "category/same-name", source: String = "git", status: String = "disabled", sha: String = "old") -> JSON {
        .object(["name": .string(name), "key": .string(key), "source": .string(source), "status": .string(status),
                 "installed_sha": .string(sha), "catalog_name": .string("catalog-entry"), "update_available": .bool(true)])
    }

    func testActionsUseCanonicalKeyAndOnlyOwningProfile() async throws {
        var writes: [[String: JSON]] = []
        let api = AgentPluginLifecycleClient(api: BotConnectorsClient(profile: "writer") { method, params in
            XCTAssertEqual(method, "plugins.manage"); XCTAssertEqual(params["profile"], .string("writer"))
            if params["action"] == .string("list") { return .object(["plugins": .array([self.row()])]) }
            writes.append(params)
            return .object(["ok": .bool(true), "name": .string(params["action"] == .string("toggle") ? "category/same-name" : "same-name")])
        })
        let reviewed = AgentPluginRecord(row())
        _ = try await api.perform(.enable, reviewed: reviewed)
        _ = try await api.perform(.remove, reviewed: reviewed)
        XCTAssertEqual(writes, [
            ["action": .string("toggle"), "key": .string("category/same-name"), "enable": .bool(true), "profile": .string("writer")],
            ["action": .string("remove"), "name": .string("same-name"), "profile": .string("writer")]
        ])
    }

    func testWiderUpdateReturnsReviewAndNeverGrantsCapabilities() async throws {
        var writes: [[String: JSON]] = []
        let api = AgentPluginLifecycleClient(api: BotConnectorsClient(profile: "writer") { _, params in
            if params["action"] == .string("list") { return .object(["plugins": .array([self.row()])]) }
            writes.append(params)
            return .object(["ok": .bool(false), "consent_required": .bool(true), "sha": .string("new-pin"), "delta_lines": .array([.string("Adds terminal access")])])
        })
        let result = try await api.perform(.update, reviewed: AgentPluginRecord(row()))
        guard case .requiresBoundConsent(let review) = result else { return XCTFail("Wider updates cannot be applied without bound consent") }
        XCTAssertEqual(review.sha, "new-pin"); XCTAssertEqual(review.lines, ["Adds terminal access"])
        XCTAssertEqual(writes.count, 1); XCTAssertNil(writes[0]["accept_capabilities"])
    }

    func testSamePermissionUpdateRequiresInstalledRevisionReceipt() async throws {
        var confirmed = false
        let api = AgentPluginLifecycleClient(api: BotConnectorsClient(profile: "writer") { _, params in
            XCTAssertEqual(params["profile"], .string("writer"))
            if params["action"] == .string("list") { return .object(["plugins": .array([self.row()])]) }
            XCTAssertEqual(params["action"], .string("update")); XCTAssertEqual(params["name"], .string("same-name"))
            XCTAssertNil(params["accept_capabilities"])
            return confirmed ? .object(["ok": .bool(true), "name": .string("renamed-plugin"), "sha": .string("installed-pin")]) : .object(["ok": .bool(true)])
        })
        do { _ = try await api.perform(.update, reviewed: AgentPluginRecord(row())); XCTFail("Missing installed revision") } catch { }
        confirmed = true
        guard case .applied(let receipt) = try await api.perform(.update, reviewed: AgentPluginRecord(row())) else { return XCTFail("Unwidened update should apply") }
        XCTAssertEqual(receipt["sha"], .string("installed-pin"))
    }

    func testChangedRevisionBundledRemovalAndCustomUpdateAreRejectedBeforeWrites() async throws {
        var current = row(sha: "changed")
        var writes = 0
        let api = AgentPluginLifecycleClient(api: BotConnectorsClient(profile: "writer") { _, params in
            if params["action"] == .string("list") { return .object(["plugins": .array([current])]) }
            writes += 1; return .object(["ok": .bool(true)])
        })
        do { _ = try await api.perform(.remove, reviewed: AgentPluginRecord(row())); XCTFail("Changed revision") } catch { }
        current = row(source: "bundled")
        do { _ = try await api.perform(.remove, reviewed: AgentPluginRecord(current)); XCTFail("Bundled removal") } catch { }
        current = .object(["name": .string("custom"), "key": .string("custom"), "source": .string("git"), "status": .string("enabled")])
        do { _ = try await api.perform(.update, reviewed: AgentPluginRecord(current)); XCTFail("Custom update") } catch { }
        XCTAssertEqual(writes, 0)
    }

    func testUnknownStateAndMismatchedReceiptCannotReportToggleSuccess() async throws {
        var current = row(status: "future-state")
        var writes = 0
        let api = AgentPluginLifecycleClient(api: BotConnectorsClient(profile: "writer") { _, params in
            if params["action"] == .string("list") { return .object(["plugins": .array([current])]) }
            writes += 1; return .object(["ok": .bool(true), "name": .string("other-plugin")])
        })
        do { _ = try await api.perform(.enable, reviewed: AgentPluginRecord(current)); XCTFail("Unknown state") } catch { XCTAssertEqual(writes, 0) }
        current = row()
        do { _ = try await api.perform(.enable, reviewed: AgentPluginRecord(current)); XCTFail("Different plugin receipt") } catch { XCTAssertEqual(writes, 1) }
    }
}
