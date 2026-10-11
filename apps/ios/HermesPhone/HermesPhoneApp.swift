import SwiftUI
import HermesGateway

@main struct HermesPhoneApp: App {
    @State private var store = PhoneStore()
    var body: some Scene { WindowGroup { RosterView(store: store) } }
}

private enum RosterSheet: Identifiable {
    case gateway(GatewayEndpoint?), create, delete(VMDeletionTarget)
    var id: String {
        switch self { case .gateway(let endpoint): return "gateway-" + (endpoint?.id.uuidString ?? "new"); case .create: return "create"; case .delete(let target): return "delete-\(target.id)" }
    }
}

struct RosterView: View {
    @Bindable var store: PhoneStore
    @State private var sheet: RosterSheet?
    var body: some View {
        NavigationStack {
            List {
                if store.endpoints.isEmpty {
                    ContentUnavailableView("Your bots, wherever you are", systemImage: "network", description: Text("Connect to your HTTPS Hermes gateway. Bots keep running on their own machines when you close this app."))
                    Button("Connect a gateway") { sheet = .gateway(nil) }
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
                        if !endpoint.baseURL.path.contains("/gateways/") {
                            Button("Sign in to controller…") { sheet = .gateway(endpoint) }
                        }
                        if let owner = store.vmOwners[endpoint.id.uuidString], owner.owns(endpoint), store.vmDeletionControllers.contains(owner.mainID),
                           let target = VMDeletionTarget(mainID: owner.mainID, requestID: owner.requestID) {
                            Button("Delete Bot and VM…", role: .destructive) { sheet = .delete(target) }
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
                        Button("Add Gateway", systemImage: "network") { sheet = .gateway(nil) }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add bot or gateway")
                }
            }
            .refreshable { await store.refresh() }
            .task { await store.refresh() }
            .sheet(item: $sheet) { selected in
                switch selected {
                case .gateway(let endpoint): GatewayForm(store: store, existing: endpoint)
                case .create: CreateBotView(store: store)
                case .delete(let target): VMDeletionView(target: target, store: store)
                }
            }
        }
    }
}

private enum GatewayLoginMethod: String, CaseIterable, Identifiable {
    case password = "Username and password", token = "Access token"
    var id: String { rawValue }
}

struct GatewayForm: View {
    let store: PhoneStore
    let existing: GatewayEndpoint?
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var address: String
    @State private var method = GatewayLoginMethod.password
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var providers: [JSON] = []
    @State private var provider = ""
    @State private var error: String?
    @State private var connecting = false
    init(store: PhoneStore, existing: GatewayEndpoint? = nil) {
        self.store = store; self.existing = existing
        _label = State(initialValue: existing?.label ?? "")
        _address = State(initialValue: existing?.baseURL.absoluteString ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway") {
                    TextField("Name", text: $label).disabled(existing != nil).accessibilityIdentifier("gatewayName")
                    TextField("https://hermes.example.com", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(existing != nil).accessibilityIdentifier("gatewayURL")
                }.disabled(connecting)
                Section("Controller login") {
                    Picker("Sign-in method", selection: $method) { ForEach(GatewayLoginMethod.allCases) { Text($0.rawValue).tag($0) } }
                    if method == .password {
                        TextField("Username", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $password).textContentType(.password).privacySensitive()
                        if providers.count > 1 {
                            Picker("Login provider", selection: $provider) {
                                Text("Choose provider").tag("")
                                ForEach(providers, id: \.self) { Text($0["display_name"].string ?? $0["name"].string ?? "Provider").tag($0["name"].string ?? "") }
                            }
                        }
                    } else {
                        SecureField("Access token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().accessibilityIdentifier("gatewayToken")
                    }
                }.disabled(connecting)
                Section { Text("Sign in to your HTTPS Hermes controller. Its saved session stays in Keychain on this phone. Your password is not saved.").font(.footnote) }
                if let error { Text(error).foregroundStyle(.red) }
                Button { connect() } label: {
                    HStack { Text(connecting ? "Connecting…" : method == .password ? "Sign in" : "Connect"); if connecting { ProgressView() } }
                }.disabled(connecting || address.isEmpty || (method == .password ? username.isEmpty || password.isEmpty : token.isEmpty)).accessibilityIdentifier("saveGateway")
            }
            .navigationTitle(existing == nil ? "Connect Gateway" : "Sign in again").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(connecting) } }
            .onChange(of: address) { _, _ in clearSecrets(); providers = []; provider = "" }
            .onChange(of: method) { _, _ in clearSecrets() }
            .onDisappear { clearSecrets() }
        }
    }
    private func clearSecrets() { password = ""; token = "" }
    private func connect() {
        connecting = true; error = nil
        let submittedPassword = password, submittedToken = token
        Task {
            do {
                if method == .token {
                    try await store.add(label: label, address: address.trimmingCharacters(in: .whitespacesAndNewlines), token: submittedToken.trimmingCharacters(in: .whitespacesAndNewlines), replacing: existing?.id)
                } else {
                    guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw GatewayError.message("Enter an HTTPS controller URL.") }
                    guard !url.path.contains("/api/plugins/bot-provisioning/v1/gateways/") else { throw GatewayError.message("Sign in to the owning main controller, then connect this bot from its registry.") }
                    let endpoint = try existing ?? GatewayEndpoint(label: label.isEmpty ? url.host ?? "Controller" : label, baseURL: url)
                    let controller = ControllerSession(endpoint: endpoint)
                    providers = try await controller.passwordProviders()
                    if providers.count == 1 { provider = providers[0]["name"].string ?? "" }
                    guard providers.contains(where: { $0["name"].string == provider }), !provider.isEmpty else { throw GatewayError.message(providers.isEmpty ? "This gateway has no username/password sign-in provider. Use its supported connection method." : "Choose a login provider, then sign in.") }
                    try await controller.signIn(provider: provider, username: username, password: submittedPassword)
                    try await store.signIn(endpoint: endpoint, controller: controller)
                }
                clearSecrets(); dismiss()
            } catch { self.error = "Sign-in failed. " + (submittedPassword.isEmpty ? error.localizedDescription : error.localizedDescription.replacingOccurrences(of: submittedPassword, with: "[redacted]")) }
            connecting = false
        }
    }
}
