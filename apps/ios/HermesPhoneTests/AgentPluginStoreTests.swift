import XCTest
import HermesGateway
@testable import HermesPhone

@MainActor final class AgentPluginStoreTests: XCTestCase {
    private func row(status: String = "disabled") -> JSON {
        .object(["name": .string("demo"), "key": .string("demo"), "source": .string("git"), "status": .string(status)])
    }
    func testUncertainActionNeedsRefreshAndDoesNotReplay() async throws {
        var writes = 0
        var status = "disabled"
        let api = AgentPluginLifecycleClient(api: BotConnectorsClient(profile: "writer") { _, params in
            if params["action"] == .string("list") { return .object(["plugins": .array([self.row(status: status)])]) }
            writes += 1; status = "enabled"
            throw GatewayError.message("Connection lost after submission")
        })
        let state = AgentPluginStore(id: "demo"); state.bind(api)
        await state.refresh()
        let reviewed = try XCTUnwrap(state.record)
        let success = await state.perform(.enable, reviewed: reviewed)
        XCTAssertFalse(success); XCTAssertTrue(state.needsRefresh); XCTAssertFalse(state.canAct)
        _ = await state.perform(.enable, reviewed: reviewed)
        XCTAssertEqual(writes, 1)
        await state.refresh()
        XCTAssertTrue(state.canAct); XCTAssertEqual(state.record?.plugin.status, "enabled"); XCTAssertEqual(writes, 1)
    }
    func testDisableAndRemovalReceiptsRetainRestartAndMemoryProviderEffects() {
        let disable = AgentPluginStore.receipt(.object(["ok": .bool(true)]), action: .disable)
        XCTAssertTrue(disable.contains("until the bot gateway restarts"))
        let removal = AgentPluginStore.receipt(.object(["ok": .bool(true), "cleared_memory_provider": .bool(true)]), action: .remove)
        XCTAssertTrue(removal.contains("memory provider")); XCTAssertTrue(removal.contains("selection was cleared"))
    }
    func testConfirmedUpdateIsOneShotAndUncertainReplyClearsReview() async throws {
        let record = JSON.object(["name": .string("demo"), "key": .string("demo"), "source": .string("git"), "status": .string("enabled"),
                                  "installed_sha": .string("old"), "catalog_name": .string("demo"), "update_available": .bool(true)])
        let delta = JSON.object(["tools": .array([.string("shell_out")])])
        let binding = JSON.object(["installed_name": .string("demo"), "catalog_name": .string("demo"), "installed_sha": .string("old"),
                                   "target_sha": .string("new"), "delta": delta])
        var writes = 0
        let api = AgentPluginLifecycleClient(api: BotConnectorsClient(profile: "writer") { _, params in
            if params["action"] == .string("list") { return .object(["plugins": .array([record])]) }
            writes += 1
            if params["accept_capabilities"] == .bool(true) { throw GatewayError.message("Reply lost after submission") }
            return .object(["ok": .bool(false), "consent_required": .bool(true), "sha": .string("new"), "delta": delta, "update_review": binding])
        })
        let state = AgentPluginStore(id: "demo"); state.bind(api); await state.refresh()
        let selected = try XCTUnwrap(state.record)
        let previewed = await state.perform(.update, reviewed: selected)
        XCTAssertTrue(previewed)
        let review = try XCTUnwrap(state.updateReview)
        let confirmed = await state.perform(.update, reviewed: selected, consent: review)
        XCTAssertFalse(confirmed)
        XCTAssertTrue(state.needsRefresh); XCTAssertNil(state.updateReview)
        _ = await state.perform(.update, reviewed: selected, consent: review)
        await state.refresh()
        _ = await state.perform(.update, reviewed: selected, consent: review)
        XCTAssertEqual(writes, 2); XCTAssertNil(state.updateReview)
    }

}
