import XCTest
@testable import HermesGateway

final class ChatContentTests: XCTestCase {
    func testMarkdownFileDestinationsPreserveParenthesesAndDecodeEscapes() {
        let content = ChatContent.parse("[Report](</tmp/report (final).pdf>)\n[Encoded](/tmp/report%20final.pdf)\n@file:/tmp/literal%20name.pdf")
        XCTAssertEqual(content.attachments.map(\.path), ["/tmp/report (final).pdf", "/tmp/report final.pdf", "/tmp/literal%20name.pdf"])
        XCTAssertTrue(content.blocks.isEmpty)
    }
    func testInlineCodeExamplesStayLiteralWhileAuthoredQuotedDirectiveStillAttaches() {
        let examples = "Use `@file:/tmp/example.txt` and ``[PDF](/tmp/a.pdf) with `ticks` `` in your prompt."
        let content = ChatContent.parse(examples + "\n@file:`/tmp/real file.pdf`")
        XCTAssertEqual(content.attachments.map(\.path), ["/tmp/real file.pdf"])
        XCTAssertEqual(content.blocks.first?.text.trimmingCharacters(in: .whitespacesAndNewlines), examples)
    }
    func testAttachmentReferencesRespectQuotedPathsAndCodeExamples() {
        let content = ChatContent.parse("""
        See **report**.
        @image:`/workspace/photo one.jpg`
        [Report](report.pdf)
        MEDIA:/workspace/result.csv.
        ```swift
        let example = "@file:/private/example.txt"
        ```
        """)
        XCTAssertEqual(content.attachments.map(\.path), ["/workspace/photo one.jpg", "report.pdf", "/workspace/result.csv"])
        XCTAssertEqual(content.attachments.map(\.isImage), [true, false, false])
        XCTAssertTrue(content.blocks.contains { $0.kind == .code && $0.text.contains("@file:/private/example.txt") })
        XCTAssertFalse(content.blocks.filter { $0.kind != .code }.contains { $0.text.contains("@image:") })
        XCTAssertTrue(ChatContent.parse("[Web](https://example.com/file.pdf)").attachments.isEmpty)
    }
    func testStagedUploadUsesServerReferenceAndRejectsOversizeBeforeSending() async throws {
        var calls: [String] = []
        let upload = try ChatUpload(name: "photo.jpg", data: Data([1, 2, 3]), isImage: true)
        let staged = try await upload.stage { method, params in
            calls.append(method)
            XCTAssertEqual(params["name"]?.string, "photo.jpg")
            XCTAssertNil(params["path"])
            return .object(["attached": .bool(true), "path": .string("/guest/attachments/photo.jpg"), "ref_text": .string("@file:/guest/attachments/photo.jpg")])
        }
        XCTAssertEqual(calls, ["file.attach"])
        XCTAssertEqual(staged.path, "/guest/attachments/photo.jpg")
        XCTAssertEqual(staged.reference, "@file:/guest/attachments/photo.jpg")
        XCTAssertThrowsError(try ChatUpload(name: "huge", data: Data(count: ChatUpload.maximumBytes + 1), isImage: false))
    }
    @MainActor func testFileRequestRetainsOwnerProxyAndNeverUsesQueryCredentials() throws {
        let endpoint = try GatewayEndpoint(label: "Bot", baseURL: URL(string: "https://main.example:9443/hermes/api/plugins/bot-provisioning/v1/gateways/bot")!)
        let client = GatewayClient(endpoint: endpoint, token: "private-token")
        let request = try client.fileRequest(path: "/workspace/report + one.pdf", profile: "writer", storedSessionID: "stored-tip")
        let parts = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertTrue(parts.percentEncodedQuery?.contains("%2B") == true)
        XCTAssertEqual(parts.path, "/hermes/api/plugins/bot-provisioning/v1/gateways/bot/api/fs/download")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name, $0.value!) }), ["profile": "writer", "session_id": "stored-tip", "path": "/workspace/report + one.pdf"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-token")
        let cookieClient = GatewayClient(endpoint: endpoint, token: nil)
        XCTAssertNil(try cookieClient.fileRequest(path: "/workspace/file", profile: "writer", storedSessionID: "stored-tip").value(forHTTPHeaderField: "Authorization"))
        XCTAssertThrowsError(try client.fileRequest(path: "/workspace/file", profile: "writer", storedSessionID: ""))
        XCTAssertThrowsError(try client.fileRequest(path: "https://foreign.example/file", profile: "writer", storedSessionID: "stored-tip"))
    }
    func testToolHistoryProjectsOnlyNamedToolRowsAndKeepsStableCallIdentity() {
        let rows: [JSON] = [.object(["role": .string("tool"), "name": .string("terminal"), "tool_call_id": .string("call-1"), "context": .string("ls")]), .object(["role": .string("tool"), "content": .string("raw")])]
        let messages = ChatMessage.project(rows)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.id, "tool-call-1")
        XCTAssertEqual(messages.first?.toolName, "terminal")
    }
}
