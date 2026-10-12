import XCTest
import HermesGateway
@testable import HermesPhone

final class RaiseToCallGestureTests: XCTestCase {
    private func lower(_ gesture: inout RaiseToCallGesture, at time: Double = 0) {
        XCTAssertFalse(gesture.update(time: time, near: false, gravityY: -0.4, gravityZ: -0.9, acceleration: 0, rotation: 0, eligible: true))
        XCTAssertFalse(gesture.update(time: time + 0.3, near: false, gravityY: -0.7, gravityZ: -0.6, acceleration: 0.2, rotation: 1, eligible: true))
    }
    private func near(_ gesture: inout RaiseToCallGesture, at time: Double, eligible: Bool = true) -> Bool {
        gesture.update(time: time, near: true, gravityY: -0.95, gravityZ: -0.1, acceleration: 0, rotation: 0, eligible: eligible)
    }
    func testRaiseNeedsMovementAndSustainedNearUprightPosition() {
        var gesture = RaiseToCallGesture()
        XCTAssertFalse(near(&gesture, at: 0))
        lower(&gesture)
        XCTAssertFalse(near(&gesture, at: 0.4))
        XCTAssertTrue(near(&gesture, at: 0.7))
        XCTAssertFalse(near(&gesture, at: 1))
        XCTAssertFalse(near(&gesture, at: 2))
        lower(&gesture, at: 3)
        XCTAssertFalse(near(&gesture, at: 3.4))
        XCTAssertTrue(near(&gesture, at: 3.7))
    }
    func testCoveredSensorAndPocketPositionCannotStartCall() {
        var gesture = RaiseToCallGesture()
        for time in stride(from: 0.0, through: 2, by: 0.1) { XCTAssertFalse(near(&gesture, at: time)) }
        lower(&gesture, at: 3)
        XCTAssertFalse(gesture.update(time: 3.4, near: true, gravityY: 0.9, gravityZ: 0, acceleration: 0.3, rotation: 1, eligible: true))
        XCTAssertFalse(near(&gesture, at: 3.8))
    }
    func testInactiveDisabledLockedOrOccupiedResetsGestureAndCannotRetriggerAtEar() {
        var gesture = RaiseToCallGesture()
        lower(&gesture)
        XCTAssertFalse(near(&gesture, at: 0.4))
        XCTAssertFalse(near(&gesture, at: 0.6, eligible: false))
        XCTAssertFalse(near(&gesture, at: 0.9))
        XCTAssertFalse(near(&gesture, at: 1.3))
    }
    func testMotionLongAfterLoweredPositionCannotArmRaise() {
        var gesture = RaiseToCallGesture()
        XCTAssertFalse(gesture.update(time: 0, near: false, gravityY: -0.4, gravityZ: -0.9, acceleration: 0, rotation: 0, eligible: true))
        XCTAssertFalse(gesture.update(time: 5, near: false, gravityY: -0.95, gravityZ: -0.1, acceleration: 0.2, rotation: 1, eligible: true))
        XCTAssertFalse(near(&gesture, at: 5.1)); XCTAssertFalse(near(&gesture, at: 5.5))
    }
    func testStaleMovementAndNearWithoutMovementCannotTrigger() {
        var gesture = RaiseToCallGesture()
        lower(&gesture)
        XCTAssertFalse(near(&gesture, at: 2))
        XCTAssertFalse(gesture.update(time: 3, near: false, gravityY: -0.4, gravityZ: -0.9, acceleration: 0, rotation: 0, eligible: true))
        XCTAssertFalse(near(&gesture, at: 3.4)); XCTAssertFalse(near(&gesture, at: 3.8))
    }
}

@MainActor final class RaiseToCallTargetTests: XCTestCase {
    private func bot(_ endpoint: GatewayEndpoint, profile: String) -> Bot {
        Bot(endpointID: endpoint.id, row: .object(["name": .string(profile), "display_name": .string("Same name")]))
    }
    func testVisibleChatWinsDefaultAndOtherPagesReturnToExactSavedTarget() throws {
        let suite = "raise-tests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = PhoneStore(preferences: preferences)
        let first = try GatewayEndpoint(label: "First", baseURL: XCTUnwrap(URL(string: "https://first.example")))
        let second = try GatewayEndpoint(label: "Second", baseURL: XCTUnwrap(URL(string: "https://second.example")))
        store.endpoints = [first, second]
        let chat = ChatStore(bot: bot(first, profile: "chat-profile"))
        let controller = RaiseToCallController(preferences: preferences)
        let saved = RaiseCallTarget(bot: bot(second, profile: "default-profile"), endpoint: second)
        controller.defaultTarget = saved
        controller.showChat(chat)
        XCTAssertEqual(controller.selectedTarget(in: store)?.endpointID, first.id)
        XCTAssertEqual(controller.selectedTarget(in: store)?.profile, "chat-profile")
        controller.hideChat(chat)
        XCTAssertEqual(controller.selectedTarget(in: store), saved)
        let restored = RaiseToCallController(preferences: preferences)
        XCTAssertEqual(restored.defaultTarget, saved)
        controller.enabled = false
        XCTAssertFalse(RaiseToCallController(preferences: preferences).enabled)
    }
    func testMissingChatGatewayNeverFallsBackAndChangedGatewayCannotMatchSavedAgent() throws {
        let suite = "raise-tests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = PhoneStore(preferences: preferences)
        let endpoint = try GatewayEndpoint(label: "Original", baseURL: XCTUnwrap(URL(string: "https://original.example")))
        let agent = bot(endpoint, profile: "owned")
        let target = RaiseCallTarget(bot: agent, endpoint: endpoint)
        let controller = RaiseToCallController(preferences: preferences)
        controller.defaultTarget = target
        controller.showChat(ChatStore(bot: agent))
        XCTAssertNil(controller.selectedTarget(in: store))
        XCTAssertFalse(target.matches(agent, endpoints: []))
        let changed = try GatewayEndpoint(id: endpoint.id, label: "Changed", baseURL: XCTUnwrap(URL(string: "https://changed.example")))
        XCTAssertFalse(target.matches(agent, endpoints: [changed]))
        XCTAssertFalse(target.matches(bot(endpoint, profile: "different"), endpoints: [endpoint]))
    }
    func testForegroundDisabledControllerDoesNotMonitorOrStartCall() {
        let suite = "raise-tests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let controller = RaiseToCallController(preferences: preferences)
        controller.enabled = false
        controller.configure(store: PhoneStore(preferences: preferences), foreground: true)
        controller.beginCall()
        XCTAssertFalse(controller.pending)
        XCTAssertNil(controller.error)
        controller.configure(store: PhoneStore(preferences: preferences), foreground: false)
    }
}
