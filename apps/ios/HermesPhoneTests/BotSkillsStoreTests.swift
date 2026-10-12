import XCTest
import HermesGateway
@testable import HermesPhone

@MainActor final class BotSkillsStoreTests: XCTestCase {
    private func rows(_ enabled: Bool) -> JSON { .array([.object(["name": .string("example"), "enabled": .bool(enabled)])]) }
    func testUncertainToggleRequiresRefreshWithoutReplay() async {
        var enabled = true
        var writes = 0
        let api = BotSkillsClient(profile: "writer", request: { _, _ in .object([:]) }, http: { _, _, _, method, _ in
            if method == "PUT" { enabled = false; writes += 1; throw GatewayError.message("Lost receipt") }
            return self.rows(enabled)
        })
        let model = BotSkillsStore(); model.bind(api); await model.refresh()
        await model.setEnabled(name: "example", enabled: false); await model.setEnabled(name: "example", enabled: false)
        XCTAssertEqual(writes, 1); XCTAssertFalse(model.canChange); XCTAssertTrue(model.needsRefresh)
        XCTAssertNil(model.notice); XCTAssertFalse(model.installAvailable)
        await model.refresh()
        XCTAssertEqual(model.skills.first?.enabled, false); XCTAssertTrue(model.canChange); XCTAssertEqual(writes, 1)
    }
    func testOldOwnerCannotReplaceNewSkills() async {
        var pending: CheckedContinuation<JSON, Never>?
        let old = BotSkillsClient(profile: "old", request: { _, _ in .null }, http: { _, _, _, _, _ in await withCheckedContinuation { pending = $0 } })
        let new = BotSkillsClient(profile: "new", request: { _, params in
            XCTAssertEqual(params["profile"], .string("new")); return .object(["skills_install_next_session": .bool(true)])
        }, http: { _, profile, _, _, _ in XCTAssertEqual(profile, "new"); return self.rows(false) })
        let model = BotSkillsStore(); model.bind(old)
        let read = Task { await model.refresh() }
        while pending == nil { await Task.yield() }
        model.bind(new); await model.refresh(); pending?.resume(returning: rows(true)); await read.value
        XCTAssertEqual(model.skills.first?.enabled, false); XCTAssertTrue(model.installAvailable); XCTAssertTrue(model.canChange)
    }
}
