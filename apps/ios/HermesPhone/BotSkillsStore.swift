import Foundation
import Observation
import HermesGateway

@MainActor @Observable final class BotSkillsStore {
    private(set) var skills: [InstalledBotSkill] = []
    private(set) var loading = false
    private(set) var working = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var installAvailable = false
    private(set) var installAvailabilityError: String?
    private(set) var needsRefresh = true
    private var api: BotSkillsClient?
    private var generation = 0
    var canChange: Bool { api != nil && !loading && !working && !needsRefresh }
    func connectionFailed(_ error: Error) { self.error = botToolsError(error); needsRefresh = true }
    func bind(_ api: BotSkillsClient) { disconnect(); self.api = api }
    func disconnect() {
        generation += 1; api = nil
        skills = []; loading = false; working = false; error = nil; notice = nil
        installAvailable = false; installAvailabilityError = nil; needsRefresh = true
    }
    func refresh() async {
        guard let api, !loading, !working else { return }
        let current = generation
        loading = true; error = nil
        defer { if generation == current { loading = false } }
        do {
            let rows = try await api.installed()
            try Task.checkCancellation()
            guard generation == current else { return }
            skills = rows; needsRefresh = false
        } catch is CancellationError { return }
        catch {
            guard generation == current else { return }
            self.error = botToolsError(error); needsRefresh = true
        }
        do {
            let available = try await api.supportsNextSessionInstall()
            guard generation == current else { return }
            installAvailable = available
            installAvailabilityError = available ? nil : "Update the bot runtime to enable installs that preserve active chats."
        } catch {
            guard generation == current else { return }
            installAvailable = false; installAvailabilityError = botToolsError(error)
        }
    }
    func setEnabled(name: String, enabled: Bool) async {
        guard let api, canChange else { return }
        await change { try await api.setEnabled(name: name, enabled: enabled) }
    }
    func install(identifier: String) async {
        guard let api, canChange, installAvailable else { return }
        await change {
            try await api.install(identifier: identifier)
            return try await api.installed()
        }
    }
    private func change(_ action: () async throws -> [InstalledBotSkill]) async {
        let current = generation
        working = true; error = nil; notice = nil
        defer { if generation == current { working = false } }
        do {
            let rows = try await action()
            guard generation == current else { return }
            skills = rows
            notice = "Saved for new sessions. This screen did not reload the current chat."
        } catch {
            guard generation == current else { return }
            self.error = botToolsError(error) + " Refresh before another change."
            needsRefresh = true
        }
    }
}
