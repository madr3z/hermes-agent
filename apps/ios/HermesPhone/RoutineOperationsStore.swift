import Foundation
import Observation
import HermesGateway

@MainActor @Observable final class RoutineOperationsStore {
    private(set) var details: RoutineDetails?
    private(set) var runs: [RoutineRun] = []
    private(set) var loading = false
    private(set) var working = false
    private(set) var needsRefresh = false
    private(set) var uncertainRun = false
    private(set) var historyRead = false
    private(set) var historyLimit = 20
    private(set) var error: String?
    private(set) var notice: String?
    private var generation = 0
    private var api: RoutineOperationsClient?
    var canChange: Bool { api != nil && details != nil && !loading && !working && !needsRefresh }
    var canRun: Bool { canChange && !uncertainRun && !runs.contains(where: \.schedulerOwned) }
    var canReviewOutcome: Bool { uncertainRun && historyRead && !loading && !working && !runs.contains(where: \.schedulerOwned) }
    func bind(_ api: RoutineOperationsClient) {
        generation += 1; self.api = api
        details = nil; runs = []; loading = false; working = false; needsRefresh = false; uncertainRun = false; historyRead = false; error = nil; notice = nil; historyLimit = 20
    }
    func refresh(limit: Int? = nil) async {
        guard let api, !loading, !working else { return }
        let owner = generation
        loading = true; error = nil; historyRead = false
        defer { if owner == generation { loading = false } }
        do {
            let details: RoutineDetails?
            do { details = try await api.details() }
            catch GatewayError.http(let status, _) where status == 404 { details = nil }
            let runs = try await api.runs(limit: limit ?? historyLimit)
            guard owner == generation, !Task.isCancelled else { return }
            self.details = details; self.runs = runs; needsRefresh = false; historyRead = true
            if details == nil { notice = "This task is no longer in the schedule. Only its recorded run history is shown." }
            if let limit { historyLimit = limit }
        } catch {
            guard owner == generation else { return }
            self.error = error.localizedDescription; needsRefresh = true
        }
    }
    func update(_ draft: RoutineEditDraft, original: RoutineDetails) async -> Bool {
        await mutate(isRun: false) { try await $0.update(draft, original: original) }
    }
    func runNow(_ reviewed: RoutineDetails) async {
        guard canRun else { return }
        _ = await mutate(isRun: true) { try await $0.runNow(reviewed: reviewed) }
    }
    private func mutate(isRun: Bool, action: (RoutineOperationsClient) async throws -> JSON) async -> Bool {
        guard let api, canChange else { return false }
        let owner = generation
        working = true; error = nil; notice = nil
        do {
            let result = try await action(api)
            guard owner == generation else { return false }
            notice = result["warning"].string ?? result["message"].string ?? (isRun ? "The gateway returned a run result. Check its recorded outcome below." : "Task settings saved on the gateway.")
            working = false
            await refresh()
            return true
        } catch {
            guard owner == generation else { return false }
            working = false; needsRefresh = true
            if isRun && error is RoutineRunUnconfirmed { uncertainRun = true }
            self.error = error.localizedDescription + (isRun && error is RoutineRunUnconfirmed ? " The run may have started. No run request was retried. Refresh and review its actual history before another manual run." : isRun ? " No run request was submitted. Refresh and review this task again." : " No edit was retried. Refresh this task before another change.")
            return false
        }
    }
    func acknowledgeReviewedOutcome() {
        guard canReviewOutcome else { return }
        uncertainRun = false
        notice = "You reviewed the recorded history. This does not prove whether the earlier request started; another manual run can repeat work."
    }
    func transcript(run: RoutineRun, offset: Int = 0) async throws -> SavedChatPage {
        guard let api, runs.contains(run) else { throw GatewayError.message("Refresh this task’s history before opening a run.") }
        let owner = generation
        let result = try await api.messages(run: run, offset: offset)
        guard owner == generation else { throw GatewayError.message("The selected bot changed. Reopen its run history.") }
        return result
    }
}
