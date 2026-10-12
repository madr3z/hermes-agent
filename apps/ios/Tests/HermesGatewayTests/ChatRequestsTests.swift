import XCTest
@testable import HermesGateway

@MainActor final class ChatRequestsTests: XCTestCase {
    func testOnlyOfferedApprovalChoicesAndExactOwnerCanBeAnswered() async throws {
        let frame = Self.approval()
        XCTAssertNil(ChatHumanRequest(frame, runtimeID: "other"))
        let item = try XCTUnwrap(ChatHumanRequest(frame, runtimeID: "runtime"))
        guard case .approval(_, _, _, let choices) = item.kind else { return XCTFail("Approval expected") }
        XCTAssertEqual(choices, ["once", "deny"])
        var calls: [(String, [String: JSON])] = []
        let api = ChatRequestsClient(profile: "writer", sessionID: "runtime") { method, params in
            calls.append((method, params)); return .object(["status": .string("ok")])
        }
        do { _ = try await api.answer(item, choice: "always"); XCTFail("Unadvertised permission") } catch {}
        XCTAssertTrue(calls.isEmpty)
        try await api.received(item)
        let answered = try await api.answer(item, choice: "once")
        XCTAssertTrue(answered)
        XCTAssertEqual(calls.map(\.0), ["approval.received", "request.answer"])
        XCTAssertEqual(calls[0].1["request_id"], .string("queue1"))
        XCTAssertEqual(calls[1].1["id"], .string("srq1"))
        XCTAssertEqual(calls[1].1["result"], .object(["choice": .string("once")]))
        for call in calls {
            XCTAssertEqual(call.1["profile"], .string("writer"))
            XCTAssertEqual(call.1["session_id"], .string("runtime"))
        }
    }
    func testBatchClarifyRestoresLockedAnswersAndUsesExplicitScopedSkipAndCancel() async throws {
        let item = try XCTUnwrap(ChatHumanRequest(Self.clarify(), runtimeID: "runtime"))
        guard case .clarify(let questions, let answers) = item.kind else { return XCTFail("Clarify expected") }
        XCTAssertEqual(questions.map(\.id), ["q1", "q2"])
        XCTAssertEqual(answers["q1"], .string("First answer"))
        let encoded = try XCTUnwrap(questions[1].answer(picks: ["A", "B", "unknown"], text: "Other"))
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(encoded.utf8)), ["A", "B", "Other"])
        XCTAssertEqual(questions[1].displayAnswer(encoded), "A, B, Other")
        var calls: [(String, [String: JSON])] = []
        let api = ChatRequestsClient(profile: "writer", sessionID: "runtime") { method, params in
            calls.append((method, params)); return .object(["status": .string("expired")])
        }
        let locked = try await api.lock(item, questionID: "q2", answer: nil)
        XCTAssertFalse(locked.active)
        let cancelled = try await api.answer(item, cancel: true)
        XCTAssertFalse(cancelled)
        XCTAssertEqual(calls[0].0, "clarify.lock")
        XCTAssertEqual(calls[0].1["answer"], .null)
        XCTAssertEqual(calls[1].1["result"], .object([:]))
        XCTAssertEqual(calls[1].1["session_id"], .string("runtime"))
        do { _ = try await api.lock(item, questionID: "foreign", answer: "x"); XCTFail("Foreign question") } catch {}
        XCTAssertEqual(calls.count, 2)
    }
    static func approval() -> JSON {
        .object(["id": .string("srq1"), "method": .string("approval"), "params": .object([
            "session_id": .string("runtime"), "request_id": .string("queue1"), "command": .string("fixture action"), "allow_permanent": .bool(false), "allow_session": .bool(false), "choices": .array([.string("once"), .string("session"), .string("always"), .string("deny"), .string("unsafe")])
        ])])
    }
    static func clarify() -> JSON {
        .object(["id": .string("srq2"), "method": .string("clarify"), "params": .object([
            "session_id": .string("runtime"), "questions": .array([
                .object(["qid": .string("q1"), "question": .string("First?")]),
                .object(["qid": .string("q2"), "question": .string("Second?"), "choices": .array([.string("A"), .string("B")]), "multi_select": .bool(true)])
            ]), "answers": .object(["q1": .string("First answer")])
        ])])
    }
}
