import Foundation
import Observation
import HermesGateway

@MainActor @Observable final class SavedChatsStore {
    private(set) var rows: [SavedChat] = []
    private(set) var messages: [ChatMessage] = []
    private(set) var selected: SavedChat?
    private(set) var hasMore = false
    private(set) var hasEarlier = false
    private(set) var loading = false
    private(set) var transcriptLoading = false
    private(set) var bindingID = UUID()
    var query = ""
    var error: String?
    private var api: SavedChatsClient?
    private var revision = 0
    private var listRevision = 0
    private var messageRevision = 0
    private var offset = 0
    private var messageOffset = 0
    private var resolvedID: String?
    func bind(profile: String, read: SavedChatsClient.Read?) {
        revision += 1; listRevision += 1; messageRevision += 1; bindingID = UUID()
        api = read.map { SavedChatsClient(profile: profile, read: $0) }
        rows = []; messages = []; selected = nil; query = ""; error = nil
        hasMore = false; hasEarlier = false; loading = false; transcriptLoading = false; offset = 0; messageOffset = 0; resolvedID = nil
    }
    func disconnect() { bind(profile: "", read: nil) }
    func load(more: Bool = false) async {
        guard let api else { return }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !more || (!loading && search.isEmpty && hasMore) else { return }
        listRevision += 1
        let owner = revision, request = listRevision
        loading = true; error = nil
        if !more { rows = []; offset = 0; hasMore = false }
        defer { if revision == owner && listRevision == request { loading = false } }
        do {
            let result: (rows: [SavedChat], hasMore: Bool)
            if search.isEmpty { result = try await api.list(offset: offset) }
            else { result = (try await api.search(search), false) }
            guard owner == revision, request == listRevision, search == query.trimmingCharacters(in: .whitespacesAndNewlines), !Task.isCancelled else { return }
            rows = more ? rows + result.rows.filter { next in !rows.contains { $0.id == next.id } } : result.rows
            offset += 100; hasMore = result.hasMore
        } catch { if owner == revision && request == listRevision { self.error = error.localizedDescription } }
    }
    func open(_ chat: SavedChat) async {
        messageRevision += 1; transcriptLoading = false
        selected = chat; messages = []; messageOffset = 0; resolvedID = nil; hasEarlier = false
        await loadMessages(more: false)
    }
    func loadMessages(more: Bool = true) async {
        guard let api, let selected, !transcriptLoading else { return }
        messageRevision += 1
        let owner = revision, request = messageRevision, id = selected.id
        transcriptLoading = true; error = nil
        defer { if owner == revision && request == messageRevision { transcriptLoading = false } }
        do {
            let page = try await api.messages(id: id, offset: messageOffset)
            guard owner == revision, request == messageRevision, self.selected?.id == id, !Task.isCancelled else { return }
            // Compression can rotate the stored tip between pages. Never splice two histories.
            if let resolvedID, resolvedID != page.sessionID { throw GatewayError.message("This transcript changed on the gateway. Reopen the saved chat before loading earlier messages.") }
            resolvedID = page.sessionID
            messages = more ? page.messages.filter { next in !messages.contains { $0.id == next.id } } + messages : page.messages
            messageOffset += page.returned; hasEarlier = page.returned == 100
        } catch { if owner == revision && request == messageRevision { self.error = error.localizedDescription } }
    }
    func export(profile: String) -> String? {
        selected.map { SavedChatsClient.markdown(chat: $0, profile: profile, messages: messages, hasEarlier: hasEarlier) }
    }
}
