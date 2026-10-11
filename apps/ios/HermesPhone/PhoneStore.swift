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
    private var controllerSessions: [UUID: ControllerSession] = [:]
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let data = preferences.data(forKey: "vm-owners"), let saved = try? JSONDecoder().decode([String: ProvisionedOwner].self, from: data) { vmOwners = saved }
        if let data = preferences.data(forKey: "gateways"), let saved = try? JSONDecoder().decode([GatewayEndpoint].self, from: data) { endpoints = saved }
    }
    func add(label: String, address: String, token: String, replacing id: UUID? = nil) async throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let url = URL(string: address) else { throw GatewayError.message("Enter a gateway URL and access token.") }
        let endpoint = try GatewayEndpoint(id: id ?? UUID(), label: label.isEmpty ? url.host ?? "Gateway" : label, baseURL: url)
        let client = GatewayClient(endpoint: endpoint, token: token)
        try await client.connect()
        let rows = try await client.request("profiles.list", ["include_sessions": .bool(true)])
        try GatewayKeychain.save(token, id: endpoint.id)
        disconnectController(endpoint.id)
        controllerSessions.removeValue(forKey: endpoint.id)?.session.invalidateAndCancel()
        if !endpoints.contains(where: { $0.id == endpoint.id }) { endpoints.append(endpoint) }
        clients[endpoint.id] = client
        bots.removeAll { $0.endpointID == endpoint.id }
        bots += rows["profiles"].array.map { Bot(endpointID: endpoint.id, row: $0) }
        preferences.set(try JSONEncoder().encode(endpoints), forKey: "gateways")
    }
    func client(for id: UUID) async throws -> GatewayClient {
        if let client = clients[id], client.connected { return client }
        guard let endpoint = endpoints.first(where: { $0.id == id }) else { throw GatewayError.message("Gateway no longer exists.") }
        let client = try makeClient(for: endpoint)
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
        let endpoint = endpoints.first(where: { $0.baseURL == gateway.baseURL }) ?? gateway
        guard let owner = ProvisionedOwner.matchingRegistryRow(row, main: main, gateway: endpoint),
              endpoint.baseURL == main.url(path: "api/plugins/bot-provisioning/v1/gateways/" + owner.requestID) else { throw GatewayError.message("Missing canonical managed VM identity.") }
        let client = try makeClient(for: endpoint, owner: owner)
        try await client.connect()
        let rows = try await client.request("profiles.list", ["include_sessions": .bool(true)])
        if !endpoints.contains(where: { $0.id == endpoint.id }) { endpoints.append(endpoint) }
        clients[endpoint.id]?.disconnect(); clients[endpoint.id] = client
        bots.removeAll { $0.endpointID == endpoint.id }
        bots += rows["profiles"].array.map { Bot(endpointID: endpoint.id, row: $0) }
        vmOwners[endpoint.id.uuidString] = owner
        preferences.set(try JSONEncoder().encode(endpoints), forKey: "gateways")
        preferences.set(try JSONEncoder().encode(vmOwners), forKey: "vm-owners")
    }
    private func makeClient(for endpoint: GatewayEndpoint, owner explicitOwner: ProvisionedOwner? = nil) throws -> GatewayClient {
        let owner = explicitOwner ?? vmOwners[endpoint.id.uuidString]
        let authenticationEndpoint: GatewayEndpoint
        if let owner {
            guard owner.owns(endpoint), let main = endpoints.first(where: { $0.id == owner.mainID }),
                  endpoint.baseURL == main.url(path: "api/plugins/bot-provisioning/v1/gateways/" + owner.requestID) else { throw GatewayError.message("Managed VM no longer matches its controller. Reconnect it from the registry.") }
            authenticationEndpoint = main
        } else { authenticationEndpoint = endpoint }
        let id = authenticationEndpoint.id
        if controllerSessions[id] == nil {
            controllerSessions[id] = try ControllerSession.restore(endpoint: authenticationEndpoint, data: GatewayKeychain.readData(id))
        }
        if let controller = controllerSessions[id] {
            return GatewayClient(endpoint: endpoint, token: nil, session: controller.session, authenticationEndpoint: authenticationEndpoint, onAuthenticationChange: { [weak self, weak controller] in
                guard let self, let controller, self.controllerSessions[id] === controller else { return }
                try GatewayKeychain.saveData(controller.savedData(), id: id)
            })
        }
        return GatewayClient(endpoint: endpoint, token: try GatewayKeychain.read(id))
    }
    func signIn(endpoint: GatewayEndpoint, controller: ControllerSession) async throws {
        guard controller.endpoint.baseURL == endpoint.baseURL else { throw GatewayError.message("Controller address changed. Restart sign-in.") }
        let client = GatewayClient(endpoint: endpoint, token: nil, session: controller.session, onAuthenticationChange: { [weak self, weak controller] in
            guard let self, let controller, self.controllerSessions[endpoint.id] === controller else { return }
            try GatewayKeychain.saveData(controller.savedData(), id: endpoint.id)
        })
        try await client.connect()
        let rows = try await client.request("profiles.list", ["include_sessions": .bool(true)])
        do { try GatewayKeychain.saveData(controller.savedData(), id: endpoint.id) }
        catch { client.disconnect(); throw error }
        disconnectController(endpoint.id)
        controllerSessions[endpoint.id]?.session.invalidateAndCancel()
        controllerSessions[endpoint.id] = controller
        clients[endpoint.id] = client
        if !endpoints.contains(where: { $0.id == endpoint.id }) { endpoints.append(endpoint) }
        bots.removeAll { $0.endpointID == endpoint.id }
        bots += rows["profiles"].array.map { Bot(endpointID: endpoint.id, row: $0) }
        preferences.set(try JSONEncoder().encode(endpoints), forKey: "gateways")
    }
    private func disconnectController(_ mainID: UUID) {
        for id in Array(clients.keys) where id == mainID || vmOwners[id.uuidString]?.mainID == mainID { clients.removeValue(forKey: id)?.disconnect() }
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
