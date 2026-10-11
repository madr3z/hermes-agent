import XCTest
@testable import HermesGateway

final class RemoteAccessTests: XCTestCase {
    func testRemoteStreamsKeepProxyTicketSeparateFromMainCredential() throws {
        let endpoint = try GatewayEndpoint(label: "VM", baseURL: URL(string: "https://hermes.example:9443/api/plugins/bot-provisioning/v1/gateways/guest")!)
        let request = RemoteStream.display(ticket: "guest+ticket &?").request(endpoint: endpoint, token: "main-secret")
        let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.scheme, "wss"); XCTAssertEqual(parts.port, 9443)
        XCTAssertEqual(parts.path, endpoint.baseURL.path + "/api/display/ws")
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "token", value: "main-secret"), URLQueryItem(name: "display_ticket", value: "guest+ticket &?")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer main-secret")
        XCTAssertFalse(request.url!.absoluteString.contains("guest+ticket"))
        let terminal = RemoteStream.terminal.request(endpoint: endpoint, token: "main-secret")
        XCTAssertEqual(terminal.url?.path, endpoint.baseURL.path + "/api/terminal/ws")
        XCTAssertEqual(URLComponents(url: terminal.url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "token", value: "main-secret")])
    }
    func testOnlyIntentionalDepartureHandsBackDisplayLease() {
        XCTAssertEqual(RemoteStream.closeCode(intentional: true).rawValue, 1000)
        XCTAssertEqual(RemoteStream.closeCode(intentional: false).rawValue, 1011)
    }
    func testDisplayLeaseRequiresViewerHashAndScopedProfileKey() {
        let viewer = "viewer-A"
        let lease = JSON.object(["holder": .string("human"), "viewer_hash": .string(DisplayIdentity.hash(viewer))])
        XCTAssertTrue(DisplayIdentity.holds(lease, viewer: viewer))
        XCTAssertFalse(DisplayIdentity.holds(lease, viewer: "viewer-B"))
        XCTAssertFalse(DisplayIdentity.holds(lease, viewer: nil))
        let event = JSON.object(["payload": .object(["profile_key": .string("guest/writer")])])
        XCTAssertTrue(DisplayIdentity.matches(event, profileKey: "guest/writer"))
        XCTAssertFalse(DisplayIdentity.matches(event, profileKey: "guest/default"))
        XCTAssertFalse(DisplayIdentity.matches(event, profileKey: nil))
    }
    func testPersistedPowerRequestRetriesExactUUIDAndSeparateMainOwner() throws {
        let main = UUID(), id = UUID().uuidString.lowercased()
        let url = URL(string: "https://hermes.example/api/plugins/bot-provisioning/v1/gateways/guest")!
        let owner = try ProvisionedOwner(mainID: main, requestID: id, gatewayURL: url)
        XCTAssertEqual(owner.route, "api/plugins/bot-provisioning/v1/requests/" + id)
        let request = VMPowerRequest(action: .restart)
        let restored = try JSONDecoder().decode(VMPowerRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(request.body, restored.body)
        XCTAssertEqual(restored.action, .restart)
        XCTAssertTrue(restored.receiptPath.contains(request.operationID.uuidString.lowercased()))
        XCTAssertThrowsError(try ProvisionedOwner(mainID: main, requestID: "../guest", gatewayURL: url))
    }
    func testOwnerRecoveryRequiresExactRegistryRouteAndKeepsCapturedOwner() throws {
        let main = try GatewayEndpoint(label: "Main", baseURL: URL(string: "https://hermes.example:9443")!)
        let row = JSON.object(["request_id": .string(UUID().uuidString), "gateway": .object(["base_url": .string("/api/plugins/bot-provisioning/v1/gateways/guest")])])
        let guest = try main.provisionedGateway(row)
        let owner = try XCTUnwrap(ProvisionedOwner.matchingRegistryRow(row, main: main, gateway: guest))
        XCTAssertEqual(owner.mainID, main.id)
        XCTAssertEqual(owner.requestID, row["request_id"].string)
        XCTAssertTrue(owner.owns(guest))
        let edited = try GatewayEndpoint(id: guest.id, label: "Edited", baseURL: URL(string: "https://hermes.example:9443/api/plugins/bot-provisioning/v1/gateways/other")!)
        XCTAssertFalse(owner.owns(edited))
        XCTAssertNil(ProvisionedOwner.matchingRegistryRow(row, main: main, gateway: edited))
        let foreign = try GatewayEndpoint(label: "Foreign", baseURL: URL(string: "https://other.example")!)
        XCTAssertNil(ProvisionedOwner.matchingRegistryRow(row, main: foreign, gateway: guest))
        let missing = JSON.object(["gateway": row["gateway"]])
        XCTAssertNil(ProvisionedOwner.matchingRegistryRow(missing, main: main, gateway: guest))
        let restored = try JSONDecoder().decode(ProvisionedOwner.self, from: JSONEncoder().encode(owner))
        XCTAssertEqual(restored, owner)
    }

}
