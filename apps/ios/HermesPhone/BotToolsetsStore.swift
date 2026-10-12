import Foundation
import Observation
import HermesGateway

@MainActor @Observable final class BotToolsetsStore {
    private(set) var snapshot: BotToolsetsSnapshot?
    private(set) var loading = false
    private(set) var working = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var needsRefresh = false
    private var api: BotToolsetsClient?
    private var generation = 0
    var canChange: Bool { api != nil && snapshot != nil && !loading && !working && !needsRefresh }

    func bind(_ api: BotToolsetsClient) {
        generation += 1
        self.api = api
        snapshot = nil; error = nil; notice = nil
        loading = false; working = false; needsRefresh = false
    }

    func refresh() async {
        guard let api, !loading, !working else { return }
        let current = generation
        loading = true; error = nil
        defer { if generation == current { loading = false } }
        do {
            let snapshot = try await api.snapshot()
            try Task.checkCancellation()
            guard generation == current else { return }
            self.snapshot = snapshot; needsRefresh = false
        } catch is CancellationError { return }
        catch {
            guard generation == current else { return }
            self.error = botToolsError(error); needsRefresh = true
        }
    }

    func setEnabled(name: String, enabled: Bool) async {
        guard let api, canChange else { return }
        let current = generation
        working = true; error = nil; notice = nil
        do {
            let result = try await api.setEnabled(name: name, enabled: enabled)
            guard generation == current else { return }
            notice = result["post_setup_started"].string == nil
                ? "Saved for new sessions. This screen did not reload the current chat."
                : "Saved for new sessions. Setup started on this bot. This screen did not reload the current chat."
            working = false
            await refresh()
        } catch {
            guard generation == current else { return }
            working = false; needsRefresh = true
            self.error = botToolsError(error) + " Refresh this bot's toolsets before another change."
        }
    }
}
