import SwiftUI
import HermesGateway

struct DispatchConversationRow: View {
    let bot: Bot
    var detail: String?
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 14) {
                DispatchAvatar(symbol: "text.bubble", size: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(bot.conversationPreview.isEmpty ? "Start a conversation" : bot.conversationPreview)
                        .font(.subheadline.weight(.medium)).foregroundStyle(DispatchStyle.ink).lineLimit(2)
                    Text([bot.name, detail].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(DispatchStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.body.weight(.light)).foregroundStyle(DispatchStyle.secondary)
            }.padding(.vertical, 10).frame(minHeight: 64).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint("Opens the conversation with \(bot.name)")
    }
}

struct DispatchChatsView: View {
    let store: PhoneStore
    let openChat: (Bot) -> Void
    @State private var search = ""
    private var bots: [Bot] {
        store.bots.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
            || $0.conversationPreview.localizedCaseInsensitiveContains(search) }
            .sorted { $0.lastActive > $1.lastActive }
    }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if bots.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "Your conversations" : "No matching chats",
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text(search.isEmpty ? "Connect a bot from Today or Bots to start a conversation." : "Try a bot name or a word from a recent message."))
                }
                ForEach(bots) { bot in
                    DispatchConversationRow(bot: bot, detail: store.endpoints.first { $0.id == bot.endpointID }?.label,
                                            open: { openChat(bot) })
                    Rectangle().fill(DispatchStyle.rule).frame(height: 1)
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .searchable(text: $search, prompt: "Search bots and recent messages")
        .background(DispatchStyle.paper.ignoresSafeArea())
    }
}

struct DispatchSettingsView: View {
    let store: PhoneStore
    let edit: (GatewayEndpoint) -> Void
    let mobile: (GatewayEndpoint) -> Void
    let add: () -> Void
    let create: () -> Void
    let callSettings: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Connections") {
                    ForEach(store.endpoints.filter { !$0.baseURL.path.contains("/gateways/") }) { endpoint in
                        Button { edit(endpoint) } label: { Label(endpoint.label, systemImage: "network") }
                        Button { mobile(endpoint) } label: { Label("Calls and notifications · \(endpoint.label)", systemImage: "bell") }
                    }
                    Button(action: add) { Label("Connect a gateway", systemImage: "plus") }
                }
                Section("Calls") {
                    Button(action: callSettings) { Label("Call settings", systemImage: "phone.badge.waveform") }
                        .accessibilityIdentifier("dispatchCallSettings")
                }
                Section("Bots") {
                    Button(action: create) { Label("Create Bot", systemImage: "person.badge.plus") }
                        .disabled(store.endpoints.isEmpty)
                    Text("Open a bot’s conversation for accounts, skills, scheduled tasks and computer controls.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden).background(DispatchStyle.paper)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(DispatchStyle.forest)
    }
}
