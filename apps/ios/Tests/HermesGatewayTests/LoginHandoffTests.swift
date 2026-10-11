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
}
