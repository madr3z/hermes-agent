import XCTest
import WebKit
import HermesGateway
@testable import HermesPhone

@MainActor final class RemoteControlTests: XCTestCase {
    func testDelayedOpenCannotReattachAfterDeparture() async throws {
        let endpoint = try GatewayEndpoint(label: "Fixture", baseURL: URL(string: "https://hermes.example")!)
        let bot = Bot(endpointID: endpoint.id, row: .object(["name": .string("writer")]))
        let control = RemoteControl(bot: bot)
        var resume: CheckedContinuation<GatewayClient, Never>?
        let requested = expectation(description: "Gateway connection requested")
        let opening = Task {
            await control.open {
                await withCheckedContinuation { continuation in resume = continuation; requested.fulfill() }
            }
        }
        await fulfillment(of: [requested], timeout: 5)
        control.close()
        resume?.resume(returning: GatewayClient(endpoint: endpoint, token: "unused"))
        await opening.value
        XCTAssertFalse(control.connected)
        XCTAssertFalse(control.working)
        XCTAssertEqual(control.connection, "Disconnected")
        XCTAssertNil(control.error) // A departed open must never bind or issue display.status.
        control.rendererMessage("connected", body: ["generation": UUID().uuidString])
        XCTAssertFalse(control.connected)
    }

    func testDesktopStoppingDoesNotDetachIndependentTerminal() throws {
        let endpoint = try GatewayEndpoint(label: "Fixture", baseURL: URL(string: "https://hermes.example")!)
        let control = RemoteControl(bot: Bot(endpointID: endpoint.id, row: .object(["name": .string("default")])))
        let event = JSON.object(["type": .string("display.stopped"), "payload": .object(["profile_key": .string("guest")])])
        control.mode = .terminal; control.status = .object(["profile_key": .string("guest")]); control.connected = true
        control.receiveDisplayEvent(event)
        XCTAssertTrue(control.connected); XCTAssertNil(control.error)
        control.mode = .display; control.status = .object(["profile_key": .string("guest")])
        control.receiveDisplayEvent(event)
        XCTAssertFalse(control.connected)
    }

    func testFailedGuestStillAllowsExplicitStopRecovery() {
        let power = VMPowerControl()
        power.supported = true
        power.vm = .object(["phase": .string("failed"), "desired_state": .string("running"), "observed_state": .string("failed")])
        XCTAssertTrue(power.allowed(.stop))
        XCTAssertFalse(power.allowed(.start)); XCTAssertFalse(power.allowed(.restart))
        power.vm = .object(["phase": .string("stopped"), "desired_state": .string("stopped"), "observed_state": .string("stopped")])
        XCTAssertTrue(power.allowed(.start)); XCTAssertFalse(power.allowed(.stop)); XCTAssertFalse(power.allowed(.restart))
    }
}

@MainActor private final class RendererMessages: NSObject, WKScriptMessageHandler {
    var received: [[String: Any]] = []
    var navigation: WKNavigationDelegate?
    var control: RemoteControl?
    var next: (([String: Any]) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        received.append(body); next?(body)
    }
}

