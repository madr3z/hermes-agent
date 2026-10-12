import XCTest
@testable import HermesGateway

final class RoutineOperationsTests: XCTestCase {
    func testEditUsesFullPromptAndOnlyExplicitChangesPreservingAdvancedSettings() throws {
        let job = try RoutineDetails(.object([
            "id": .string("daily"), "profile": .string("writer"), "name": .string("[bot:writer] Digest"), "prompt": .string("Full instructions beyond any preview."),
            "schedule": .object(["kind": .string("cron"), "expr": .string("0 9 * * 1-5")]), "schedule_display": .string("Weekdays 9am"),
            "script": .string("collect.sh"), "model": .string("existing-model"), "deliver": .string("bot-chat"), "repeat": .object(["times": .number(5)])
        ]), profile: "writer", id: "daily")
        var draft = RoutineEditDraft(job)
        XCTAssertEqual(draft.instruction, "Full instructions beyond any preview.")
        XCTAssertEqual(try draft.updates(original: job), [:])
        draft.name = "Morning notes"
        XCTAssertEqual(try draft.updates(original: job), ["name": .string("[bot:writer] Morning notes")])
        draft.changeSchedule = true
        XCTAssertThrowsError(try draft.updates(original: job))
        draft.schedule = "every 2h"
        XCTAssertEqual(Set(try draft.updates(original: job).keys), ["name", "schedule"])
        XCTAssertFalse(try draft.updates(original: job).keys.contains("script"))
        let current = try RoutineDetails(.object(["id": .string("daily"), "profile": .string("writer"), "name": .string("[bot:writer] Digest"), "prompt": .string("Updated on Mac")]), profile: "writer", id: "daily")
        draft.rebase(from: job, to: current)
        XCTAssertEqual(draft.name, "Morning notes")
        XCTAssertEqual(draft.instruction, "Updated on Mac")
    }
    func testForeignJobsAndRunsAreRejectedAndScriptPreviewDoesNotInventAChat() throws {
        let details = JSON.object(["id": .string("daily"), "profile": .string("other"), "prompt": .string("Foreign")])
        XCTAssertThrowsError(try RoutineDetails(details, profile: "writer", id: "daily"))
        let output = JSON.object(["id": .string("cron_output:daily:exec:0"), "profile": .string("writer"), "source": .string("cron_output"), "title": .string("FAILED · Script-only run"), "preview": .string("Actual ledger error")])
        let run = try RoutineRun(output, profile: "writer", jobID: "daily")
        XCTAssertTrue(run.scriptOutput)
        XCTAssertEqual(run.preview, "Actual ledger error")
        XCTAssertThrowsError(try RoutineRun(output, profile: "other", jobID: "daily"))
        XCTAssertThrowsError(try RoutineRun(output, profile: "writer", jobID: "different"))
    }
}

@MainActor final class RoutineOperationsClientTests: XCTestCase {
    func testStrictAcknowledgementGatesWritesAndSparseEditUsesSameOwner() async throws {
        var calls: [(String, String, JSON?, String, [URLQueryItem])] = []
        let row = Self.job()
        let api = RoutineOperationsClient(profile: "writer", jobID: "daily") { path, profile, body, method, query in
            calls.append((path, profile, body, method, query)); return row
        }
        let original = try await api.details()
        var draft = RoutineEditDraft(original); draft.name = "Changed"
        _ = try await api.update(draft, original: original)
        XCTAssertEqual(calls.map(\.3), ["GET", "GET", "PUT"])
        XCTAssertEqual(calls.last?.2, .object(["updates": .object(["name": .string("[bot:writer] Changed")])]))
        XCTAssertTrue(calls.allSatisfy { $0.0 == "api/cron/jobs/daily" && $0.1 == "writer" && $0.4 == [URLQueryItem(name: "strict_profile", value: "true")] })
        var writes = 0
        let old = RoutineOperationsClient(profile: "writer", jobID: "daily") { _, _, _, method, _ in
            if method != "GET" { writes += 1 }
            return .object(["id": .string("daily"), "profile": .string("writer"), "prompt": .string("Full")])
        }
        do { _ = try await old.update(draft, original: original); XCTFail("Missing strict ack") } catch {}
        XCTAssertEqual(writes, 0)
    }
    func testTriggerUncertaintyNeverRetriesAndChangedTaskNeverTriggers() async throws {
        var triggers = 0
        let row = Self.job()
        let api = RoutineOperationsClient(profile: "writer", jobID: "daily") { _, _, _, method, _ in
            if method == "POST" { triggers += 1; throw GatewayError.message("Response lost") }
            return row
        }
        let reviewed = try await api.details()
        do { _ = try await api.runNow(reviewed: reviewed); XCTFail("Lost response") }
        catch { XCTAssertTrue(error is RoutineRunUnconfirmed) }
        XCTAssertEqual(triggers, 1)
        let changed = RoutineOperationsClient(profile: "writer", jobID: "daily") { _, _, _, method, _ in
            if method == "POST" { triggers += 1 }
            return Self.job(prompt: "Changed instructions")
        }
        do { _ = try await changed.runNow(reviewed: reviewed); XCTFail("Changed task") }
        catch { XCTAssertFalse(error is RoutineRunUnconfirmed) }
        XCTAssertEqual(triggers, 1)
    }
    func testHistoryUsesBoundedActualOwnedRowsAndTranscriptIsReadOnly() async throws {
        var paths: [String] = []
        let api = RoutineOperationsClient(profile: "writer", jobID: "daily") { path, profile, body, method, query in
            paths.append(path)
            XCTAssertEqual(profile, "writer"); XCTAssertEqual(method, "GET"); XCTAssertNil(body)
            if path.hasSuffix("/runs") {
                XCTAssertEqual(query.first { $0.name == "limit" }?.value, "20")
                return .object(["profile": .string("writer"), "strict_profile": .bool(true), "runs": .array([
                    .object(["id": .string("cron_daily_20261012_010000"), "profile": .string("writer"), "source": .string("cron")])
                ])])
            }
            return .object(["session_id": .string("cron_daily_20261012_010000"), "profile": .string("writer"), "messages": .array([.object(["id": .number(8), "role": .string("assistant"), "display_content": .string("Actual result")])]), "pagination": .object(["returned": .number(1)])])
        }
        let runs = try await api.runs()
        let transcript = try await api.messages(run: runs[0])
        XCTAssertEqual(transcript.messages.map(\.text), ["Actual result"])
        XCTAssertEqual(paths, ["api/cron/jobs/daily/runs", "api/sessions/cron_daily_20261012_010000/messages"])
        do { _ = try await api.runs(limit: 1000); XCTFail("Unbounded history") } catch {}
        XCTAssertEqual(paths.count, 2)
        let foreign = try RoutineRun(.object(["id": .string("cron_daily_20261012_010000"), "profile": .string("other"), "source": .string("cron")]), profile: "other", jobID: "daily")
        do { _ = try await api.messages(run: foreign); XCTFail("Foreign run must not retarget") } catch {}
        XCTAssertEqual(paths.count, 2)
    }
    static func job(prompt: String = "Full instructions") -> JSON {
        .object(["id": .string("daily"), "profile": .string("writer"), "strict_profile": .bool(true), "name": .string("[bot:writer] Digest"), "prompt": .string(prompt), "schedule_display": .string("Every day"), "enabled": .bool(false), "state": .string("paused")])
    }
}
