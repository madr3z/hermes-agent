import SwiftUI
import HermesGateway

struct BotSkillsView: View {
    let bot: Bot
    let store: PhoneStore
    @State private var model = BotSkillsStore()
    @State private var api: BotSkillsClient?
    @State private var search = ""
    @State private var pending: InstalledBotSkill?
    @Environment(\.scenePhase) private var scenePhase
    private var visible: [InstalledBotSkill] {
        model.skills.filter { search.isEmpty || ($0.name + " " + $0.category + " " + $0.description).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        DispatchList {
            DispatchSection {
                BotIdentityLabel(name: bot.name, detail: "Installed skills")
                Text("Use Commands in Bot Chat to choose an installed skill, add arguments, then send. Saved skill settings apply to new sessions; the current chat keeps its loaded instructions.")
                    .font(.subheadline).foregroundStyle(DispatchStyle.secondary)
                if let api {
                    NavigationLink("Browse skill hub") { BotSkillHubView(bot: bot, api: api, model: model) }
                    NavigationLink("Inspect memory") { BotMemoryView(bot: bot, store: store) }
                }
            }
            if model.loading { ProgressView("Loading skills…") }
            if let error = model.error { PhoneNotice(title: "Skills unavailable", message: error) }
            if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(DispatchStyle.secondary) }
            if !model.loading && model.error == nil && model.skills.isEmpty {
                DispatchEmptyState("No installed skills", systemImage: "books.vertical")
            } else if !model.skills.isEmpty && visible.isEmpty { DispatchEmptyState.search(text: search) }
            ForEach(visible) { skill in
                DispatchSection {
                    if let api {
                        NavigationLink { BotSkillContentView(bot: bot, skill: skill, api: api) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(skill.name).font(DispatchStyle.serif(23, relativeTo: .headline))
                                if !skill.description.isEmpty { Text(skill.description).font(.subheadline) }
                                Text("\(skill.category) · \(skill.provenance) · \(skill.enabled ? "Enabled" : "Disabled")")
                                    .font(.caption).foregroundStyle(DispatchStyle.secondary)
                            }
                        }
                    }
                    Button(skill.enabled ? "Disable for new sessions" : "Enable for new sessions") { pending = skill }
                        .disabled(!model.canChange)
                }
            }
        }
        .dispatchTitle("Skills").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find a skill or category")
        .task(id: bot.id) { await connect() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.refresh() } } }
        .refreshable { await model.refresh() }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.disabled(model.loading || model.working) }
        .confirmationDialog("Change skill settings for \(bot.name)?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let skill = pending {
                Button(skill.enabled ? "Disable \(skill.name)" : "Enable \(skill.name)") {
                    Task { await model.setEnabled(name: skill.name, enabled: !skill.enabled) }
                }
            }
        } message: { Text("This applies to new sessions. The current chat will keep its loaded instructions.") }
    }
    private func connect() async {
        api = nil; model.disconnect()
        do {
            let client = try await store.client(for: bot.endpointID)
            try Task.checkCancellation()
            let api = BotSkillsClient(profile: bot.profile, request: { try await client.request($0, $1) }, http: {
                try await client.http($0, profile: $1, body: $2, method: $3, query: $4)
            })
            self.api = api; model.bind(api)
            await model.refresh()
        } catch is CancellationError { return }
        catch { api = nil; model.connectionFailed(error) }
    }
}

struct BotSkillContentView: View {
    let bot: Bot
    let skill: InstalledBotSkill
    let api: BotSkillsClient
    @State private var content: String?
    @State private var error: String?
    var body: some View {
        DispatchList {
            BotIdentityLabel(name: bot.name, detail: skill.name)
            Text("Installed instructions · \(skill.provenance)").font(.footnote).foregroundStyle(DispatchStyle.secondary)
            if let error { PhoneNotice(title: "Instructions unavailable", message: error) }
            if let content { Text(content).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            else if error == nil { ProgressView("Loading instructions…") }
        }
        .dispatchTitle(skill.name).navigationBarTitleDisplayMode(.inline)
        .task { await load() }.refreshable { await load() }
    }
    private func load() async {
        content = nil; error = nil
        do { content = try await api.content(name: skill.name) }
        catch { self.error = botToolsError(error) }
    }
}
