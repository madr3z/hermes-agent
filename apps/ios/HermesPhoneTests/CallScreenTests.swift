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
    func testReconnectRecoversAndFailureRetainsTranscript() async {
        let voice = VoiceCall()
        await voice.receive(.object(["type": .string("session.started")]))
        await voice.receive(.object(["type": .string("session.output_transcript.delta"), "event_id": .string("a"), "delta": .string("Your appointment changed."), "start_ms": .number(0), "end_ms": .number(1000)]))
        voice.connectionChanged(.disconnected)
        XCTAssertEqual(voice.activity, "Reconnecting…")
        voice.connectionChanged(.connected)
        XCTAssertEqual(voice.activity, "Listening")
        XCTAssertTrue(voice.active)
        voice.connectionChanged(.failed)
        XCTAssertFalse(voice.active)
        XCTAssertNotNil(voice.error)
        XCTAssertEqual(voice.turns.first?.text, "Your appointment changed.")
    }
}
