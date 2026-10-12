import Foundation

/// Read-only ringing checks share the push deadline. Answer actions are never retried here.
public enum MobileInvitationLookup {
    public static func ringing(
        _ push: MobilePush,
        now: () -> Date = Date.init,
        pause: () async throws -> Void = { try await Task.sleep(for: .seconds(3)) },
        lookup: () async throws -> MobileInvitation
    ) async throws -> MobileInvitation {
        while push.isCurrent(at: now()) {
            try Task.checkCancellation()
            do {
                let invitation = try await lookup()
                try Task.checkCancellation()
                guard push.isCurrent(at: now()) else { break }
                return invitation
            } catch {
                try Task.checkCancellation()
                guard isTemporary(error) else { throw error }
                try await pause()
            }
        }
        throw GatewayError.message("This incoming call expired.")
    }

    private static func isTemporary(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.cancelled, .timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
        }
        if case GatewayError.http(let status, _) = error { return status == 408 || status == 429 || (500..<600).contains(status) }
        return false
    }
}
