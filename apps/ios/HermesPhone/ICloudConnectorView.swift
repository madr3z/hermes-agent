import SwiftUI
import HermesGateway

struct ICloudConnectorView: View {
    let connectors: ConnectorsStore
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ICloudAccountDraft()
    @State private var separateMail = false
    @State private var setup = StdioSecretSetup()
    var body: some View {
        NavigationStack {
            DispatchForm {
                DispatchSection {
                    BotIdentityLabel(name: connectors.bot.name, detail: "iCloud account")
                }
                Group {
                    DispatchSection("iCloud account") {
                        TextField("Unique account name", text: $draft.name)
                        TextField("Apple Account email", text: $draft.email).keyboardType(.emailAddress).textContentType(.username)
                        SecureField("App-specific password", text: $draft.password).privacySensitive()
                        Toggle("Use a different iCloud Mail address", isOn: $separateMail)
                            .onChange(of: separateMail) { _, value in if !value { draft.mailAddress = "" } }
                        if separateMail { TextField("iCloud Mail address", text: $draft.mailAddress).keyboardType(.emailAddress) }
                        Text("Create an app-specific password for this account. Hermes saves it in a new secret slot on this bot. It does not save the password on this iPhone.").font(.footnote).foregroundStyle(DispatchStyle.secondary)
                    }
                    DispatchSection("Permissions") {
                        Text("Calendar and Mail reads are enabled. Contacts are disabled.").font(.footnote)
                        Toggle("Read-only access", isOn: $draft.readOnly)
                            .onChange(of: draft.readOnly) { _, value in if value { draft.mailWrite = false; draft.mailSend = false } }
                        if !draft.readOnly {
                            Text("Calendar tools can create, change and delete events.").font(.footnote)
                            Toggle("Allow Mail changes", isOn: $draft.mailWrite)
                            Text("Mail changes can mark, move or trash messages.").font(.footnote).foregroundStyle(DispatchStyle.secondary)
                        }
                        Toggle("Allow sending mail", isOn: $draft.mailSend).disabled(draft.readOnly)
                        if draft.readOnly { Text("Read-only disables all changes, including sending mail.").font(.footnote).foregroundStyle(DispatchStyle.secondary) }
                        if draft.mailSend {
                            Text("Mail sending requires this separate permission.").font(.footnote)
                            Toggle("Allow all recipients", isOn: $draft.allowAllRecipients)
                            if draft.allowAllRecipients { PhoneNotice(title: "All recipients allowed", message: "This bot can send mail to any address.") }
                            else { TextField("Allowed recipient addresses", text: $draft.recipients, axis: .vertical).keyboardType(.emailAddress) }
                        }
                    }
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(setup.installer != nil || setup.saved || connectors.working)
                DispatchSection {
                    DisclosureGroup("Connector installation details") {
                    Text("Install or update the connector on this bot's VM, then test the connection. Saving an account does not install the runtime.").font(.footnote)
                    Link("ThomasCrouzet/icloud-mcp · MIT", destination: ICloudAccountDraft.source)
                    Text("Pinned revision: \(ICloudAccountDraft.revision)").font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                StdioSetupActions(setup: setup, connectors: connectors, store: store, plan: {
                    if separateMail && draft.mailAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw GatewayError.message("Enter the separate iCloud Mail address.")
                    }
                    return try draft.plan(existingNames: connectors.servers.map(\.name))
                }, clearSecrets: { draft.password = "" })
            }
            .scrollDismissesKeyboard(.interactively)
            .dispatchTitle("Add iCloud account").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(setup.saved ? "Done" : "Close") { dismiss() }.disabled(connectors.working) } }
        }.interactiveDismissDisabled(connectors.working).onDisappear { draft.password = "" }
    }
}
