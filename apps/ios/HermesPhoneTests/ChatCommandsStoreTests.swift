import XCTest
import HermesGateway
@testable import HermesPhone

@MainActor final class ChatCommandsStoreTests: XCTestCase {
    func testRebindDropsOldCompletionAndCatalogReplies() async {
        let store = ChatCommandsStore()
        var pending: CheckedContinuation<JSON, Never>?
        store.bind(profile: "writer", runtimeID: "old") { _, _ in
            await withCheckedContinuation { pending = $0 }
        }
        let oldCompletion = Task { await store.complete("/sta") }
        while pending == nil { await Task.yield() }
        store.bind(profile: "writer", runtimeID: "new") { method, params in
            XCTAssertEqual(params["session_id"], .string("new"))
            XCTAssertEqual(params["profile"], .string("writer"))
            if method == "commands.catalog" { return .object(["pairs": .array([.array([.string("/help"), .string("Commands")])])]) }
            return .object(["items": .array([.object(["text": .string("help ")])]), "replace_from": .number(1)])
        }
        await store.load()
        await store.complete("/he")
        pending?.resume(returning: .object(["items": .array([.object(["text": .string("status ")])]), "replace_from": .number(1)]))
        await oldCompletion.value
        XCTAssertEqual(store.completions.map(\.text), ["help "])
        XCTAssertEqual(store.apply(store.completions[0], to: "/he"), "/help ")
        XCTAssertNil(store.apply(store.completions[0], to: "ordinary message"))
        XCTAssertEqual(store.catalog?.commands.map(\.id), ["/help"])
        store.disconnect()
        XCTAssertTrue(store.completions.isEmpty)
        XCTAssertNil(store.catalog)
        XCTAssertFalse(store.connected)
    }
}
