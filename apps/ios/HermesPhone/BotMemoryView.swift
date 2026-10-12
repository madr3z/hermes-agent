import SwiftUI
import HermesGateway

struct BotMemoryView: View {
    let bot: Bot
    let store: PhoneStore
    @State private var model = BotMemoryStore()
    @State private var api: BotMemoryClient?
    @State private var search = ""
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        List {
            Section {
                BotIdentityLabel(name: bot.name, detail: "Memory inspection")
                Text("Read the built-in memory and user-profile notes saved for this bot. External memory services are not included. This view does not reload the current chat.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if model.loading { ProgressView("Loading memory…") }
            if let error = model.error { PhoneNotice(title: "Memory unavailable", message: error) }
            if !model.loading && model.error == nil && model.cards.isEmpty {
                ContentUnavailableView("No built-in memory", systemImage: "brain")
            }
            ForEach(model.cards.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }) { card in
                if let api {
                    NavigationLink { BotMemoryDetail(bot: bot, card: card, api: api) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.label)
                            Text(card.source == "profile" ? "User profile" : "Memory").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Memory").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find a memory")
        .task(id: bot.id) { await connect() }.refreshable { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.refresh() } } }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.disabled(model.loading) }
    }
    private func connect() async {
        api = nil; model.disconnect()
        do {
            let client = try await store.client(for: bot.endpointID)
            try Task.checkCancellation()
            let api = BotMemoryClient(profile: bot.profile) { try await client.http($0, profile: $1, query: $2) }
            self.api = api; model.bind(api); await model.refresh()
        } catch is CancellationError { return }
        catch { model.connectionFailed(error) }
    }
}

struct BotMemoryDetail: View {
    let bot: Bot
    let card: BotMemoryCard
    let api: BotMemoryClient
    @State private var content: String?
    @State private var error: String?
    var body: some View {
        List {
            BotIdentityLabel(name: bot.name, detail: card.source == "profile" ? "User profile" : "Memory")
            if let error { PhoneNotice(title: "Memory unavailable", message: error) }
            if let content { Text(content).textSelection(.enabled) }
            else if error == nil { ProgressView("Loading memory…") }
        }
        .navigationTitle("Memory card").navigationBarTitleDisplayMode(.inline)
        .task { await load() }.refreshable { await load() }
    }
    private func load() async {
        content = nil; error = nil
        do { content = try await api.content(card: card) }
        catch { self.error = botToolsError(error) }
    }
}
