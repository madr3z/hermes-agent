import AuthenticationServices
import HermesGateway
import XCTest
@testable import HermesPhone

@MainActor private final class TestLoginBrowser: LoginBrowser {
    var starts = 0
    var canceled = false
    func start() -> Bool { starts += 1; return true }
    func cancel() { canceled = true }
}

@MainActor final class ChatLoginControllerTests: XCTestCase {
    private let url = URL(string: "https://login.example/authorize?state=owned-state&redirect_uri=com.hermes.iphone%3A%2Foauth%2Fcallback")!
    private var request: LoginHandoff { LoginHandoff(.object([
        "id": .string("request-a"), "name": .string("account-a"), "provider": .string("mcp")
    ])) }

    func testBrowserStaysBusyAndHumanCancelRetiresTheOwningAttempt() async {
        let controller = ChatLoginController(), browser = TestLoginBrowser()
        var callback: ((URL?, Error?) -> Void)?
        controller.makeBrowser = { _, _, completion in callback = completion; return browser }
        let canceled = expectation(description: "Owning request canceled")
        let send: (String, [String: JSON]) async throws -> JSON = { action, _ in
            XCTAssertEqual(action, "cancel"); canceled.fulfill(); return .null
        }
        controller.presentAuthentication(url, request: request, isCurrent: { true }, send: send, refresh: {})
        XCTAssertTrue(controller.working)
        controller.presentAuthentication(url, request: request, isCurrent: { true }, send: send, refresh: {})
        XCTAssertEqual(browser.starts, 1)
        callback?(nil, ASWebAuthenticationSessionError(.canceledLogin))
        await fulfillment(of: [canceled], timeout: 5)
        await Task.yield()
        XCTAssertFalse(controller.working)
    }

    func testDepartedBrowserCannotRelayItsLateCallbackOrClearNewAttempt() async {
        let controller = ChatLoginController(), first = TestLoginBrowser(), second = TestLoginBrowser()
        var callbacks: [(URL?, Error?) -> Void] = []
        controller.makeBrowser = { _, _, completion in callbacks.append(completion); return callbacks.count == 1 ? first : second }
        let canceled = expectation(description: "Old attempt canceled")
        controller.presentAuthentication(url, request: request, isCurrent: { true }, send: { action, _ in
            XCTAssertEqual(action, "cancel"); canceled.fulfill(); return .null
        }, refresh: {})
        controller.contextChanged()
        await fulfillment(of: [canceled], timeout: 5)
        controller.presentAuthentication(url, request: request, isCurrent: { true }, send: { _, _ in
            XCTFail("An old callback must not reach the new attempt"); return .null
        }, refresh: {})
        callbacks[0](URL(string: "com.hermes.iphone:/oauth/callback?code=PRIVATE&state=owned-state"), nil)
        await Task.yield()
        XCTAssertTrue(first.canceled)
        XCTAssertTrue(controller.working)
        XCTAssertFalse(second.canceled)
        controller.closeBrowser(cancelAttempt: false)
    }
}
