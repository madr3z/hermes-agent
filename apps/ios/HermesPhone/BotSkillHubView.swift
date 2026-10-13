import SwiftUI
import HermesGateway

struct BotSkillHubView: View {
    let bot: Bot
    let api: BotSkillsClient
    let model: BotSkillsStore
    @State private var rows: [HubBotSkill] = []
    @State private var page = 1
    @State private var more = false
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        DispatchList {
            BotIdentityLabel(name: bot.name, detail: "Skill hub")
            Text("Skills contain instructions that the bot can follow. Review the source and preview before installing. The gateway scans downloaded skills and can refuse an install.")
                .font(.subheadline).foregroundStyle(DispatchStyle.secondary)
            if let error { PhoneNotice(title: "Skill hub unavailable", message: error) }
            if loading { ProgressView("Loading skill hub…") }
            ForEach(rows) { skill in
                NavigationLink { BotHubSkillReview(bot: bot, skill: skill, api: api, model: model) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(skill.name).font(DispatchStyle.serif(23, relativeTo: .headline))
                        Text(skill.description).font(.subheadline)
                        Text("\(skill.source) · \(skill.trust)").font(.caption).foregroundStyle(DispatchStyle.secondary)
                    }
                }
            }
            if !loading && rows.isEmpty && error == nil { Text("No hub skills found.") }
            if more { Button("Next page") { Task { await load(page: page + 1) } }.disabled(loading) }
            if page > 1 { Button("Previous page") { Task { await load(page: page - 1) } }.disabled(loading) }
        }
        .dispatchTitle("Skill hub").navigationBarTitleDisplayMode(.inline)
        .task { await load(page: page) }.refreshable { await load(page: page) }
    }
    private func load(page: Int) async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await api.browse(page: page)
            try Task.checkCancellation()
            rows = result.skills; more = result.hasMore; self.page = page
        } catch is CancellationError { return }
        catch { self.error = botToolsError(error) }
    }
}

struct BotHubSkillReview: View {
    let bot: Bot
    let skill: HubBotSkill
    let api: BotSkillsClient
    let model: BotSkillsStore
    @State private var preview: String?
    @State private var error: String?
    @State private var confirm = false
    @State private var attempted = false
    var body: some View {
        DispatchList {
            DispatchSection {
                BotIdentityLabel(name: bot.name, detail: skill.name)
                LabeledContent("Source", value: skill.source)
                LabeledContent("Trust", value: skill.trust)
                Text(skill.identifier).font(.caption).textSelection(.enabled)
                Text("The hub preview is a partial review. The source can change before download; the gateway scans the downloaded skill. Installed instructions apply to new sessions.")
                    .font(.footnote).foregroundStyle(DispatchStyle.secondary)
            }
            if let error { PhoneNotice(title: "Preview unavailable", message: error) }
            if let preview { Text(preview).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            else if error == nil { ProgressView("Loading preview…") }
            DispatchSection {
                Button("Install for \(bot.name)") { confirm = true }
                    .disabled(preview == nil || !model.canChange || !model.installAvailable)
                if let reason = model.installAvailabilityError { Text(reason).font(.footnote).foregroundStyle(DispatchStyle.secondary) }
                if let error = model.error { PhoneNotice(title: "Install not confirmed", message: error) }
                if attempted, let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(DispatchStyle.secondary) }
                Button("Refresh status") { Task { await model.refresh() } }.disabled(model.loading || model.working)
            }
        }
        .dispatchTitle("Review skill").navigationBarTitleDisplayMode(.inline)
        .task { await load() }.refreshable { await load(); await model.refresh() }
        .confirmationDialog("Install \(skill.name) on \(bot.name)?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Install for new sessions") { attempted = true; Task { await model.install(identifier: skill.identifier) } }
        } message: { Text("This downloads instructions from \(skill.source). The current chat will keep its loaded instructions.") }
    }
    private func load() async {
        preview = nil; error = nil
        do { preview = try await api.preview(identifier: skill.identifier) }
        catch { self.error = botToolsError(error) }
    }
}
