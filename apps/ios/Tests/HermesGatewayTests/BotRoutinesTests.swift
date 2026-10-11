import XCTest
@testable import HermesGateway

@MainActor final class BotRoutinesTests: XCTestCase {
    private func job(_ enabled: Bool = true) -> JSON {
        .object(["job_id": .string("job-one"), "name": .string("[bot:writer] Digest"), "enabled": .bool(enabled),
                 "schedule": .string("every 1d"), "last_status": .string("error"), "last_delivery_error": .string("Delivery unavailable")])
    }
    func testListingIncludesPausedAndMutationsUseOnlyExactSelectedProfileAndJobID() async throws {
        var calls: [[String: JSON]] = []
        let api = BotRoutinesClient(profile: "writer") { method, params in
            XCTAssertEqual(method, "cron.manage")
            calls.append(params)
            if params["action"] == .string("list") {
                return .object(["scoped": .string("writer"), "jobs": .array([self.job()])])
            }
            return .object(["success": .bool(true)])
        }
        let listed = try await api.list()
        XCTAssertEqual(listed.first?.displayName(profile: "writer"), "Digest")
        XCTAssertEqual(listed.first?.lastError, "Delivery unavailable")
        _ = try await api.setEnabled(id: "job-one", enabled: false)
        _ = try await api.remove(id: "job-one")
        XCTAssertTrue(calls.allSatisfy { $0["profile"] == .string("writer") })
        XCTAssertTrue(calls.filter { $0["action"] == .string("list") }.allSatisfy { $0["include_disabled"] == .bool(true) })
        XCTAssertEqual(calls.filter { $0["action"] != .string("list") }.map { $0["name"] }, [.string("job-one"), .string("job-one")])
        XCTAssertEqual(calls.map { $0["action"] }, [.string("list"), .string("list"), .string("pause"), .string("list"), .string("remove")])
    }
    func testUnconfirmedOrWrongProfileListsAndVanishedJobsNeverReachMutation() async {
        for scoped in [JSON.null, .string("other")] {
            var calls: [[String: JSON]] = []
            let api = BotRoutinesClient(profile: "writer") { _, params in
                calls.append(params)
                return .object(["scoped": scoped, "jobs": .array([self.job()])])
            }
            do { _ = try await api.remove(id: "job-one"); XCTFail("Unscoped list must fail closed") } catch {}
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls[0]["action"], .string("list"))
        }
        var writes = 0
        let api = BotRoutinesClient(profile: "writer") { _, params in
            if params["action"] != .string("list") { writes += 1 }
            return .object(["scoped": .string("writer"), "jobs": .array([])])
        }
        do { _ = try await api.setEnabled(id: "gone", enabled: true); XCTFail("Missing job must not mutate") } catch {}
        XCTAssertEqual(writes, 0)
    }
    func testCreateUsesBotChatAndStableAbsoluteTimeOrExplicitIntervals() async throws {
        var draft = BotRoutineDraft(); draft.name = " Digest "; draft.instruction = " Summarize local notes. "
        draft.frequency = .once; draft.date = Date(timeIntervalSince1970: 2_000_000_000)
        let params = try draft.parameters(profile: "writer", now: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(params["schedule"], .string("2033-05-18T03:33:20Z"))
        XCTAssertEqual(params["name"], .string("[bot:writer] Digest"))
        XCTAssertEqual(params["prompt"], .string("Summarize local notes."))
        XCTAssertEqual(params["deliver"], .string("bot-chat"))
        XCTAssertEqual(params["continuity"], .bool(false))
        for (frequency, schedule) in [(RoutineFrequency.hourly, "every 1h"), (.daily, "every 1d"), (.weekly, "every 7d")] {
            draft.frequency = frequency
            XCTAssertEqual(try draft.parameters(profile: "writer")["schedule"], .string(schedule))
        }
        var calls: [[String: JSON]] = []
        let api = BotRoutinesClient(profile: "writer") { _, params in
            calls.append(params)
            return .object(["scoped": .string("writer"), "jobs": .array([]), "success": .bool(true)])
        }
        _ = try await api.create(draft)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1]["profile"], .string("writer"))
        XCTAssertEqual(calls[1]["deliver"], .string("bot-chat"))
    }
    func testToolLevelFailureAndUncertainCreateAreNotRetried() async {
        var draft = BotRoutineDraft(); draft.name = "Task"; draft.instruction = "Read notes"
        var adds = 0
        let api = BotRoutinesClient(profile: "writer") { _, params in
            if params["action"] == .string("list") { return .object(["scoped": .string("writer"), "jobs": .array([])]) }
            adds += 1
            throw GatewayError.message("Lost acknowledgement")
        }
        do { _ = try await api.create(draft); XCTFail("Uncertain result must surface") } catch {}
        XCTAssertEqual(adds, 1)
        let failure = BotRoutinesClient(profile: "writer") { _, _ in .object(["success": .bool(false), "error": .string("Scheduler unavailable")]) }
        do { _ = try await failure.list(); XCTFail("Tool error is not an empty list") }
        catch { XCTAssertEqual(error.localizedDescription, "Scheduler unavailable") }
    }
}
