import SwiftUI
import Observation
import HermesGateway

@MainActor @Observable final class StdioSecretSetup {
    var message: String?
    var error: String?
    var saved = false
    var accountName = ""
    private(set) var installer: StdioAccountInstaller?
    func save(plan: StdioAccountPlan?, connectors: ConnectorsStore, store: PhoneStore) async {
        guard !connectors.working, !connectors.loading, let api = connectors.api, let gateway = connectors.gateway else {
            error = "Reconnect to this bot before saving."; return
        }
        if let plan {
            accountName = plan.name
            installer = StdioAccountInstaller(plan: plan, client: api) { path, method, body in
                try await gateway.http(path, profile: connectors.bot.profile, body: body, method: method)
            }
        }
        guard let installer else { return }
        connectors.working = true; error = nil; message = nil
        do {
            try await installer.save(); saved = true
            message = "Account saved on \(connectors.bot.name). Test the connection after its VM runtime is installed or updated. New tools apply to a new chat session."
        } catch { self.error = error.localizedDescription }
        connectors.working = false
        await connectors.load(store: store)
    }
    func test(connectors: ConnectorsStore) async {
        guard saved, !connectors.working, let api = connectors.api else { return }
        connectors.working = true; error = nil
        defer { connectors.working = false }
        do {
            let result = try await api.call("mcp.servers.test", ["name": .string(accountName)])
            if result["ok"].bool { message = "Connection test passed. New tools apply to a new chat session." }
            else { error = "Connection test failed. Check the VM connector installation, account credentials and permissions. The saved account was kept." }
        } catch { self.error = "Connection test could not complete. Check the VM connector installation and retry. The saved account was kept." }
    }
    func discard() { installer = nil }
}

struct StdioSetupActions: View {
    let setup: StdioSecretSetup
    let connectors: ConnectorsStore
    let store: PhoneStore
    let plan: () throws -> StdioAccountPlan
    let clearSecrets: () -> Void
    @State private var review: StdioAccountPlan?
    @State private var confirming = false
    var body: some View {
        Section {
            if let message = setup.message { Text(message).foregroundStyle(.secondary) }
            if let error = setup.error { Text(error).foregroundStyle(.red) }
            if setup.saved {
                Button("Test connection") { Task { await setup.test(connectors: connectors) } }
            } else if let installer = setup.installer {
                if installer.canRetry {
                    Button("Retry this account setup") { Task { await setup.save(plan: nil, connectors: connectors, store: store) } }
                }
            } else {
                Button("Review and save account") {
                    do { review = try plan(); setup.error = nil; confirming = true }
                    catch { setup.error = error.localizedDescription }
                }
            }
            if connectors.working { ProgressView("Working on this bot…") }
        }
        .disabled(connectors.working || connectors.loading)
        .confirmationDialog("Save this account on \(connectors.bot.name)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Save account") {
                guard let submitted = review else { return }
                review = nil; clearSecrets()
                Task { await setup.save(plan: submitted, connectors: connectors, store: store) }
            }
            Button("Cancel", role: .cancel) { review = nil }
        } message: {
            Text("The selected command runs on this bot's VM. Credentials are saved only on this bot. Existing accounts are kept. Review the permissions above before saving.")
        }
        .onDisappear { review = nil; setup.discard(); clearSecrets() }
    }
}
