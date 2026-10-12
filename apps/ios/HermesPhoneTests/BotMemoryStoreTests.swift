import XCTest
import HermesGateway
@testable import HermesPhone

@MainActor final class BotMemoryStoreTests: XCTestCase {
    private func graph(_ label: String) -> JSON {
        .object(["nodes": .array([.object(["id": .string("memory:memory:0:abcdef012345"), "kind": .string("memory"), "label": .string(label), "memorySource": .string("memory")])])])
    }
    func testRebindAndFailedRefreshDoNotShowAnotherOwnersMemory() async {
        var pending: CheckedContinuation<JSON, Never>?
        let old = BotMemoryClient(profile: "old") { _, _, _ in await withCheckedContinuation { pending = $0 } }
        var fail = false
        let new = BotMemoryClient(profile: "new") { _, profile, _ in
            XCTAssertEqual(profile, "new")
            if fail { throw GatewayError.message("Disconnected") }
            return self.graph("New synthetic note")
        }
        let model = BotMemoryStore(); model.bind(old)
        let read = Task { await model.refresh() }
        while pending == nil { await Task.yield() }
        model.bind(new); XCTAssertTrue(model.cards.isEmpty); await model.refresh()
        pending?.resume(returning: graph("Old synthetic note")); await read.value
        XCTAssertEqual(model.cards.first?.label, "New synthetic note")
        fail = true; await model.refresh(); XCTAssertTrue(model.cards.isEmpty); XCTAssertNotNil(model.error)
        fail = false; await model.refresh(); XCTAssertFalse(model.cards.isEmpty)
        model.disconnect(); model.connectionFailed(GatewayError.message("New owner unavailable"))
        XCTAssertTrue(model.cards.isEmpty); XCTAssertNotNil(model.error)
    }
}
