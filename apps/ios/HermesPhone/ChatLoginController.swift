import AuthenticationServices
import HermesGateway
import Observation
import SwiftUI

@MainActor protocol LoginBrowser: AnyObject {
    func start() -> Bool
    func cancel()
}
extension ASWebAuthenticationSession: LoginBrowser {}

@MainActor @Observable final class ChatLoginController: NSObject, ASWebAuthenticationPresentationContextProviding {
    var requests: [LoginHandoff] = []
    var error: String?
    var working = false
    private var operation = UUID()
    private var browser: (any LoginBrowser)?
    var makeBrowser: (URL, ASWebAuthenticationPresentationContextProviding, @escaping (URL?, Error?) -> Void) -> any LoginBrowser = { url, context, callback in
        let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: "com.hermes.iphone", completionHandler: callback)
        browser.presentationContextProvider = context
        browser.prefersEphemeralWebBrowserSession = false
        return browser
    }
    private var activeID: String?
    private var browserOperation: UUID?
    private func call(_ action: String, chat: ChatStore, extra: [String: JSON] = [:]) async throws -> JSON {
        guard let client = chat.client, let runtimeID = chat.runtimeID else { throw GatewayError.message("Reconnect to the bot first.") }
        return try await client.request("login.handoff." + action, ["session_id": .string(runtimeID), "profile": .string(chat.bot.profile)].merging(extra) { _, new in new })
    }
    func refresh(chat: ChatStore) async {
        guard chat.connected else { return }
        let runtime = chat.runtimeID
        do {
            let result = try await call("list", chat: chat)
            guard chat.runtimeID == runtime else { return }
            requests = result["requests"].array.map(LoginHandoff.init)
            if let activeID, let current = requests.first(where: { $0.id == activeID }), current.status != "awaiting_human" {
                closeBrowser(cancelAttempt: false)
            }
        } catch GatewayError.rpc(let code, _) where code == -32601 { requests = [] }
        catch { self.error = "Sign-in status is unavailable. Reconnect to this bot to check it." }
    }
    func act(_ action: String, request: LoginHandoff, chat: ChatStore) async {
        if action != "cancel" && working { return }
        let runtime = chat.runtimeID
        working = true
        defer { if chat.runtimeID == runtime { working = false } }
        do {
            if action == "cancel" { operation = UUID(); closeBrowser(cancelAttempt: false); working = true }
            var extra: [String: JSON] = ["request_id": .string(request.id)]
            if action == "cancel", let attemptID = request.attemptID { extra["attempt_id"] = .string(attemptID) }
            _ = try await call(action, chat: chat, extra: extra)
            guard chat.runtimeID == runtime else { return }
            error = nil
            await refresh(chat: chat)
        } catch { if chat.runtimeID == runtime { self.error = "The bot could not confirm this sign-in action. Refresh and try again." } }
    }
    func signIn(_ request: LoginHandoff, chat: ChatStore) async {
        guard !working else { return }
        working = true; error = nil
        let operation = UUID(); self.operation = operation
        defer { if self.operation == operation && browser == nil { working = false } }
        let runtime = chat.runtimeID
        guard let client = chat.client, let runtime else { working = false; return }
        let profile = chat.bot.profile
        var attemptID: String?
        let cancel = {
            guard let attemptID else { return }
            var params: [String: JSON] = ["session_id": .string(runtime), "profile": .string(profile), "request_id": .string(request.id)]
            params["attempt_id"] = .string(attemptID)
            _ = try? await client.request("login.handoff.cancel", params)
        }
        do {
            var extra: [String: JSON] = ["request_id": .string(request.id)]
            if ["mcp", "google-gmail"].contains(request.provider) { extra["client_redirect_uri"] = .string(MCPOAuthSession.callbackURI) }
            let started = try await call("start", chat: chat, extra: extra)
            attemptID = started["request"]["attempt_id"].string
            guard chat.runtimeID == runtime, self.operation == operation else { await cancel(); return }
            for _ in 0..<30 {
                try Task.checkCancellation()
                guard chat.runtimeID == runtime, self.operation == operation else { await cancel(); return }
                await refresh(chat: chat)
                guard chat.runtimeID == runtime, self.operation == operation else { await cancel(); return }
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
        } catch {
            await cancel()
            if self.operation == operation { self.error = "Sign-in could not start. Refresh and try again." }
        }
    }
    private func openAuthentication(_ url: URL, request: LoginHandoff, chat: ChatStore, runtime: String?) {
        guard let client = chat.client, let runtime else { working = false; return }
        let profile = chat.bot.profile
        let send: (String, [String: JSON]) async throws -> JSON = { action, extra in
            var owner: [String: JSON] = ["session_id": .string(runtime), "profile": .string(profile), "request_id": .string(request.id)]
            if action == "cancel", let attemptID = request.attemptID { owner["attempt_id"] = .string(attemptID) }
            return try await client.request("login.handoff." + action,
                owner
                    .merging(extra) { _, new in new })
        }
        presentAuthentication(url, request: request, isCurrent: { chat.runtimeID == runtime }, send: send,
                              refresh: { await self.refresh(chat: chat) })
    }
    func presentAuthentication(_ url: URL, request: LoginHandoff, isCurrent: @escaping () -> Bool,
        send: @escaping (String, [String: JSON]) async throws -> JSON, refresh: @escaping () async -> Void) {
        guard browser == nil else { return }
        activeID = request.id
        let browserOperation = UUID(); self.browserOperation = browserOperation; working = true
        cancelBrowserAttempt = { _ = try? await send("cancel", [:]) }
        let browser = makeBrowser(url, self) { [weak self] callback, _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeID == request.id, self.browserOperation == browserOperation else { return }
                guard isCurrent() else { self.closeBrowser(); return }
                defer {
                    if self.browserOperation == browserOperation {
                        self.activeID = nil; self.browser = nil; self.cancelBrowserAttempt = nil
                        self.browserOperation = nil; self.working = false
                    }
                }
                if let callback {
                    do {
                        let flow = try MCPOAuthSession(name: request.name, result: .object(["ok": .bool(true), "session_id": .string(request.id), "auth_url": .string(url.absoluteString)]))
                        var params = try flow.callbackParameters(callback)
                        params.removeValue(forKey: "name"); params.removeValue(forKey: "session_id")
                        params["request_id"] = .string(request.id)
                        _ = try await send("callback", params)
                        if isCurrent() { await refresh() }
                    } catch { self.error = "The bot rejected the provider callback. Retry sign-in." }
                } else {
                    do {
                        _ = try await send("cancel", [:])
                        if isCurrent() { await refresh() }
                        self.error = "Sign-in canceled. You can retry when ready."
                    } catch { self.error = "The browser closed. Reconnect to check whether sign-in was canceled." }
                }
            }
        }
        self.browser = browser
        if !browser.start() {
            error = "Secure sign-in could not open. This provider may require its registered Mac callback."
            closeBrowser()
        }
    }
    private var cancelBrowserAttempt: (() async -> Void)?
    func closeBrowser(cancelAttempt: Bool = true) {
        activeID = nil; browserOperation = nil; browser?.cancel(); browser = nil; working = false
        if cancelAttempt, let cancel = cancelBrowserAttempt { Task { await cancel() } }
        cancelBrowserAttempt = nil
    }
    func contextChanged() {
        operation = UUID(); closeBrowser(); requests = []; error = nil
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
