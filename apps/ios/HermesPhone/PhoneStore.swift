import Foundation
import Observation
import HermesGateway

@MainActor @Observable final class PhoneStore {
    var endpoints: [GatewayEndpoint] = []
    var bots: [Bot] = []
    var loading = false
    var error: String?
    var vmOwners: [String: ProvisionedOwner] = [:]
    var clients: [UUID: GatewayClient] = [:]
    var vmDeletionControllers: Set<UUID> = []
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let data = preferences.data(forKey: "vm-owners"), let saved = try? JSONDecoder().decode([String: ProvisionedOwner].self, from: data) { vmOwners = saved }
        if let data = preferences.data(forKey: "gateways"), let saved = try? JSONDecoder().decode([GatewayEndpoint].self, from: data) { endpoints = saved }
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
        preferences.set(try JSONEncoder().encode(endpoints), forKey: "gateways")
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
        loading = true; error = nil; vmDeletionControllers.removeAll()
        defer { loading = false }
        for endpoint in endpoints {
            do {
                let client = try await client(for: endpoint.id)
                let result = try await client.request("profiles.list", ["include_sessions": .bool(true)])
                bots.removeAll { $0.endpointID == endpoint.id }
                bots += result["profiles"].array.map { Bot(endpointID: endpoint.id, row: $0) }
                if vmOwners.values.contains(where: { $0.mainID == endpoint.id }),
                   let capabilities = try? await client.http("api/plugins/bot-provisioning/v1/capabilities"), capabilities["vm_delete"].bool {
                    vmDeletionControllers.insert(endpoint.id)
                }
            } catch { self.error = "\(endpoint.label): \(error.localizedDescription)" }
        }
    }
    func resolveVMOwner(for id: UUID) async throws -> ProvisionedOwner? {
        guard let endpoint = endpoints.first(where: { $0.id == id }) else { return nil }
        if let owner = vmOwners[id.uuidString] {
            guard owner.owns(endpoint) else { throw GatewayError.message("This gateway no longer matches its saved VM owner. Reconnect it from the controller registry.") }
            return owner
        }
        guard endpoint.baseURL.path.hasPrefix("/api/plugins/bot-provisioning/v1/gateways/") else { return nil }
        let mains = endpoints.filter { candidate in
            !candidate.baseURL.path.contains("/gateways/") && candidate.baseURL.host == endpoint.baseURL.host && candidate.baseURL.port == endpoint.baseURL.port
        }
        for main in mains {
            let rows = try await client(for: main.id).http("api/plugins/bot-provisioning/v1/requests")["requests"].array
            for row in rows {
                guard let owner = ProvisionedOwner.matchingRegistryRow(row, main: main, gateway: endpoint) else { continue }
                vmOwners[id.uuidString] = owner
                preferences.set(try JSONEncoder().encode(vmOwners), forKey: "vm-owners")
                return owner
            }
        }
        return nil
    }
    func addProvisioned(_ row: JSON, main: GatewayEndpoint) async throws {
        let gateway = try main.provisionedGateway(row)
        let url = gateway.baseURL
        if !endpoints.contains(where: { $0.baseURL == url }) {
            try await add(label: gateway.label, address: url.absoluteString, token: GatewayKeychain.read(main.id))
        }
        guard let endpoint = endpoints.first(where: { $0.baseURL == url }), let owner = ProvisionedOwner.matchingRegistryRow(row, main: main, gateway: endpoint) else { throw GatewayError.message("Missing provisioned VM identity.") }
        vmOwners[endpoint.id.uuidString] = owner
        preferences.set(try JSONEncoder().encode(vmOwners), forKey: "vm-owners")
    }
    func recordManagedOwner(_ row: JSON, mainID: UUID) throws {
        guard let main = endpoints.first(where: { $0.id == mainID }) else { return }
        for endpoint in endpoints {
            if let owner = ProvisionedOwner.matchingRegistryRow(row, main: main, gateway: endpoint) { vmOwners[endpoint.id.uuidString] = owner }
        }
        preferences.set(try JSONEncoder().encode(vmOwners), forKey: "vm-owners")
    }
    func removeDeletedVM(mainID: UUID, requestID: String, removeCredential: (UUID) throws -> Void = GatewayKeychain.remove) throws {
        let removed = Set(endpoints.compactMap { endpoint -> UUID? in
            guard endpoint.id != mainID, let owner = vmOwners[endpoint.id.uuidString], owner.mainID == mainID,
                  owner.requestID == requestID, owner.owns(endpoint) else { return nil }
            return endpoint.id
        })
        for id in removed { try removeCredential(id) }
        for id in removed { clients.removeValue(forKey: id)?.disconnect(); vmOwners.removeValue(forKey: id.uuidString) }
        endpoints.removeAll { removed.contains($0.id) }
        bots.removeAll { removed.contains($0.endpointID) }
        preferences.set(try JSONEncoder().encode(endpoints), forKey: "gateways")
        preferences.set(try JSONEncoder().encode(vmOwners), forKey: "vm-owners")
    }

}
