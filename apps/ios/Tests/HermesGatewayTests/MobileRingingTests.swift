import XCTest
@testable import HermesGateway

final class MobileRingingTests: XCTestCase {
    private let controller = UUID(), invitation = UUID(), guest = UUID()
    private func push(expires: Date) throws -> MobilePush {
        try MobilePush(.object(["controller_id": .string(controller.uuidString), "invitation_id": .string(invitation.uuidString), "expires_at": .number(expires.timeIntervalSince1970)]))
    }
    private func resolved(_ push: MobilePush, state: String = "pending", guest: UUID? = nil, now: Date) throws -> MobileInvitation {
        try MobileInvitation(.object(["invitation_id": .string(invitation.uuidString), "guest_id": .string((guest ?? self.guest).uuidString), "profile": .string("default"), "kind": .string("call"), "state": .string(state), "expires_at": .number(push.expiresAt.timeIntervalSince1970)]), push: push, allowedGuests: [self.guest], now: now)
    }
    func testTemporaryReadFailuresRecoverWithoutAnsweringOrChangingDeadline() async throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let incoming = try push(expires: clock.addingTimeInterval(60))
        var reads = 0, waits = 0
        let result = try await MobileInvitationLookup.ringing(incoming, now: { clock }, pause: {
            waits += 1; clock.addTimeInterval(3)
        }) {
            reads += 1
            switch reads {
            case 1: throw URLError(.networkConnectionLost)
            case 2: throw GatewayError.http(status: 503, message: "Unavailable")
            case 3: throw URLError(.cancelled)
            default: return try self.resolved(incoming, now: clock)
            }
        }
        XCTAssertEqual(result.state, "pending")
        XCTAssertEqual(reads, 4); XCTAssertEqual(waits, 3)
        XCTAssertEqual(incoming.expiresAt.timeIntervalSince1970, 1060)
        var presentation = IncomingCallPresentation(); presentation.begin(incoming)
        XCTAssertTrue(presentation.isPresented); XCTAssertFalse(presentation.accepted)
    }
    func testOriginalDeadlineAndTerminalRejectionsStopReads() async throws {
        let start = Date(timeIntervalSince1970: 1000)
        let incoming = try push(expires: start.addingTimeInterval(6))
        var clock = start, reads = 0
        do {
            _ = try await MobileInvitationLookup.ringing(incoming, now: { clock }, pause: { clock.addTimeInterval(3) }) {
                reads += 1; throw URLError(.timedOut)
            }
            XCTFail("The original expiry must end retries")
        } catch { XCTAssertEqual(reads, 2); XCTAssertEqual(clock, incoming.expiresAt) }
        for state in ["expired", "cancelled", "accepted", "ended"] {
            reads = 0
            do {
                _ = try await MobileInvitationLookup.ringing(incoming, now: { start }, pause: { XCTFail("Terminal state retried") }) {
                    reads += 1; return try self.resolved(incoming, state: state, now: start)
                }
                XCTFail("Terminal state accepted")
            } catch { XCTAssertEqual(reads, 1) }
        }
        for status in [401, 403, 404, 409] {
            reads = 0
            do {
                _ = try await MobileInvitationLookup.ringing(incoming, now: { start }, pause: { XCTFail("Authentication or ownership failure retried") }) {
                    reads += 1; throw GatewayError.http(status: status, message: "Rejected")
                }
                XCTFail("Rejected read accepted")
            } catch { XCTAssertEqual(reads, 1) }
        }
        do {
            _ = try await MobileInvitationLookup.ringing(incoming, now: { start }, pause: { XCTFail("Foreign owner retried") }) {
                try self.resolved(incoming, guest: UUID(), now: start)
            }
            XCTFail("Foreign invitation accepted")
        } catch {}
    }
    @MainActor func testExplicitCancellationAndStaleReadCannotDismissNewInvitation() async throws {
        let clock = Date(timeIntervalSince1970: 1000)
        let first = try push(expires: clock.addingTimeInterval(60))
        let second = try MobilePush(.object(["controller_id": .string(controller.uuidString), "invitation_id": .string(UUID().uuidString), "expires_at": .number(first.expiresAt.timeIntervalSince1970)]))
        var presentation = IncomingCallPresentation(); presentation.begin(first)
        let started = expectation(description: "Old status read started")
        var pending: CheckedContinuation<MobileInvitation, Error>?
        let read = Task {
            try await MobileInvitationLookup.ringing(first, now: { clock }, pause: { XCTFail("Canceled call retried") }) {
                try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(presentation.finish(first.invitationID))
        read.cancel()
        presentation.begin(second)
        pending?.resume(throwing: URLError(.cancelled))
        do { _ = try await read.value; XCTFail("Explicit cancellation was ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(presentation.finish(first.invitationID))
        XCTAssertEqual(presentation.invitation, second)
        XCTAssertTrue(presentation.isPresented); XCTAssertFalse(presentation.accepted)
    }
}
