import Foundation

public struct MCPOAuthSession: Sendable {
    public static let callbackURI = "com.hermes.iphone:/oauth/callback"
    public let name: String
    public let id: String
    public let authorizationURL: URL?

    public init(name: String, result: JSON) throws {
        guard result["ok"].bool, let id = result["session_id"].string, !id.isEmpty else {
            throw GatewayError.message("The gateway could not start sign-in.")
        }
        self.name = name; self.id = id
        let raw = result["auth_url"].string ?? ""
        if raw.isEmpty { authorizationURL = nil }
        else {
            guard let url = URL(string: raw), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil else {
                throw GatewayError.message("The provider did not return a secure sign-in URL. Finish sign-in on your Mac.")
            }
            authorizationURL = url
        }
    }

    public var parameters: [String: JSON] { ["name": .string(name), "session_id": .string(id)] }

    public func callbackParameters(_ url: URL) throws -> [String: JSON] {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "com.hermes.iphone", parts.host == nil, parts.path == "/oauth/callback",
              parts.user == nil, parts.password == nil, parts.fragment == nil else {
            throw GatewayError.message("The provider returned an invalid callback.")
        }
        var params = parameters
        for key in ["code", "state", "error", "iss"] {
            let values = (parts.queryItems ?? []).filter { $0.name == key }
            guard values.count <= 1 else { throw GatewayError.message("The provider returned an ambiguous callback.") }
            if let value = values.first?.value, !value.isEmpty { params[key] = .string(value) }
        }
        guard params["state"] != nil, params["code"] != nil || params["error"] != nil else {
            throw GatewayError.message("The provider returned an incomplete callback.")
        }
        return params
    }
}

extension BotConnectorsClient {
    public func startOAuth(name: String) async throws -> MCPOAuthSession {
        do {
            let result = try await call("mcp.servers.oauth.start", ["name": .string(name), "client_redirect_uri": .string(MCPOAuthSession.callbackURI)])
            do { return try MCPOAuthSession(name: name, result: result) }
            catch {
                if let id = result["session_id"].string, !id.isEmpty {
                    _ = try? await call("mcp.servers.oauth.cancel", ["name": .string(name), "session_id": .string(id)])
                }
                throw error
            }
        } catch GatewayError.rpc(let code, let message) where code == 4001 && message.contains("loopback") {
            let reason = message.contains("registered loopback") ? "This provider requires its registered Mac callback. Finish sign-in on your Mac." : "This gateway needs an update to support iPhone sign-in. Update Hermes from your Mac."
            throw GatewayError.message(reason)
        } catch GatewayError.rpc(let code, _) where code == -32601 {
            throw GatewayError.message("This gateway needs an update to support iPhone sign-in. Update Hermes from your Mac.")
        }
    }
    public func deliverOAuth(_ session: MCPOAuthSession, callback: URL) async throws {
        let result = try await call("mcp.servers.oauth.callback", session.callbackParameters(callback))
        guard result["ok"].bool else { throw GatewayError.message("The gateway rejected the sign-in callback.") }
    }
    public func pollOAuth(_ session: MCPOAuthSession) async throws -> String {
        let result = try await call("mcp.servers.oauth.poll", session.parameters)
        guard result["ok"].bool else { throw GatewayError.message("The gateway could not check sign-in.") }
        switch result["status"].string {
        case "approved": return "approved"
        case "pending": return "pending"
        default: throw GatewayError.message("The provider did not complete sign-in. Try again or finish sign-in on your Mac.")
        }
    }
    public func cancelOAuth(_ session: MCPOAuthSession) async throws {
        let result = try await call("mcp.servers.oauth.cancel", session.parameters)
        guard result["ok"].bool else { throw GatewayError.message("The gateway could not confirm cancellation.") }
    }
}
