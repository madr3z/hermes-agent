import XCTest
import HermesGateway
@testable import HermesPhone

private final class BotCreationHTTPFixture: URLProtocol {
    static var response: ((URLRequest) throws -> (Int, JSON))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, json) = try Self.response!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(json))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) throws -> JSON {
        if let data = request.httpBody { return try JSONDecoder().decode(JSON.self, from: data) }
        let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return try JSONDecoder().decode(JSON.self, from: data)
    }
}

@MainActor final class BotCreationTests: XCTestCase {
    private var capabilities: JSON { .object(["linux_account": .object(["username": .string("bot_name"), "username_pattern": .string("^[a-z][a-z0-9_-]{0,31}$"), "reserved_usernames": .array([.string("root"), .string("daemon")]), "password": .object(["required": .bool(true), "min_bytes": .number(8), "max_bytes": .number(256)])])]) }
    func testExactLinuxUsernameAndUTF8PasswordValidation() {
        let policy = capabilities
        for name in ["a", "research_1-bot", String(repeating: "a", count: 32)] { XCTAssertNil(BotCreationSubmission.usernameError(name, capabilities: policy)) }
        for name in ["", "Research", " research", "research ", "research\n", "1bot", "résearch", "root", "daemon", String(repeating: "a", count: 33)] { XCTAssertNotNil(BotCreationSubmission.usernameError(name, capabilities: policy), name) }
        for password in ["12345678", String(repeating: "é", count: 4), String(repeating: "é", count: 128)] {
            XCTAssertNil(BotCreationSubmission.validationError(name: "research", password: password, confirmation: password, capabilities: policy))
        }
        for password in ["1234567", String(repeating: "é", count: 129), "abcd\0efgh", "abcd\refgh", "abcd\nefgh", "abcd\r\nefgh"] {
            XCTAssertNotNil(BotCreationSubmission.validationError(name: "research", password: password, confirmation: password, capabilities: policy))
        }
        XCTAssertNotNil(BotCreationSubmission.validationError(name: "research", password: "12345678", confirmation: "different", capabilities: policy))
        XCTAssertNotNil(BotCreationSubmission.validationError(name: "research", password: "12345678", confirmation: "12345678", capabilities: .null))
    }
    func testUncertainCreationRestoresWithoutPasswordAndChecksReceiptBeforeSameIDRetry() async throws {
        let suite = "hermes-bot-create-test-\(UUID())", gatewayID = UUID()
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); BotCreationHTTPFixture.response = nil }
        let endpoint = try GatewayEndpoint(id: gatewayID, label: "Main", baseURL: URL(string: "https://main.example")!)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [BotCreationHTTPFixture.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = GatewayClient(endpoint: endpoint, token: "controller-only", session: session)
        let body = JSON.object(["name": .string("research"), "resources": .object(["cpu": .number(2), "memory_mib": .number(2048), "disk_gib": .number(20)]), "credentials": .object(["copy": .bool(false), "source_profile": .string("default")]), "soul": .string("Research")])
        let password = "chosen-password-é"
        let key = "provision-request-\(gatewayID)"
        var posted: [JSON] = [], methods: [String] = [], lookupStatus = 404, loseResponse = true
        BotCreationHTTPFixture.response = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer controller-only")
            methods.append(request.httpMethod ?? "GET")
            if request.httpMethod == "POST" {
                let sent = try BotCreationHTTPFixture.body(request)
                let savedData = try XCTUnwrap(preferences.data(forKey: key))
                let saved = try JSONDecoder().decode(JSON.self, from: savedData)
                XCTAssertEqual(saved["request_id"], sent["request_id"])
                XCTAssertEqual(saved["linux_password"], .null)
                XCTAssertFalse(String(decoding: savedData, as: UTF8.self).contains(password))
                XCTAssertEqual(sent["linux_password"].string, password)
                posted.append(sent)
                if loseResponse { loseResponse = false; throw URLError(.timedOut) }
                return (202, .object(["request_id": sent["request_id"], "name": sent["name"], "phase": .string("queued")]))
            }
            XCTAssertTrue(request.url!.path.hasSuffix(posted.last!["request_id"].string!))
            if lookupStatus == 200 { return (200, .object(["request_id": posted.last!["request_id"], "phase": .string("queued")])) }
            return (lookupStatus, .object(["error": .object(["message": .string("Request unavailable")])]))
        }
        let original = BotCreationSubmission(preferences: preferences); original.restore(gatewayID: gatewayID)
        do { _ = try await original.submit(body: body, password: password, confirmation: password, capabilities: capabilities, client: client); XCTFail("Expected lost response") } catch {}
        let pending = try XCTUnwrap(original.pending)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(original.requestID)))
        XCTAssertEqual(methods, ["POST"])
        let restored = BotCreationSubmission(preferences: preferences); restored.restore(gatewayID: gatewayID)
        XCTAssertEqual(restored.pending, pending)
        let missingReceipt = try await restored.recover(client: client)
        XCTAssertNil(missingReceipt)
        XCTAssertTrue(restored.needsPassword)
        XCTAssertEqual(methods, ["POST", "GET"])
        do { _ = try await restored.submit(body: body, password: "", confirmation: "", capabilities: capabilities, client: client); XCTFail("Password re-entry required after 404") } catch {}
        XCTAssertEqual(posted.count, 1)
        let changedForm = JSON.object(["name": .string("other")])
        _ = try await restored.submit(body: changedForm, password: password, confirmation: password, capabilities: capabilities, client: client)
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(posted[0], posted[1])
        XCTAssertEqual(Array(methods.suffix(2)), ["GET", "POST"])
        XCTAssertNil(restored.pending); XCTAssertNil(preferences.data(forKey: key))

        loseResponse = true
        let nextCreation = BotCreationSubmission(preferences: preferences); nextCreation.restore(gatewayID: gatewayID)
        do { _ = try await nextCreation.submit(body: body, password: password, confirmation: password, capabilities: capabilities, client: client); XCTFail("Expected lost response") } catch {}
        let recovered = BotCreationSubmission(preferences: preferences); recovered.restore(gatewayID: gatewayID)
        lookupStatus = 503
        do { _ = try await recovered.submit(body: body, password: password, confirmation: password, capabilities: capabilities, client: client); XCTFail("GET failure must block POST") } catch {}
        XCTAssertEqual(posted.count, 3); XCTAssertNotNil(recovered.pending)
        lookupStatus = 200
        let receipt = try await recovered.submit(body: changedForm, password: "", confirmation: "", capabilities: .null, client: client)
        XCTAssertEqual(receipt["phase"].string, "queued")
        XCTAssertEqual(posted.count, 3)
        XCTAssertNil(recovered.pending); XCTAssertNil(preferences.data(forKey: key))
    }
}
