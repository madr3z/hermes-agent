import Foundation
import Observation
import HermesGateway

@MainActor @Observable final class ChatStore {
    let bot: Bot
    var messages: [ChatMessage] = []
    var draft = ""
    var runtimeID: String?
    var status = "Connecting…"
    var error: String?
    var loading = false
    var sending = false
    var busy = false
    var connected = false
    var client: GatewayClient?
    var voice = VoiceCall()
    private var streamID: String?
    private var buffered: [JSON] = []
    private var invalidation: Task<Void, Never>?
    private var needsCanonicalRefresh = false
    private var activityRevision = 0
    init(bot: Bot) { self.bot = bot }
    func open(store: PhoneStore) async {
        guard !loading else { return }
        loading = true; error = nil
        defer {
            loading = false
            if needsCanonicalRefresh { scheduleCanonicalRefresh() }
        }
        do {
            let client = try await store.client(for: bot.endpointID)
            self.client = client
            client.onEvent = { [weak self] event in
                guard let self else { return }
                let route = ChatEventRoute.route(event, runtimeID: self.runtimeID, profile: self.bot.profile)
                if self.loading && route == .session { self.buffered.append(event) }
                else { self.receive(event) }
            }
            client.onDisconnect = { [weak self] message in
                self?.connected = false; self?.error = message; self?.voice.stop()
            }
            let snapshot = try await CanonicalChat.open(profile: bot.profile) { try await client.request($0, $1) }
            runtimeID = snapshot["session_id"].string
            messages = ChatMessage.project(snapshot["messages"].array)
            busy = snapshot["running"].bool || snapshot["inflight"]["streaming"].bool
            let inflight = snapshot["inflight"]
            if let text = inflight["user"].string, !text.isEmpty, messages.last?.text != text {
                messages.append(ChatMessage(id: "inflight-user", role: "user", text: text))
            }
            if let text = inflight["assistant"].string, !text.isEmpty {
                streamID = UUID().uuidString
                messages.append(ChatMessage(id: streamID!, role: "assistant", text: text))
            } else { streamID = nil }
            connected = true; status = busy ? "Working on the gateway" : "Connected"
            let hadBuffered = buffered.contains { $0["session_id"].string == runtimeID }
            buffered.removeAll()
            loading = false
            if hadBuffered { await refreshSnapshot() }
            await voice.recoverTranscripts(client: client, profile: bot.profile, runtimeID: runtimeID ?? "")
        } catch { self.error = error.localizedDescription; connected = false }
    }
    func params(_ extra: [String: JSON] = [:]) -> [String: JSON] {
        ["session_id": .string(runtimeID ?? ""), "profile": .string(bot.profile)].merging(extra) { _, new in new }
    }
    func send() async {
        guard let client, connected, runtimeID != nil, !sending, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = draft
        sending = true; error = nil
        let pendingID = UUID().uuidString
        messages.append(ChatMessage(id: pendingID, role: "user", text: text))
        busy = true
        status = "Sending…"
        defer {
            sending = false
            if needsCanonicalRefresh && !busy { scheduleCanonicalRefresh() }
        }
        do {
            let result = try await client.request("prompt.submit", params(["text": .string(text), "queued": .bool(true)]))
            if draft == text { draft = "" }
            status = result["status"].string == "queued" ? "Queued on the gateway" : "Working on the gateway"
        } catch {
            messages.removeAll { $0.id == pendingID }
            self.error = error.localizedDescription
            await refreshSnapshot()
        }
    }
    func interrupt() async {
        guard let client, connected else { return }
        do { _ = try await client.request("session.interrupt", params()) }
        catch { self.error = error.localizedDescription }
    }
    func startVoice() async {
        guard let client, let runtimeID, connected else { return }
        await voice.start(client: client, profile: bot.profile, runtimeID: runtimeID, history: messages)
    }
    private func refreshSnapshot() async {
        guard let client, let runtimeID else { return }
        let revision = activityRevision
        do {
            let snapshot = try await client.request("session.activate", params())
            guard self.runtimeID == runtimeID, activityRevision == revision else { return }
            messages = ChatMessage.project(snapshot["messages"].array)
            busy = snapshot["running"].bool || snapshot["inflight"]["streaming"].bool
            streamID = nil
            if let text = snapshot["inflight"]["assistant"].string, !text.isEmpty {
                streamID = UUID().uuidString
                messages.append(ChatMessage(id: streamID!, role: "assistant", text: text))
            }
            status = busy ? "Working on the gateway" : "Connected"
        } catch { self.error = error.localizedDescription }
    }
    private func scheduleCanonicalRefresh(reclaimed: Bool = false) {
        needsCanonicalRefresh = true
        if reclaimed {
            connected = false; busy = false; status = "Reconnecting Bot Chat…"; voice.stop()
        }
        invalidation?.cancel()
        invalidation = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, let client = self.client, !self.busy, !self.sending, !self.loading else { return }
            self.loading = true
            let revision = self.activityRevision
            defer { self.loading = false }
            do {
                let snapshot = try await CanonicalChat.open(profile: self.bot.profile) { try await client.request($0, $1) }
                guard !Task.isCancelled else { return }
                self.runtimeID = snapshot["session_id"].string
                self.connected = true
                self.needsCanonicalRefresh = false
                if self.activityRevision == revision {
                    self.messages = ChatMessage.project(snapshot["messages"].array)
                    self.busy = snapshot["running"].bool || snapshot["inflight"]["streaming"].bool
                    self.streamID = nil
                    if let text = snapshot["inflight"]["assistant"].string, !text.isEmpty {
                        self.streamID = UUID().uuidString
                        self.messages.append(ChatMessage(id: self.streamID!, role: "assistant", text: text))
                    }
                }
                self.status = self.busy ? "Working on the gateway" : "Connected"
                let hadBuffered = !self.buffered.isEmpty
                self.buffered.removeAll()
                self.loading = false
                if hadBuffered { await self.refreshSnapshot() }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func receive(_ event: JSON) {
        switch ChatEventRoute.route(event, runtimeID: runtimeID, profile: bot.profile) {
        case .ignore: return
        case .reclaimed: scheduleCanonicalRefresh(reclaimed: true); return
        case .refreshCanonical: scheduleCanonicalRefresh(); return
        case .session: break
        }
        activityRevision += 1
        let payload = event["payload"]
        switch event["type"].string {
        case "message.start": busy = true; streamID = nil
        case "message.delta":
            if streamID == nil { streamID = UUID().uuidString; messages.append(ChatMessage(id: streamID!, role: "assistant", text: "")) }
            if let index = messages.firstIndex(where: { $0.id == streamID }) { messages[index].text += payload["text"].string ?? "" }
        case "message.complete":
            let text = payload["text"].string ?? ""
            if let index = messages.firstIndex(where: { $0.id == streamID }) { messages[index].text = text }
            else if !text.isEmpty && !payload["response_reused"].bool { messages.append(ChatMessage(id: UUID().uuidString, role: "assistant", text: text)) }
            busy = false; streamID = nil; status = "Connected"
            error = payload["error"].string
            voice.taskFinished(payload)
            Task { await refreshSnapshot() }
            if needsCanonicalRefresh { scheduleCanonicalRefresh() }
        case "status.update": status = payload["text"].string ?? status
        case "tool.start":
            status = "Running \(payload["name"].string ?? payload["tool"].string ?? "a tool")"
        case "voice.live.transcript":
            messages = ChatMessage.upserting(payload["message"], into: messages)
        case "error": error = payload["message"].string ?? "The gateway reported an error."
        default: break
        }
    }
}
