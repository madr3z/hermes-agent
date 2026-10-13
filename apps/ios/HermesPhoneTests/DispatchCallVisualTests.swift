import XCTest
import SwiftUI
import HermesGateway
@testable import HermesPhone

/// Synthetic visual fixtures only. No gateway, microphone, audio route, or outbox is opened.
@MainActor final class DispatchCallVisualTests: XCTestCase {
    private enum State: Equatable {
        case incoming, preparing, ready, active, muted, reconnecting, ended
    }

    func testCaptureCallStatesForVisualReview() async throws {
        let fixtures: [(String, State, ColorScheme, DynamicTypeSize)] = [
            ("incoming", .incoming, .light, .large),
            ("preparing", .preparing, .light, .large),
            ("outgoing", .ready, .light, .large),
            ("active", .active, .light, .large),
            ("muted-dark", .muted, .dark, .large),
            ("reconnecting", .reconnecting, .light, .large),
            ("ended", .ended, .light, .large),
            ("incoming-accessible", .incoming, .light, .accessibility3),
            ("active-accessible", .active, .light, .accessibility3)
        ]
        for (name, state, scheme, size) in fixtures {
            let voice = await fixtureVoice(state)
            defer { voice.stop() }
            let content = CallScreen(
                voice: voice, name: "Assistant",
                reason: state == .ready ? nil : "Your appointment moved to Thursday. Let’s find a time that works for you.",
                ringing: state == .incoming, preparing: state == .preparing,
                onStart: state == .ready ? {} : nil,
                onAnswer: {}, onLater: {}, onEnd: {}, onClose: {})
                .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size)
            try await capture(content, name: name, scheme: scheme)
        }
    }

    func testCaptureMinimizedCallForVisualReview() async throws {
        let content = VStack {
            Spacer()
            CallSummary(name: "Assistant", status: "Microphone muted", endLabel: "End call", onReturn: {}, onEnd: {})
            Spacer()
        }.background(DispatchStyle.paper)
        try await capture(content, name: "minimized", scheme: .light)
    }

    private func fixtureVoice(_ state: State) async -> VoiceCall {
        let voice = VoiceCall()
        if [.active, .muted, .reconnecting, .ended].contains(state) {
            await voice.receive(.object([
                "type": .string("session.output_transcript.delta"), "event_id": .string("synthetic-assistant"),
                "delta": .string("Your appointment moved to Thursday. Would the afternoon work?"),
                "start_ms": .number(0), "end_ms": .number(1000)
            ]))
            await voice.receive(.object([
                "type": .string("session.input_transcript.delta"), "event_id": .string("synthetic-user"),
                "delta": .string("Yes, after two would be good."),
                "start_ms": .number(1200), "end_ms": .number(2200)
            ]))
            voice.active = true
        }
        voice.muted = state == .muted
        if state == .reconnecting { voice.connectionChanged(.disconnected) }
        if state == .ended { voice.stop() }
        return voice
    }

    private func capture<V: View>(_ content: V, name: String, scheme: ColorScheme) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: content)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let laidOut = expectation(description: "Call fixture laid out")
        DispatchQueue.main.async { host.view.layoutIfNeeded(); laidOut.fulfill() }
        await fulfillment(of: [laidOut], timeout: 5)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        var drawn = false
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            drawn = host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn, "Capture must include the live SwiftUI scroll hierarchy")
        XCTAssertEqual(image.size, CGSize(width: 390, height: 844))
        let attachment = XCTAttachment(image: image)
        attachment.name = "dispatch-call-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-call-\(name).png")
        try XCTUnwrap(image.pngData()).write(to: destination)
        print("DISPATCH_CALL_RENDER \(destination.path)")
    }
}
