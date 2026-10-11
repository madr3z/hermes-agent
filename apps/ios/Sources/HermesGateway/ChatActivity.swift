import Foundation

public enum ChatActivityPhase: String, Equatable, Sendable {
    case idle, sending, queued, thinking, responding, tool, waitingForInput
    case completed, cancelled, failed, disconnected
}

/// A projection of gateway activity. It never retains model reasoning or changes the transcript.
public struct ChatActivityState: Equatable, Sendable {
    public let profile: String
    public private(set) var runtimeID: String?
    public private(set) var phase: ChatActivityPhase = .idle
    public private(set) var detail: String?
    private var tools: [String: String] = [:]
    private var requests: Set<String> = []
    private var submission: UUID?
    private var sawTurnActivity = false

    public init(profile: String) { self.profile = profile }

    public var isAnimating: Bool {
        [.sending, .queued, .thinking, .responding, .tool].contains(phase)
    }
    public var isVisible: Bool { isAnimating || phase == .waitingForInput }
    public var title: String {
        switch phase {
        case .idle: return "Ready"
        case .sending: return "Sending…"
        case .queued: return "Message queued"
        case .thinking: return "Thinking…"
        case .responding: return "Responding…"
        case .tool: return "Using tools…"
        case .waitingForInput: return "Waiting for your input"
        case .completed: return "Completed"
        case .cancelled: return "Stopped"
        case .failed: return "Could not complete the response"
        case .disconnected: return "Disconnected"
        }
    }

    /// Use only an authoritative snapshot which passed the caller's runtime/revision guard.
    public mutating func bind(runtimeID: String?, snapshot: JSON) {
        self.runtimeID = runtimeID
        tools.removeAll(); requests.removeAll(); submission = nil; detail = nil
        sawTurnActivity = false
        guard runtimeID != nil else { finish(.idle); return }
        for request in snapshot["open_requests"].array {
            if let id = request["id"].string { requests.insert(id) }
        }
        if snapshot["pending_approval"] != .null {
            requests.insert(snapshot["pending_approval"]["request_id"].string ?? "approval")
        }
        if snapshot["pending_connection"] != .null {
            requests.insert(snapshot["pending_connection"]["op_id"].string ?? "connection")
        }
        if !requests.isEmpty {
            phase = .waitingForInput
            detail = "Open the request card or use a connected Mac to respond."
        } else if let error = snapshot["inflight"]["error"].string, !error.isEmpty {
            finish(.failed, detail: error)
        } else if snapshot["running"].bool || snapshot["info"]["running"].bool || snapshot["inflight"]["streaming"].bool {
            sawTurnActivity = true
            phase = (snapshot["inflight"]["assistant"].string ?? "").isEmpty ? .thinking : .responding
        } else if snapshot["inflight"]["status"].string == "interrupted" {
            finish(.cancelled)
        } else if snapshot["queued"] != .null {
            phase = .queued
        } else { finish(.idle) }
    }

    @discardableResult public mutating func beginSubmission() -> UUID {
        let id = UUID(); submission = id
        if !isVisible { phase = .sending; detail = nil; sawTurnActivity = false }
        return id
    }
    public mutating func submissionAccepted(_ id: UUID, result: JSON) {
        guard submission == id else { return }
        submission = nil
        // A completion can precede its RPC acknowledgement. Never restart that indicator.
        guard phase == .sending else { return }
        phase = result["status"].string == "queued" ? .queued : .thinking
    }
    public mutating func submissionFailed(_ id: UUID, message: String) {
        guard submission == id else { return }
        submission = nil
        if phase == .sending { finish(.failed, detail: message) }
    }
    public mutating func disconnect() { finish(.disconnected) }
    public mutating func interrupted(_ result: JSON) {
        if result["status"].string == "interrupted" || result["interrupted"].bool { finish(.cancelled) }
    }

