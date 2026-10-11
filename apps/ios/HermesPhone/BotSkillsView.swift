import SwiftUI
import HermesGateway

struct BotSkillsView: View {
    let bot: Bot
    let store: PhoneStore
    @State private var skills: [BotSkill] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    private var visible: [BotSkill] {
        skills.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            Section {
                BotIdentityLabel(name: bot.name, detail: "Installed skills")
                Text("Skills give this bot instructions for specific tasks. Describe what you need in Bot Chat.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if loading { ProgressView("Loading skills…") }
            if let error {
                Section {
                    PhoneNotice(title: "Could not load skills", message: error)
                    Button("Try again") { Task { await load() } }.disabled(loading)
                }
            }
            if !loading && error == nil && skills.isEmpty {
                ContentUnavailableView("No installed skills", systemImage: "books.vertical", description: Text("Add skills from your Mac, then refresh this list."))
            } else if !skills.isEmpty && visible.isEmpty {
                ContentUnavailableView.search(text: search)
            }
            ForEach(Array(Set(visible.map(\.category))).sorted(), id: \.self) { category in
                Section(category) {
                    ForEach(visible.filter { $0.category == category }) { skill in
                        Label { Text(skill.name).textSelection(.enabled) } icon: {
                            Image(systemName: "text.book.closed").foregroundStyle(.tint).accessibilityHidden(true)
                        }.padding(.vertical, 6)
                    }
                }
            }
        }
        .navigationTitle("Skills").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find a skill or category")
        .task { await load() }
        .refreshable { await load() }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading) }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let client = try await store.client(for: bot.endpointID)
            let api = BotCapabilitiesClient(profile: bot.profile) { try await client.request($0, $1) }
            let result = try await api.skills()
            try Task.checkCancellation()
            skills = result
        } catch is CancellationError { return }
        catch { self.error = botToolsError(error) }
    }
}
