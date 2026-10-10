import Foundation

public enum VoiceSubmission {
    @MainActor public static func submit(
        _ params: [String: JSON], request: (String, [String: JSON]) async throws -> JSON
    ) async throws -> JSON {
        do { return try await request("prompt.submit", params) }
        catch let error as GatewayError where error.rejectsClientTurnID {
            // This exact validation error is returned before the handler runs. No send
            // is retried after a timeout, transport error or an accepted submission.
            var legacy = params
            legacy.removeValue(forKey: "client_turn_id")
            return try await request("prompt.submit", legacy)
        }
    }
}
