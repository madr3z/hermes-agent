import Foundation
import Observation
import HermesGateway

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
        await ProfileMutation.run(
            client: api,
            loading: loading,
            working: &working,
            error: &error,
            notice: &notice,
            body: body,
            accept: { result in
                result["warning"].string ?? result["message"].string ?? "Saved on \(self.bot.name)’s gateway."
            },
            fail: { botToolsError($0) + " Refresh before trying this action again." },
            afterFailure: { self.api = nil },
            reload: { await self.load(store: store) }
        )
    }
}
