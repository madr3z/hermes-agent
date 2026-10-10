import Foundation

public struct VoiceTaskResult: Equatable {
    public let delegationID: String
    public let text: String
}

public struct VoiceDelegationTracker {
    public private(set) var currentID: String?
    private var userRowID: Double?
    private var earlyCompletions: [Double: JSON] = [:]
    public init() {}
    public mutating func begin(_ id: String) {
        currentID = id; userRowID = nil; earlyCompletions.removeAll()
    }
    public mutating func cancel() {
        currentID = nil; userRowID = nil; earlyCompletions.removeAll()
    }
    public mutating func accept(_ result: JSON, delegationID: String) -> VoiceTaskResult? {
        guard currentID == delegationID else { return nil }
        userRowID = result["user_row_id"].number
        guard let userRowID, let early = earlyCompletions.removeValue(forKey: userRowID) else { return nil }
        return complete(early)
    }
    public var hasTurnReceipt: Bool { userRowID != nil }
    public mutating func complete(_ payload: JSON) -> VoiceTaskResult? {
        guard let currentID, let receipt = payload["persisted_turn"]["user_row_id"].number else { return nil }
        guard let userRowID else {
            if earlyCompletions.count < 8 { earlyCompletions[receipt] = payload }
            return nil
        }
        guard receipt == userRowID else { return nil }
        let text = payload["text"].string ?? ""
        let success = payload["status"].string == "complete" && payload["error"].string == nil
        cancel()
        return success && !text.isEmpty ? VoiceTaskResult(delegationID: currentID, text: text) : nil
    }
}
