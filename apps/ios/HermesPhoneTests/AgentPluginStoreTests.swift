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
}
