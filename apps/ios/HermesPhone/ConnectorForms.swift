import SwiftUI
import HermesGateway

struct AddMCPView: View {
    let connectors: ConnectorsStore
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MCPConnectionDraft()
    @State private var error: String?
    @State private var confirming = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Server for \(connectors.bot.name)") {
                    TextField("Unique name, e.g. gmail-work", text: $draft.name).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("mcpAccountName")
                    Picker("Transport", selection: $draft.transport) { Text("HTTPS").tag("http"); Text("Command on bot VM").tag("stdio") }
                    TextField(draft.transport == "http" ? "https://provider.example/mcp" : "Command on the bot VM", text: $draft.target)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if draft.transport == "stdio" {
                        TextField("Arguments, one per line", text: $draft.arguments, axis: .vertical).lineLimit(2...6).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("The command runs on this bot's VM. Configure provider-specific environment credentials from your Mac.").font(.footnote)
                    } else {
                        Toggle("OAuth sign-in", isOn: $draft.oauth)
                        if !draft.oauth { SecureField("Bearer token (optional)", text: $draft.bearer).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive() }
                    }
                }
                Section { Text("Use one named server per account. Credentials stay on the selected bot's gateway. For OAuth servers, save first, then choose Sign in. Some providers require sign-in on your Mac.").font(.footnote) }
                if let error { Text(error).foregroundStyle(.red) }
                if let error = connectors.error { Text(error).foregroundStyle(.red) }
                Button("Review server") {
                    do {
                        _ = try draft.parameters()
                        guard !connectors.servers.contains(where: { $0.name == draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }) else { throw GatewayError.message("This name is already in use. Choose a distinct name for the account.") }
                        error = nil; confirming = true
                    } catch { self.error = error.localizedDescription }
                }.disabled(connectors.working)
            }
            .navigationTitle("Add MCP server").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(connectors.working) } }
            .confirmationDialog("Save \(draft.name) on \(connectors.bot.name)?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Save server") {
                    let submitted = draft
                    draft.bearer = ""
                    Task {
                        if await connectors.mutate(store: store, secret: submitted.bearer, body: { try await $0.addMCP(submitted) }) { dismiss() }
                    }
                }
            } message: { Text(draft.target + "\nNew tools apply in a new session. Saving does not prove the server can connect.") }
        }
        .interactiveDismissDisabled(connectors.working)
        .onDisappear { draft.bearer = "" }
    }
}

struct MCPCredentialView: View {
    let server: MCPConnection
    let connectors: ConnectorsStore
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    var body: some View {
        NavigationStack {
            Form {
                Section(server.name) {
                    SecureField("Bearer token", text: $value).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    Text("Save a new credential on \(connectors.bot.name). The current credential is never sent to this phone.").font(.footnote)
                }
                if let error = connectors.error { Text(error).foregroundStyle(.red) }
                Button("Save credential") {
                    let submitted = value; value = ""
                    Task {
                        if await connectors.mutate(store: store, secret: submitted, body: { try await $0.call("mcp.servers.set_api_key", ["name": .string(server.name), "value": .string(submitted)]) }) { dismiss() }
                    }
                }.disabled(value.isEmpty || connectors.working)
            }
            .navigationTitle("Server credential").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(connectors.working) } }
        }.interactiveDismissDisabled(connectors.working).onDisappear { value = "" }
    }
}

struct CustomPluginView: View {
    let connectors: ConnectorsStore
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ""
    @State private var sha = ""
    @State private var review: PluginInstallReview?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Custom plugin") {
                    TextField("https://github.com/owner/repository", text: $repo).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Full commit SHA (40 hex characters)", text: $sha).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("A custom source is not part of the reviewed Hermes catalog. This installs code on \(connectors.bot.name).").font(.footnote)
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button("Review installation") {
                    do { review = try PluginInstallReview(repo: repo, sha: sha); error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(connectors.working)
            }
            .navigationTitle("Install plugin").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: $review) { PluginInstallReviewView(review: $0, connectors: connectors, store: store) }
        }
    }
}

struct PluginCatalogView: View {
    let connectors: ConnectorsStore
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var review: PluginInstallReview?
    var body: some View {
        NavigationStack {
            List {
                Section { Text("Plugins run on \(connectors.bot.name)'s gateway. Check the supported platforms before installing.").font(.footnote).foregroundStyle(.secondary) }
                ForEach(connectors.catalog.filter { query.isEmpty || ($0.title + " " + $0.description).localizedCaseInsensitiveContains(query) }) { plugin in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(plugin.title).font(.headline)
                        Text(plugin.description).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                        Text("\(plugin.tier) · \(plugin.platforms.isEmpty ? "All platforms" : plugin.platforms.joined(separator: ", "))").font(.caption)
                        if plugin.installed { Text("Installed").font(.caption).foregroundStyle(.secondary) }
                        else { Button("Review installation") { review = PluginInstallReview(catalog: plugin) }.font(.caption).disabled(connectors.working) }
                    }.padding(.vertical, 4)
                }
            }
            .searchable(text: $query)
            .navigationTitle("Hermes catalog").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $review) { PluginInstallReviewView(review: $0, connectors: connectors, store: store) }
        }
    }
}

struct PluginInstallReviewView: View {
    let review: PluginInstallReview
    let connectors: ConnectorsStore
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section(review.title) {
                    Text(review.description)
                    LabeledContent("Bot", value: connectors.bot.name)
                    Text(review.repo).font(.caption).textSelection(.enabled)
                    Text("Commit: " + review.sha).font(.caption.monospaced()).textSelection(.enabled)
                }
                Section {
                    Text("Installing allows this plugin to run on the bot's VM. Review the source and its capabilities before you continue. Existing Hermes scan and compatibility checks still apply.").font(.footnote)
                    if let error = connectors.error { Text(error).foregroundStyle(.red) }
                    if connectors.working { ProgressView("Installing…") }
                    Button("Install on \(connectors.bot.name)") {
                        Task { if await connectors.mutate(store: store, body: { try await $0.install(review) }) { dismiss() } }
                    }.disabled(connectors.working)
                }
            }
            .navigationTitle("Review installation").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(connectors.working) } }
        }.interactiveDismissDisabled(connectors.working)
    }
}
