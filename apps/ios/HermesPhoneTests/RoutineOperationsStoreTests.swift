import XCTest
import HermesGateway
@testable import HermesPhone

@MainActor final class RoutineOperationsStoreTests: XCTestCase {
    func testLostRunResponseStaysBlockedAfterRefreshUntilExplicitOutcomeReview() async throws {
        let store = RoutineOperationsStore()
        var triggers = 0
        let api = RoutineOperationsClient(profile: "writer", jobID: "daily") { path, profile, _, method, _ in
            XCTAssertEqual(profile, "writer")
            if method == "POST" { triggers += 1; throw GatewayError.message("Connection lost") }
            return path.hasSuffix("/runs") ? Self.history() : Self.job()
        }
        store.bind(api); await store.refresh()
        XCTAssertTrue(store.canRun)
        await store.runNow(try XCTUnwrap(store.details))
        XCTAssertTrue(store.uncertainRun)
        XCTAssertFalse(store.canRun)
        await store.refresh()
        XCTAssertTrue(store.uncertainRun)
        XCTAssertFalse(store.canRun)
        await store.runNow(try XCTUnwrap(store.details))
        XCTAssertEqual(triggers, 1)
        XCTAssertTrue(store.canReviewOutcome)
        store.acknowledgeReviewedOutcome()
        XCTAssertTrue(store.canRun)
        XCTAssertEqual(triggers, 1) // Review is not another execution.
    }
    func testDeletedOneShotStillShowsActualHistoryAndLateOwnerReplyIsDropped() async {
        let store = RoutineOperationsStore()
        store.bind(RoutineOperationsClient(profile: "writer", jobID: "daily") { path, _, _, _, _ in
            if !path.hasSuffix("/runs") { throw GatewayError.http(status: 404, message: "Job not found") }
            return Self.history()
        })
        await store.refresh()
        XCTAssertNil(store.details)
        XCTAssertEqual(store.runs.map(\.id), ["cron_daily_20261012_010000"])
        XCTAssertFalse(store.canRun)
        var pending: CheckedContinuation<JSON, Never>?
        store.bind(RoutineOperationsClient(profile: "writer", jobID: "daily") { path, _, _, _, _ in
            if path.hasSuffix("/runs") { return Self.history() }
            return await withCheckedContinuation { pending = $0 }
        })
        let old = Task { await store.refresh() }
        while pending == nil { await Task.yield() }
        store.bind(RoutineOperationsClient(profile: "other", jobID: "daily") { path, _, _, _, _ in
            path.hasSuffix("/runs") ? Self.history(profile: "other") : Self.job(profile: "other")
        })
        await store.refresh()
        pending?.resume(returning: Self.job())
        await old.value
        XCTAssertEqual(store.details?.profile, "other")
        XCTAssertFalse(store.loading)
    }
    static func job(profile: String = "writer") -> JSON {
        .object(["id": .string("daily"), "profile": .string(profile), "strict_profile": .bool(true), "name": .string("Digest"), "prompt": .string("Full task"), "schedule_display": .string("Every day")])
    }
    static func history(profile: String = "writer") -> JSON {
        .object(["profile": .string(profile), "strict_profile": .bool(true), "runs": .array([
            .object(["id": .string("cron_daily_20261012_010000"), "profile": .string(profile), "source": .string("cron"), "title": .string("Recorded result"), "started_at": .number(100), "ended_at": .number(101)])
        ])])
    }
}
