import SwiftUI
import HermesGateway

struct AgentPluginView: View {
    let pluginID: String
    let bot: Bot
    let store: PhoneStore
    var body: some View { AgentPluginPage(pluginID: pluginID, bot: bot, store: store).id(bot.id + ":" + pluginID) }
}

private struct AgentPluginPage: View {
    @Environment(\.scenePhase) private var scenePhase
    let pluginID: String
    let bot: Bot
    let store: PhoneStore
    @State private var state: AgentPluginStore
    @State private var connectionError: String?
    @State private var review: PluginActionSelection?
    init(pluginID: String, bot: Bot, store: PhoneStore) {
        self.pluginID = pluginID; self.bot = bot; self.store = store
        _state = State(initialValue: AgentPluginStore(id: pluginID))
    }
    var body: some View {
        List {
            Section { BotIdentityLabel(name: bot.name, detail: "Agent plugin on this bot") } footer: {
                Text("These controls manage this bot's agent plugin. Mac desktop extensions are managed in the Mac app.")
            }
            if state.loading || state.working { Section { ProgressView(state.working ? "Applying plugin action…" : "Reading plugin…") } }
            if let error = connectionError ?? state.error { Section { PhoneNotice(title: "Plugin action unavailable", message: error) } }
            if let notice = state.notice { Section { PhoneNotice(title: "Plugin result", message: notice, systemImage: "info.circle") } }
            if let record = state.record {
                Section(record.plugin.name) {
                    if !record.plugin.description.isEmpty { Text(record.plugin.description) }
                    LabeledContent("Agent status", value: record.plugin.status)
                    PluginProvenance(record: record)
                    if record.hasDesktopHalf { Text("This package also has a Mac desktop extension. It is not loaded or controlled by this iPhone.").font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Manage agent plugin") {
                    if record.canToggle {
                        Button(record.enabled ? "Disable…" : "Enable…") { review = PluginActionSelection(action: record.enabled ? .disable : .enable, record: record) }
                    } else { Text("This gateway did not report a supported activation state and canonical key.").foregroundStyle(.secondary) }
                    if record.canUpdate { Button("Update to current catalog pin…") { review = PluginActionSelection(action: .update, record: record) } }
                    else if record.canRemove, record.catalogName == nil { Text("Custom-source updates use the Hermes CLI on this bot. Catalog updates use a pinned commit.").font(.footnote).foregroundStyle(.secondary) }
                    if record.canRemove { Button("Remove…", role: .destructive) { review = PluginActionSelection(action: .remove, record: record) } }
                    else { Text("Bundled and entry-point plugins cannot be removed here.").font(.footnote).foregroundStyle(.secondary) }
                }.disabled(!state.canAct)
            } else if state.removed { Section { Text("This plugin is no longer installed on this bot.").foregroundStyle(.secondary) } }
            if let update = state.updateReview {
                Section("Update requires a new grant") {
                    Text("Reviewed commit: " + update.sha).font(.footnote.monospaced()).textSelection(.enabled)
                    ForEach(update.lines, id: \.self) { Text($0).font(.subheadline) }
                    Text("The installed plugin was kept. Update the gateway to support commit-bound confirmation before applying this wider update from iPhone.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(state.record?.plugin.name ?? "Agent plugin")
        .navigationBarTitleDisplayMode(.inline)
        .task { await connect() }
        .refreshable { await refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(state.loading || state.working) }
        .sheet(item: $review) { PluginActionReview(selection: $0, botName: bot.name, state: state) }
    }
    private func connect() async {
        do {
            let gateway = try await store.client(for: bot.endpointID)
            try Task.checkCancellation()
            let api = BotConnectorsClient(profile: bot.profile) { try await gateway.request($0, $1, timeout: 120) }
            state.bind(AgentPluginLifecycleClient(api: api)); connectionError = nil
            await state.refresh()
        } catch is CancellationError { return }
        catch { connectionError = error.localizedDescription }
    }
    private func refresh() async {
        if connectionError != nil { await connect() } else { await state.refresh() }
    }
}

private struct PluginProvenance: View {
    let record: AgentPluginRecord
    var body: some View {
        LabeledContent("Source", value: record.plugin.source)
        if !record.version.isEmpty { LabeledContent("Version", value: record.version) }
        if let key = record.key { Text("Registry key: " + key).font(.footnote.monospaced()).textSelection(.enabled) }
        if let name = record.catalogName { LabeledContent("Catalog entry", value: name) }
        if let sha = record.installedSHA ?? record.pinnedSHA { Text("Installed commit: " + sha).font(.footnote.monospaced()).textSelection(.enabled) }
        if let sha = record.catalogSHA { Text("Catalog commit: " + sha).font(.footnote.monospaced()).textSelection(.enabled) }
    }
}

private struct PluginActionSelection: Identifiable {
    let id = UUID()
    let action: AgentPluginAction
    let record: AgentPluginRecord
    var explanation: String {
        switch action {
        case .enable: return "Enabling can run this plugin's code, hooks, commands, MCP servers, and skills now. It can access this bot's files and credentials. Some tools and prompt changes apply in new sessions."
        case .disable: return "Disable the saved plugin selection. Existing handlers can remain active until this bot's gateway restarts. This action does not restart it or rebuild the current chat."
        case .update: return "The gateway resolves and installs the current catalog commit. Updated code can run now with this plugin's existing access to the bot's files and credentials. If it adds permissions or capabilities, the update is left unchanged. This iPhone does not grant a wider update through the current confirmation API."
        case .remove: return "Remove this user-installed plugin and its selection from this bot. A selected memory provider may be cleared. Existing handlers can remain active until the gateway restarts. Mac desktop extensions and provider account grants are managed separately."
        }
    }
}

private struct PluginActionReview: View {
    @Environment(\.dismiss) private var dismiss
    let selection: PluginActionSelection
    let botName: String
    let state: AgentPluginStore
    var body: some View {
        NavigationStack {
            Form {
                Section { BotIdentityLabel(name: botName, detail: selection.record.plugin.name) }
                Section("Source and revision") { PluginProvenance(record: selection.record) }
                Section { Text(selection.explanation) }
                if let error = state.error { PhoneNotice(title: "Could not complete action", message: error) }
                Button(selection.action.title, role: selection.action == .remove ? .destructive : nil) {
                    Task { if await state.perform(selection.action, reviewed: selection.record) { dismiss() } }
                }.disabled(!state.canAct)
                if state.working { ProgressView("Waiting for this bot's gateway…") }
            }
            .navigationTitle(selection.action.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(state.working) } }
        }.interactiveDismissDisabled(state.working)
    }
}
