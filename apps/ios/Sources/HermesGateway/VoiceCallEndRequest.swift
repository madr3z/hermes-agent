import Foundation

/// Speech and transcript text never carry call-control authority.
public enum VoiceCallEndRequest {
    public static func matches(_ payload: JSON, callID: String, delegationID: String?, clientTurnID: String?) -> Bool {
        guard !callID.isEmpty, let delegationID, let clientTurnID else { return false }
        return payload["call_id"].string == callID && payload["delegation_id"].string == delegationID && payload["client_turn_id"].string == clientTurnID
    }
}
