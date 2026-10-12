import XCTest
import HermesGateway
@testable import HermesPhone

@MainActor final class SavedChatsStoreTests: XCTestCase {
    func testOldOwnerResponsesCannotReplaceHistoryAndBrowsingDoesNotUseLiveRPCs() async {
        let store = SavedChatsStore()
        var delayed: CheckedContinuation<JSON, Never>?
        store.bind(profile: "old") { _, _, _ in await withCheckedContinuation { delayed = $0 } }
        let old = Task { await store.load() }
        while delayed == nil { await Task.yield() }
        var paths: [String] = []
        store.bind(profile: "writer") { path, profile, _ in
            paths.append(path)
            XCTAssertEqual(profile, "writer")
            if path == "api/sessions" { return .object(["sessions": .array([Self.row("new")])]) }
            return Self.page(sessionID: "new", returned: 1, text: "Saved result")
        }
        await store.load()
        delayed?.resume(returning: .object(["sessions": .array([Self.row("old")])]))
        await old.value
        XCTAssertEqual(store.rows.map(\.id), ["new"])
        await store.open(store.rows[0])
        XCTAssertEqual(store.messages.map(\.text), ["Saved result"])
        XCTAssertEqual(paths, ["api/sessions", "api/sessions/new/messages"])
        XCTAssertFalse(store.hasEarlier)
        store.disconnect()
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNil(store.selected)
    }
    func testPagingCannotSpliceChangedCompressionTipAndExportStatesLoadedExtent() async {
        let store = SavedChatsStore()
        var page = 0
        store.bind(profile: "writer") { path, _, query in
            if path == "api/sessions" { return .object(["sessions": .array([Self.row("root")])]) }
            page += 1
            XCTAssertEqual(query.first { $0.name == "offset" }?.value, page == 1 ? "0" : "100")
            return Self.page(sessionID: page == 1 ? "tip1" : "tip2", returned: page == 1 ? 100 : 1, text: page == 1 ? "Current tail" : "Wrong earlier segment")
        }
        await store.load()
        await store.open(store.rows[0])
        XCTAssertTrue(store.hasEarlier)
        XCTAssertTrue(store.export(profile: "writer")?.contains("Loaded messages only") == true)
        await store.loadMessages()
        XCTAssertEqual(store.messages.map(\.text), ["Current tail"])
        XCTAssertTrue(store.error?.contains("changed") == true)
    }
    static func row(_ id: String) -> JSON {
        .object(["id": .string(id), "profile": .string("writer"), "title": .string("Saved")])
    }
    static func page(sessionID: String, returned: Int, text: String) -> JSON {
        .object(["session_id": .string(sessionID), "profile": .string("writer"), "messages": .array([
            .object(["role": .string("assistant"), "row_id": .number(1), "content": .string(text)])
        ]), "pagination": .object(["returned": .number(Double(returned))])])
    }
}
