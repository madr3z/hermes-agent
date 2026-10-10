import XCTest
@testable import HermesGateway

final class GatewayTests: XCTestCase {
    func testGatewayRetainsProxyPrefixAndEscapesToken() throws {
        let endpoint = try GatewayEndpoint(label: "VM", baseURL: URL(string: "https://hermes.example/api/plugins/bot-provisioning/v1/gateways/bot-one/")!)
        let parts = URLComponents(url: endpoint.webSocketURL(token: "a&b +?"), resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.scheme, "wss")
        XCTAssertEqual(parts.path, "/api/plugins/bot-provisioning/v1/gateways/bot-one/api/ws")
        XCTAssertEqual(parts.queryItems?.first?.value, "a&b +?")
        XCTAssertEqual(endpoint.url(path: "api/audio/voice-live/session", profile: "writer").path, "/api/plugins/bot-provisioning/v1/gateways/bot-one/api/audio/voice-live/session")
    }
    func testRejectsPlaintextAndEmbeddedCredentials() {
        for url in ["http://example.com", "https://user:password@example.com", "https://example.com?token=secret", "https://example.com/#secret"] {
            XCTAssertThrowsError(try GatewayEndpoint(label: "Bad", baseURL: URL(string: url)!))
        }
    }
    func testTranscriptRetainsStableVoiceIdentityAndHidesInternalRows() throws {
        let rows = try JSONDecoder().decode([JSON].self, from: Data("""
        [{"role":"user","text":"Hello","row_id":12},
         {"role":"assistant","text":"secret context","display_kind":"hidden"},
         {"role":"assistant","text":"Spoken answer","display_kind":"voice_live","display_metadata":{"voice_message_id":"voice:call:utterance"}},
         {"role":"tool","content":"raw tool output"}]
        """.utf8))
        let messages = ChatMessage.project(rows)
        XCTAssertEqual(messages.map(\.id), ["row-12", "voice:call:utterance"])
        XCTAssertTrue(messages.last!.voice)
    }
    func testSpokenAcknowledgementAndReplayReplaceAccumulatedText() {
        func row(_ text: String) -> JSON { .object(["role": .string("assistant"), "text": .string(text), "display_kind": .string("voice_live"), "display_metadata": .object(["voice_message_id": .string("voice:call:segment")])]) }
        var messages = ChatMessage.upserting(row("Hello"), into: [])
        messages = ChatMessage.upserting(row("Hello world"), into: messages)
        messages = ChatMessage.upserting(row("Hello world"), into: messages)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.text, "Hello world")
    }
    func testProvisionedGatewayIsSameOriginAndKeepsMainPort() throws {
        let main = try GatewayEndpoint(label: "Main", baseURL: URL(string: "https://hermes.example:9443")!)
        let ready = JSON.object(["gateway": .object(["base_url": .string("/api/plugins/bot-provisioning/v1/gateways/bot-1"), "label": .string("Bot")])])
        let vm = try main.provisionedGateway(ready)
        XCTAssertEqual(vm.baseURL.port, 9443)
        XCTAssertEqual(vm.url(path: "api/ws").path, "/api/plugins/bot-provisioning/v1/gateways/bot-1/api/ws")
        for path in ["https://evil.example", "//evil.example/api/ws", "/api/plugins/bot-provisioning/v1/gateways/../secrets", "/api/plugins/bot-provisioning/v1/gateways/bot?token=x"] {
            XCTAssertThrowsError(try main.provisionedGateway(.object(["gateway": .object(["base_url": .string(path)])])))
        }
    }
    func testGlobalReclamationAndInvalidationStayScopedToCurrentOwner() {
        let reclaimed = JSON.object(["type": .string("session.reclaimed"), "session_id": .string(""), "payload": .object(["session_id": .string("runtime"), "stored_session_id": .string("stored")])])
        XCTAssertEqual(ChatEventRoute.route(reclaimed, runtimeID: "runtime", profile: "writer"), .reclaimed)
        XCTAssertEqual(ChatEventRoute.route(reclaimed, runtimeID: "other", profile: "writer"), .ignore)
        XCTAssertEqual(ChatEventRoute.route(.object(["type": .string("sessions.changed"), "session_id": .string("")]), runtimeID: "runtime", profile: "writer"), .refreshCanonical)
        XCTAssertEqual(ChatEventRoute.route(.object(["type": .string("sessions.changed"), "profile": .string("other")]), runtimeID: "runtime", profile: "writer"), .ignore)
        XCTAssertEqual(ChatEventRoute.route(.object(["type": .string("message.delta"), "session_id": .string("other")]), runtimeID: "runtime", profile: "writer"), .ignore)
    }
    func testSupersededSpokenTaskNeverSpeaksUnderNewDelegation() {
        var tracker = VoiceDelegationTracker()
        func accepted(_ row: Double) -> JSON { .object(["user_row_id": .number(row)]) }
        func completion(_ row: Double, _ text: String) -> JSON { .object(["status": .string("complete"), "text": .string(text), "persisted_turn": .object(["user_row_id": .number(row)])]) }
        tracker.begin("A")
        XCTAssertNil(tracker.accept(accepted(10), delegationID: "A"))
        tracker.begin("B")
        XCTAssertNil(tracker.complete(completion(10, "late A")))
        XCTAssertNil(tracker.accept(accepted(20), delegationID: "B"))
        XCTAssertNil(tracker.complete(completion(30, "unrelated typed turn")))
        XCTAssertEqual(tracker.complete(completion(20, "B result")), VoiceTaskResult(delegationID: "B", text: "B result"))
        XCTAssertNil(tracker.complete(completion(20, "duplicate B")))
    }
    func testVoiceCompletionBeforeSubmitAcknowledgementKeepsItsIdentity() {
        var tracker = VoiceDelegationTracker()
        tracker.begin("B")
        let completion = JSON.object(["status": .string("complete"), "text": .string("fast B"), "persisted_turn": .object(["user_row_id": .number(20)])])
        XCTAssertNil(tracker.complete(completion))
        XCTAssertNil(tracker.accept(.object(["user_row_id": .number(10)]), delegationID: "A"))
        XCTAssertEqual(tracker.accept(.object(["user_row_id": .number(20)]), delegationID: "B"), VoiceTaskResult(delegationID: "B", text: "fast B"))
    }
    @MainActor func testCanonicalResumeUsesCompressionTipAndOwnerWithoutCreating() async throws {
        var calls: [(String, [String: JSON])] = []
        let result = try await CanonicalChat.open(profile: "writer") { method, params in
            calls.append((method, params))
            if method == "session.list" { return .object(["sessions": .array([.object(["id": .string("root"), "resolved_id": .string("tip"), "title": .string("Bot Chat")])])]) }
            return .object(["session_id": .string("runtime")])
        }
        XCTAssertEqual(result["session_id"].string, "runtime")
        XCTAssertEqual(calls.map(\.0), ["session.list", "session.resume"])
        XCTAssertEqual(calls[1].1["session_id"], .string("tip"))
        XCTAssertEqual(calls[1].1["profile"], .string("writer"))
        XCTAssertEqual(calls[1].1["close_on_disconnect"], .bool(false))
    }
    @MainActor func testRegistryFailureNeverCreatesReplacementConversation() async {
        var calls: [String] = []
        do {
            _ = try await CanonicalChat.open(profile: "writer") { method, _ in
                calls.append(method); throw GatewayError.message("offline")
            }
            XCTFail("Expected registry failure")
        } catch { XCTAssertEqual(calls, ["session.list"]) }
    }
    @MainActor func testConcurrentCanonicalCreationAdoptsRegistryWinner() async throws {
        var lookups = 0
        var calls: [String] = []
        let result = try await CanonicalChat.open(profile: "writer") { method, params in
            calls.append(method)
            switch method {
            case "session.list":
                lookups += 1
                return .object(["sessions": .array(lookups == 1 ? [] : [.object(["id": .string("winner"), "title": .string("Bot Chat")])])])
            case "session.create": return .object(["session_id": .string("loser")])
            case "session.title": throw GatewayError.message("Title already in use")
            case "session.resume":
                XCTAssertEqual(params["session_id"], .string("winner"))
                return .object(["session_id": .string("winner-runtime")])
            default: XCTFail("Unexpected RPC \(method)"); return .null
            }
        }
        XCTAssertEqual(result["session_id"].string, "winner-runtime")
        XCTAssertFalse(calls.contains("prompt.submit"))
    }
}
