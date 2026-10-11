import Foundation
import Observation
import HermesGateway

@MainActor @Observable final class VMPowerControl {
    var vm: JSON = .null
    var receipt: JSON = .null
    var pending: VMPowerRequest?
    var supported = false
    private var statusFresh = false
    var working = false
    var error: String?
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    private var owner: ProvisionedOwner?
    private var client: GatewayClient?
    private var persistenceKey: String? { owner.map { "vm-power-\($0.mainID)-\($0.requestID)" } }
    var phase: String { vm["phase"].string ?? "Unknown" }
    var operationPhase: String { receipt["phase"].string ?? "unconfirmed" }
    var mayBeginNewAction: Bool { statusFresh && ["accepted", "failed", "unknown"].contains(operationPhase) && !working }
    func load(bot: Bot, store: PhoneStore) async {
        do {
            guard let owner = try await store.resolveVMOwner(for: bot.endpointID) else { return }
            let client = try await store.client(for: owner.mainID)
            await load(owner: owner, client: client)
        } catch { self.error = error.localizedDescription }
    }
    func load(owner: ProvisionedOwner, client: GatewayClient) async {
        self.owner = owner; self.client = client
        if let persistenceKey, let data = preferences.data(forKey: persistenceKey) { pending = try? JSONDecoder().decode(VMPowerRequest.self, from: data) }
        do {
            let capabilities = try await client.http("api/plugins/bot-provisioning/v1/capabilities")
            supported = capabilities["vm_control"].bool
            if supported { await refresh() }
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard let owner, let client, supported, !working else { return }
        working = true; statusFresh = false; defer { working = false }
        do {
            vm = try await client.http(owner.route + "/vm")
            statusFresh = true
            if let pending { receipt = try await client.http(owner.route + "/" + pending.receiptPath) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func allowed(_ action: VMPowerAction) -> Bool {
        guard supported, !working, pending == nil else { return false }
        switch action {
        case .start: return vm["phase"].string == "stopped"
        case .stop: return vm["desired_state"].string == "running"
        case .restart: return vm["phase"].string == "running"
        }
    }
    func perform(_ action: VMPowerAction) async {
        guard allowed(action), let persistenceKey else { return }
        let request = VMPowerRequest(action: action)
        do {
            // A timeout or app exit must never turn retry into a second restart.
            preferences.set(try JSONEncoder().encode(request), forKey: persistenceKey)
            pending = request; receipt = .null
            await retry()
        } catch { self.error = error.localizedDescription }
    }
    func retry() async {
        guard let owner, let client, let pending, !working else { return }
        working = true; error = nil; statusFresh = false
        do { receipt = try await client.http(owner.route + "/power", body: pending.body) }
        catch { self.error = "\(error.localizedDescription) This action keeps its operation ID; refresh or retry the same action." }
        working = false
        await refresh()
    }
    func beginNewAction() {
        guard mayBeginNewAction else { return }
        if let persistenceKey { preferences.removeObject(forKey: persistenceKey) }
        pending = nil; receipt = .null
    }
}