    public mutating func receive(_ event: JSON) {
        guard ChatEventRoute.route(event, runtimeID: runtimeID, profile: profile) == .session else { return }
        let payload = event["payload"]
        switch event["type"].string {
        case "message.start":
            tools.removeAll(); requests.removeAll(); sawTurnActivity = true
            phase = .thinking; detail = nil
        case "message.delta", "message.interim":
            guard !((payload["text"].string ?? "").isEmpty) else { return }
            progress(.responding)
        case "reasoning.delta", "reasoning.available":
            // These contracts do not distinguish public summaries from private reasoning.
            // Presence is useful; the text is never saved or displayed by this projection.
            if phase != .responding && phase != .tool { progress(.thinking) }
        case "thinking.delta": receiveProviderWait(payload)
        case "tool.generating": progress(.thinking, detail: "Preparing \(payload["name"].string ?? "tool")")
        case "tool.start": startTool(payload)
        case "tool.complete": completeTool(payload)
        case "status.update": receiveStatus(payload)
        case "message.complete": complete(payload)
        case "session.info": receiveInfo(payload)
        case "connection.request":
            guard isVisible else { return }
            requests.insert(payload["op_id"].string ?? "connection")
            phase = .waitingForInput; detail = "Open the connection request to continue."
        case "connection.update": receiveConnection(payload)
        case "request.cancel": cancelRequest(payload)
        case "error": finish(.failed, detail: payload["message"].string)
        default: break
        }
    }

    private mutating func progress(_ next: ChatActivityPhase, detail: String? = nil) {
        // Late deltas/status frames after an explicit terminal signal must not reopen a turn.
        guard isVisible else { return }
        sawTurnActivity = true
        guard requests.isEmpty else { return }
        phase = next; self.detail = clipped(detail)
    }
    private mutating func startTool(_ payload: JSON) {
        guard isVisible else { return }
        let name = payload["name"].string ?? "Tool"
        tools[payload["tool_id"].string ?? name] = name
        progress(.tool, detail: payload["context"].string ?? "Running \(name)")
    }
    private mutating func completeTool(_ payload: JSON) {
        guard isVisible else { return }
        tools.removeValue(forKey: payload["tool_id"].string ?? payload["name"].string ?? "Tool")
        progress(tools.isEmpty ? .thinking : .tool,
                 detail: tools.isEmpty ? payload["summary"].string : "Running " + tools.values.sorted().joined(separator: ", "))
    }
    private mutating func receiveStatus(_ payload: JSON) {
        guard isVisible else { return }
        let text = clipped(payload["text"].string)
        if requests.isEmpty {
            if ["compacting", "compressing"].contains(payload["kind"].string ?? "") { phase = .thinking }
            detail = text
        }
    }
    private mutating func receiveProviderWait(_ payload: JSON) {
        let text = payload["text"].string ?? ""
        let pattern = "^(?:⏳|⚠|↻|⚙)\\s*(?:(?:still\\s+)?waiting on|loading|processing prompt|no (?:output|response)|model returned|rate limited|provider (?:overloaded|temporarily unavailable))"
        guard text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return }
        progress(.thinking, detail: text)
    }
    private mutating func receiveInfo(_ payload: JSON) {
        if payload["running"] == .bool(false), sawTurnActivity, isVisible { finish(.completed) }
        else if payload["running"] == .bool(true), phase == .idle || phase == .disconnected {
            phase = .thinking; sawTurnActivity = true
        }
    }
    private mutating func complete(_ payload: JSON) {
        if payload["status"].string == "interrupted" { finish(.cancelled) }
        else if payload["status"].string == "error" || !(payload["error"].string ?? "").isEmpty {
            finish(.failed, detail: payload["error"].string ?? payload["failure_reason"].string)
        } else { finish(.completed) }
    }
    private mutating func receiveConnection(_ payload: JSON) {
        guard let id = payload["op_id"].string, requests.contains(id) else { return }
        if payload["settled"].bool {
            requests.remove(id)
            if requests.isEmpty { phase = .thinking; detail = nil }
        }
    }
    private mutating func cancelRequest(_ payload: JSON) {
        guard let id = payload["id"].string, requests.remove(id) != nil else { return }
        if payload["reason"].string == "interrupted" { finish(.cancelled) }
        else if requests.isEmpty { phase = .thinking; detail = nil }
    }
    private mutating func finish(_ next: ChatActivityPhase, detail: String? = nil) {
        phase = next; self.detail = clipped(detail)
        tools.removeAll(); requests.removeAll(); submission = nil; sawTurnActivity = false
    }
    private func clipped(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(240))
    }
}
