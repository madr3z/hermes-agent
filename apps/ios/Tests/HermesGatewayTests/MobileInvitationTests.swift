import XCTest
@testable import HermesGateway

final class MobileInvitationTests: XCTestCase {
    let controller = UUID(), invitation = UUID(), guest = UUID()
    func payload(now: Date) -> JSON { .object(["controller_id": .string(controller.uuidString), "invitation_id": .string(invitation.uuidString), "expires_at": .number(now.timeIntervalSince1970 + 60)]) }
    func resolved(now: Date, state: String = "pending") -> JSON { .object(["invitation_id": .string(invitation.uuidString), "guest_id": .string(guest.uuidString), "profile": .string("default"), "kind": .string("call"), "state": .string(state), "expires_at": .number(now.timeIntervalSince1970 + 60), "name": .string("Research"), "reason": .string("Ready to discuss")]) }
    func testPushCannotSupplyDestinationOrBypassOwnershipAndExpiry() throws {
        let now = Date(), push = try MobilePush(payload(now: Date()))
        XCTAssertEqual(push.controllerID, controller)
        XCTAssertTrue(push.isCurrent(at: now))
        XCTAssertThrowsError(try MobileInvitation(resolved(now: now), push: push, allowedGuests: []))
        XCTAssertThrowsError(try MobileInvitation(resolved(now: now), push: push, allowedGuests: [guest], now: now.addingTimeInterval(61)))
        XCTAssertThrowsError(try MobilePush(.object(["controller_id": .string("https://untrusted.example"), "invitation_id": .string(invitation.uuidString), "expires_at": .number(9999999999)])))
    }
    func testAnswerRequiresAuthenticatedAcceptedCallForExactInvitationAndBot() throws {
        let now = Date(), push = try MobilePush(payload(now: now))
        XCTAssertThrowsError(try MobileInvitation(resolved(now: now), push: push, allowedGuests: [guest], accepting: true))
        let accepted = try MobileInvitation(resolved(now: now, state: "accepted"), push: push, allowedGuests: [guest], accepting: true)
        XCTAssertEqual(accepted.guestID, guest)
        XCTAssertEqual(accepted.profile, "default")
        guard case .object(var foreign) = resolved(now: now, state: "accepted") else { return XCTFail("Missing fixture") }
        foreign["invitation_id"] = .string(UUID().uuidString)
        XCTAssertThrowsError(try MobileInvitation(.object(foreign), push: push, allowedGuests: [guest], accepting: true))
        foreign["invitation_id"] = .string(invitation.uuidString); foreign["profile"] = .string("other")
        XCTAssertThrowsError(try MobileInvitation(.object(foreign), push: push, allowedGuests: [guest], accepting: true))
    }
    func testDeferredCallRequiresAuthenticatedBotAndScheduledState() throws {
        let due = Date().addingTimeInterval(900)
        var fields: [String: JSON] = ["invitation_id": .string(invitation.uuidString), "guest_id": .string(guest.uuidString), "profile": .string("default"), "kind": .string("call"), "state": .string("postponed"), "deferred_state": .string("scheduled"), "scheduled_at": .number(due.timeIntervalSince1970)]
        let call = try MobileDeferredCall(.object(fields), controllerID: controller, allowedGuests: [guest])
        XCTAssertEqual(call.id, invitation)
        XCTAssertEqual(call.controllerID, controller)
        XCTAssertEqual(call.scheduledAt.timeIntervalSince1970, due.timeIntervalSince1970, accuracy: 0.000001)
        XCTAssertThrowsError(try MobileDeferredCall(.object(fields), controllerID: controller, allowedGuests: []))
        fields["deferred_state"] = .string("cancelled")
        XCTAssertThrowsError(try MobileDeferredCall(.object(fields), controllerID: controller, allowedGuests: [guest]))
    }
    func testCustomRingTimeIsBoundedAndFinite() throws {
        let now = Date()
        try MobileDeferredCall.validateTime(now.addingTimeInterval(900), now: now)
        try MobileDeferredCall.validateTime(now.addingTimeInterval(3600), now: now)
        XCTAssertThrowsError(try MobileDeferredCall.validateTime(now.addingTimeInterval(59), now: now))
        XCTAssertThrowsError(try MobileDeferredCall.validateTime(now.addingTimeInterval(7 * 86400 + 1), now: now))
        XCTAssertThrowsError(try MobileDeferredCall.validateTime(Date(timeIntervalSince1970: .infinity), now: now))
    }
}
