import XCTest
import HermesGateway
@testable import HermesPhone

private final class VMDeletionHTTPFixture: URLProtocol {
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

@MainActor final class VMDeletionTests: XCTestCase {
    func testDeletionRequiresConfirmationAndRecoversStableReceiptBeforeRetry() async throws {
        let suite = "hermes-vm-delete-test-\(UUID())", preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); VMDeletionHTTPFixture.response = nil }
        let main = try GatewayEndpoint(label: "Main", baseURL: URL(string: "https://main.example")!)
        let target = try XCTUnwrap(VMDeletionTarget(mainID: main.id, requestID: UUID().uuidString.lowercased()))
        XCTAssertNil(VMDeletionTarget(mainID: main.id, requestID: "../pilot"))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [VMDeletionHTTPFixture.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = GatewayClient(endpoint: main, token: "owning-main-only", session: session)
        var posts: [JSON] = [], methods: [String] = [], supported = true, receiptExists = false, foreignReceipt = false
        var creationPhase = "ready", operationPhase = "queued"
        VMDeletionHTTPFixture.response = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owning-main-only")
            XCTAssertTrue(request.httpShouldHandleCookies) // Preserve the supplied main session's cookie handling.
            let path = request.url!.path
            if path.hasSuffix("/capabilities") { return (200, .object(["vm_delete": .bool(supported)])) }
            if path == "/" + target.route { return (200, .object(["request_id": .string(target.requestID), "name": .string("research"), "phase": .string(creationPhase)])) }
            methods.append(request.httpMethod ?? "GET")
            if request.httpMethod == "POST" {
                XCTAssertEqual(path, "/" + target.route + "/delete")
                let body = try VMDeletionHTTPFixture.body(request)
                let saved = preferences.dictionaryRepresentation().values.compactMap { value -> VMDeletionRequest? in
                    guard let data = value as? Data else { return nil }; return try? JSONDecoder().decode(VMDeletionRequest.self, from: data)
                }
                XCTAssertEqual(saved.first?.body, body)
                XCTAssertEqual(body["confirm_name"].string, "research")
                posts.append(body)
                if posts.count == 1 { throw URLError(.timedOut) }
                receiptExists = true; operationPhase = "queued"; creationPhase = "deleting"
            }
            guard receiptExists else { return (404, .object(["error": .object(["message": .string("Receipt not found")])])) }
            return (request.httpMethod == "POST" ? 202 : 200, .object(["request_id": .string(foreignReceipt ? UUID().uuidString : target.requestID), "operation_id": posts.last!["operation_id"], "action": .string("delete"), "phase": .string(operationPhase)]))
        }
        let original = VMDeletionControl(preferences: preferences)
        await original.load(target: target, client: client)
        XCTAssertTrue(original.canConfirm); XCTAssertTrue(posts.isEmpty)
        await original.refresh(); XCTAssertTrue(posts.isEmpty)
        await original.confirm()
        XCTAssertEqual(posts.count, 1); XCTAssertFalse(original.deleted); XCTAssertTrue(original.missingReceipt)
        let pending = try XCTUnwrap(original.pending)
        let restored = VMDeletionControl(preferences: preferences)
        await restored.load(target: target, client: client)
        XCTAssertEqual(restored.pending, pending); XCTAssertEqual(posts.count, 1)
        await restored.retrySameOperation()
        XCTAssertEqual(posts.count, 2); XCTAssertEqual(posts[0], posts[1])
        XCTAssertEqual(Array(methods.suffix(3)), ["GET", "POST", "GET"])
        XCTAssertFalse(restored.deleted); XCTAssertFalse(restored.canConfirm)
        operationPhase = "failed"; creationPhase = "delete_failed"
        await restored.refresh(); XCTAssertTrue(restored.canConfirm); XCTAssertEqual(posts.count, 2)
        await restored.confirm()
        XCTAssertEqual(posts.count, 3); XCTAssertNotEqual(posts[2]["operation_id"], posts[1]["operation_id"])
        operationPhase = "deleted"; creationPhase = "deleted"; foreignReceipt = true
        await restored.refresh(); XCTAssertFalse(restored.deleted); XCTAssertNotNil(restored.error)
        foreignReceipt = false
        await restored.refresh(); XCTAssertTrue(restored.deleted)
        supported = false
        let unavailable = VMDeletionControl(preferences: preferences)
        await unavailable.load(target: target, client: client)
        await unavailable.confirm(); await unavailable.retrySameOperation()
        XCTAssertFalse(unavailable.supported); XCTAssertEqual(posts.count, 3)
    }
    func testLocalCleanupRemovesOnlyTheExactManagedOwnerAndKeepsPilotMainAndEditedEndpoints() throws {
        let suite = "hermes-vm-cleanup-test-\(UUID())", preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let requestID = UUID().uuidString.lowercased()
        let main = try GatewayEndpoint(label: "Main", baseURL: URL(string: "https://main.example")!)
        let otherMain = try GatewayEndpoint(label: "Other main", baseURL: URL(string: "https://other.example")!)
        let path = "/api/plugins/bot-provisioning/v1/gateways/" + requestID
        let managed = try GatewayEndpoint(label: "Managed", baseURL: URL(string: "https://main.example" + path)!)
        let pilot = try GatewayEndpoint(label: "Pilot", baseURL: URL(string: "https://pilot.example")!)
        let edited = try GatewayEndpoint(label: "Edited", baseURL: URL(string: "https://edited.example")!)
        let other = try GatewayEndpoint(label: "Other managed", baseURL: URL(string: "https://other.example" + path)!)
        let store = PhoneStore(preferences: preferences)
        store.endpoints = [main, otherMain, managed, pilot, edited, other]
        store.vmOwners[edited.id.uuidString] = try ProvisionedOwner(mainID: main.id, requestID: requestID, gatewayURL: managed.baseURL)
        store.vmOwners[other.id.uuidString] = try ProvisionedOwner(mainID: otherMain.id, requestID: requestID, gatewayURL: other.baseURL)
        let row = JSON.object(["request_id": .string(requestID), "name": .string("research"), "gateway": .object(["base_url": .string(path)])])
        try store.recordManagedOwner(row, mainID: main.id)
        XCTAssertNotNil(store.vmOwners[managed.id.uuidString]); XCTAssertNil(store.vmOwners[pilot.id.uuidString])
        store.bots = [managed, pilot, edited, other].map { Bot(endpointID: $0.id, row: .object(["name": .string("default")])) }
        store.clients[main.id] = GatewayClient(endpoint: main, token: "main-token")
        store.clients[managed.id] = GatewayClient(endpoint: managed, token: "copied-main-token")
        var removedCredentials: [UUID] = []
        try store.removeDeletedVM(mainID: main.id, requestID: requestID) { removedCredentials.append($0) }
        XCTAssertEqual(removedCredentials, [managed.id])
        XCTAssertEqual(store.endpoints, [main, otherMain, pilot, edited, other])
        XCTAssertEqual(Set(store.bots.map(\.endpointID)), Set([pilot.id, edited.id, other.id]))
        XCTAssertNotNil(store.clients[main.id]); XCTAssertNil(store.clients[managed.id])
        XCTAssertNil(store.vmOwners[managed.id.uuidString]); XCTAssertNotNil(store.vmOwners[edited.id.uuidString]); XCTAssertNotNil(store.vmOwners[other.id.uuidString])
        let persisted = try JSONDecoder().decode([GatewayEndpoint].self, from: XCTUnwrap(preferences.data(forKey: "gateways")))
        XCTAssertEqual(persisted, store.endpoints)
    }
}
