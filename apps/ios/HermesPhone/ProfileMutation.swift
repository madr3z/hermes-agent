import Foundation
import HermesGateway

/// Shared load/working/notice skeleton for profile-scoped phone stores.
@MainActor enum ProfileMutation {
    static func run<Client>(
        client: Client?,
        loading: Bool,
        working: inout Bool,
        error: inout String?,
        notice: inout String?,
        body: (Client) async throws -> JSON,
        accept: (JSON) throws -> String,
        fail: (Error) -> String,
        afterFailure: () -> Void = {},
        reload: () async -> Void
    ) async -> Bool {
        guard let client, !loading, !working else { return false }
        working = true
        error = nil
        notice = nil
        do {
            notice = try accept(try await body(client))
            working = false
            await reload()
            return true
        } catch let thrown {
            error = fail(thrown)
            afterFailure()
            working = false
            return false
        }
    }
}
