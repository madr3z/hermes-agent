import SwiftUI
import HermesGateway

struct ConnectorsView: View {
    let bot: Bot
    let store: PhoneStore
    var body: some View { BotConnectorsView(bot: bot, store: store).id(bot.id) }
}

private struct BotConnectorsView: View {
    let bot: Bot
    let store: PhoneStore
    @State private var connectors: ConnectorsStore
    @State private var sheet: ConnectorSheet?
    @State private var removal: MCPConnection?
    init(bot: Bot, store: PhoneStore) {
        self.bot = bot; self.store = store
        _connectors = State(initialValue: ConnectorsStore(bot: bot))
    }
    var body: some View {
        List {
            Section {
                BotIdentityLabel(name: bot.name, detail: "Connections for this bot")
            } footer: {
                Text("Credentials stay on this bot’s gateway. New tools apply in a new session.")
            }
            if connectors.loading || connectors.working || connectors.error != nil || connectors.notice != nil {
                Section {
                    if connectors.loading { ProgressView("Loading connections…") }
                    if connectors.working { ProgressView("Saving on gateway…") }
                    if let error = connectors.error { PhoneNotice(title: "Could not complete the request", message: error) }
                    if let notice = connectors.notice { PhoneNotice(title: "Connection update", message: notice, systemImage: "info.circle") }
                }
            }
            Section {
                Button("Add iCloud account", systemImage: "icloud") { sheet = .icloud }
                Button("Add another account", systemImage: "person.crop.circle.badge.plus") { sheet = .stdioAccount }
            } header: { Text("Add an account") } footer: {
                Text("Use a separate name and credentials for each account. The connector must be installed on this bot’s VM.")
            }
            .disabled(connectors.api == nil || connectors.working || connectors.loading)
            mcpSection
            pluginSection
            hostedSection
        }
        .navigationTitle("Connectors")
        .navigationBarTitleDisplayMode(.inline)
        .task { await connectors.load(store: store) }
        .refreshable { await connectors.load(store: store) }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await connectors.load(store: store) } }.disabled(connectors.loading || connectors.working) }
        .sheet(item: $sheet) { selection in
            switch selection {
            case .mcp: AddMCPView(connectors: connectors, store: store)
            case .icloud: ICloudConnectorView(connectors: connectors, store: store)
            case .stdioAccount: StdioAccountConnectorView(connectors: connectors, store: store)
            case .customPlugin: CustomPluginView(connectors: connectors, store: store)
            case .catalog: PluginCatalogView(connectors: connectors, store: store)
            case .oauth(let server): MCPOAuthView(server: server, connectors: connectors, store: store)
            case .credential(let server): MCPCredentialView(server: server, connectors: connectors, store: store)
            case .pluginSettings(let plugin): PluginSettingsView(plugin: plugin, connectors: connectors, store: store)
            }
        }
        .confirmationDialog("Remove \(removal?.name ?? "MCP server") from \(bot.name)?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            if let selected = removal {
                Button("Remove server", role: .destructive) {
                    removal = nil
                    Task { _ = await connectors.mutate(store: store) { try await $0.call("mcp.servers.remove", ["name": .string(selected.name)]) } }
                }
            }
        } message: { Text("This removes the saved server configuration. It does not delete an account at the provider.") }
    }
    private var mcpSection: some View {
        Section("MCP servers") {
            ForEach(connectors.servers) { server in
                VStack(alignment: .leading, spacing: 6) {
                    Text(server.name).font(.headline)
                    Text(server.target).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Label(server.enabled ? "Enabled · \(server.transport)" : "Disabled", systemImage: server.enabled ? "checkmark.circle" : "pause.circle").font(.subheadline).foregroundStyle(.secondary)
                    if server.auth == "oauth" {
                        Text(server.authorized ? "Saved OAuth authorization" : "Sign-in required")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(server.authorized ? "Check sign-in" : "Sign in") { sheet = .oauth(server) }.font(.subheadline).buttonStyle(.borderless).frame(minHeight: 44)
                    }
                    if let plugin = server.plugin {
                        Text("Managed by plugin \(plugin)").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Button("Test") { test(server) }
                            if server.transport == "http", server.auth != "oauth" {
                                Button("Credentials") { sheet = .credential(server) }
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { removal = server }
                        }.font(.subheadline).buttonStyle(.borderless).frame(minHeight: 44)
                    }
                }.padding(.vertical, 4)
            }
            sectionError("MCP servers")
            if connectors.servers.isEmpty, connectors.sectionErrors["MCP servers"] == nil, !connectors.loading { Text("No MCP servers configured.").foregroundStyle(.secondary) }
            Button("Add MCP server", systemImage: "plus.circle") { sheet = .mcp }.disabled(connectors.api == nil || connectors.working || connectors.loading)

        }.disabled(connectors.working)
    }
    private var pluginSection: some View {
        Section("Plugins") {
            ForEach(connectors.plugins) { plugin in
                VStack(alignment: .leading, spacing: 6) {
                    Text(plugin.name).font(.headline)
                    Text(plugin.status).font(.caption).foregroundStyle(.secondary)
                    if !plugin.settings.isEmpty { Button("Settings") { sheet = .pluginSettings(plugin) }.font(.caption) }
                }
            }
            sectionError("Plugins")
            Button("Browse Hermes catalog") { sheet = .catalog }.disabled(connectors.catalog.isEmpty || connectors.working)
            Button("Install from Git URL…") { sheet = .customPlugin }.disabled(connectors.api == nil || connectors.working || connectors.loading)
            sectionError("Plugin catalog")
            Text("The Hermes catalog is the supported marketplace. Custom Git sources require a pinned commit and your confirmation.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var hostedSection: some View {
        Section("Hosted accounts") {
            ForEach(connectors.accounts) { account in
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.connector).font(.headline)
                    Text(account.label)
                    if let alias = account.alias { Text(alias).font(.caption).foregroundStyle(.secondary) }
                    Text("\(account.status)\(account.active ? " · Provider's active account" : "")").font(.caption).foregroundStyle(.secondary)
                }
            }
            sectionError("Hosted accounts")
            if connectors.accounts.isEmpty, connectors.sectionErrors["Hosted accounts"] == nil, !connectors.loading { Text("No hosted accounts connected.").foregroundStyle(.secondary) }
            Text("Account inventory is read-only here. Independent selection of several accounts for the same hosted connector is not supported by the current Hermes integration. Manage hosted sign-in on your Mac.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func sectionError(_ key: String) -> some View {
        if let error = connectors.sectionErrors[key] { PhoneNotice(title: "\(key) unavailable", message: error, systemImage: "info.circle") }
    }
    private func test(_ server: MCPConnection) {
        Task {
            let ok = await connectors.mutate(store: store) { api in
                let result = try await api.call("mcp.servers.test", ["name": .string(server.name)])
                guard result["ok"].bool else { throw GatewayError.message(result["error"].string ?? "The server test failed.") }
                return result
            }
            if ok { connectors.notice = "\(server.name) responded to the test. Its tools can be used in a new session." }
        }
    }
}

private enum ConnectorSheet: Identifiable {
    case mcp, icloud, stdioAccount, customPlugin, catalog, oauth(MCPConnection), credential(MCPConnection), pluginSettings(InstalledPlugin)
    var id: String {
        switch self {
        case .mcp: return "mcp"
        case .icloud: return "icloud"
        case .stdioAccount: return "stdio-account"
        case .customPlugin: return "custom-plugin"
        case .catalog: return "catalog"
        case .oauth(let server): return "oauth-" + server.name
        case .credential(let server): return "credential-" + server.name
        case .pluginSettings(let plugin): return "settings-" + plugin.id
        }
    }
}
