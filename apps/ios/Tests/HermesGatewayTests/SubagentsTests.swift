import XCTest
@testable import HermesGateway

@MainActor final class SubagentsTests: XCTestCase {
    private func row(_ controls: Bool = true, status: String = "running") -> JSON {
        .object(["subagent_id": .string("child-a"), "goal": .string("Read project notes"), "status": .string(status),
                 "tool_count": .number(3), "last_tool": .string("terminal"), "can_interrupt": .bool(controls), "can_steer": .bool(controls),
                 "summary": .string("Found the release notes")])
    }
    func testSnapshotRestoresResultsAndControlsRequireExplicitLiveAuthority() async throws {
        let live = try SubagentTask(row())
        XCTAssertEqual(live.toolCount, 3); XCTAssertTrue(live.canSteer); XCTAssertTrue(live.canInterrupt)
        let reconstructed = try SubagentTask(row(false))
        XCTAssertFalse(reconstructed.canSteer); XCTAssertFalse(reconstructed.canInterrupt)
        let completed = try SubagentTask(row(status: "completed"))
        XCTAssertEqual(completed.summary, "Found the release notes")
        XCTAssertFalse(completed.canInterrupt); XCTAssertFalse(completed.canSteer)
        let legacy = try SubagentTask(.object(["subagent_id": .string("legacy"), "status": .string("running"), "accepting_steer": .bool(true)]))
        XCTAssertFalse(legacy.canSteer)
        var mutations = 0
        let api = SubagentsClient(profile: "writer", sessionID: "runtime-a") { _, _ in mutations += 1; return .null }
        do { _ = try await api.interrupt(reconstructed); XCTFail("View-only child cannot mutate") } catch {}
        do { _ = try await api.steer(completed, text: "Continue"); XCTFail("Completed child cannot mutate") } catch {}
        XCTAssertEqual(mutations, 0)
    }
    func testRequestsKeepExactChatProfileAndChildWithNoUncertainReplay() async throws {
        var calls: [(String, [String: JSON])] = []
        let api = SubagentsClient(profile: "writer", sessionID: "runtime-a") { method, params in
            calls.append((method, params))
            switch method {
            case "subagent.list": return .object(["subagents": .array([self.row()])])
            case "subagent.steer": return .object(["status": .string("queued")])
            default: throw GatewayError.message("Lost acknowledgement")
            }
        }
        let listed = try await api.list()
        let task = try XCTUnwrap(listed.first)
        _ = try await api.steer(task, text: " Use the new notes. ")
        do { _ = try await api.interrupt(task); XCTFail("Uncertain result must surface") } catch {}
        XCTAssertEqual(calls.map(\.0), ["subagent.list", "subagent.steer", "subagent.interrupt"])
        XCTAssertTrue(calls.allSatisfy { $0.1["profile"] == .string("writer") && $0.1["session_id"] == .string("runtime-a") })
        XCTAssertEqual(calls[1].1["subagent_id"], .string("child-a"))
        XCTAssertEqual(calls[1].1["text"], .string("Use the new notes."))
    }
}
