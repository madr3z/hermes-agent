import Foundation
import Observation
import HermesGateway

@MainActor @Observable final class BotMemoryStore {
    private(set) var cards: [BotMemoryCard] = []
    private(set) var loading = false
    private(set) var error: String?
    private var api: BotMemoryClient?
    private var generation = 0
    func bind(_ api: BotMemoryClient) { disconnect(); self.api = api }
    func disconnect() {
        generation += 1; api = nil; cards = []; error = nil; loading = false
    }
    func refresh() async {
        guard let api, !loading else { return }
        let current = generation
        loading = true; error = nil; cards = []
        defer { if generation == current { loading = false } }
        do {
            let cards = try await api.cards()
            try Task.checkCancellation()
            guard generation == current else { return }
            self.cards = cards
        } catch is CancellationError { return }
        catch {
            guard generation == current else { return }
            self.error = botToolsError(error)
        }
    }
    func connectionFailed(_ error: Error) { self.error = botToolsError(error) }
}
