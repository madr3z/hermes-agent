import XCTest
import HermesGateway
@testable import HermesPhone

@MainActor final class ChatAttachmentStateTests: XCTestCase {
    private func store() throws -> ChatStore {
        let endpoint = try GatewayEndpoint(label: "Bot", baseURL: URL(string: "https://main.example/api/plugins/bot-provisioning/v1/gateways/bot")!)
        return ChatStore(bot: Bot(endpointID: endpoint.id, row: .object(["name": .string("writer")])))
    }
    func testAttachmentDraftSurvivesCanonicalRebindButStagingNeverCrossesRuntime() async throws {
        let chat = try store()
        chat.draft = "Read this"
        chat.bindSnapshot(.object(["session_id": .string("runtime-A"), "stored_session_id": .string("stored-A")]))
        chat.addUpload(name: "report.pdf", data: Data("report".utf8), image: false)
        XCTAssertEqual(chat.uploads.count, 1)
        chat.uploads[0].staged = try await chat.uploads[0].stage { _, _ in
            .object(["attached": .bool(true), "path": .string("/guest/report.pdf"), "ref_text": .string("@file:/guest/report.pdf")])
        }
        XCTAssertNotNil(chat.uploads[0].staged)
        chat.bindSnapshot(.object(["session_id": .string("runtime-B"), "stored_session_id": .string("stored-B")]))
        XCTAssertEqual(chat.draft, "Read this")
        XCTAssertEqual(chat.uploads.count, 1)
        XCTAssertNil(chat.uploads.first?.staged)
        XCTAssertEqual(chat.storedSessionID, "stored-B")
        chat.bindSnapshot(.object(["session_id": .string("unowned-runtime")]))
        XCTAssertNil(chat.storedSessionID)
    }
    func testCombinedUploadLimitAndRemovalCannotChangeAnActiveSend() throws {
        let chat = try store()
        chat.addUpload(name: "first", data: Data(count: 6 * 1024 * 1024), image: false)
        chat.addUpload(name: "second", data: Data(count: 6 * 1024 * 1024), image: false)
        XCTAssertEqual(chat.uploads.count, 1)
        XCTAssertNotNil(chat.error)
        let id = try XCTUnwrap(chat.uploads.first?.id)
        chat.sending = true; chat.removeUpload(id)
        XCTAssertEqual(chat.uploads.count, 1)
        chat.sending = false; chat.removeUpload(id)
        XCTAssertTrue(chat.uploads.isEmpty)
    }
}
