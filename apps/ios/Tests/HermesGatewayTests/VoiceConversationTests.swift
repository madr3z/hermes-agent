import XCTest
@testable import HermesGateway

final class VoiceConversationTests: XCTestCase {
    func testOverlappingStreamsKeepSpeakerIdentityAndStableUtterancesWithoutReplay() throws {
        var conversation = VoiceConversation()
        let first = try XCTUnwrap(conversation.append(speaker: "assistant", text: "I’m calling about ", startMS: 0, endMS: 1000, eventID: "a"))
        _ = try conversation.append(speaker: "user", text: "Yes?", startMS: 400, endMS: 900, eventID: "b")
        let continued = try XCTUnwrap(conversation.append(speaker: "assistant", text: "your appointment.", startMS: 1000, endMS: 2000, eventID: "c"))
        XCTAssertEqual(first.id, continued.id)
        XCTAssertEqual(conversation.turns.map(\.speaker), ["assistant", "user"])
        XCTAssertEqual(conversation.turns.first?.text, "I’m calling about your appointment.")
        XCTAssertNil(try conversation.append(speaker: "user", text: "Yes?", startMS: 400, endMS: 900, eventID: "b"))
        _ = try conversation.append(speaker: "user", text: "Please continue.", startMS: 4000, endMS: 5000, eventID: "d")
        XCTAssertEqual(conversation.turns.count, 3)
    }
    func testOpeningWaitsForReadyAndCannotSpeakTwice() {
        var opening = VoiceOpening(reason: "Your appointment changed.")
        XCTAssertNil(opening.event(sessionReady: false))
        let event = opening.event(sessionReady: true)
        XCTAssertEqual(event?["type"]?.string, "session.commentary.append")
        XCTAssertEqual(event?["content"]?.string, "I’m calling because Your appointment changed.")
        XCTAssertEqual(event?["delegation_id"], .null)
        XCTAssertNil(opening.event(sessionReady: true))
        var outgoing = VoiceOpening()
        XCTAssertNil(outgoing.event(sessionReady: true))
    }
    func testEndClearsIncomingPanelAndStaleEndCannotDismissNewCall() throws {
        func push() throws -> MobilePush {
            try MobilePush(.object(["controller_id": .string(UUID().uuidString), "invitation_id": .string(UUID().uuidString), "expires_at": .number(Date().timeIntervalSince1970 + 60)]))
        }
        let first = try push(), second = try push()
        var state = IncomingCallPresentation()
        state.begin(first); state.accept(first.invitationID); state.isPresented = false
        XCTAssertTrue(state.accepted)
        XCTAssertNotNil(state.invitation)
        state.begin(second)
        XCTAssertFalse(state.finish(first.invitationID))
        XCTAssertTrue(state.isPresented)
        XCTAssertTrue(state.finish(second.invitationID))
        XCTAssertNil(state.invitation)
        XCTAssertFalse(state.accepted)
        XCTAssertFalse(state.isPresented)
    }
}
