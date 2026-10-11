import Foundation

public enum ControllerScope {
    public static func contains(_ url: URL, in base: URL) -> Bool {
        let prefix = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = url.standardized.path
        return url.scheme == "https" && url.host == base.host && (url.port ?? 443) == (base.port ?? 443) &&
            url.user == nil && url.password == nil && (prefix.isEmpty || path == "/" + prefix || path.hasPrefix("/" + prefix + "/"))
    }
}
private final class ControllerScopeDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let base: URL
    init(base: URL) { self.base = base }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { ControllerScope.contains($0, in: base) } == true ? request : nil)
    }
}

@MainActor public final class ControllerSession {
    private struct Cookie: Codable {
        let name: String
        let value: String
        let expires: Date?
    }
    private struct Record: Codable {
        let kind: String
        let baseURL: URL
        let cookies: [Cookie]
    }
    public let endpoint: GatewayEndpoint
    public let session: URLSession
    public init(endpoint: GatewayEndpoint, configuration: URLSessionConfiguration = .ephemeral) {
        self.endpoint = endpoint
        self.session = URLSession(configuration: configuration, delegate: ControllerScopeDelegate(base: endpoint.baseURL), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public static func restore(endpoint: GatewayEndpoint, data: Data) throws -> ControllerSession? {
        guard let record = try? JSONDecoder().decode(Record.self, from: data), record.kind == "controller_cookie_v1" else { return nil }
        guard record.baseURL == endpoint.baseURL else { throw GatewayError.message("Gateway address changed. Sign in again.") }
        let result = ControllerSession(endpoint: endpoint)
        let prefix = result.cookiePath
        for saved in record.cookies where saved.expires == nil || saved.expires! > Date() {
            guard result.cookieNames.contains(saved.name) else { throw GatewayError.message("Invalid saved controller session. Sign in again.") }
            var properties: [HTTPCookiePropertyKey: Any] = [.name: saved.name, .value: saved.value, .domain: endpoint.baseURL.host!, .path: prefix, .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]
            if let expires = saved.expires { properties[.expires] = expires }
            if let cookie = HTTPCookie(properties: properties) { result.session.configuration.httpCookieStorage?.setCookie(cookie) }
        }
        return result
    }
    private var cookiePath: String {
        let path = endpoint.baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? "/" : "/" + path
    }
    private var cookieNames: [String] {
        let prefix = cookiePath == "/" ? "__Host-" : "__Secure-"
        return ["hermes_session_at", "hermes_session_rt", "hermes_session_provider"].map { prefix + $0 }
    }
    private var cookies: [HTTPCookie] {
        (session.configuration.httpCookieStorage?.cookies ?? []).filter {
            cookieNames.contains($0.name) && $0.isSecure && $0.isHTTPOnly && $0.path == cookiePath &&
            $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == endpoint.baseURL.host?.lowercased()
        }
    }
    public func savedData() throws -> Data {
        try JSONEncoder().encode(Record(kind: "controller_cookie_v1", baseURL: endpoint.baseURL, cookies: cookies.map { Cookie(name: $0.name, value: $0.value, expires: $0.expiresDate) }))
    }
    public func passwordProviders() async throws -> [JSON] {
        try await request("api/auth/providers")["providers"].array.filter { $0["supports_password"].bool }
    }
    public func signIn(provider: String, username: String, password: String) async throws {
        guard !username.isEmpty, !password.isEmpty else { throw GatewayError.message("Enter the controller username and password.") }
        let response = try await request("auth/password-login", body: .object(["provider": .string(provider), "username": .string(username), "password": .string(password), "next": .string("")]))
        guard response["ok"].bool, cookies.contains(where: { $0.name.hasSuffix("hermes_session_at") }) else { throw GatewayError.message("Controller did not return a secure session. Check its HTTPS setup.") }
    }
    private func request(_ path: String, body: JSON? = nil) async throws -> JSON {
        var request = URLRequest(url: endpoint.url(path: path))
        request.setValue("application/json", forHTTPHeaderField: "Accept"); request.timeoutInterval = 30
        if let body {
            request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw GatewayError.http(status: code, message: code == 401 ? "Invalid controller username or password." : "Controller sign-in failed (HTTP \(code)). Check the gateway or try again.")
        }
        return try JSONDecoder().decode(JSON.self, from: data)
    }
}
