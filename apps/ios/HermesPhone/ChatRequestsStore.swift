import Foundation
import Observation
import HermesGateway

@MainActor @Observable final class ChatRequestsStore {
    private(set) var items: [ChatHumanRequest] = []
    private(set) var working: Set<String> = []
    private(set) var uncertain: Set<String> = []
    private(set) var bindingID = UUID()
    private(set) var connected = false
    private(set) var snapshotRevision = 0
    var error: String?
    private var api: ChatRequestsClient?
    private var runtimeID: String?
    private var profile = ""
    private var revision = 0
    private var received: Set<String> = []
    func bind(profile: String, runtimeID: String?, supported: Bool, request: ChatRequestsClient.Request?) {
        revision += 1; snapshotRevision += 1; bindingID = UUID(); items = []; working = []; uncertain = []; received = []; error = nil
        self.runtimeID = runtimeID; self.profile = profile
        connected = supported && runtimeID != nil && request != nil
        if connected, let runtimeID, let request { api = ChatRequestsClient(profile: profile, sessionID: runtimeID, request: request) }
        else { api = nil }
    }
    func disconnect() { bind(profile: "", runtimeID: nil, supported: false, request: nil) }
    func receive(_ frame: JSON) {
        guard connected, let runtimeID, let item = ChatHumanRequest(frame, runtimeID: runtimeID) else { return }
        snapshotRevision += 1
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { items.append(item) }
    }
    func restore(_ snapshot: JSON, ifUnchanged expectedRevision: Int? = nil) {
        guard expectedRevision == nil || expectedRevision == snapshotRevision else { return }
        guard snapshot["session_id"].string == runtimeID, connected else { return }
        guard case .array(let frames) = snapshot["open_requests"] else { return }
        let ids = Set(frames.compactMap { $0["id"].string })
        snapshotRevision += 1
        items.removeAll { !ids.contains($0.id) }
        frames.forEach(receive)
    }
    func event(_ event: JSON) {
        guard (event["profile"].string == nil || event["profile"].string == profile), event["session_id"].string == runtimeID, event["type"].string == "request.cancel", let id = event["payload"]["id"].string else { return }
        snapshotRevision += 1
        items.removeAll { $0.id == id }; uncertain.remove(id); working.remove(id)
    }
    func shown(_ item: ChatHumanRequest) async {
        guard let api, connected, items.contains(where: { $0.id == item.id }), !received.contains(item.id) else { return }
        received.insert(item.id)
        // Receipt starts the existing approval timeout; it is never consent.
        do { try await api.received(item) }
        catch { /* Keep the card; an acknowledgement failure must never choose an action. */ }
    }
    func answer(_ item: ChatHumanRequest, choice: String? = nil, cancel: Bool = false) async {
        await mutate(item) { api in
            let active = try await api.answer(item, choice: choice, cancel: cancel)
            return (true, active ? nil : "This request was already handled or withdrawn.")
        }
    }
    func lock(_ item: ChatHumanRequest, questionID: String, answer: String?) async {
        let owner = revision
        await mutate(item) { api in
            let result = try await api.lock(item, questionID: questionID, answer: answer)
            if self.revision == owner, result.active, !result.remaining.isEmpty,
               let index = self.items.firstIndex(where: { $0.id == item.id }),
               case .clarify(let questions, var answers) = self.items[index].kind {
                answers[questionID] = answer.map(JSON.string) ?? .null
                self.snapshotRevision += 1
                self.items[index].kind = .clarify(questions: questions, answers: answers)
            }
            return (!result.active || result.remaining.isEmpty, result.active ? nil : "This request was already handled or withdrawn.")
        }
    }
    private func mutate(_ item: ChatHumanRequest, action: (ChatRequestsClient) async throws -> (remove: Bool, notice: String?)) async {
        guard let api, connected, items.contains(where: { $0.id == item.id }), !working.contains(item.id), !uncertain.contains(item.id) else { return }
        let owner = revision
        working.insert(item.id); error = nil
        defer { if owner == revision { working.remove(item.id) } }
        do {
            let result = try await action(api)
            guard owner == revision, connected else { return }
            if result.remove { snapshotRevision += 1; items.removeAll { $0.id == item.id } }
            error = result.notice
        } catch {
            guard owner == revision else { return }
            uncertain.insert(item.id)
            self.error = error.localizedDescription + " No answer was retried. Reconnect to restore the request before taking another action."
        }
    }
}
