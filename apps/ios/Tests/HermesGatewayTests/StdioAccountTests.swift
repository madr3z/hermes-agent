import XCTest
@testable import HermesGateway

@MainActor final class StdioAccountTests: XCTestCase {
    func testThreeAccountsUseDistinctSecretReferencesAndNeverPersistValuesInConfig() throws {
        let plans = try ["personal", "work", "third"].map {
            try StdioAccountPlan(name: $0, command: "/opt/server", secrets: [.init(name: "API_KEY", value: "fixture-\($0)")])
        }
        let slots = plans.flatMap { $0.secrets.keys }
        XCTAssertEqual(Set(slots).count, 3)
        for plan in plans {
            let slot = try XCTUnwrap(plan.secrets.keys.first)
            XCTAssertTrue(slot.hasPrefix("MCP_\(plan.name.uppercased().replacingOccurrences(of: "-", with: "_"))_"))
            XCTAssertEqual(plan.parameters["config"]?["env"]["API_KEY"], .string("${\(slot)}"))
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(JSON.object(plan.parameters)), as: UTF8.self).contains("fixture-"))
        }
        let duplicateAttempt = try StdioAccountPlan(name: "personal", command: "/opt/server", secrets: [.init(name: "API_KEY", value: "new")])
        XCTAssertNotEqual(Set(duplicateAttempt.secrets.keys), Set(plans[0].secrets.keys))
        XCTAssertNoThrow(try StdioAccountPlan(name: "personal", command: "/opt/server", secrets: [], existingNames: ["personal"]))
        XCTAssertThrowsError(try StdioAccountPlan(name: "work", command: "/opt/server", secrets: [.init(name: "API_KEY", value: "x"), .init(name: "API_KEY", value: "y")]))
    }
    func testICloudPresetIsReadOnlyByDefaultAndSendRequiresExplicitRecipientPolicy() throws {
        var draft = ICloudAccountDraft(); draft.email = "fixture@icloud.com"; draft.password = "fixture-password"
        let plan = try draft.plan(timeZone: "Europe/London")
        let env = plan.parameters["config"]!["env"]
        XCTAssertEqual(plan.parameters["config"]?["command"], .string("/opt/hermes-connectors/icloud-mcp"))
        XCTAssertEqual(env["ICLOUD_MCP_READ_ONLY"], .string("true"))
        XCTAssertEqual(env["ICLOUD_MCP_ENABLE_CONTACTS"], .string("false"))
        XCTAssertEqual(env["ICLOUD_MCP_ENABLE_MAIL_WRITE"], .string("false"))
        XCTAssertEqual(env["ICLOUD_MCP_ENABLE_MAIL_SEND"], .string("false"))
        XCTAssertEqual(env["ICLOUD_MAIL_ADDRESS"], .string(draft.email))
        draft.mailSend = true
        XCTAssertThrowsError(try draft.plan())
        draft.readOnly = false
        for recipients in ["", "*", "a@example.com,", "a@example.com,A@example.com", "Name <a@example.com>"] {
            draft.recipients = recipients
            XCTAssertThrowsError(try draft.plan())
        }
        draft.recipients = "a@example.com\nb@example.com"
        XCTAssertEqual(try draft.plan().parameters["config"]?["env"]["ICLOUD_MCP_SMTP_ALLOWED_RECIPIENTS"], .string("a@example.com,b@example.com"))
        draft.allowAllRecipients = true; draft.mailWrite = true
        XCTAssertEqual(try draft.plan().parameters["config"]?["env"]["ICLOUD_MCP_SMTP_ALLOWED_RECIPIENTS"], .string("*"))
        XCTAssertEqual(try draft.plan().parameters["config"]?["env"]["ICLOUD_MCP_ENABLE_MAIL_WRITE"], .string("true"))
        draft.readOnly = true; draft.mailSend = false
        XCTAssertEqual(try draft.plan().parameters["config"]?["env"]["ICLOUD_MCP_ENABLE_MAIL_WRITE"], .string("false"))
    }
    func testPartialCredentialFailureRetriesSameSlotsBeforeAddingAndScopesEveryRPC() async throws {
        let plan = try StdioAccountPlan(name: "work", command: "/opt/server", secrets: [.init(name: "API_KEY", value: "first"), .init(name: "PASSWORD", value: "second")])
        var methods: [String] = []
        let api = BotConnectorsClient(profile: "secondary") { method, params in
            XCTAssertEqual(params["profile"], .string("secondary")); methods.append(method)
            return .object(["ok": .bool(true), "servers": .array([])])
        }
        var attempts: [String] = []; var fail = true
        let installer = StdioAccountInstaller(plan: plan, client: api) { _, method, body in
            if method == "GET" { return .object([:]) }
            let slot = body!["key"].string!; attempts.append(slot)
            if attempts.count == 2 && fail { fail = false; throw GatewayError.message("fixture second secret must not echo") }
            return .object(["ok": .bool(true)])
        }
        do { try await installer.save(); XCTFail("Expected credential failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("fixture second")) }
        XCTAssertFalse(methods.contains("mcp.servers.add")); XCTAssertTrue(installer.canRetry)
        try await installer.save()
        XCTAssertEqual(attempts.count, 3); XCTAssertEqual(attempts[1], attempts[2])
        XCTAssertEqual(methods.filter { $0 == "mcp.servers.add" }.count, 1)
        XCTAssertTrue(installer.saved); XCTAssertFalse(installer.canRetry)
    }
    func testUncertainAddCannotReplayAndExistingCredentialCannotBeOverwritten() async throws {
        let plan = try StdioAccountPlan(name: "work", command: "/opt/server", secrets: [.init(name: "API_KEY", value: "fixture-secret")])
        var adds = 0; var writes = 0
        let api = BotConnectorsClient(profile: "bot") { method, _ in
            if method == "mcp.servers.add" { adds += 1; throw GatewayError.message("fixture-secret") }
            return .object(["servers": .array([])])
        }
        let installer = StdioAccountInstaller(plan: plan, client: api) { _, method, _ in
            if method == "PUT" { writes += 1 }
            return .object(["ok": .bool(true)])
        }
        for _ in 0..<2 {
            do { try await installer.save(); XCTFail("Expected failure") }
            catch { XCTAssertFalse(error.localizedDescription.contains("fixture-secret")) }
        }
        XCTAssertEqual(adds, 1); XCTAssertEqual(writes, 1)
        let collision = StdioAccountInstaller(plan: plan, client: api) { _, method, _ in
            XCTAssertEqual(method, "GET")
            return .object([plan.secrets.keys.first!: .object(["is_set": .bool(true)])])
        }
        do { try await collision.save(); XCTFail("Expected collision") } catch {}
        XCTAssertFalse(collision.canRetry); XCTAssertEqual(writes, 1)
    }
}
