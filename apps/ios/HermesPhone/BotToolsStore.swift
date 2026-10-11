import Foundation
import Observation
import HermesGateway

func botToolsError(_ error: Error) -> String {
    if case GatewayError.rpc(let code, _) = error, code == -32601 {
        return "This gateway does not support this feature yet. Update its Hermes runtime on your Mac."
    }
    return error.localizedDescription
}

@MainActor @Observable final class BotRoutinesStore {
    let bot: Bot
    var jobs: [BotRoutine] = []
    var loading = false
    var working = false
    var error: String?
    var notice: String?
    private(set) var api: BotRoutinesClient?
    init(bot: Bot) { self.bot = bot }
    func load(store: PhoneStore) async {
        guard !loading, !working else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let client = try await store.client(for: bot.endpointID)
            let api = BotRoutinesClient(profile: bot.profile) { try await client.request($0, $1) }
            let jobs = try await api.list()
            try Task.checkCancellation()
            self.api = api; self.jobs = jobs
        } catch is CancellationError { return }
        catch { api = nil; self.error = botToolsError(error) }
    }
    func mutate(store: PhoneStore, body: (BotRoutinesClient) async throws -> JSON) async -> Bool {
        guard let api, !loading, !working else { return false }
        working = true; error = nil; notice = nil
        do {
            let result = try await body(api)
            notice = result["warning"].string ?? result["message"].string ?? "Saved on \(bot.name)’s gateway."
            working = false
            await load(store: store)
            return true
        } catch {
            self.error = botToolsError(error) + " Refresh before trying this action again."
            // A timeout can mean accepted work. Never replay the action automatically.
            self.api = nil; working = false
            return false
        }
    }
}
