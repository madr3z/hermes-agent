import Foundation
import Observation
import HermesGateway

struct PhoneCommandOutput: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}
enum PhoneCommandRoute: String, Identifiable { case help, agents, model, browser, profile; var id: String { rawValue } }

@MainActor @Observable final class ChatCommandsStore {
    private(set) var catalog: ChatCommandCatalog?
    private(set) var completions: [ChatCommandCompletion] = []
    private(set) var connected = false
    private(set) var loading = false
    private(set) var bindingID = UUID()
    var error: String?
    var output: PhoneCommandOutput?
    var route: PhoneCommandRoute?
    private var api: ChatCommandsClient?
    private var revision = 0
    private var query = ""
    func bind(profile: String, runtimeID: String?, request: ((String, [String: JSON]) async throws -> JSON)?) {
        revision += 1; bindingID = UUID(); completions = []; catalog = nil; error = nil; loading = false; route = nil; output = nil
        connected = runtimeID != nil && request != nil
        if let runtimeID, let request { api = ChatCommandsClient(profile: profile, sessionID: runtimeID, request: request) }
        else { api = nil }
    }
    func disconnect() { bind(profile: "", runtimeID: nil, request: nil) }
    func load() async {
        guard let api, !loading else { return }
        let owner = revision
        loading = true
        defer { if revision == owner { loading = false } }
        do {
            let result = try await api.catalog()
            guard revision == owner, !Task.isCancelled else { return }
            catalog = result; error = nil
        } catch { if revision == owner, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func complete(_ text: String) async {
        query = text; completions = []
        guard let api, text.hasPrefix("/") else { return }
        let owner = revision
        do {
            try await Task.sleep(for: .milliseconds(180))
            let rows = try await api.complete(text)
            guard owner == revision, query == text, !Task.isCancelled else { return }
            completions = Array(rows.prefix(5))
        } catch { /* Completion is advisory; Commands provides explicit errors and refresh. */ }
    }
    func apply(_ completion: ChatCommandCompletion, to text: String) -> String? {
        query == text ? completion.applying(to: text) : nil
    }
    func execute(_ text: String) async throws -> ChatCommandOutcome {
        guard let api, connected else { throw GatewayError.message("Reconnect Bot Chat before using commands.") }
        let owner = revision
        let result = try await api.execute(text)
        guard owner == revision, connected else { throw GatewayError.message("Bot Chat changed while the command was running. Check the original chat before trying again.") }
        return result
    }
}
