import Foundation
import Observation
import HermesGateway

struct VMDeletionTarget: Identifiable {
    let mainID: UUID
    let requestID: String
    var id: String { "\(mainID)-\(requestID)" }
    init?(mainID: UUID, requestID: String) {
        guard UUID(uuidString: requestID) != nil else { return nil }
        self.mainID = mainID; self.requestID = requestID
    }
    var route: String { "api/plugins/bot-provisioning/v1/requests/\(requestID)" }
}
struct VMDeletionRequest: Codable, Equatable {
    let operationID: UUID
    let confirmName: String
    var body: JSON { .object(["operation_id": .string(operationID.uuidString.lowercased()), "confirm_name": .string(confirmName)]) }
    var receiptPath: String { "delete/\(operationID.uuidString.lowercased())" }
}

@MainActor @Observable final class VMDeletionControl {
    private(set) var status: JSON = .null
    private(set) var receipt: JSON = .null
    private(set) var pending: VMDeletionRequest?
    private(set) var supported = false
    private(set) var working = false
    private(set) var missingReceipt = false
    private(set) var error: String?
    private var statusFresh = false
    private let preferences: UserDefaults
    private var target: VMDeletionTarget?
    private var client: GatewayClient?
    private var key: String? { target.map { "vm-delete-\($0.id)" } }
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    var name: String { status["name"].string ?? "Bot" }
    var phase: String { receipt["phase"].string ?? (pending == nil ? status["phase"].string ?? "unknown" : "unconfirmed") }
    var deleted: Bool { receipt["phase"].string == "deleted" }
    var canConfirm: Bool {
        supported && statusFresh && !working && status["name"].string != nil &&
        ["queued", "provisioning", "ready", "failed", "delete_failed"].contains(status["phase"].string ?? "") &&
        (pending == nil || receipt["phase"].string == "failed")
    }
    func load(target: VMDeletionTarget, client: GatewayClient) async {
        self.target = target; self.client = client
        if let key, let data = preferences.data(forKey: key) { pending = try? JSONDecoder().decode(VMDeletionRequest.self, from: data) }
        do {
            supported = try await client.http("api/plugins/bot-provisioning/v1/capabilities")["vm_delete"].bool
            if supported { await refresh() }
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard let target, let client, supported, !working else { return }
        working = true; error = nil; statusFresh = false; defer { working = false }
        do {
            status = try await client.http(target.route)
            statusFresh = true
            if pending == nil, let id = status["deletion_operation_id"].string.flatMap(UUID.init(uuidString:)), let name = status["name"].string {
                try save(VMDeletionRequest(operationID: id, confirmName: name))
            }
            if let pending { _ = try await recover(pending, target: target, client: client) }
        } catch { self.error = error.localizedDescription }
    }
    func confirm() async {
        guard canConfirm, let target, let client else { return }
        working = true; error = nil
        do {
            let request = VMDeletionRequest(operationID: UUID(), confirmName: name)
            try save(request)
            let response = try await client.http(target.route + "/delete", body: request.body)
            try accept(response, request: request, target: target)
        } catch { self.error = error.localizedDescription }
        working = false
        await refresh()
    }
    func retrySameOperation() async {
        guard let pending, let target, let client, supported, !working else { return }
        working = true; error = nil
        do {
            if try await recover(pending, target: target, client: client) == false {
                let response = try await client.http(target.route + "/delete", body: pending.body)
                try accept(response, request: pending, target: target)
            }
        } catch { self.error = error.localizedDescription }
        working = false
        await refresh()
    }
    private func recover(_ request: VMDeletionRequest, target: VMDeletionTarget, client: GatewayClient) async throws -> Bool {
        missingReceipt = false
        do {
            let response = try await client.http(target.route + "/" + request.receiptPath)
            try accept(response, request: request, target: target); return true
        }
        catch GatewayError.http(status: 404, message: _) { receipt = .null; missingReceipt = true; return false }
    }
    private func accept(_ value: JSON, request: VMDeletionRequest, target: VMDeletionTarget) throws {
        guard value["request_id"].string == target.requestID,
              value["operation_id"].string.flatMap(UUID.init(uuidString:)) == request.operationID,
              value["action"].string == "delete" else { throw GatewayError.message("Controller returned a mismatched deletion receipt.") }
        receipt = value
    }
    private func save(_ request: VMDeletionRequest) throws {
        guard let key else { throw GatewayError.message("Missing managed VM identity.") }
        preferences.set(try JSONEncoder().encode(request), forKey: key)
        pending = request; missingReceipt = false
    }
}
