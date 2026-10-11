import Foundation

@MainActor public final class GatewayClient {
    public let endpoint: GatewayEndpoint
    private let token: String?
    private let authenticationEndpoint: GatewayEndpoint
    private let onAuthenticationChange: (() throws -> Void)?
    private var connectionGeneration = UUID()
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<JSON, Error>] = [:]
    private var observers: [UUID: (JSON) -> Void] = [:]
    private var disconnectObservers: [UUID: () -> Void] = [:]
    public var onEvent: ((JSON) -> Void)?
    public var onDisconnect: ((String) -> Void)?
    public private(set) var connected = false

    public init(endpoint: GatewayEndpoint, token: String?, session: URLSession = .shared, authenticationEndpoint: GatewayEndpoint? = nil, onAuthenticationChange: (() throws -> Void)? = nil) {
        self.endpoint = endpoint; self.token = token; self.session = session
        self.authenticationEndpoint = authenticationEndpoint ?? endpoint
        self.onAuthenticationChange = onAuthenticationChange
    }
    deinit {
        reader?.cancel(); heartbeat?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }
    public func connect() async throws {
        disconnect()
        let generation = connectionGeneration
        let url: URL
        if let token { url = endpoint.webSocketURL(token: token) }
        else {
            var parts = URLComponents(url: endpoint.url(path: "api/ws"), resolvingAgainstBaseURL: false)!
            parts.scheme = "wss"; parts.queryItems = [URLQueryItem(name: "ticket", value: try await webSocketTicket())]
            url = parts.url!
        }
        guard generation == connectionGeneration, !Task.isCancelled else { throw GatewayError.message("Connection cancelled.") }
        let ws = session.webSocketTask(with: url)
        socket = ws; ws.resume()
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    let data: Data
                    switch message { case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue }
                    let frame = try JSONDecoder().decode(JSON.self, from: data)
                    guard let self, self.socket === ws else { return }
                    self.receive(frame)
                }
            } catch {
                guard let self, self.socket === ws else { return }
                self.disconnect(); self.onDisconnect?("Gateway disconnected. Reconnect to restore the server transcript.")
            }
        }
        _ = try await request("profiles.list", ["include_sessions": .bool(true)])
        connected = true
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(20))
                    guard let self else { return }
                    _ = try await self.checkLiveness()
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    self.disconnect()
                    self.onDisconnect?("Gateway heartbeat timed out. Reconnect to restore the server transcript.")
                    return
                }
            }
        }
    }
    public func checkLiveness(timeout: Double = 10) async throws {
        // gateway.ping is handled by the WS reader, outside the serial RPC dispatcher.
        _ = try await request("gateway.ping", [:], timeout: timeout)
    }
    public func disconnect() {
        connectionGeneration = UUID()
        connected = false
        Array(disconnectObservers.values).forEach { $0() }
        let old = socket; socket = nil
        reader?.cancel(); heartbeat?.cancel()
        old?.cancel(with: .goingAway, reason: nil)
        let waiting = pending; pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: GatewayError.message("Connection closed. The request may have reached the server; refresh before retrying.")) }
    }
    public func request(_ method: String, _ params: [String: JSON], timeout: Double = 60) async throws -> JSON {
        guard let socket else { throw GatewayError.message("Connect to the gateway first.") }
        let id = UUID().uuidString
        let data = try JSONEncoder().encode(JSON.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .object(params)]))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
                catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.pending.removeValue(forKey: id)?.resume(throwing: GatewayError.message("Gateway request timed out. Refresh before retrying a send."))
            }
        }
    }
    private func receive(_ frame: JSON) {
        if frame["method"].string == "event" {
            let event = frame["params"]
            onEvent?(event); Array(observers.values).forEach { $0(event) }; return
        }
        if let id = frame["id"].string, let continuation = pending.removeValue(forKey: id) {
            if let error = frame["error"]["message"].string { continuation.resume(throwing: GatewayError.rpc(code: Int(frame["error"]["code"].number ?? 0), message: error)) }
            else { continuation.resume(returning: frame["result"]) }
        }
        // This client never advertises server_requests. On a shared transport, silence
        // preserves another capable client's authority to answer the fan-out request.
    }

    public func observe(events: @escaping (JSON) -> Void, disconnected: @escaping () -> Void) -> UUID {
        let id = UUID(); observers[id] = events; disconnectObservers[id] = disconnected; return id
    }
    public func removeObserver(_ id: UUID) { observers.removeValue(forKey: id); disconnectObservers.removeValue(forKey: id) }
    public func remoteSocket(_ stream: RemoteStream) async throws -> URLSessionWebSocketTask {
        let ticket = token == nil ? try await webSocketTicket() : nil
        return session.webSocketTask(with: stream.request(endpoint: endpoint, token: token, ticket: ticket))
    }
    private func webSocketTicket() async throws -> String {
        let result = try await http("api/auth/ws-ticket", profile: nil, body: .object([:]), at: authenticationEndpoint)
        guard let ticket = result["ticket"].string, !ticket.isEmpty else { throw GatewayError.message("Controller did not return a WebSocket ticket. Sign in again.") }
        return ticket
    }
    public func fileRequest(path: String, profile: String, storedSessionID: String) throws -> URLRequest {
        guard !storedSessionID.isEmpty, ChatAttachment(path: path) != nil else { throw GatewayError.message("File owner is unavailable. Reopen Bot Chat.") }
        var parts = URLComponents(url: endpoint.url(path: "api/fs/download"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "session_id", value: storedSessionID), URLQueryItem(name: "path", value: path)]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: parts.url!)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        return request
    }
    public func downloadFile(_ attachment: ChatAttachment, profile: String, storedSessionID: String) async throws -> URL {
        let request = try fileRequest(path: attachment.path, profile: profile, storedSessionID: storedSessionID)
        let (temporary, response) = try await session.download(for: request, delegate: FileDownloadScope())
        defer { try? FileManager.default.removeItem(at: temporary) }
        try onAuthenticationChange?()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw GatewayError.http(status: status, message: "File download failed (HTTP \(status)). Check this bot's connection and file access.")
        }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 25 * 1024 * 1024 else { throw GatewayError.message("File previews and sharing are limited to 25 MiB.") }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-file-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let name = (attachment.name as NSString).lastPathComponent
        let destination = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "attachment" : name)
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            #endif
            return destination
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    public func http(_ path: String, profile: String? = nil, body: JSON? = nil, method: String? = nil) async throws -> JSON {
        try await http(path, profile: profile, body: body, at: endpoint, method: method)
    }
    private func http(_ path: String, profile: String?, body: JSON?, at owner: GatewayEndpoint, method: String? = nil) async throws -> JSON {
        var request = URLRequest(url: owner.url(path: path, profile: profile))
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        request.httpMethod = method ?? (body == nil ? "GET" : "POST")
        if let body { request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try onAuthenticationChange?()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let payload = try? JSONDecoder().decode(JSON.self, from: data)
            let detail = payload?["detail"].string ?? payload?["error"]["message"].string
            throw GatewayError.http(status: status, message: detail ?? "Gateway HTTP \(status). Check authentication and service availability.")
        }
        return try JSONDecoder().decode(JSON.self, from: data)
    }
}

private final class FileDownloadScope: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A file response has no reason to change its owner or route.
        completionHandler(nil)
    }
}
