import Foundation
import CryptoKit

public enum RemoteStream: Equatable {
    case display(ticket: String), terminal
    public func request(endpoint: GatewayEndpoint, token: String) -> URLRequest {
        let path: String
        switch self { case .display: path = "api/display/ws"; case .terminal: path = "api/terminal/ws" }
        var parts = URLComponents(url: endpoint.url(path: path), resolvingAgainstBaseURL: false)!
        parts.scheme = "wss"
        // Hermes' WS authentication seam consumes a query token, independently
        // of the guest's single-use display ticket. This URL never enters WebKit.
        parts.queryItems = [URLQueryItem(name: "token", value: token)]
        if case .display(let ticket) = self { parts.queryItems?.append(URLQueryItem(name: "display_ticket", value: ticket)) }
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: parts.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
    public static func closeCode(intentional: Bool) -> URLSessionWebSocketTask.CloseCode {
        intentional ? .normalClosure : .internalServerError
    }
    public static func closeMessage(_ code: Int) -> String {
        switch code {
        case 4000: return "Desktop control moved to another viewer. Reconnect to watch."
        case 4001: return "The guest desktop stopped. Refresh its status."
        case 4401: return "The screen ticket expired. Reconnect for a fresh ticket."
        case 4403: return "The server refused this remote connection."
        case 4409: return "The terminal is open elsewhere. Reconnect explicitly to take input ownership."
        case 4410: return "The shell exited. Reconnect to open a shell."
        default: return "Remote connection closed. Reconnect to resume."
        }
    }
}

public enum DisplayIdentity {
    public static func hash(_ viewer: String) -> String {
        SHA256.hash(data: Data(viewer.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }
    public static func holds(_ lease: JSON, viewer: String?) -> Bool {
        guard let viewer else { return false }
        return lease["holder"].string == "human" && lease["viewer_hash"].string == hash(viewer)
    }
    public static func matches(_ event: JSON, profileKey: String?) -> Bool {
        guard let profileKey else { return false }
        return event["payload"]["profile_key"].string == profileKey
    }
}

public struct ProvisionedOwner: Codable, Equatable, Sendable {
    public let mainID: UUID
    public let requestID: String
    public let gatewayURL: URL
    public init(mainID: UUID, requestID: String, gatewayURL: URL) throws {
        guard UUID(uuidString: requestID) != nil else { throw GatewayError.message("Invalid VM request identity.") }
        self.mainID = mainID; self.requestID = requestID; self.gatewayURL = gatewayURL
    }
    public func owns(_ gateway: GatewayEndpoint) -> Bool { gatewayURL == gateway.baseURL }
    public static func matchingRegistryRow(_ row: JSON, main: GatewayEndpoint, gateway: GatewayEndpoint) -> ProvisionedOwner? {
        guard let returned = try? main.provisionedGateway(row), returned.baseURL == gateway.baseURL,
              let requestID = row["request_id"].string else { return nil }
        return try? ProvisionedOwner(mainID: main.id, requestID: requestID, gatewayURL: gateway.baseURL)
    }
    public var route: String { "api/plugins/bot-provisioning/v1/requests/\(requestID)" }
}

public enum VMPowerAction: String, CaseIterable, Codable, Identifiable {
    case start, stop, restart
    public var id: String { rawValue }
}
public struct VMPowerRequest: Codable, Equatable {
    public let operationID: UUID
    public let action: VMPowerAction
    public init(action: VMPowerAction, operationID: UUID = UUID()) { self.action = action; self.operationID = operationID }
    public var body: JSON { .object(["operation_id": .string(operationID.uuidString.lowercased()), "action": .string(action.rawValue)]) }
    public var receiptPath: String { "power/\(operationID.uuidString.lowercased())" }
}
