import SwiftUI
import HermesGateway

@main struct HermesPhoneApp: App {
    @State private var store = PhoneStore()
    var body: some Scene { WindowGroup { RosterView(store: store) } }
}

private enum RosterSheet: String, Identifiable {
    case gateway, create
    var id: String { rawValue }
}

struct RosterView: View {
    @Bindable var store: PhoneStore
    @State private var sheet: RosterSheet?
    var body: some View {
        NavigationStack {
            List {
                if store.endpoints.isEmpty {
                    ContentUnavailableView("Your bots, wherever you are", systemImage: "network", description: Text("Connect to your HTTPS Hermes gateway. Bots keep running on their own machines when you close this app."))
                    Button("Connect a gateway") { sheet = .gateway }
                        .accessibilityIdentifier("connectGateway")
                }
                ForEach(store.endpoints) { endpoint in
                    Section(endpoint.label) {
                        let rows = store.bots.filter { $0.endpointID == endpoint.id }
                        if rows.isEmpty { Text("No bots loaded").foregroundStyle(.secondary) }
                        ForEach(rows) { bot in
                            NavigationLink(value: bot) {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "sparkle").font(.title2).foregroundStyle(.tint).frame(width: 34, height: 42)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(bot.name).font(.headline)
                                        Text(bot.preview.isEmpty ? "Open Bot Chat" : bot.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }.padding(.vertical, 5)
                            }
                        }
                    }
                }
                if let error = store.error { Section { Text(error).foregroundStyle(.red); Button("Retry") { Task { await store.refresh() } } } }
                Section { Text("Conversations and tasks live on your gateway. Your phone holds the gateway access token in Keychain.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Hermes")
            .navigationDestination(for: Bot.self) { bot in ChatView(bot: bot, store: store) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Create Bot", systemImage: "plus.circle") { sheet = .create }.disabled(store.endpoints.isEmpty)
                        Button("Add Gateway", systemImage: "network") { sheet = .gateway }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add bot or gateway")
                }
            }
            .refreshable { await store.refresh() }
            .task { await store.refresh() }
            .sheet(item: $sheet) { selected in
                switch selected {
                case .gateway: GatewayForm(store: store)
                case .create: CreateBotView(store: store)
                }
            }
        }
    }
}

struct GatewayForm: View {
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var address = ""
    @State private var token = ""
    @State private var error: String?
    @State private var connecting = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway") {
                    TextField("Name", text: $label).accessibilityIdentifier("gatewayName")
                    TextField("https://hermes.example.com", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("gatewayURL")
                    SecureField("Access token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("gatewayToken")
                }
                Section { Text("Use the same authenticated gateway as Hermes Desktop. Your gateway must be reachable from this phone over HTTPS.").font(.footnote) }
                if let error { Text(error).foregroundStyle(.red) }
                Button { connect() } label: {
                    HStack { Text(connecting ? "Connecting…" : "Connect"); if connecting { ProgressView() } }
                }.disabled(connecting || address.isEmpty || token.isEmpty).accessibilityIdentifier("saveGateway")
            }
            .navigationTitle("Connect Gateway").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(connecting) } }
        }
    }
    private func connect() {
        connecting = true; error = nil
        Task {
            do { try await store.add(label: label, address: address.trimmingCharacters(in: .whitespacesAndNewlines), token: token.trimmingCharacters(in: .whitespacesAndNewlines)); token = ""; dismiss() }
            catch { self.error = error.localizedDescription }
            connecting = false
        }
    }
}
