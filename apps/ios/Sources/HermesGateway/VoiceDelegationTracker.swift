import Foundation

public struct VoiceTaskResult: Equatable {
    public let delegationID: String
    public let text: String
}

public struct VoiceDelegationTracker {
    public private(set) var currentID: String?
    public private(set) var clientTurnID: String?
    private var correlationAccepted = false
    private var userRowID: Double?
    private var earlyCompletions: [Double: JSON] = [:]
    public init() {}
    public mutating func begin(_ id: String, clientTurnID: String = UUID().uuidString) {
        currentID = id; self.clientTurnID = clientTurnID; correlationAccepted = false
        userRowID = nil; earlyCompletions.removeAll()
    }
    public mutating func cancel() {
        currentID = nil; clientTurnID = nil; correlationAccepted = false
        userRowID = nil; earlyCompletions.removeAll()
    }
    public mutating func accept(_ result: JSON, delegationID: String, clientTurnID expectedTurnID: String? = nil) -> VoiceTaskResult? {
        guard currentID == delegationID, expectedTurnID == nil || expectedTurnID == clientTurnID else { return nil }
        if let token = result["client_turn_id"].string, token != clientTurnID { return nil }
        correlationAccepted = result["client_turn_id"].string != nil && result["client_turn_id"].string == clientTurnID
        userRowID = result["user_row_id"].number
        guard let userRowID, let early = earlyCompletions.removeValue(forKey: userRowID) else { return nil }
        return complete(early)
    }
    public var hasTurnIdentity: Bool { correlationAccepted || userRowID != nil }
    public mutating func complete(_ payload: JSON) -> VoiceTaskResult? {
        guard let currentID else { return nil }
        if let token = payload["client_turn_id"].string {
            guard token == clientTurnID else { return nil }
        } else {
            guard !correlationAccepted, let receipt = payload["persisted_turn"]["user_row_id"].number else { return nil }
            guard let userRowID else {
                if earlyCompletions.count < 8 { earlyCompletions[receipt] = payload }
                return nil
            }
            guard receipt == userRowID else { return nil }
        }
        let text = payload["text"].string ?? ""
        let success = payload["status"].string == "complete" && payload["error"].string == nil
        cancel()
        return success && !text.isEmpty ? VoiceTaskResult(delegationID: currentID, text: text) : nil
    }
}
