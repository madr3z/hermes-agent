import XCTest
@testable import HermesGateway

final class ManagedGatewayIdentityTests: XCTestCase {
    func testManagedConnectionKeepsExactControllerIdentityAcrossPersistence() throws {
        let main = try GatewayEndpoint(label: "Controller", baseURL: URL(string: "https://hermes.example:9443")!)
        let requestID = "7d68969d-a9cb-49b3-9092-a95f014f93e1"
        let path = "api/plugins/bot-provisioning/v1/gateways/" + requestID
        let row = JSON.object(["request_id": .string(requestID), "gateway": .object(["base_url": .string("/" + path)])])
        let managed = try main.provisionedGateway(row)
        let owner = try XCTUnwrap(ProvisionedOwner.matchingRegistryRow(row, main: main, gateway: managed))
        XCTAssertTrue(owner.owns(managed))
        XCTAssertEqual(managed.baseURL, main.url(path: path))
        XCTAssertNil(main.url(path: path).query)

        // PhoneStore persists these two values independently after registry connection.
        let endpoints = try JSONDecoder().decode([GatewayEndpoint].self, from: JSONEncoder().encode([main, managed]))
        let owners = try JSONDecoder().decode([String: ProvisionedOwner].self, from: JSONEncoder().encode([managed.id.uuidString: owner]))
        let restoredMain = try XCTUnwrap(endpoints.first(where: { $0.id == owner.mainID }))
        let restoredManaged = try XCTUnwrap(endpoints.first(where: { $0.id == managed.id }))
        let restoredOwner = try XCTUnwrap(owners[managed.id.uuidString])
        XCTAssertNil(restoredManaged.baseURL.query)
        XCTAssertEqual(restoredOwner.gatewayURL, restoredManaged.baseURL)
        XCTAssertTrue(restoredOwner.owns(restoredManaged))
        XCTAssertEqual(restoredManaged.baseURL, restoredMain.url(path: path))
        XCTAssertEqual(ProvisionedOwner.matchingRegistryRow(row, main: restoredMain, gateway: restoredManaged), restoredOwner)

        let foreign = try GatewayEndpoint(id: managed.id, label: "Other", baseURL: URL(string: "https://other.example/" + path)!)
        XCTAssertFalse(restoredOwner.owns(foreign))
        XCTAssertNil(ProvisionedOwner.matchingRegistryRow(row, main: restoredMain, gateway: foreign))
    }

    func testGatewayQueriesKeepExplicitItemsAndCapturedProfile() throws {
        let endpoint = try GatewayEndpoint(label: "Controller", baseURL: URL(string: "https://hermes.example/controller/")!)
        let query = [URLQueryItem(name: "search", value: "a +&?"), URLQueryItem(name: "profile", value: "foreign")]
        let url = endpoint.url(path: "/api/search/", profile: "writer", query: query)
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.path, "/controller/api/search")
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "search", value: "a +&?"), URLQueryItem(name: "profile", value: "writer")])
        XCTAssertEqual(URLComponents(url: endpoint.url(path: "api/search", query: query), resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "search", value: "a +&?")])
    }
}
