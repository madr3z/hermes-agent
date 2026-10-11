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
}
