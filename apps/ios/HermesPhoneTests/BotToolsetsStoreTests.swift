import XCTest
import HermesGateway
@testable import HermesPhone

@MainActor final class BotToolsetsStoreTests: XCTestCase {
    private func row(name: String = "terminal", enabled: Bool = true) -> JSON {
        .array([.object(["name": .string(name), "enabled": .bool(enabled)])])
    }

    func testUncertainWriteRequiresRefreshAndDoesNotReplay() async {
        var enabled = true
        var writes = 0
        let api = BotToolsetsClient(profile: "writer", runtimeID: nil, request: { _, _ in .null }, http: { _, _, _, method in
            if method == "GET" { return self.row(enabled: enabled) }
            writes += 1; enabled = false
            throw GatewayError.message("Lost acknowledgement")
        })
        let store = BotToolsetsStore()
        store.bind(api)
        await store.refresh()
        await store.setEnabled(name: "terminal", enabled: false)
        await store.setEnabled(name: "terminal", enabled: false)
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(store.canChange)
        XCTAssertTrue(store.needsRefresh)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.snapshot?.toolsets.first?.enabled, true)
        await store.refresh()
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(store.snapshot?.toolsets.first?.enabled, false)
        XCTAssertTrue(store.canChange)
    }

    func testOldOwnerReadCannotOverwriteNewOwnerAfterRebinding() async {
        var pending: CheckedContinuation<JSON, Never>?
        let old = BotToolsetsClient(profile: "old", runtimeID: nil, request: { _, _ in .null }, http: { _, _, _, _ in
            await withCheckedContinuation { pending = $0 }
        })
        let new = BotToolsetsClient(profile: "new", runtimeID: nil, request: { _, _ in .null }, http: { _, profile, _, _ in
            XCTAssertEqual(profile, "new")
            return self.row(name: "file")
        })
        let store = BotToolsetsStore()
        store.bind(old)
        let oldRead = Task { await store.refresh() }
        while pending == nil { await Task.yield() }
        store.bind(new)
        await store.refresh()
        pending?.resume(returning: row())
        await oldRead.value
        XCTAssertEqual(store.snapshot?.toolsets.map(\.id), ["file"])
        XCTAssertFalse(store.loading)
        XCTAssertTrue(store.canChange)
    }
}
