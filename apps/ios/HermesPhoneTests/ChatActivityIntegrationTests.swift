import XCTest
import HermesGateway
@testable import HermesPhone

@MainActor final class ChatActivityIntegrationTests: XCTestCase {
    private func store() throws -> ChatStore {
        let endpoint = try GatewayEndpoint(label: "Bot", baseURL: URL(string: "https://main.example")!)
        return ChatStore(bot: Bot(endpointID: endpoint.id, row: .object(["name": .string("writer")])))
    }

    func testStaleCanonicalSnapshotCannotReopenCompletedActivity() throws {
        let chat = try store()
        let snapshot: JSON = .object(["session_id": .string("runtime-A"), "running": .bool(true)])
        chat.bindSnapshot(snapshot)
        XCTAssertTrue(chat.activity.isAnimating)
        chat.activity.receive(.object(["type": .string("message.complete"), "session_id": .string("runtime-A"), "payload": .object([:])]))
        chat.bindSnapshot(snapshot, restoreActivity: false)
        XCTAssertEqual(chat.activity.phase, .completed)
        XCTAssertFalse(chat.activity.isAnimating)
    }

    func testNewCanonicalRuntimeDropsOldActivityDespiteStaleRevision() throws {
        let chat = try store()
        chat.bindSnapshot(.object(["session_id": .string("runtime-A"), "running": .bool(true)]))
        chat.bindSnapshot(.object(["session_id": .string("runtime-B")]), restoreActivity: false)
        XCTAssertEqual(chat.activity.runtimeID, "runtime-B")
        XCTAssertEqual(chat.activity.phase, .idle)
        chat.activity.receive(.object(["type": .string("message.start"), "session_id": .string("runtime-A"), "payload": .object([:])]))
        XCTAssertFalse(chat.activity.isAnimating)
    }
}
