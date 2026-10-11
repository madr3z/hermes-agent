import XCTest
@testable import HermesGateway

@MainActor final class BotCapabilitiesTests: XCTestCase {
    private func inventory(provider: String = "configured") -> JSON {
        .object(["provider": .string(provider), "model": .string("old-model"), "providers": .array([
            .object(["slug": .string(provider), "name": .string("Configured provider"), "authenticated": .bool(true),
                     "models": .array([.string("old-model"), .string("new-model"), .string("unavailable")]),
                     "unavailable_models": .array([.string("unavailable")])])])])
    }
    func testSkillsAndReadinessStayOnSelectedBotAndNeverReloadPrompt() async throws {
        var calls: [(String, [String: JSON])] = []
        let api = BotCapabilitiesClient(profile: "writer", runtimeID: "runtime") { method, params in
            calls.append((method, params))
            if method == "skills.manage" { return .object(["skills": .object(["writing": .array([.string("proofread")]), "research": .array([.string("search")])])]) }
            if method == "model.options" { return self.inventory() }
            return .object(["ok": .bool(true), "profile": .string("writer")])
        }
        let skills = try await api.skills()
        XCTAssertEqual(skills.map(\.name), ["search", "proofread"])
        let models = try await api.models()
        XCTAssertEqual(models.availableModels, ["old-model", "new-model"])
        _ = try await api.readiness()
        XCTAssertTrue(calls.allSatisfy { $0.1["profile"] == .string("writer") })
        XCTAssertEqual(calls.map(\.0), ["skills.manage", "model.options", "setup.runtime_check"])
        XCTAssertEqual(calls[1].1["session_id"], .string("runtime"))
    }
    func testModelSelectionKeepsProviderSessionScopeAndServerCostConfirmation() async throws {
        var writes: [[String: JSON]] = []
        let api = BotCapabilitiesClient(profile: "writer", runtimeID: "runtime") { method, params in
            if method == "model.options" { return self.inventory() }
            writes.append(params)
            if params["confirm_expensive_model"] == .bool(false) {
                return .object(["key": .string("model"), "confirm_required": .bool(true), "confirm_message": .string("Higher price")])
            }
            return .object(["key": .string("model"), "value": .string("new-model"), "deferred": .bool(true)])
        }
        let guarded = try await api.selectModel("new-model", provider: "configured")
        XCTAssertTrue(guarded["confirm_required"].bool)
        XCTAssertEqual(writes.count, 1)
        let selected = try await api.selectModel("new-model", provider: "configured", confirmed: true)
        XCTAssertTrue(selected["deferred"].bool)
        XCTAssertEqual(writes.count, 2)
        XCTAssertTrue(writes.allSatisfy { $0["profile"] == .string("writer") && $0["session_id"] == .string("runtime") })
        XCTAssertEqual(writes[0]["value"], .string("new-model --provider configured --session"))
        XCTAssertEqual(writes[1]["confirm_expensive_model"], .bool(true))
    }
    func testMissingRuntimeProviderDriftAndUnavailableModelsNeverWrite() async {
        var writes = 0
        let request: (String, [String: JSON]) async throws -> JSON = { method, _ in
            if method == "model.options" { return self.inventory(provider: "changed") }
            writes += 1; return .object([:])
        }
        let missing = BotCapabilitiesClient(profile: "writer", request: request)
        do { _ = try await missing.selectModel("new-model", provider: "configured"); XCTFail("A live runtime is required") } catch {}
        let api = BotCapabilitiesClient(profile: "writer", runtimeID: "runtime", request: request)
        do { _ = try await api.selectModel("new-model", provider: "configured"); XCTFail("Provider change must fail") } catch {}
        do { _ = try await api.selectModel("unavailable", provider: "changed"); XCTFail("Unavailable model must fail") } catch {}
        XCTAssertEqual(writes, 0)
    }
}
