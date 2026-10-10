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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [Bundle.module.url(forResource: "gateway", withExtension: "py", subdirectory: "Fixtures")!.path]
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
        let status = try await client.http("api/audio/voice-live/status", profile: "writer")
        XCTAssertEqual(status["profile"].string, "writer")
        XCTAssertEqual(status["path"].string, "/api/plugins/bot-provisioning/v1/gateways/vm/api/audio/voice-live/status")
        let snapshot = try await CanonicalChat.open(profile: "writer") { try await client.request($0, $1) }
        XCTAssertEqual(snapshot["session_id"].string, "runtime")
        XCTAssertEqual(ChatMessage.project(snapshot["messages"].array).first?.text, "Existing canonical history")
        var chunks = ""
        let complete = expectation(description: "Streaming completion on real text WebSocket")
        client.onEvent = { event in
            if event["type"].string == "message.delta" { chunks += event["payload"]["text"].string ?? "" }
            if event["type"].string == "message.complete" { complete.fulfill() }
        }
        _ = try await client.request("prompt.submit", ["session_id": .string("runtime"), "profile": .string("writer"), "text": .string("test")])
        await fulfillment(of: [complete], timeout: 10)
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
        client.disconnect()
        try await client.connect()
        let resumed = try await CanonicalChat.open(profile: "writer") { try await client.request($0, $1) }
        XCTAssertEqual(resumed["stored_session_id"].string, "tip")
        do { _ = try await client.request("unknown.method", [:]); XCTFail("Expected server error") }
        catch { XCTAssertEqual(error.localizedDescription, "Unsupported fixture RPC") }
    }
}
