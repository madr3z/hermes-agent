import AuthenticationServices
import Observation
import SwiftUI
import HermesGateway

struct MCPOAuthView: View {
    let server: MCPConnection
    let connectors: ConnectorsStore
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var signIn = MCPOAuthController()
    var body: some View {
        NavigationStack {
            Form {
                Section(server.label) {
                    Text("Authorize this named server on \(connectors.bot.name). Tokens stay on the bot's gateway.")
                    Text("Choose the intended provider account. This signs in only the selected account ID.").font(.footnote).foregroundStyle(.secondary)
                    if signIn.working { ProgressView(signIn.message) }
                    if let error = signIn.error { Text(error).foregroundStyle(.red) }
                    if signIn.approved { Label("Authorization saved on gateway", systemImage: "checkmark.circle") }
                    Button(signIn.approved ? "Check sign-in" : "Sign in") {
                        guard let api = connectors.api else { return }
                        signIn.start(name: server.name, api: api) {
                            connectors.notice = "Authorization saved for \(server.label). Its tools apply in a new session."
                            await connectors.load(store: store)
                        }
                    }.disabled(signIn.working || connectors.api == nil)
                }
                Section { Text("Some providers require their registered Mac callback. If iPhone sign-in is unavailable, finish sign-in on your Mac.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("MCP sign-in").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(signIn.approved ? "Done" : "Cancel") { dismiss() } } }
        }.onDisappear { signIn.cancel() }
    }
}

@MainActor @Observable private final class MCPOAuthController: NSObject, ASWebAuthenticationPresentationContextProviding {
    var working = false
    var approved = false
    var message = "Starting sign-in…"
    var error: String?
    private var session: MCPOAuthSession?
    private var api: BotConnectorsClient?
    private var browser: ASWebAuthenticationSession?
    private var task: Task<Void, Never>?
    private var cancelled = false
    private var attempt = UUID()

    func start(name: String, api: BotConnectorsClient, onApproved: @escaping () async -> Void) {
        guard !working else { return }
        working = true; approved = false; cancelled = false; error = nil
        let attempt = UUID(); self.attempt = attempt
        message = "Starting sign-in…"; self.api = api
        task = Task { [self] in
            do {
                let session = try await api.startOAuth(name: name)
                if self.attempt != attempt || cancelled || Task.isCancelled { try await api.cancelOAuth(session); return }
                self.session = session
                guard let url = session.authorizationURL else { await finish(session, api: api, onApproved: onApproved); return }
                message = "Complete sign-in in the secure browser…"
                let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: "com.hermes.iphone") { [weak self] callback, failure in
                    Task { @MainActor [weak self] in
                        guard let self, self.attempt == attempt, !self.cancelled else { return }
                        if let callback {
                            self.task = Task {
                                do {
                                    try await api.deliverOAuth(session, callback: callback)
                                    await self.finish(session, api: api, onApproved: onApproved)
                                } catch {
                                    if self.attempt == attempt, !self.cancelled { self.fail("The gateway could not complete sign-in. Try again or finish sign-in on your Mac.") }
                                }
                            }
                        } else {
                            self.fail(failure is ASWebAuthenticationSessionError ? "Sign-in was cancelled or could not open." : "The provider did not return a sign-in callback.")
                        }
                    }
                }
                browser.presentationContextProvider = self
                browser.prefersEphemeralWebBrowserSession = true
                self.browser = browser
                if !browser.start() { fail("The secure sign-in browser could not open. Try again or finish sign-in on your Mac.") }
            } catch {
                if self.attempt == attempt, !cancelled { fail(error.localizedDescription) }
            }
        }
    }
    private func finish(_ session: MCPOAuthSession, api: BotConnectorsClient, onApproved: @escaping () async -> Void) async {
        message = "Checking authorization on gateway…"
        do {
            for _ in 0..<120 {
                try Task.checkCancellation()
                guard !cancelled, self.session?.id == session.id else { return }
                if try await api.pollOAuth(session) == "approved" {
                    guard !cancelled, self.session?.id == session.id else { return }
                    approved = true; working = false; self.session = nil; browser = nil
                    await onApproved()
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
            fail("Sign-in is still pending. Try again or finish sign-in on your Mac.")
        } catch {
            if !cancelled, self.session?.id == session.id { fail("The gateway could not verify authorization. Try again or finish sign-in on your Mac.") }
        }
    }
    private func fail(_ message: String) {
        error = message
        cancel()
    }
    func cancel() {
        cancelled = true; working = false
        task?.cancel(); task = nil
        browser?.cancel(); browser = nil
        if let session, let api {
            self.session = nil
            let attempt = self.attempt
            Task {
                do { try await api.cancelOAuth(session) }
                catch {
                    if self.attempt == attempt { self.error = "The gateway could not confirm cancellation. The sign-in session will expire." }
                }
            }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