@MainActor final class RemoteRendererTests: XCTestCase {
    private func load() async throws -> (WKWebView, RendererMessages) {
        let messages = RendererMessages(), configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(messages, name: "remote")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 370, height: 480), configuration: configuration)
        let endpoint = try GatewayEndpoint(label: "Viewer fixture", baseURL: URL(string: "https://hermes.example")!)
        let control = RemoteControl(bot: Bot(endpointID: endpoint.id, row: .object(["name": .string("default")])))
        messages.control = control
        messages.navigation = RemoteSurface.Coordinator(control)
        view.navigationDelegate = messages.navigation
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow })
        window.addSubview(view)
        let loaded = expectation(description: "Bundled renderer executes in WKWebView with CSP")
        messages.next = { if $0["type"] as? String == "loaded" { loaded.fulfill() } }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Remote"))
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        await fulfillment(of: [loaded], timeout: 60)
        let ready = try await view.evaluateJavaScript("Boolean(window.remote)") as? Bool
        guard ready == true else { throw GatewayError.message("The bundled viewer did not initialize after WebKit startup.") }
        return (view, messages)
    }
    private func call(_ view: WKWebView, _ method: String, _ args: [Any] = []) async throws {
        _ = try await view.callAsyncJavaScript("await window.remote[method](...args)", arguments: ["method": method, "args": args], in: nil, contentWorld: .page)
    }
    func testTerminalAnnouncesActualInitialGeometryAfterNativeSocketOpens() async throws {
        let (view, messages) = try await load()
        defer { view.removeFromSuperview(); view.configuration.userContentController.removeScriptMessageHandler(forName: "remote") }
        let ready = expectation(description: "Terminal ready")
        messages.next = { if $0["type"] as? String == "ready" { ready.fulfill() } }
        try await call(view, "setup", [["kind": "terminal", "generation": "terminal-test"]])
        await fulfillment(of: [ready], timeout: 10)
        messages.received.removeAll()
        let resized = expectation(description: "Resize explicitly emitted on initial open")
        var waitingForInitialResize = true
        messages.next = {
            if waitingForInitialResize && $0["type"] as? String == "resize" {
                waitingForInitialResize = false; resized.fulfill()
            }
        }
        try await call(view, "opened")
        await fulfillment(of: [resized], timeout: 10)
        messages.next = nil
        let frame = try XCTUnwrap(messages.received.first { $0["type"] as? String == "resize" })
        XCTAssertEqual(frame["generation"] as? String, "terminal-test")
        XCTAssertGreaterThan(frame["cols"] as? Int ?? 0, 2)
        XCTAssertLessThan(frame["cols"] as? Int ?? 100, 80)
        try await call(view, "bytes", [Data("\u{1b}[32mphone terminal\u{1b}[0m".utf8).base64EncodedString()])
        _ = try await view.callAsyncJavaScript("await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))", arguments: [:], in: nil, contentWorld: .page)
        let text = try await view.evaluateJavaScript("document.querySelector('.xterm-rows').textContent") as? String
        XCTAssertTrue(text?.contains("phone terminal") == true, "Visible terminal rows: \(String(describing: text))")
        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
            view.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? GatewayError.message("Viewer snapshot failed.")) }
            }
        }
        let attachment = XCTAttachment(image: image); attachment.lifetime = .keepAlways; add(attachment)
    }
    func testBundledNoVNCUsesNativeChannelForRFBHandshake() async throws {
        let (view, messages) = try await load()
        defer { view.removeFromSuperview(); view.configuration.userContentController.removeScriptMessageHandler(forName: "remote") }
        let ready = expectation(description: "Screen ready")
        messages.next = { if $0["type"] as? String == "ready" { ready.fulfill() } }
        try await call(view, "setup", [["kind": "display", "generation": "display-test"]])
        await fulfillment(of: [ready], timeout: 10)
        try await call(view, "opened")
        let bytes = expectation(description: "RFB negotiation travels through native byte bridge")
        messages.next = { if $0["type"] as? String == "bytes" { bytes.fulfill() } }
        try await call(view, "bytes", [Data("RFB 003.008\n".utf8).base64EncodedString()])
        await fulfillment(of: [bytes], timeout: 10)
        messages.next = nil
        let packet = try XCTUnwrap(messages.received.first { $0["type"] as? String == "bytes" })
        XCTAssertEqual(packet["generation"] as? String, "display-test")
        XCTAssertEqual(Data(base64Encoded: packet["data"] as? String ?? ""), Data("RFB 003.008\n".utf8))
        // Complete an unauthenticated Unix-socket RFB handshake behind native gateway auth.
        try await call(view, "bytes", [Data([1, 1]).base64EncodedString()])
        try await call(view, "bytes", [Data([0, 0, 0, 0]).base64EncodedString()])
        let connected = expectation(description: "RFB desktop initialized")
        messages.next = { if $0["type"] as? String == "connected" { connected.fulfill() } }
        var initialization = Data([4, 0, 3, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0, 0, 0, 0, 4])
        initialization.append(Data("test".utf8))
        try await call(view, "bytes", [initialization.base64EncodedString()])
        await fulfillment(of: [connected], timeout: 10)
        messages.next = nil
        _ = try await view.evaluateJavaScript("Array.from(document.querySelectorAll('#tools button')).find(button => button.textContent === '1:1').click()")
        let width = try await view.evaluateJavaScript("document.querySelector('canvas').getBoundingClientRect().width") as? Double
        XCTAssertEqual(try XCTUnwrap(width), 1024, accuracy: 1) // Native guest pixels, clipped by the phone's outer viewport.
        _ = try await view.evaluateJavaScript("Array.from(document.querySelectorAll('#tools button')).find(button => button.textContent === 'Pan').click()")
        let pan = try await view.evaluateJavaScript("Array.from(document.querySelectorAll('#tools button')).find(button => button.textContent === 'Pan').classList.contains('selected')") as? Bool
        XCTAssertEqual(pan, true)
        try await assertLocalPinch(view, messages: messages, controlling: false)
        // Fit then 1:1 resets zoom and scroll before the same gesture with input authority.
        _ = try await view.evaluateJavaScript("Array.from(document.querySelectorAll('#tools button')).find(button => button.textContent === 'Fit').click(); Array.from(document.querySelectorAll('#tools button')).find(button => button.textContent === '1:1').click()")
        try await assertLocalPinch(view, messages: messages, controlling: true)
        // Turn Pan off. A subsequent tap must target the same guest pixel after zoom.
        _ = try await view.evaluateJavaScript("Array.from(document.querySelectorAll('#tools button')).find(button => button.textContent === 'Pan').click()")
        messages.received.removeAll()
        let tapped = expectation(description: "Tap reaches the guest after local zoom")
        var awaitingTap = true
        messages.next = { if awaitingTap && $0["type"] as? String == "bytes" { awaitingTap = false; tapped.fulfill() } }
        _ = try await view.callAsyncJavaScript("""
            const canvas = document.querySelector('canvas'), rect = canvas.getBoundingClientRect();
            canvas.dispatchEvent(new CustomEvent('gesturestart', {detail:{type:'onetap',clientX:rect.left+200,clientY:rect.top+200}}));
            """, arguments: [:], in: nil, contentWorld: .page)
        await fulfillment(of: [tapped], timeout: 10)
        messages.next = nil
        let pointers = messages.received.compactMap { message -> Data? in
            guard message["type"] as? String == "bytes", let raw = message["data"] as? String,
                  let data = Data(base64Encoded: raw), data.first == 5 else { return nil }
            return data
        }
        XCTAssertFalse(pointers.isEmpty)
        for packet in pointers {
            XCTAssertEqual(Int(packet[2]) * 256 + Int(packet[3]), 100)
            XCTAssertEqual(Int(packet[4]) * 256 + Int(packet[5]), 100)
        }
    }

    private func assertLocalPinch(_ view: WKWebView, messages: RendererMessages, controlling: Bool) async throws {
        try await call(view, "control", [controlling])
        _ = try await view.callAsyncJavaScript("await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))", arguments: [:], in: nil, contentWorld: .page)
        messages.received.removeAll()
        let noInput = expectation(description: "Pinch sends no input to the guest")
        noInput.isInverted = true
        messages.next = { if $0["type"] as? String == "bytes" { noInput.fulfill() } }
        // Exercise noVNC's real touch recognizer. Opposing finger motion becomes a local pinch.
        _ = try await view.callAsyncJavaScript("""
            const canvas = document.querySelector('canvas'), rect = canvas.getBoundingClientRect();
            const y = rect.top + 100;
            const touch = (type, fingers) => {
                const event = new Event(type, {bubbles:true,cancelable:true});
                Object.defineProperty(event, 'changedTouches', {value:fingers.map(([identifier,clientX]) => ({identifier,clientX,clientY:y}))});
                canvas.dispatchEvent(event);
            };
            // Each finger must cross noVNC's strict >50px two-touch threshold.
            touch('touchstart', [[0,110],[1,230]]);
            touch('touchmove', [[0,50],[1,290]]);
            touch('touchend', [[0,50],[1,290]]);
            """, arguments: [:], in: nil, contentWorld: .page)
        await fulfillment(of: [noInput], timeout: 0.3)
        messages.next = nil
        let width = try await view.evaluateJavaScript("document.querySelector('canvas').getBoundingClientRect().width") as? Double
        XCTAssertEqual(try XCTUnwrap(width), 2048, accuracy: 1)
        let sent = messages.received.filter { $0["type"] as? String == "bytes" }
        XCTAssertTrue(sent.isEmpty, "Pinch must not send guest pointer, key, wheel, or resize messages.")
    }
}
