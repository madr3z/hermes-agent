import Foundation

@MainActor public final class GatewayClient {
    public let endpoint: GatewayEndpoint
    private let token: String
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

    public init(endpoint: GatewayEndpoint, token: String, session: URLSession = .shared) {
        self.endpoint = endpoint; self.token = token; self.session = session
    }
    deinit {
        reader?.cancel(); heartbeat?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }
    public func connect() async throws {
        disconnect()
        let ws = session.webSocketTask(with: endpoint.webSocketURL(token: token))
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
    public func remoteSocket(_ stream: RemoteStream) -> URLSessionWebSocketTask {
        session.webSocketTask(with: stream.request(endpoint: endpoint, token: token))
    }

    public func http(_ path: String, profile: String? = nil, body: JSON? = nil) async throws -> JSON {
        var request = URLRequest(url: endpoint.url(path: path, profile: profile))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        if let body {
            request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let payload = try? JSONDecoder().decode(JSON.self, from: data)
            let detail = payload?["detail"].string ?? payload?["error"]["message"].string
            throw GatewayError.http(status: status, message: detail ?? "Gateway HTTP \(status). Check authentication and service availability.")
        }
        return try JSONDecoder().decode(JSON.self, from: data)
    }
}
