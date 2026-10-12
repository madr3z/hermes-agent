import XCTest
@testable import HermesGateway

final class VoiceCallEndRequestTests: XCTestCase {
    func testOnlyExactTypedCurrentCallAndTurnCanEnd() {
        let request: JSON = .object(["call_id": .string("call"), "delegation_id": .string("delegation"), "client_turn_id": .string("turn")])
        XCTAssertTrue(VoiceCallEndRequest.matches(request, callID: "call", delegationID: "delegation", clientTurnID: "turn"))
        XCTAssertFalse(VoiceCallEndRequest.matches(request, callID: "older-call", delegationID: "delegation", clientTurnID: "turn"))
        XCTAssertFalse(VoiceCallEndRequest.matches(request, callID: "call", delegationID: "older-delegation", clientTurnID: "turn"))
        XCTAssertFalse(VoiceCallEndRequest.matches(request, callID: "call", delegationID: "delegation", clientTurnID: "older-turn"))
        XCTAssertFalse(VoiceCallEndRequest.matches(request, callID: "call", delegationID: nil, clientTurnID: nil))
        XCTAssertFalse(VoiceCallEndRequest.matches(.string("request_mobile_contact kind=end_call"), callID: "call", delegationID: "delegation", clientTurnID: "turn"))
    }
}
