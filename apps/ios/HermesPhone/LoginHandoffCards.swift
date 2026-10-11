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
            ForEach(login.requests.filter(\.needsAction)) { request in
                LoginHandoffCard(request: request, botName: chat.bot.name, working: login.working,
                    signIn: { Task { await login.signIn(request, chat: chat) } },
                    cancel: { Task { await login.act("cancel", request: request, chat: chat) } },
                    continueTask: { Task { await login.act("continue", request: request, chat: chat) } })
            }
            if login.working { ProgressView("Preparing secure sign-in…") }
            if let error = login.error, login.working || login.requests.contains(where: \.needsAction) { PhoneNotice(title: "Sign-in needs attention", message: error) }
        }
        .task(id: chat.runtimeID) {
            while !Task.isCancelled {
                await login.refresh(chat: chat)
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onChange(of: chat.runtimeID) { _, _ in login.contextChanged() }
        .onDisappear { login.contextChanged() }
    }
}

struct LoginHandoffCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let request: LoginHandoff
    let botName: String
    let working: Bool
    let signIn: () -> Void
    let cancel: () -> Void
    let continueTask: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: request.status == "authorized" ? "checkmark.shield" : "person.badge.key")
                        .font(.title2).foregroundStyle(.tint).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.status == "authorized" ? "Account connected" : "Sign in to continue").font(.headline)
                    Text(request.name + " · " + botName).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text(request.detail).font(.body).fixedSize(horizontal: false, vertical: true)
            if let identity = request.verifiedIdentity {
                Label(identity, systemImage: "checkmark.seal").font(.subheadline)
            }
            if !request.userCode.isEmpty {
                Text(request.userCode).font(.title2.monospaced().weight(.semibold))
                    .textSelection(.enabled).accessibilityLabel("Device code \(request.userCode)")
                Text("Enter this code only for the sign-in you requested.").font(.footnote).foregroundStyle(.secondary)
            }
            DisclosureGroup("Permissions and account") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.scopes.isEmpty ? "Review the permissions on the provider’s consent screen." : request.scopes.joined(separator: ", "))
                    if !request.accountReference.isEmpty { Text("Account: \(request.accountReference)").textSelection(.enabled) }
                    Text("Authorization stays on this bot. Use Computer for other website logins.")
                }.font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
            }.font(.subheadline).frame(minHeight: 44)
            if request.status == "authorized" {
                if request.continued {
                    Label(request.continuationStatus == "unconfirmed" ? "Check this chat before sending another message." : "Task continuation submitted", systemImage: request.continuationStatus == "unconfirmed" ? "exclamationmark.circle" : "checkmark.circle").font(.subheadline)
                } else {
                    Button("Confirm account and continue", action: continueTask)
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(working)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { actions }
                    VStack(alignment: .leading, spacing: 12) { actions }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Color.accentColor.opacity(0.15)) }
    }
    @ViewBuilder private var actions: some View {
        Button(request.canRetry ? "Retry sign-in" : "Sign in", action: signIn)
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(working)
        Button("Cancel", role: .cancel, action: cancel).buttonStyle(.bordered).controlSize(.large)
    }
}
