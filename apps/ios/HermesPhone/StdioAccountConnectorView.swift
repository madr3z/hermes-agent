import SwiftUI
import HermesGateway

struct StdioAccountConnectorView: View {
    let connectors: ConnectorsStore
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var provider = "custom-mcp"
    @State private var identity = ""
    @State private var command = ""
    @State private var arguments = ""
    @State private var entries: [StdioEnvironmentEntry] = [.init()]
    @State private var setup = StdioSecretSetup()
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BotIdentityLabel(name: connectors.bot.name, detail: "Custom account")
                }
                Group {
                    Section("Stdio account") {
                        TextField("Account label", text: $name)
                        TextField("Provider, e.g. custom-mcp", text: $provider)
                        TextField("Expected account identity (optional)", text: $identity)
                        TextField("Command installed on this VM", text: $command)
                        TextField("Arguments, one per line", text: $arguments, axis: .vertical).lineLimit(2...6)
                        Text("The command runs on this bot's VM and can access its files. Install the server there first. Keep credentials out of the command and arguments.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Account environment") {
                        ForEach($entries) { $entry in
                            VStack(alignment: .leading, spacing: 12) {
                                TextField("Environment name, e.g. API_KEY", text: $entry.name)
                                SecureField("Value", text: $entry.value).privacySensitive()
                                Button("Remove entry", role: .destructive) { entries.removeAll { $0.id == entry.id } }.font(.subheadline).frame(minHeight: 44)
                            }
                        }
                        if entries.count < 16 { Button("Add environment entry") { entries.append(.init()) } }
                        Text("Each value uses a new secret slot for this account. Three accounts can use the same environment names without sharing credentials. Values stay on this bot; this iPhone keeps them only during setup.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(setup.installer != nil || setup.saved || connectors.working)
                StdioSetupActions(setup: setup, connectors: connectors, store: store, plan: {
                    try StdioAccountPlan(name: name, command: command, arguments: arguments, provider: provider, requestedIdentity: identity, secrets: entries, existingNames: connectors.servers.map(\.name))
                }, clearSecrets: { entries.removeAll() })
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Add stdio account").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(setup.saved ? "Done" : "Close") { dismiss() }.disabled(connectors.working) } }
        }.interactiveDismissDisabled(connectors.working).onDisappear { entries.removeAll() }
    }
}
