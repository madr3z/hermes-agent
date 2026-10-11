import XCTest
@testable import HermesGateway

@MainActor final class MCPOAuthTests: XCTestCase {
    func testNativeCallbackRelaysOnlyExpectedFieldsToSelectedProfile() async throws {
        var calls: [(String, [String: JSON])] = []
        let client = BotConnectorsClient(profile: "writer") { method, params in
            calls.append((method, params))
            if method.hasSuffix("start") { return .object(["ok": .bool(true), "session_id": .string("flow-1"), "auth_url": .string("https://provider.example/authorize?state=expected")]) }
            if method.hasSuffix("poll") { return .object(["ok": .bool(true), "status": .string("approved")]) }
            return .object(["ok": .bool(true)])
        }
        let session = try await client.startOAuth(name: "gmail-work")
        XCTAssertEqual(calls[0].1["client_redirect_uri"], .string("com.hermes.iphone:/oauth/callback"))
        try await client.deliverOAuth(session, callback: XCTUnwrap(URL(string: "com.hermes.iphone:/oauth/callback?code=one-time-code&state=expected&iss=https%3A%2F%2Fprovider.example&other=ignored")))
        XCTAssertEqual(calls[1].1["code"], .string("one-time-code"))
        XCTAssertEqual(calls[1].1["state"], .string("expected"))
        XCTAssertEqual(calls[1].1["iss"], .string("https://provider.example"))
        XCTAssertNil(calls[1].1["other"])
        let status = try await client.pollOAuth(session)
        XCTAssertEqual(status, "approved")
        try await client.cancelOAuth(session)
        XCTAssertTrue(calls.allSatisfy { $0.1["profile"] == .string("writer") && $0.1["name"] == .string("gmail-work") })
        XCTAssertTrue(calls.dropFirst().allSatisfy { $0.1["session_id"] == .string("flow-1") })
    }
    func testRejectsWrongCallbackOrAmbiguousStateBeforeRelay() throws {
        let session = try MCPOAuthSession(name: "gmail-work", result: .object(["ok": .bool(true), "session_id": .string("flow"), "auth_url": .string("")]))
        for raw in ["https://example.com/oauth/callback?code=c&state=s", "com.hermes.iphone://other/oauth/callback?code=c&state=s", "com.hermes.iphone:/other?code=c&state=s", "com.hermes.iphone:/oauth/callback?code=c", "com.hermes.iphone:/oauth/callback?code=c&state=s&state=second"] {
            XCTAssertThrowsError(try session.callbackParameters(XCTUnwrap(URL(string: raw))))
        }
        XCTAssertEqual(try session.callbackParameters(XCTUnwrap(URL(string: "com.hermes.iphone:/oauth/callback?error=access_denied&state=s")))["error"], .string("access_denied"))
    }
    func testOldGatewayAndPinnedMacCallbackReturnHonestFallback() async throws {
        for message in ["client_redirect_uri must be a loopback http URL", "This provider uses a registered loopback callback. Complete sign-in on your Mac."] {
            let client = BotConnectorsClient(profile: "bot") { _, _ in throw GatewayError.rpc(code: 4001, message: message) }
            do { _ = try await client.startOAuth(name: "gmail-work"); XCTFail("Should reject") }
            catch { XCTAssertTrue(error.localizedDescription.contains(message.contains("registered") ? "Finish sign-in on your Mac" : "needs an update")) }
        }
    }
    func testUnsafeAuthorizationURLCancelsItsBackendSession() async throws {
        var methods: [String] = []
        let client = BotConnectorsClient(profile: "bot") { method, _ in
            methods.append(method)
            return .object(["ok": .bool(true), "session_id": .string("flow"), "auth_url": .string("http://provider.example/authorize")])
        }
        do { _ = try await client.startOAuth(name: "gmail-work"); XCTFail("Should reject insecure authorization") }
        catch { XCTAssertTrue(error.localizedDescription.contains("secure sign-in URL")) }
        XCTAssertEqual(methods, ["mcp.servers.oauth.start", "mcp.servers.oauth.cancel"])
    }
}
