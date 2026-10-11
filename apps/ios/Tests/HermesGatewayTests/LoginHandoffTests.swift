import XCTest
@testable import HermesGateway

final class LoginHandoffTests: XCTestCase {
    func testCardOnlyAcceptsSecureProviderAndFixedDeviceVerificationURLs() {
        let card = LoginHandoff(.object([
            "id": .string("request-a"), "provider": .string("mcp"), "name": .string("linear"),
            "auth_url": .string("https://user:password@example.com/authorize"),
            "verification_url": .string("https://phishing.example/device"), "status": .string("expired")
        ]))
        XCTAssertNil(card.authorizationURL)
        XCTAssertNil(card.verificationURL)
        XCTAssertTrue(card.canRetry)
        let valid = LoginHandoff(.object([
            "auth_url": .string("https://linear.app/oauth/authorize?state=opaque"),
            "verification_url": .string("https://auth.openai.com/codex/device"),
            "scopes": .array([.string("read")]), "status": .string("authorized"), "continued": .bool(true)
        ]))
        XCTAssertEqual(valid.authorizationURL?.host, "linear.app")
        XCTAssertEqual(valid.verificationURL?.host, "auth.openai.com")
        XCTAssertEqual(valid.scopes, ["read"])
        XCTAssertTrue(valid.continued)
        XCTAssertFalse(valid.canRetry)
    }
    func testHandledRequestsStayHiddenWhenRestoredButAccountConfirmationRemainsVisible() throws {
        for row: JSON in [
            .object(["status": .string("authorized"), "continued": .bool(true), "continuation_status": .string("submitted")]),
            .object(["status": .string("authorized"), "continued": .bool(true)]),
            .object(["status": .string("canceled")]),
            .object(["status": .string("dismissed")])
        ] {
            XCTAssertFalse(LoginHandoff(row).needsAction)
            let restored = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(row))
            XCTAssertFalse(LoginHandoff(restored).needsAction)
        }
        XCTAssertTrue(LoginHandoff(.object(["status": .string("authorized"), "continued": .bool(false)])).needsAction)
    }
    func testOutstandingLoginRetryAndUncertainContinuationRemainVisible() {
        for status in ["awaiting_human", "failed", "expired"] {
            XCTAssertTrue(LoginHandoff(.object(["status": .string(status)])).needsAction)
        }
        XCTAssertTrue(LoginHandoff(.object(["status": .string("authorized"), "continued": .bool(true), "continuation_status": .string("unconfirmed")])).needsAction)
    }

}
