import SwiftUI
import HermesGateway

struct GoogleAccountConnectorView: View {
    let connectors: ConnectorsStore
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var email = ""
    @State private var origin = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var plan: StdioAccountPlan?
    @State private var setup = StdioSecretSetup()
    @State private var preparing = false
    @State private var prepared = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            DispatchForm {
                DispatchSection { BotIdentityLabel(name: connectors.bot.name, detail: "Optional self-hosted Gmail setup") }
                DispatchSection("Account") {
                    TextField("Account label", text: $label)
                    TextField("Expected Google email", text: $email).keyboardType(.emailAddress)
                    Text("Google's returned email must match this address. Each account has its own credentials and sign-in.").font(.footnote).foregroundStyle(DispatchStyle.secondary)
                }
                DispatchSection("Advanced: existing Google Web client") {
                    TextField("Approved private HTTPS controller origin", text: $origin).keyboardType(.URL)
                    TextField("Client ID", text: $clientID)
                    SecureField("Client secret", text: $clientSecret).privacySensitive()
                    Text("This optional connector requires an existing Google Web client. It is not a one-click Google sign-in. Register the exact /api/connector-callbacks/google redirect first. The pinned Workspace MCP connector must be installed on this bot. A tailnet HTTPS name alone does not prove Google domain approval.").font(.footnote).foregroundStyle(DispatchStyle.secondary)
                }
                .disabled(prepared || preparing || connectors.working)
                if let error { PhoneNotice(title: "Google setup needs attention", message: error) }
                if prepared {
                    DispatchSection {
                        Text("Prepared for \(email). Read-only Gmail access. Credentials save on \(connectors.bot.name); this phone keeps them only during setup. After saving, open Bot Chat and choose Sign in to an account.").font(.footnote)
                        StdioSetupActions(setup: setup, connectors: connectors, store: store, plan: {
                            guard let plan else { throw GatewayError.message("Prepare this account first.") }
                            return plan
                        }, clearSecrets: { self.plan = nil; clientID = ""; clientSecret = "" })
                    }
                } else {
                    Button("Prepare account") { Task { await prepare() } }.disabled(preparing || connectors.api == nil || connectors.working)
                    if preparing { ProgressView("Preparing account on gateway…") }
                }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .scrollDismissesKeyboard(.interactively)
            .dispatchTitle("Advanced Google setup").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(setup.saved ? "Done" : "Close") { dismiss() }.disabled(preparing || connectors.working) } }
        }
        .interactiveDismissDisabled(preparing || connectors.working)
        .onDisappear { clientID = ""; clientSecret = ""; plan = nil }
    }
    private func prepare() async {
        guard let api = connectors.api else { return }
        preparing = true; error = nil
        defer { preparing = false }
        do {
            let result = try await api.call("mcp.accounts.gmail.plan", ["label": .string(label), "email": .string(email), "controller_origin": .string(origin)])
            guard let name = result["name"].string, case .object(let config) = result["config"],
                  let idSlot = result["secret_slots"]["CLIENT_ID"].string,
                  let secretSlot = result["secret_slots"]["CLIENT_SECRET"].string else {
                throw GatewayError.message("The gateway did not prepare this account.")
            }
            plan = try StdioAccountPlan(parameters: ["name": .string(name), "config": .object(config)], secrets: [idSlot: clientID, secretSlot: clientSecret])
            prepared = true
            clientID = ""; clientSecret = ""
        } catch { self.error = "Could not prepare this account. Check the registered client, callback and gateway version. No credentials were saved." }
    }
}
