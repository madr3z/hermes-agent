import Foundation

public struct VoiceTranscriptTurn: Identifiable, Equatable {
    public let id: String
    public let speaker: String
    public var text: String
    public var endMS: Double
}

/// Keeps the two transcript streams separate, including overlapping speech and replayed events.
public struct VoiceConversation {
    public private(set) var turns: [VoiceTranscriptTurn] = []
    private var seen: Set<String> = []
    private var current: [String: Int] = [:]
    public init() {}
    public mutating func append(speaker: String, text: String, startMS: Double, endMS: Double, eventID: String) throws -> VoiceTranscriptTurn? {
        guard ["user", "assistant"].contains(speaker), startMS.isFinite, endMS.isFinite,
              startMS >= 0, endMS >= startMS, text.count <= 16_000 else {
            throw GatewayError.message("Invalid voice transcript fragment.")
        }
        guard !text.isEmpty, !seen.contains(eventID) else { return nil }
        seen.insert(eventID)
        let index: Int
        if let previous = current[speaker], startMS - turns[previous].endMS <= 1500 {
            index = previous
        } else {
            index = turns.count
            turns.append(VoiceTranscriptTurn(id: UUID().uuidString, speaker: speaker, text: "", endMS: endMS))
            current[speaker] = index
        }
        turns[index].text += text
        turns[index].endMS = endMS
        return turns[index]
    }
}

/// A new session can speak its authenticated call reason once, after the session is ready.
public struct VoiceOpening {
    private var reason: String?
    public init(reason: String? = nil) {
        let value = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reason = value?.isEmpty == false ? String(value!.prefix(500)) : nil
    }
    public mutating func event(sessionReady: Bool) -> [String: JSON]? {
        guard sessionReady, let reason else { return nil }
        self.reason = nil
        return ["type": .string("session.commentary.append"), "event_id": .string(UUID().uuidString),
                "delegation_id": .null, "content": .string(reason)]
    }
}

/// Presentation belongs to the call identity; stale callbacks cannot hide a newer call.
public struct IncomingCallPresentation {
    public private(set) var invitation: MobilePush?
    public private(set) var accepted = false
    public var isPresented = false
    public init() {}
    public mutating func begin(_ invitation: MobilePush) { self.invitation = invitation; accepted = false; isPresented = true }
    public mutating func accept(_ id: UUID) { if invitation?.invitationID == id { accepted = true; isPresented = true } }
    @discardableResult public mutating func finish(_ id: UUID) -> Bool {
        guard invitation?.invitationID == id else { return false }
        invitation = nil; accepted = false; isPresented = false
        return true
    }
}
