import Foundation
import Observation
import HermesGateway

@MainActor @Observable final class SubagentsStore {
    private(set) var tasks: [SubagentTask] = []
    private(set) var bindingID = UUID()
    private(set) var connected = false
    private(set) var loading = false
    private(set) var working = false
    var error: String?
    var notice: String?
    private var api: SubagentsClient?
    private var revision = 0

    func bind(profile: String, runtimeID: String?, request: ((String, [String: JSON]) async throws -> JSON)?) {
        revision += 1; bindingID = UUID()
        tasks = []; error = nil; notice = nil; loading = false; working = false
        connected = runtimeID != nil && request != nil
        if let runtimeID, let request { api = SubagentsClient(profile: profile, sessionID: runtimeID, request: request) }
        else { api = nil }
    }
    func disconnect() {
        revision += 1; bindingID = UUID(); connected = false; api = nil; loading = false; working = false
    }
    func refresh() async {
        guard let api, connected, !loading, !working else { return }
        let owner = revision
        loading = true
        defer { if revision == owner { loading = false } }
        do {
            let tasks = try await api.list()
            guard owner == revision, !Task.isCancelled else { return }
            self.tasks = tasks; error = nil
        } catch {
            guard owner == revision, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
    func watch(isActive: () -> Bool) async {
        await refresh()
        while !Task.isCancelled, connected {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if isActive() { await refresh() }
        }
    }
    func interrupt(id: String) async { _ = await mutate(id: id) { try await $0.interrupt($1) } }
    func steer(id: String, text: String) async -> Bool {
        await mutate(id: id) { try await $0.steer($1, text: text) }
    }
    @discardableResult private func mutate(id: String, body: (SubagentsClient, SubagentTask) async throws -> String) async -> Bool {
        guard let api, connected, !working, !loading, error == nil, let task = tasks.first(where: { $0.id == id }) else { return false }
        let owner = revision
        working = true; error = nil; notice = nil
        do {
            let message = try await body(api, task)
            guard owner == revision else { return false }
            notice = message; working = false
            await refresh()
            return true
        } catch {
            guard owner == revision else { return false }
            self.error = error.localizedDescription + " Refresh before trying again. No action was replayed."
            working = false
            return false
        }
    }
}
