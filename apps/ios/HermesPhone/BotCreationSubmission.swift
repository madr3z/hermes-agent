import Foundation
import Observation
import HermesGateway

@MainActor @Observable final class BotCreationSubmission {
    private(set) var pending: JSON?
    private(set) var needsPassword = true
    private let preferences: UserDefaults
    private var key: String?
    private let route = "api/plugins/bot-provisioning/v1/requests"
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    var requestID: String? { pending?["request_id"].string }

    func restore(gatewayID: UUID) {
        let nextKey = "provision-request-\(gatewayID)"
        guard key != nextKey else { return }
        key = nextKey; pending = nil; needsPassword = true
        if let data = preferences.data(forKey: nextKey), let saved = try? JSONDecoder().decode(JSON.self, from: data) {
            pending = Self.nonSecretBody(saved); needsPassword = false
        }
    }
    func recover(client: GatewayClient) async throws -> JSON? {
        guard let requestID else { return nil }
        needsPassword = false
        do {
            let receipt = try await client.http(route + "/" + requestID)
            clear(); return receipt
        } catch GatewayError.http(status: 404, message: _) {
            needsPassword = true; return nil
        }
    }
    func submit(body: JSON, password: String, confirmation: String, capabilities: JSON, client: GatewayClient) async throws -> JSON {
        if pending != nil, let receipt = try await recover(client: client) { return receipt }
        let candidate = pending ?? Self.nonSecretBody(body)
        if let message = Self.validationError(name: candidate["name"].string ?? "", password: password, confirmation: confirmation, capabilities: capabilities) {
            throw GatewayError.message(message)
        }
        guard let key else { throw GatewayError.message("Choose a controller first.") }
        if pending == nil {
            guard case .object(var fields) = candidate else { throw GatewayError.message("Invalid bot request.") }
            fields["request_id"] = .string(UUID().uuidString.lowercased())
            let saved = JSON.object(fields)
            // Save only non-secret settings before sending an uncertain request.
            preferences.set(try JSONEncoder().encode(saved), forKey: key)
            pending = saved
        }
        guard case .object(var outgoing)? = pending else { throw GatewayError.message("Invalid bot request.") }
        outgoing["linux_password"] = .string(password)
        needsPassword = false
        let receipt = try await client.http(route, body: .object(outgoing))
        clear(); return receipt
    }
    private func clear() {
        if let key { preferences.removeObject(forKey: key) }
        pending = nil; needsPassword = true
    }
    private static func nonSecretBody(_ body: JSON) -> JSON {
        .object(Dictionary(uniqueKeysWithValues: ["request_id", "name", "resources", "credentials", "soul"].compactMap { key in
            body[key] == .null ? nil : (key, body[key])
        }))
    }
    static func supportsLinuxAccount(_ capabilities: JSON) -> Bool {
        capabilities["linux_account"]["username"].string == "bot_name" && capabilities["linux_account"]["password"]["required"].bool
    }
    static func usernameError(_ name: String, capabilities: JSON) -> String? {
        let pattern = "^[a-z][a-z0-9_-]{0,31}$"
        guard name.range(of: pattern, options: .regularExpression) == name.startIndex..<name.endIndex else {
            return "Use 1–32 ASCII characters. Start with a lowercase letter, then use lowercase letters, digits, _ or -."
        }
        if capabilities["linux_account"]["reserved_usernames"].array.contains(.string(name)) { return "This Linux username is reserved. Choose another bot name." }
        return nil
    }
    static func validationError(name: String, password: String, confirmation: String, capabilities: JSON) -> String? {
        guard supportsLinuxAccount(capabilities) else { return "Update the controller to support bot Linux accounts." }
        if let error = usernameError(name, capabilities: capabilities) { return error }
        let policy = capabilities["linux_account"]["password"]
        let minimum = Int(policy["min_bytes"].number ?? 8), maximum = Int(policy["max_bytes"].number ?? 256)
        guard (minimum...maximum).contains(password.utf8.count), !password.utf8.contains(where: { $0 == 0 || $0 == 13 || $0 == 10 }) else {
            return "Use a password of \(minimum)–\(maximum) UTF-8 bytes without NUL or line breaks."
        }
        guard password == confirmation else { return "Passwords do not match." }
        return nil
    }
}
