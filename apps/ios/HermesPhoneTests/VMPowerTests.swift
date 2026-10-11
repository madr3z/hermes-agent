import XCTest
import HermesGateway
@testable import HermesPhone

private final class PowerHTTPFixture: URLProtocol {
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
}

@MainActor final class VMPowerTests: XCTestCase {
    func testUncertainRestartPersistsBeforeSendAndOnlyExplicitRetryReusesIdentity() async throws {
        let suite = "hermes-phone-power-test-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); PowerHTTPFixture.response = nil }
        let endpoint = try GatewayEndpoint(label: "Main", baseURL: URL(string: "https://main.example")!)
        let owner = try ProvisionedOwner(mainID: endpoint.id, requestID: UUID().uuidString.lowercased(), gatewayURL: URL(string: "https://main.example/api/plugins/bot-provisioning/v1/gateways/guest")!)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PowerHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GatewayClient(endpoint: endpoint, token: "main-only", session: session)
        var submissions: [JSON] = []
        var failStatus = false
        let route = "/" + owner.route
        PowerHTTPFixture.response = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer main-only")
            let path = request.url!.path
            if path == "/api/plugins/bot-provisioning/v1/capabilities" { return (200, .object(["vm_control": .bool(true)])) }
            if path == route + "/vm" { if failStatus { throw URLError(.cannotConnectToHost) }; return (200, .object(["phase": .string("running"), "desired_state": .string("running"), "observed_state": .string("running")])) }
            if path == route + "/power" && request.httpMethod == "POST" {
                let bytes: Data
                if let body = request.httpBody { bytes = body }
                else {
                    let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
                    var collected = Data(), buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; collected.append(buffer, count: count) }
                    bytes = collected
                }
                let body = try JSONDecoder().decode(JSON.self, from: bytes)
                let persisted = preferences.dictionaryRepresentation().values.compactMap { value -> VMPowerRequest? in
                    guard let data = value as? Data else { return nil }
                    return try? JSONDecoder().decode(VMPowerRequest.self, from: data)
                }
                XCTAssertEqual(persisted.first?.body, body)
                submissions.append(body)
                if submissions.count == 1 { throw URLError(.timedOut) }
                return (202, .object(["operation_id": body["operation_id"], "request_id": .string(owner.requestID), "action": .string("restart"), "phase": .string("accepted")]))
            }
            if path.contains("/power/") && submissions.count > 1 { return (200, .object(["phase": .string("accepted")])) }
            return (404, .object(["error": .object(["message": .string("Receipt not found")])]))
        }
        let original = VMPowerControl(preferences: preferences)
        await original.load(owner: owner, client: client)
        XCTAssertTrue(submissions.isEmpty)
        await original.perform(.restart)
        XCTAssertEqual(submissions.count, 1)
        let pending = try XCTUnwrap(original.pending)
        XCTAssertNotNil(original.error)
        let restored = VMPowerControl(preferences: preferences)
        await restored.load(owner: owner, client: client)
        XCTAssertEqual(restored.pending, pending)
        XCTAssertEqual(submissions.count, 1) // Loading and refreshing must never dispatch power.
        await restored.retry()
        XCTAssertEqual(submissions.count, 2)
        XCTAssertEqual(submissions[0], submissions[1])
        XCTAssertEqual(restored.operationPhase, "accepted")
        XCTAssertTrue(restored.mayBeginNewAction)
        failStatus = true
        await restored.refresh()
        XCTAssertFalse(restored.mayBeginNewAction) // Stale VM state must not authorize a fresh UUID.
        XCTAssertEqual(restored.pending, pending)
        XCTAssertEqual(submissions.count, 2)
        failStatus = false
        await restored.refresh()
        XCTAssertTrue(restored.mayBeginNewAction)
    }
}
