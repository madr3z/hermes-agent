import XCTest
import HermesGateway
@testable import HermesPhone

@MainActor final class SubagentsStoreTests: XCTestCase {
    private let rows: JSON = .object(["subagents": .array([.object([
        "subagent_id": .string("child-a"), "goal": .string("Task A"), "status": .string("running"),
        "can_interrupt": .bool(true), "can_steer": .bool(true)
    ])])])
    func testReconnectRejectsOldSnapshotAndLoadsNewCanonicalOwner() async {
        let store = SubagentsStore()
        var pending: CheckedContinuation<JSON, Never>?
        store.bind(profile: "writer", runtimeID: "old-runtime") { _, _ in
            await withCheckedContinuation { pending = $0 }
        }
        let oldRead = Task { await store.refresh() }
        while pending == nil { await Task.yield() }
        store.disconnect()
        var newCalls: [[String: JSON]] = []
        store.bind(profile: "writer", runtimeID: "new-runtime") { _, params in
            newCalls.append(params)
            return .object(["subagents": .array([.object(["subagent_id": .string("finished"), "status": .string("completed"), "summary": .string("Saved result")])])])
        }
        await store.refresh()
        pending?.resume(returning: rows)
        await oldRead.value
        XCTAssertEqual(store.tasks.map(\.id), ["finished"])
        XCTAssertEqual(store.tasks.first?.summary, "Saved result")
        XCTAssertEqual(newCalls.first?["session_id"], .string("new-runtime"))
        XCTAssertFalse(store.loading)
    }
    func testDisconnectAndUncertainMutationDisableReplayUntilRefresh() async {
        let store = SubagentsStore()
        var mutations = 0
        store.bind(profile: "writer", runtimeID: "runtime-a") { method, _ in
            if method == "subagent.list" { return self.rows }
            mutations += 1; throw GatewayError.message("Lost acknowledgement")
        }
        await store.refresh()
        await store.interrupt(id: "child-a")
        await store.interrupt(id: "child-a")
        XCTAssertEqual(mutations, 1)
        XCTAssertNotNil(store.error)
        store.disconnect()
        await store.refresh()
        await store.interrupt(id: "child-a")
        XCTAssertEqual(mutations, 1)
        XCTAssertFalse(store.connected)
        XCTAssertFalse(store.working)
    }
}
