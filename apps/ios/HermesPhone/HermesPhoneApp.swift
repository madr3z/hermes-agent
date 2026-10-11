import SwiftUI
import HermesGateway

@main struct HermesPhoneApp: App {
    @UIApplicationDelegateAdaptor(HermesApplicationDelegate.self) private var appDelegate
    @State private var store = PhoneStore()
    var body: some Scene { WindowGroup { RosterView(store: store) } }
}

private enum RosterSheet: Identifiable {
    case gateway(GatewayEndpoint?), create, delete(VMDeletionTarget), mobile(GatewayEndpoint)
    var id: String {
        switch self { case .gateway(let endpoint): return "gateway-" + (endpoint?.id.uuidString ?? "new"); case .mobile(let endpoint): return "mobile-" + endpoint.id.uuidString; case .create: return "create"; case .delete(let target): return "delete-\(target.id)" }
    }
}

private struct ChatDestination: Hashable {
    let bot: Bot
    var messageID: String? = nil
}

struct RosterView: View {
    @Bindable var store: PhoneStore
    @State private var sheet: RosterSheet?
    @State private var path: [ChatDestination] = []
    @Bindable private var contact = MobileContact.shared
    @Bindable private var calls = CallPresentation.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.endpoints.isEmpty {
                    Section {
                        ContentUnavailableView("Meet your bots", systemImage: "sparkles", description: Text("Chat, call and work with your bots from your iPhone. Connect your Hermes controller to get started."))
                        Button { sheet = .gateway(nil) } label: {
                            Label("Connect a gateway", systemImage: "network")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("connectGateway")
                    }.listRowBackground(Color.clear)
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("A little help, always here.").font(.title2.weight(.semibold))
                            Text("Pick a bot to keep the conversation going.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                        if store.loading { ProgressView("Refreshing bots…") }
                    }.listRowBackground(Color.clear)
                }
                ForEach(store.endpoints) { endpoint in
                    Section {
                        let rows = store.bots.filter { $0.endpointID == endpoint.id }
                        if rows.isEmpty {
                            PhoneNotice(title: store.loading ? "Loading bots…" : "No bots to show", message: "Pull down to refresh this gateway.", systemImage: "network")
                        }
                        ForEach(rows) { bot in
                            NavigationLink(value: ChatDestination(bot: bot)) {
                                HStack(alignment: .top, spacing: 12) {
                                    BotAvatar()
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(bot.name).font(.headline).foregroundStyle(.primary)
                                        Text(bot.preview.isEmpty ? "Start a conversation" : bot.preview)
                                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                        if bot.profile != bot.name {
                                            Text(bot.profile).font(.caption).foregroundStyle(.tertiary)
                                        }
                                    }
                                }.padding(.vertical, 12)
                            }
                            .accessibilityHint("Opens the saved conversation with \(bot.name)")
                        }
                    } header: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(endpoint.label).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Label(endpoint.baseURL.path.contains("/gateways/") ? "Bot computer" : "Controller", systemImage: endpoint.baseURL.path.contains("/gateways/") ? "desktopcomputer" : "network")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !endpoint.baseURL.path.contains("/gateways/") || store.vmOwners[endpoint.id.uuidString].map({ store.vmDeletionControllers.contains($0.mainID) }) == true {
                                Menu {
                                    if !endpoint.baseURL.path.contains("/gateways/") {
                                        Button("Sign in to controller", systemImage: "person.crop.circle") { sheet = .gateway(endpoint) }
                                        Button("Calls and notifications", systemImage: "bell") { sheet = .mobile(endpoint) }
                                    }
                                    if let owner = store.vmOwners[endpoint.id.uuidString], owner.owns(endpoint), store.vmDeletionControllers.contains(owner.mainID),
                                       let target = VMDeletionTarget(mainID: owner.mainID, requestID: owner.requestID) {
                                        Button("Delete Bot and VM…", systemImage: "trash", role: .destructive) { sheet = .delete(target) }
                                    }
                                } label: { Image(systemName: "ellipsis.circle").font(.title3).frame(minWidth: 44, minHeight: 44) }
                                .accessibilityLabel("Manage \(endpoint.label)")
                            }
                        }.textCase(nil)
                    }
                }
                if let error = store.error {
                    Section {
                        PhoneNotice(title: "Could not refresh", message: error)
                        Button("Try again", systemImage: "arrow.clockwise") { Task { await store.refresh() } }.disabled(store.loading)
                    }
                }
                Section {
                    Label("Your conversations stay on your gateway.", systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(Color.clear)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    MobileCallBanner()
                    if let outgoing = calls.outgoing, outgoing.voice.active || outgoing.voice.connecting {
                        CallSummary(name: outgoing.bot.name, status: outgoing.voice.activity, endLabel: "End",
                                    onReturn: { calls.isPresented = true }, onEnd: { outgoing.voice.stop() })
                    }
                }
            }
            .navigationTitle("Bots")
            .navigationDestination(for: ChatDestination.self) { target in
                ChatView(bot: target.bot, store: store, messageID: target.messageID).id(target)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Create Bot", systemImage: "plus.circle") { sheet = .create }.disabled(store.endpoints.isEmpty)
                        Button("Add Gateway", systemImage: "network") { sheet = .gateway(nil) }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add bot or gateway")
                }
            }
            .fullScreenCover(item: callDestination) { destination in
                switch destination {
                case .incoming: IncomingCallView(contact: contact)
                case .outgoing(let chat): VoiceView(chat: chat)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { calls.outgoing?.voice.stop() }
            }
            .refreshable { await store.refresh() }
            .task { await store.refresh() }
            .task(id: contact.notificationToOpen?.id) { await openNotification() }
            .sheet(item: $sheet) { selected in
                switch selected {
                case .gateway(let endpoint): GatewayForm(store: store, existing: endpoint)
                case .create: CreateBotView(store: store)
                case .delete(let target): VMDeletionView(target: target, store: store)
                case .mobile(let endpoint): MobileContactView(endpoint: endpoint, store: store)
                }
            }
        }
    }
    private func openNotification() async {
        guard let route = contact.notificationToOpen else { return }
        do {
            guard let main = store.endpoints.first(where: { $0.id == route.controllerID }) else { throw GatewayError.message("Connect this notification’s controller again.") }
            let client = try await store.client(for: main.id)
            let row = try await client.http("api/plugins/bot-provisioning/v1/requests/" + route.invitation.guestID.uuidString.lowercased())
            guard row["phase"].string == "ready", row["request_id"].string.flatMap(UUID.init(uuidString:)) == route.invitation.guestID else { throw GatewayError.message("This bot’s computer is no longer available.") }
            let gateway = try main.provisionedGateway(row)
            let existing = store.endpoints.first { $0.baseURL == gateway.baseURL }
            if existing == nil || !store.bots.contains(where: { $0.endpointID == existing?.id && $0.profile == route.invitation.profile }) {
                try await store.addProvisioned(row, main: main)
            }
            guard let endpoint = store.endpoints.first(where: { $0.baseURL == gateway.baseURL }),
                  let bot = store.bots.first(where: { $0.endpointID == endpoint.id && $0.profile == route.invitation.profile }) else { throw GatewayError.message("This bot’s conversation is unavailable.") }
            guard contact.notificationToOpen?.id == route.id else { return }
            sheet = nil
            path = [ChatDestination(bot: bot, messageID: route.invitation.messageID)]
            contact.notificationToOpen = nil
        } catch {
            if contact.notificationToOpen?.id == route.id { contact.error = error.localizedDescription; contact.notificationToOpen = nil }
        }
    }
    private var callDestination: Binding<CallDestination?> {
        Binding(get: {
            if contact.callPresentation.isPresented, let incoming = contact.callInvitation { return .incoming(incoming.invitationID) }
            if calls.isPresented, let outgoing = calls.outgoing { return .outgoing(outgoing) }
            return nil
        }, set: { value in
            if value == nil { contact.callPresentation.isPresented = false; calls.closeScreen() }
        })
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
                Section {
                    PhoneNotice(title: existing == nil ? "Connect to Hermes" : "Reconnect your controller", message: "Use the HTTPS address of your Hermes controller.", systemImage: "network")
                }
                Section("Your controller") {
                    TextField("Name, e.g. Home", text: $label).disabled(existing != nil).accessibilityIdentifier("gatewayName")
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
                if let error { PhoneNotice(title: "Could not sign in", message: error) }
                Button { connect() } label: {
                    HStack { Text(connecting ? "Connecting…" : method == .password ? "Sign in" : "Connect"); if connecting { ProgressView() } }
                }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity).listRowBackground(Color.clear).disabled(connecting || address.isEmpty || (method == .password ? username.isEmpty || password.isEmpty : token.isEmpty)).accessibilityIdentifier("saveGateway")
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(existing == nil ? "Connect to Hermes" : "Sign in again").navigationBarTitleDisplayMode(.inline)
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
