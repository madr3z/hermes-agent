import Foundation
import XCTest
@testable import HermesGateway

private final class ControllerHTTPFixture: URLProtocol {
    static var cookieStorage: HTTPCookieStorage?
    static var response: ((URLRequest) throws -> (Int, JSON, [String: String]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body, headers) = try Self.response!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers.merging(["Content-Type": "application/json"]) { old, _ in old })!
            // Custom URLProtocol responses bypass the HTTP loader's cookie processing.
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: request.url!)
            Self.cookieStorage?.setCookies(cookies, for: request.url!, mainDocumentURL: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class ControllerSessionTests: XCTestCase {
    @MainActor func testPasswordLoginSavesOnlySecureScopedSessionAndPreservesRotatedCookies() async throws {
        let endpoint = try GatewayEndpoint(label: "Controller", baseURL: URL(string: "https://main.example:9443/hermes")!)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ControllerHTTPFixture.self]
        let controller = ControllerSession(endpoint: endpoint, configuration: configuration)
        ControllerHTTPFixture.cookieStorage = controller.session.configuration.httpCookieStorage
        defer { controller.session.invalidateAndCancel(); ControllerHTTPFixture.response = nil; ControllerHTTPFixture.cookieStorage = nil }
        let password = "transient-controller-password"
        ControllerHTTPFixture.response = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.url!.path == "/hermes/api/auth/providers" { return (200, .object(["providers": .array([.object(["name": .string("basic"), "supports_password": .bool(true)])])]), [:]) }
            if request.url!.path == "/hermes/auth/password-login" {
                XCTAssertEqual(request.httpMethod, "POST")
                let bytes: Data
                if let body = request.httpBody { bytes = body }
                else {
                    let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
                    var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }; bytes = data
                }
                let sent = try JSONDecoder().decode(JSON.self, from: bytes)
                XCTAssertEqual(sent, .object(["provider": .string("basic"), "username": .string("alice"), "password": .string(password), "next": .string("")]))
                return (200, .object(["ok": .bool(true)]), ["Set-Cookie": "__Secure-hermes_session_at=fixture-access; Path=/hermes; Max-Age=3600; Secure; HttpOnly; SameSite=Lax"])
            }
            XCTAssertEqual(request.url!.path, "/hermes/api/status")
            return (200, .object(["ok": .bool(true)]), ["Set-Cookie": "__Secure-hermes_session_at=rotated-access; Path=/hermes; Max-Age=3600; Secure; HttpOnly; SameSite=Lax"])
        }
        let providers = try await controller.passwordProviders()
        XCTAssertEqual(providers.first?["name"].string, "basic")
        try await controller.signIn(provider: "basic", username: "alice", password: password)
        let saved = try controller.savedData()
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(password))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("alice"))
        let restored = try XCTUnwrap(ControllerSession.restore(endpoint: endpoint, data: saved))
        defer { restored.session.invalidateAndCancel() }
        XCTAssertEqual(restored.session.configuration.httpCookieStorage?.cookies?.first?.value, "fixture-access")
        for address in ["https://other.example:9443/hermes", "https://main.example:9444/hermes", "https://main.example:9443/other"] {
            let changed = try GatewayEndpoint(id: endpoint.id, label: "Changed", baseURL: URL(string: address)!)
            XCTAssertThrowsError(try ControllerSession.restore(endpoint: changed, data: saved))
        }
        var persisted: Data?
        let client = GatewayClient(endpoint: endpoint, token: nil, session: controller.session, onAuthenticationChange: { persisted = try controller.savedData() })
        _ = try await client.http("api/status")
        XCTAssertTrue(String(decoding: try XCTUnwrap(persisted), as: UTF8.self).contains("rotated-access"))
        for address in ["https://other.example:9443/hermes/auth/password-login", "http://main.example:9443/hermes/auth/password-login", "https://main.example:9444/hermes", "https://main.example:9443/hermes-sibling", "https://main.example:9443/hermes/../other"] {
            let destination = URL(string: address)!
            XCTAssertFalse(ControllerScope.contains(destination, in: endpoint.baseURL), address)
            var redirected = URLRequest(url: destination)
            redirected.httpMethod = "POST"; redirected.httpBody = Data(password.utf8)
            redirected.setValue("Bearer fixture-credential", forHTTPHeaderField: "Authorization")
            redirected.setValue("fixture=cookie", forHTTPHeaderField: "Cookie")
            let task = controller.session.dataTask(with: endpoint.url(path: "auth/password-login"))
            let response = HTTPURLResponse(url: endpoint.baseURL, statusCode: 307, httpVersion: nil, headerFields: nil)!
            let delegate = try XCTUnwrap(controller.session.delegate as? URLSessionTaskDelegate)
            var called = false
            delegate.urlSession?(controller.session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { allowed in
                called = true; XCTAssertNil(allowed, "Do not forward credential-bearing redirects outside the controller scope")
            }
            XCTAssertTrue(called)
            task.cancel()
        }
        XCTAssertTrue(ControllerScope.contains(endpoint.url(path: "api/auth/ws-ticket"), in: endpoint.baseURL))
    }
}
