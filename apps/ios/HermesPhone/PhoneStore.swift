import Foundation
import Observation
import HermesGateway

@MainActor @Observable final class PhoneStore {
    var endpoints: [GatewayEndpoint] = []
    var bots: [Bot] = []
    var loading = false
    var error: String?
    var clients: [UUID: GatewayClient] = [:]
    init() {
        if let data = UserDefaults.standard.data(forKey: "gateways"), let saved = try? JSONDecoder().decode([GatewayEndpoint].self, from: data) { endpoints = saved }
    }
    func add(label: String, address: String, token: String) async throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let url = URL(string: address) else { throw GatewayError.message("Enter a gateway URL and access token.") }
        let endpoint = try GatewayEndpoint(label: label.isEmpty ? url.host ?? "Gateway" : label, baseURL: url)
        let client = GatewayClient(endpoint: endpoint, token: token)
        try await client.connect()
        let rows = try await client.request("profiles.list", ["include_sessions": .bool(true)])
        try GatewayKeychain.save(token, id: endpoint.id)
        endpoints.append(endpoint); clients[endpoint.id] = client
        bots += rows["profiles"].array.map { Bot(endpointID: endpoint.id, row: $0) }
        UserDefaults.standard.set(try JSONEncoder().encode(endpoints), forKey: "gateways")
    }
    func client(for id: UUID) async throws -> GatewayClient {
        if let client = clients[id], client.connected { return client }
        guard let endpoint = endpoints.first(where: { $0.id == id }) else { throw GatewayError.message("Gateway no longer exists.") }
        let client = GatewayClient(endpoint: endpoint, token: try GatewayKeychain.read(id))
        try await client.connect(); clients[id] = client
        return client
    }
    func refresh() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        for endpoint in endpoints {
            do {
                let client = try await client(for: endpoint.id)
                let result = try await client.request("profiles.list", ["include_sessions": .bool(true)])
                bots.removeAll { $0.endpointID == endpoint.id }
                bots += result["profiles"].array.map { Bot(endpointID: endpoint.id, row: $0) }
            } catch { self.error = "\(endpoint.label): \(error.localizedDescription)" }
        }
    }
    func addProvisioned(_ row: JSON, main: GatewayEndpoint) async throws {
        let gateway = try main.provisionedGateway(row)
        let url = gateway.baseURL
        if endpoints.contains(where: { $0.baseURL == url }) { return }
        try await add(label: gateway.label, address: url.absoluteString, token: GatewayKeychain.read(main.id))
    }
}
