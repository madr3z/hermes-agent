import XCTest
import HermesGateway
@testable import HermesPhone

@MainActor final class ChatRequestsStoreTests: XCTestCase {
    func testCapabilityGateWithdrawalAndReconnectRestoreOnlyCurrentRequest() async throws {
        let store = ChatRequestsStore()
        var calls: [String] = []
        let request: ChatRequestsClient.Request = { method, params in
            calls.append(method)
            XCTAssertEqual(params["profile"], .string("writer"))
            XCTAssertEqual(params["session_id"], .string("runtime"))
            return .object(["status": .string("ok")])
        }
        store.bind(profile: "writer", runtimeID: "runtime", supported: false, request: request)
        store.receive(Self.approval())
        XCTAssertTrue(store.items.isEmpty)
        store.bind(profile: "writer", runtimeID: "runtime", supported: true, request: request)
        store.receive(Self.approval(runtime: "foreign"))
        let oldSnapshotRevision = store.snapshotRevision
        store.receive(Self.approval())
        store.restore(.object(["session_id": .string("runtime"), "open_requests": .array([])]), ifUnchanged: oldSnapshotRevision)
        XCTAssertEqual(store.items.map(\.id), ["srq1"])
        XCTAssertTrue(calls.isEmpty) // Receiving/replay is never consent.
        await store.shown(store.items[0])
        await store.shown(store.items[0])
        XCTAssertEqual(calls, ["approval.received"])
        store.event(Self.withdraw(runtime: "foreign"))
        XCTAssertEqual(store.items.count, 1)
        store.event(Self.withdraw(runtime: "runtime"))
        XCTAssertTrue(store.items.isEmpty)
        store.restore(.object(["session_id": .string("runtime"), "open_requests": .array([Self.approval()])]))
        XCTAssertEqual(store.items.count, 1)
        store.disconnect()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.connected)
    }
    func testUncertainAnswerCannotReplayAndLateReplyCannotSettleNewOwner() async {
        let store = ChatRequestsStore()
        var calls = 0
        store.bind(profile: "writer", runtimeID: "runtime", supported: true) { _, _ in
            calls += 1; throw GatewayError.message("Lost acknowledgement")
        }
        store.receive(Self.approval())
        let item = store.items[0]
        await store.answer(item, choice: "once")
        await store.answer(item, choice: "once")
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(store.uncertain.contains(item.id))
        var delayed: CheckedContinuation<JSON, Never>?
        store.bind(profile: "writer", runtimeID: "runtime", supported: true) { _, _ in await withCheckedContinuation { delayed = $0 } }
        store.receive(Self.approval())
        let old = Task { await store.answer(store.items[0], choice: "once") }
        while delayed == nil { await Task.yield() }
        store.bind(profile: "other", runtimeID: "next", supported: true) { _, _ in .object([:]) }
        store.receive(Self.approval(runtime: "next"))
        delayed?.resume(returning: .object(["status": .string("ok")]))
        await old.value
        XCTAssertEqual(store.items.map(\.sessionID), ["next"])
        XCTAssertTrue(store.working.isEmpty)
    }
    static func approval(runtime: String = "runtime") -> JSON {
        .object(["id": .string("srq1"), "method": .string("approval"), "params": .object([
            "session_id": .string(runtime), "request_id": .string("queue1"), "command": .string("Synthetic action"), "choices": .array([.string("once"), .string("deny")])
        ])])
    }
    static func withdraw(runtime: String) -> JSON {
        .object(["session_id": .string(runtime), "type": .string("request.cancel"), "payload": .object(["id": .string("srq1")])])
    }
}
