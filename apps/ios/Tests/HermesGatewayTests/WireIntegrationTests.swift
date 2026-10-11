import Foundation
import Security
import XCTest
@testable import HermesGateway

private final class FixtureTrust: NSObject, URLSessionDelegate {
    let certificate: Data
    init(certificate: Data) { self.certificate = certificate }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let cert = chain.first, SecCertificateCopyData(cert) as Data == certificate else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        // Trust only this test process's ephemeral certificate. Production uses system trust.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

final class WireIntegrationTests: XCTestCase {
    @MainActor func testRealTLSAndTextWebSocketCanonicalStreamingAndReconnect() async throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", Bundle.module.url(forResource: "gateway", withExtension: "py", subdirectory: "Fixtures")!.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var metadataData = Data()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel() }
        while metadataData.count < 8192 {
            guard let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else { break }
            if byte == Data([10]) { break }
            metadataData.append(byte)
        }
        let metadata = try JSONDecoder().decode(JSON.self, from: metadataData)
        let port = try XCTUnwrap(metadata["port"].number)
        let certificate = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(metadata["certificate"].string)))
        let trust = FixtureTrust(certificate: certificate)
        let session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let endpoint = try GatewayEndpoint(label: "TLS fixture", baseURL: URL(string: "https://127.0.0.1:\(Int(port))/api/plugins/bot-provisioning/v1/gateways/vm")!)
        let client = GatewayClient(endpoint: endpoint, token: "fixture+token &?", session: session)
        defer { client.disconnect() }
        try await client.connect()
        // Real WSS must use main query auth plus the independent guest ticket.
        let display = try await client.remoteSocket(.display(ticket: "guest+ticket &?"))
        display.resume()
        let greeting = try await display.receive()
        guard case .data(let version) = greeting else { return XCTFail("Expected binary RFB") }
        XCTAssertEqual(String(decoding: version, as: UTF8.self), "RFB 003.008\n")
        let pointer = Data([5, 1, 0, 4, 0, 8])
        try await display.send(.data(pointer))
        guard case .data(let echoed) = try await display.receive() else { return XCTFail("Expected binary pointer echo") }
        XCTAssertEqual(echoed, pointer)
        display.cancel(with: RemoteStream.closeCode(intentional: false), reason: nil)
        let terminal = try await client.remoteSocket(.terminal); terminal.resume()
        guard case .data(let ansi) = try await terminal.receive() else { return XCTFail("Expected raw terminal bytes") }
        XCTAssertTrue(String(decoding: ansi, as: UTF8.self).contains("guest shell"))
        let keyboard = Data("echo phone\r".utf8)
        try await terminal.send(.data(keyboard))
        guard case .data(let typed) = try await terminal.receive() else { return XCTFail("Expected terminal input") }
        XCTAssertEqual(typed, keyboard)
        let resize = "{\"type\":\"resize\",\"cols\":42,\"rows\":19}"
        try await terminal.send(.string(resize))
        guard case .data(let resized) = try await terminal.receive() else { return XCTFail("Expected resize frame") }
        XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: resized)["cols"].number, 42)
        terminal.cancel(with: RemoteStream.closeCode(intentional: true), reason: nil)
        var closes: [JSON] = []
        for _ in 0..<25 {
            closes = try await client.http("api/fixture/remote_events")["events"].array
            if closes.count == 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(closes.first(where: { $0["display"].bool })?["close"].number, 1011)
        XCTAssertEqual(closes.first(where: { !$0["display"].bool })?["close"].number, 1000)
        let status = try await client.http("api/audio/voice-live/status", profile: "writer")
        XCTAssertEqual(status["profile"].string, "writer")
        XCTAssertEqual(status["path"].string, "/api/plugins/bot-provisioning/v1/gateways/vm/api/audio/voice-live/status")
        let snapshot = try await CanonicalChat.open(profile: "writer") { try await client.request($0, $1) }
        XCTAssertEqual(snapshot["session_id"].string, "runtime")
        XCTAssertEqual(ChatMessage.project(snapshot["messages"].array).first?.text, "Existing canonical history")
        var chunks = ""
        let complete = expectation(description: "Streaming completion on real text WebSocket")
        let observerCompletion = expectation(description: "Remote observer coexists with chat events")
        let observer = client.observe(events: { event in
            if event["type"].string == "message.complete" { observerCompletion.fulfill() }
        }, disconnected: {})
        client.onEvent = { event in
            if event["type"].string == "message.delta" { chunks += event["payload"]["text"].string ?? "" }
            if event["type"].string == "message.complete" { complete.fulfill() }
        }
        _ = try await client.request("prompt.submit", ["session_id": .string("runtime"), "profile": .string("writer"), "text": .string("test")])
        await fulfillment(of: [complete, observerCompletion], timeout: 10)
        client.removeObserver(observer)
        XCTAssertEqual(chunks, "Real wire stream")
        let desktop = session.webSocketTask(with: endpoint.webSocketURL(token: "fixture+token &?"))
        desktop.resume()
        defer { desktop.cancel(with: .goingAway, reason: nil) }
        _ = try await desktop.receive() // gateway.ready: desktop is attached before the fan-out.
        let desktopAnswer = Task {
            let frame = try await desktop.receive()
            guard case .string(let text) = frame else { throw GatewayError.message("Expected text request") }
            let question = try JSONDecoder().decode(JSON.self, from: Data(text.utf8))
            XCTAssertEqual(question["method"].string, "approval")
            // Give the phone's old immediate error response an opportunity to race the capable client.
            try await Task.sleep(for: .milliseconds(100))
            let reply = JSON.object(["jsonrpc": .string("2.0"), "id": question["id"], "result": .object(["choice": .string("once")])])
            try await desktop.send(.string(String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)))
        }
        _ = try await client.request("fixture.shared_question", [:])
        try await desktopAnswer.value
        try await Task.sleep(for: .milliseconds(50))
        let shared = try await client.request("fixture.question_result", [:])
        XCTAssertEqual(shared["answer"]["choice"].string, "once")
        let slow = Task { try await client.request("fixture.slow", [:]) }
        try await Task.sleep(for: .milliseconds(50))
        try await client.checkLiveness(timeout: 0.2)
        _ = try await slow.value
        XCTAssertTrue(client.connected)
        var tracker = VoiceDelegationTracker()
        var spoken: [VoiceTaskResult] = []
        client.onEvent = { event in
            if event["type"].string == "message.complete", let result = tracker.complete(event["payload"]) { spoken.append(result) }
        }
        let before = try await client.request("fixture.prompt_count", [:])["accepted"].number
        for id in ["A", "B"] {
            tracker.begin(id, clientTurnID: "queued-\(id)")
            let queued = try await VoiceSubmission.submit(["session_id": .string("runtime"), "profile": .string("writer"), "text": .string("queued \(id)"), "queued": .bool(true), "surface": .string("voice-live"), "client_turn_id": .string("queued-\(id)")]) { try await client.request($0, $1) }
            XCTAssertEqual(queued["status"].string, "queued")
            XCTAssertNil(queued["user_row_id"].number)
            XCTAssertNil(tracker.accept(queued, delegationID: id))
            XCTAssertTrue(tracker.hasTurnIdentity)
        }
        _ = try await client.request("fixture.finish_queued", [:])
        XCTAssertEqual(spoken, [VoiceTaskResult(delegationID: "B", text: "B result")])
        let legacy = try await VoiceSubmission.submit(["session_id": .string("runtime"), "profile": .string("writer"), "text": .string("legacy immediate"), "client_turn_id": .string("legacy")]) { try await client.request($0, $1) }
        XCTAssertEqual(legacy["user_row_id"].number, 2)
        let after = try await client.request("fixture.prompt_count", [:])["accepted"].number
        XCTAssertEqual(after, (before ?? 0) + 3) // Two queued turns + one legacy turn; rejection never dispatched.
        client.disconnect()
        try await client.connect()
        let resumed = try await CanonicalChat.open(profile: "writer") { try await client.request($0, $1) }
        XCTAssertEqual(resumed["stored_session_id"].string, "tip")
        do { _ = try await client.request("unknown.method", [:]); XCTFail("Expected server error") }
        catch { XCTAssertEqual(error.localizedDescription, "Unsupported fixture RPC") }
    }
    @MainActor func testCookieMainAndManagedGuestUseFreshTicketsForEveryWebSocket() async throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", Bundle.module.url(forResource: "gateway", withExtension: "py", subdirectory: "Fixtures")!.path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel() }
        var metadataData = Data()
        while metadataData.count < 8192 {
            guard let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else { break }
            if byte == Data([10]) { break }; metadataData.append(byte)
        }
        let metadata = try JSONDecoder().decode(JSON.self, from: metadataData)
        let port = Int(try XCTUnwrap(metadata["port"].number))
        let certificate = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(metadata["certificate"].string)))
        let session = URLSession(configuration: .ephemeral, delegate: FixtureTrust(certificate: certificate), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let main = try GatewayEndpoint(label: "Main", baseURL: URL(string: "https://127.0.0.1:\(port)")!)
        var login = URLRequest(url: main.url(path: "auth/password-login"))
        login.httpMethod = "POST"; login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONEncoder().encode(JSON.object(["provider": .string("basic"), "username": .string("fixture-user"), "password": .string("fixture-password"), "next": .string("")]))
        let (_, response) = try await session.data(for: login)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let client = GatewayClient(endpoint: main, token: nil, session: session)
        defer { client.disconnect() }
        try await client.connect()
        let endpoint = try GatewayEndpoint(label: "VM", baseURL: main.url(path: "api/plugins/bot-provisioning/v1/gateways/vm"))
        let guest = GatewayClient(endpoint: endpoint, token: nil, session: session, authenticationEndpoint: main)
        defer { guest.disconnect() }
        try await guest.connect()
        let display = try await guest.remoteSocket(.display(ticket: "guest+ticket &?")); display.resume()
        guard case .data(let rfb) = try await display.receive() else { return XCTFail("Expected RFB bytes") }
        XCTAssertEqual(String(decoding: rfb, as: UTF8.self), "RFB 003.008\n")
        display.cancel(with: .normalClosure, reason: nil)
        let terminal = try await guest.remoteSocket(.terminal); terminal.resume()
        guard case .data(let ansi) = try await terminal.receive() else { return XCTFail("Expected terminal bytes") }
        XCTAssertTrue(String(decoding: ansi, as: UTF8.self).contains("guest shell"))
        terminal.cancel(with: .normalClosure, reason: nil)
        guest.disconnect(); try await guest.connect()
        let count = try await client.http("api/fixture/tickets")["minted"].number
        XCTAssertEqual(count, 5) // Main RPC, guest RPC, screen, terminal and guest reconnect each consume a fresh ticket.
    }

}
