import XCTest
import SwiftUI
import HermesGateway
@testable import HermesPhone

@MainActor final class CallScreenTests: XCTestCase {
    func testTranscriptEventsKeepBothSpeakersAndIgnoreReplay() async {
        let voice = VoiceCall()
        let input: JSON = .object(["type": .string("session.input_transcript.delta"), "event_id": .string("human-1"), "delta": .string("What changed?"), "start_ms": .number(0), "end_ms": .number(1000)])
        let output: JSON = .object(["type": .string("session.output_transcript.delta"), "event_id": .string("bot-1"), "delta": .string("Your appointment moved to Thursday."), "start_ms": .number(1200), "end_ms": .number(2400)])
        await voice.receive(input); await voice.receive(output); await voice.receive(input)
        XCTAssertEqual(voice.turns.map(\.speaker), ["user", "assistant"])
        XCTAssertEqual(voice.turns.map(\.text), ["What changed?", "Your appointment moved to Thursday."])
        voice.stop()
        XCTAssertEqual(voice.turns.count, 2, "Ending a call keeps its final transcript visible")
        XCTAssertEqual(voice.activity, "Call ended")
    }
    func testIncomingActiveAndEndedScreensRenderWithoutAProvider() async throws {
        let voice = VoiceCall()
        render(CallScreen(voice: voice, name: "Assistant", reason: "Your appointment moved to Thursday. I’d like to confirm the new time.", ringing: true,
                          onAnswer: {}, onLater: {}, onEnd: {}, onClose: {}), name: "incoming")
        await voice.receive(.object(["type": .string("session.started")]))
        await voice.receive(.object(["type": .string("session.output_transcript.delta"), "event_id": .string("a"), "delta": .string("I’m calling because your appointment moved to Thursday. Does 2 pm still work for you?"), "start_ms": .number(0), "end_ms": .number(3000)]))
        await voice.receive(.object(["type": .string("session.input_transcript.delta"), "event_id": .string("b"), "delta": .string("Yes, that works. Please update my calendar."), "start_ms": .number(3200), "end_ms": .number(5000)]))
        render(CallScreen(voice: voice, name: "Assistant", onEnd: {}, onClose: {}), name: "active-transcript")
        voice.muted = true
        render(CallScreen(voice: voice, name: "Assistant", onEnd: {}, onClose: {}), name: "muted")
        voice.stop(); voice.error = "The connection was lost. Your transcript is retained on this phone until it can sync."
        render(CallScreen(voice: voice, name: "Assistant", onStart: {}, onEnd: {}, onClose: {}), name: "ended-error")
    }
    private func render<V: View>(_ view: V, name: String) {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "call-" + name; attachment.lifetime = .keepAlways; add(attachment)
        window.isHidden = true
    }
}
