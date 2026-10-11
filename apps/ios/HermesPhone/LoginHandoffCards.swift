import AuthenticationServices
import HermesGateway
import Observation
import SwiftUI

/// Insert in the Bot Chat transcript. Closing the view stops observation, not server authorization.
struct LoginHandoffCards: View {
    let chat: ChatStore
    @State private var login = ChatLoginController()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !login.accounts.isEmpty {
                Menu("Sign in to an account", systemImage: "person.badge.key") {
                    ForEach(login.accounts) { account in
                        Button(account.label + (account.requestedIdentity.isEmpty ? "" : " · " + account.requestedIdentity)) {
                            Task { await login.select(account, chat: chat) }
                        }
                    }
                }.disabled(login.working || !chat.connected)
            }
            ForEach(login.requests) { request in
                VStack(alignment: .leading, spacing: 10) {
                    Label("Sign in · \(request.name)", systemImage: "person.badge.key.fill").font(.headline)
                    Text("For \(chat.bot.name) · \(chat.bot.profile)").font(.subheadline).foregroundStyle(.secondary)
                    Text(request.detail).font(.callout)
                    Text(request.scopes.isEmpty ? "Review the requested permissions on the provider's consent screen." : "Permissions: " + request.scopes.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                    if let identity = request.verifiedIdentity { Text("Verified Google account: " + identity).font(.footnote) }
                    if !request.accountReference.isEmpty { Text("Account slot: \(request.accountReference)").font(.caption).textSelection(.enabled) }
                    if !request.userCode.isEmpty {
                        Text(request.userCode).font(.title2.monospaced()).textSelection(.enabled).accessibilityLabel("Device code \(request.userCode)")
                        Text("Enter this code only for the sign-in you requested for this bot.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if request.status == "authorized" {
                        Label(request.continued ? "Task continuation submitted" : "Authorization saved on this bot", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        if !request.continued { Button("Confirm account and continue task") { Task { await login.act("continue", request: request, chat: chat) } }.buttonStyle(.borderedProminent).controlSize(.large) }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack { signInButtons(request) }
                            VStack(alignment: .leading) { signInButtons(request) }
                        }
                    }
                    Text("API authorization stays on this bot. For other website logins, use this bot's VM controls.").font(.caption).foregroundStyle(.secondary)
                }.padding().frame(maxWidth: .infinity, alignment: .leading).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            if login.working { ProgressView("Preparing secure sign-in…") }
            if let error = login.error { PhoneNotice(title: "Sign-in needs attention", message: error) }
        }
        .task(id: chat.runtimeID) {
            await login.loadAccounts(chat: chat)
            while !Task.isCancelled {
                await login.refresh(chat: chat)
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onDisappear { login.closeBrowser() }
    }
    @ViewBuilder private func signInButtons(_ request: LoginHandoff) -> some View {
        Button(request.canRetry ? "Retry sign-in" : "Sign in") { Task { await login.signIn(request, chat: chat) } }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(login.working)
        Button("Cancel", role: .cancel) { Task { await login.act("cancel", request: request, chat: chat) } }
            .buttonStyle(.bordered).controlSize(.large)
    }

}

@MainActor @Observable private final class ChatLoginController: NSObject, ASWebAuthenticationPresentationContextProviding {
    var requests: [LoginHandoff] = []
    var accounts: [MCPConnection] = []
    var error: String?
    var working = false
    private var operation = UUID()
    private var browser: ASWebAuthenticationSession?
    private var activeID: String?
    private func call(_ action: String, chat: ChatStore, extra: [String: JSON] = [:]) async throws -> JSON {
        guard let client = chat.client, let runtimeID = chat.runtimeID else { throw GatewayError.message("Reconnect to the bot first.") }
        return try await client.request("login.handoff." + action, ["session_id": .string(runtimeID), "profile": .string(chat.bot.profile)].merging(extra) { _, new in new })
    }
    func loadAccounts(chat: ChatStore) async {
        guard let client = chat.client else { accounts = []; return }
        let runtime = chat.runtimeID
        do {
            let api = BotConnectorsClient(profile: chat.bot.profile) { try await client.request($0, $1) }
            let rows = try await api.mcpServers()
            guard chat.runtimeID == runtime else { return }
            accounts = rows.filter { $0.auth == "oauth" || $0.provider == "google-gmail" }
        } catch { accounts = [] }
    }
    func select(_ account: MCPConnection, chat: ChatStore) async {
        do {
            _ = try await call("list", chat: chat, extra: ["account_name": .string(account.name)])
            await refresh(chat: chat)
        } catch { self.error = "This account cannot start native sign-in. Check its connector and registered callback." }
    }
    func refresh(chat: ChatStore) async {
        guard chat.connected else { return }
        let runtime = chat.runtimeID
        do {
            let result = try await call("list", chat: chat)
            guard chat.runtimeID == runtime else { return }
            requests = result["requests"].array.map(LoginHandoff.init)
        } catch GatewayError.rpc(let code, _) where code == -32601 { requests = [] }
        catch { self.error = "Sign-in status is unavailable. Reconnect to this bot to check it." }
    }
    func act(_ action: String, request: LoginHandoff, chat: ChatStore) async {
        do {
            if action == "cancel" { operation = UUID(); working = false; closeBrowser() }
            _ = try await call(action, chat: chat, extra: ["request_id": .string(request.id)])
            error = nil
            await refresh(chat: chat)
        } catch { self.error = "The bot could not confirm this sign-in action. Refresh and try again." }
    }
    func signIn(_ request: LoginHandoff, chat: ChatStore) async {
        guard !working else { return }
        working = true; error = nil
        let operation = UUID(); self.operation = operation
        defer { if self.operation == operation { working = false } }
        let runtime = chat.runtimeID
        do {
            var extra: [String: JSON] = ["request_id": .string(request.id)]
            if ["mcp", "google-gmail"].contains(request.provider) { extra["client_redirect_uri"] = .string(MCPOAuthSession.callbackURI) }
            _ = try await call("start", chat: chat, extra: extra)
            for _ in 0..<30 {
                try Task.checkCancellation()
                guard chat.runtimeID == runtime, self.operation == operation else { return }
                await refresh(chat: chat)
                guard let current = requests.first(where: { $0.id == request.id }) else { return }
                if current.status == "authorized" || current.canRetry { return }
                if let url = current.authorizationURL {
                    openAuthentication(url, request: current, chat: chat, runtime: runtime)
                    return
                }
                if !current.userCode.isEmpty, let url = current.verificationURL {
                    if await UIApplication.shared.open(url) == false { error = "OpenAI sign-in could not open. Try again." }
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
            error = "The provider has not supplied sign-in yet. Retry after checking the bot connection."
        } catch { if self.operation == operation { self.error = "Sign-in could not start. Refresh and try again." } }
    }
    private func openAuthentication(_ url: URL, request: LoginHandoff, chat: ChatStore, runtime: String?) {
        closeBrowser(); activeID = request.id
        let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: "com.hermes.iphone") { [weak self] callback, _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeID == request.id, chat.runtimeID == runtime else { return }
                if let callback {
                    do {
                        let flow = try MCPOAuthSession(name: request.name, result: .object(["ok": .bool(true), "session_id": .string(request.id), "auth_url": .string(url.absoluteString)]))
                        var params = try flow.callbackParameters(callback)
                        params.removeValue(forKey: "name"); params.removeValue(forKey: "session_id")
                        params["request_id"] = .string(request.id)
                        _ = try await self.call("callback", chat: chat, extra: params)
                        await self.refresh(chat: chat)
                    } catch { self.error = "The bot rejected the provider callback. Retry sign-in." }
                } else { self.error = "Sign-in browser closed. The task remains paused. Reopen sign-in or cancel." }
                self.browser = nil
            }
        }
        browser.presentationContextProvider = self
        // Use the system's normal authentication context and local password/passkey support.
        browser.prefersEphemeralWebBrowserSession = false
        self.browser = browser
        if !browser.start() { error = "Secure sign-in could not open. This provider may require its registered Mac callback." }
    }
    func closeBrowser() { activeID = nil; browser?.cancel(); browser = nil }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
