import Foundation
import Observation
import HermesGateway

@MainActor @Observable final class AgentPluginStore {
    private(set) var record: AgentPluginRecord?
    private(set) var loading = false
    private(set) var working = false
    private(set) var needsRefresh = true
    private(set) var removed = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var updateReview: AgentPluginUpdateReview?
    private let id: String
    private var api: AgentPluginLifecycleClient?
    var canAct: Bool { api != nil && record != nil && !loading && !working && !needsRefresh && !removed }
    init(id: String) { self.id = id }

    func bind(_ api: AgentPluginLifecycleClient) { self.api = api }

    func refresh() async {
        guard let api, !loading, !working else { return }
        loading = true; error = nil; updateReview = nil
        defer { loading = false }
        do {
            let records = try await api.list()
            try Task.checkCancellation()
            record = records.first { $0.id == id }; removed = record == nil; needsRefresh = false
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription; needsRefresh = true }
    }

    func perform(_ action: AgentPluginAction, reviewed: AgentPluginRecord, consent: AgentPluginUpdateReview? = nil) async -> Bool {
        guard let api, canAct else { return false }
        if let consent, consent.binding == nil || consent.binding != updateReview?.binding { return false }
        working = true; error = nil; notice = nil; updateReview = nil
        do {
            let outcome = try await api.perform(action, reviewed: reviewed, updateConsent: consent)
            var pendingReview: AgentPluginUpdateReview?
            switch outcome {
            case .requiresBoundConsent(let review):
                pendingReview = review
                notice = review.binding == nil ? "This update was not applied. Update the gateway before confirming this added access from iPhone." : "This update was not applied. Review the exact commit and added access before confirming it."
            case .applied(let result):
                notice = Self.receipt(result, action: action)
            }
            working = false
            await refresh()
            if let pendingReview, record?.installedSHA == reviewed.installedSHA { updateReview = pendingReview }
            return true
        } catch {
            working = false; needsRefresh = true
            self.error = error.localizedDescription + " Refresh this plugin before another action. The request will not be retried automatically."
            return false
        }
    }

    static func receipt(_ result: JSON, action: AgentPluginAction) -> String {
        var lines = [result["unchanged"].bool ? "The saved setting was already current." : action == .remove ? "Plugin removed from this bot." : "Plugin change saved on this bot."]
        if result["restart_required"].bool || action == .disable || action == .remove {
            lines.append("Existing handlers can remain active until the bot gateway restarts. This screen did not restart it.")
        }
        if result["gateway_reloaded"].bool { lines.append("The gateway reloaded the plugin. Hooks, commands, MCP tools, or skills may be active now.") }
        if case .object(let deferred) = result["activation"]["deferred"], deferred.values.contains(where: { !$0.array.isEmpty }) { lines.append("Deferred tools and prompt changes apply in new sessions. This screen did not rebuild the current chat.") }
        if let sha = result["sha"].string { lines.append("Installed commit: " + sha) }
        if result["cleared_memory_provider"].bool { lines.append("This plugin was the selected memory provider. Its selection was cleared; choose another provider on your Mac.") }
        lines.append(contentsOf: result["warnings"].array.compactMap(\.string))
        return lines.joined(separator: "\n\n")
    }
}
