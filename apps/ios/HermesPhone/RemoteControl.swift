import Foundation
import Observation
import WebKit
import HermesGateway

@MainActor @Observable final class RemoteControl {
    enum Mode: String, CaseIterable, Identifiable { case display = "Screen", terminal = "Terminal"; var id: String { rawValue } }
    let bot: Bot
    var mode: Mode = .display
    var status: JSON = .null
    var lease: JSON = .null
    var error: String?
    var connection = "Disconnected"
    var working = false
    var connected = false
    var loaded = false
    weak var webView: WKWebView?
    private var client: GatewayClient?
    private var observer: UUID?
    private var viewer: String?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var generation = UUID()
    private var lifetime = UUID()
    private var attaching: Task<Void, Never>?
    init(bot: Bot) { self.bot = bot }
    var controlling: Bool { DisplayIdentity.holds(lease, viewer: viewer) && connected }
    var desktopRunning: Bool { status["running"].bool }
    private var profile: [String: JSON] { ["profile": .string(bot.profile)] }

    func open(store: PhoneStore) async {
        await open { try await store.client(for: self.bot.endpointID) }
    }
    func open(connect: () async throws -> GatewayClient) async {
        guard !Task.isCancelled else { return }
        close(); error = nil; working = true
        let current = lifetime
        defer { if current == lifetime { working = false } }
        do {
            let client = try await connect()
            guard current == lifetime, !Task.isCancelled else { return }
            self.client = client
            observer = client.observe(events: { [weak self] in self?.receiveDisplayEvent($0) }, disconnected: { [weak self] in
                guard let self else { return }; self.viewer = nil; self.lease = .null; self.detach(intentional: false); self.error = "The control connection closed. Reconnect before taking desktop control."
            })
            if mode == .display { try await refreshStatus() }
            guard current == lifetime, !Task.isCancelled else { return }
            if loaded { await configure() }
        } catch { if current == lifetime { self.error = error.localizedDescription } }
    }
    func refreshStatus() async throws {
        guard let client else { return }
        let current = generation
        let result = try await client.request("display.status", profile)
        guard current == generation, !Task.isCancelled else { return }
        status = result; adoptLease(result["lease"])
    }
    func startDesktop() async {
        guard let client, !working else { return }
        working = true; error = nil
        let current = lifetime
        defer { if current == lifetime { working = false } }
        do {
            let result = try await client.request("display.start", profile)
            guard current == lifetime, !Task.isCancelled else { return }
            status = result; adoptLease(result["lease"]); await configure()
        }
        catch { if current == lifetime { self.error = error.localizedDescription } }
    }
    func changeMode() async {
        detach(); error = nil
        let current = lifetime
        do {
            if mode == .display { try await refreshStatus() }
            guard current == lifetime, !Task.isCancelled else { return }
            await configure()
        } catch { if current == lifetime { self.error = error.localizedDescription } }
    }
    private func configure() async {
        guard !Task.isCancelled, client != nil else { return }
        detach(); error = nil
        guard loaded, client != nil else { return }
        if mode == .display && !desktopRunning { connection = "Desktop is not running"; return }
        do { try await call("setup", argument: .object(["kind": .string(mode == .display ? "display" : "terminal"), "generation": .string(generation.uuidString)])) }
        catch { self.error = error.localizedDescription }
    }
    func reconnect(store: PhoneStore) async {
        if client?.connected != true { await open(store: store) }
        else {
            do { if mode == .display { try await refreshStatus() }; await configure() } catch { self.error = error.localizedDescription }
        }
    }
    func rendererMessage(_ type: String, body: [String: Any]) {
        guard type == "loaded" || (type == "failure" && !loaded) || body["generation"] as? String == generation.uuidString else { return }
        switch type {
        case "loaded":
            loaded = true; attaching = Task { await configure() }
        case "ready": attaching = Task { await attach() }
        case "connected": connected = true; connection = "Connected"; updateControl()
        case "closed", "close":
            if socket != nil { detach(intentional: false); error = "Remote connection closed. Reconnect to resume." }
        case "failure": detach(intentional: false); error = body["message"] as? String
        case "bytes":
            guard let value = body["data"] as? String, let bytes = Data(base64Encoded: value), bytes.count <= 65536 else { return }
            send(.data(bytes))
        case "resize":
            guard mode == .terminal, let cols = body["cols"] as? Int, let rows = body["rows"] as? Int else { return }
            resize(cols: cols, rows: rows)
        default: break
        }
    }
    private func attach() async {
        guard let client, !Task.isCancelled else { return }
        let current = generation
        connection = "Connecting…"
        do {
            let stream: RemoteStream
            if mode == .display {
                var params = profile
                if let viewer { params["viewer_id"] = .string(viewer) }
                let observe = try await client.request("display.observe", params)
                guard current == generation else { return }
                guard let ticket = observe["ticket"].string, let identity = observe["viewer_id"].string else { throw GatewayError.message("The gateway returned no screen ticket.") }
                viewer = identity; status = observe; adoptLease(observe["lease"])
                stream = .display(ticket: ticket)
            } else {
                let capability: JSON
                do { capability = try await client.http("api/terminal/status") }
                catch GatewayError.http(status: 404, message: _) { throw GatewayError.message("This guest does not support the persistent terminal yet.") }
                guard current == generation else { return }
                guard capability["available"].bool, capability["protocol"].string == "hermes-terminal-v1" else { throw GatewayError.message("This guest does not support the persistent terminal yet.") }
                stream = .terminal
            }
            let ws = client.remoteSocket(stream)
            socket = ws; ws.resume()
            try await call("opened")
            guard current == generation else { return }
            receiver = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await ws.receive()
                        guard let self, self.socket === ws else { return }
                        switch message {
                        case .data(let data): try await self.call("bytes", argument: .string(data.base64EncodedString()))
                        case .string: throw GatewayError.message("The remote stream sent an unexpected text frame.")
                        @unknown default: break
                        }
                    }
                } catch {
                    guard let self, self.socket === ws else { return }
                    let code = ws.closeCode.rawValue
                    self.detach(intentional: false); self.error = RemoteStream.closeMessage(code)
                    try? await self.call("closed")
                }
            }
        } catch {
            guard current == generation else { return }
            detach(intentional: false); self.error = error.localizedDescription
        }
    }
    private func resize(cols: Int, rows: Int) {
        let body = JSON.object(["type": .string("resize"), "cols": .number(Double(min(500, max(2, cols)))), "rows": .number(Double(min(200, max(2, rows))))])
        if let data = try? JSONEncoder().encode(body) { send(.string(String(decoding: data, as: UTF8.self))) }
    }
    private func send(_ message: URLSessionWebSocketTask.Message) {
        guard let ws = socket else { return }
        let previous = sender
        sender = Task { [weak self] in
            await previous?.value
            guard let self, self.socket === ws, !Task.isCancelled else { return }
            do { try await ws.send(message) }
            catch { guard self.socket === ws else { return }; self.detach(intentional: false); self.error = "Remote input could not be delivered. Reconnect before retrying." }
        }
    }
    func takeControl() async {
        guard let client, let viewer, connected, !working else { return }
        working = true; error = nil
        let currentLifetime = lifetime
        defer { if currentLifetime == lifetime { working = false } }
        do {
            var params = profile; params["viewer_id"] = .string(viewer)
            params["reason"] = .string("iPhone remote desktop")
            let current = generation
            let result = try await client.request("display.lease.acquire", params)["lease"]
            guard current == generation, self.client === client else {
                // A control grant can finish after the view closes; relinquish only our identity.
                _ = try await client.request("display.lease.release", ["profile": .string(bot.profile), "viewer_id": .string(viewer)])
                return
            }
            adoptLease(result); updateControl()
        } catch { if currentLifetime == lifetime { self.error = error.localizedDescription } }
    }
    func releaseControl() async {
        guard let client, let viewer, !working else { return }
        working = true
        let currentLifetime = lifetime
        defer { if currentLifetime == lifetime { working = false } }
        do {
            var params = profile; params["viewer_id"] = .string(viewer)
            let current = generation
            let result = try await client.request("display.lease.release", params)["lease"]
            guard current == generation, self.client === client else { return }
            adoptLease(result); updateControl()
        } catch { if currentLifetime == lifetime { self.error = error.localizedDescription } }
    }
    func paste(_ text: String) async {
        guard connected, mode == .terminal || controlling else { return }
        do { try await call("paste", argument: .string(text)) } catch { self.error = error.localizedDescription }
    }
    func receiveDisplayEvent(_ event: JSON) {
        guard DisplayIdentity.matches(event, profileKey: status["profile_key"].string) else { return }
        switch event["type"].string {
        case "display.lease":
            let value = event["payload"]["lease"]
            adoptLease(value); updateControl()
        case "display.stopped":
            status = .null; lease = .null
            if mode == .display { detach(); error = "The guest desktop stopped. Refresh to reconnect." }
        default: break
        }
    }
    private func adoptLease(_ value: JSON) {
        if (value["epoch"].number ?? 0) >= (lease["epoch"].number ?? 0) { lease = value }
    }
    private func updateControl() { Task { try? await call("control", argument: .bool(controlling)) } }
    func call(_ method: String, argument: JSON? = nil) async throws {
        guard let webView else { return }
        let arguments = try JSONEncoder().encode(argument.map { [$0] } ?? [])
        let values = try JSONSerialization.jsonObject(with: arguments)
        _ = try await webView.callAsyncJavaScript("await window.remote[method](...args)", arguments: ["method": method, "args": values], in: nil, contentWorld: .page)
    }
    func detach(intentional: Bool = true) {
        generation = UUID(); connected = false; connection = "Disconnected"
        receiver?.cancel(); sender?.cancel()
        let old = socket; socket = nil
        // Normal closure relinquishes display control; neither stream shuts down the VM.
        old?.cancel(with: RemoteStream.closeCode(intentional: intentional), reason: nil)
        updateControl()
    }
    func close() {
        lifetime = UUID(); attaching?.cancel(); detach(); working = false
        if let observer { client?.removeObserver(observer) }
        observer = nil; client = nil; viewer = nil; lease = .null
    }
}
