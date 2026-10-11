import Foundation
import Observation
import HermesGateway

@MainActor @Observable final class ConnectorsStore {
    let bot: Bot
    var servers: [MCPConnection] = []
    var plugins: [InstalledPlugin] = []
    var catalog: [CatalogPlugin] = []
    var accounts: [HostedConnection] = []
    var sectionErrors: [String: String] = [:]
    var loading = false
    var working = false
    var notice: String?
    var error: String?
    private(set) var api: BotConnectorsClient?
    private(set) var gateway: GatewayClient?
    init(bot: Bot) { self.bot = bot }
    func load(store: PhoneStore) async {
        guard !loading, !working else { return }
        loading = true
        defer { loading = false }
        do {
            let gateway = try await store.client(for: bot.endpointID)
            self.gateway = gateway
            let api = BotConnectorsClient(profile: bot.profile) { try await gateway.request($0, $1) }
            self.api = api
            async let mcp: Void = read("MCP servers") { self.servers = try await api.mcpServers() }
            async let plugins: Void = read("Plugins") { self.plugins = try await api.plugins() }
            async let catalog: Void = read("Plugin catalog") { self.catalog = try await api.catalog() }
            async let accounts: Void = read("Hosted accounts") { self.accounts = try await api.hostedAccounts() }
            _ = await (mcp, plugins, catalog, accounts)
        } catch {
            self.error = error.localizedDescription
        }
    }
    private func read(_ section: String, body: @MainActor () async throws -> Void) async {
        do {
            try await body()
            if !Task.isCancelled { sectionErrors.removeValue(forKey: section) }
        } catch {
            if !Task.isCancelled { sectionErrors[section] = capabilityMessage(error) }
        }
    }
    func mutate(store: PhoneStore, secret: String = "", body: (BotConnectorsClient) async throws -> JSON) async -> Bool {
        guard let api, !working, !loading else { return false }
        working = true; error = nil; notice = nil
        do {
            let result = try await body(api)
            if result["ok"] == .bool(false) {
                throw GatewayError.message(result["error"].string ?? "The gateway did not complete this action.")
            }
            let deferred = result["activation"]["deferred"]
            notice = deferred == .null ? "Saved on \(bot.name). Refresh shows the server's current state." : "Saved on \(bot.name). Some changes apply in a new chat session."
            let missing = result["missing_env"].array.compactMap(\.string)
            if !missing.isEmpty { notice = "Installed. Add the required credentials: " + missing.joined(separator: ", ") }
            let warnings = result["warnings"].array.compactMap(\.string)
            if !warnings.isEmpty { notice = (notice ?? "Saved.") + "\n" + warnings.joined(separator: "\n") }
            working = false
            await load(store: store)
            return true
        } catch {
            let message = error.localizedDescription
            self.error = (secret.isEmpty ? message : message.replacingOccurrences(of: secret, with: "[redacted]")) + " Refresh before trying the action again."
            working = false
            return false
        }
    }
    private func capabilityMessage(_ error: Error) -> String {
        if case GatewayError.rpc(let code, _) = error {
            if code == -32601 { return "This gateway does not support this page yet. Update its Hermes runtime on your Mac." }
            if code == 4032 { return "Sign in to Nous for this bot on your Mac to use hosted connectors." }
            if code == 4031 { return "Hosted connectors are not available for this bot's account." }
        }
        return error.localizedDescription
    }
}
