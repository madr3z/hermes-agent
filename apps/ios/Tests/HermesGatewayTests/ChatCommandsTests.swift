import XCTest
@testable import HermesGateway

@MainActor final class ChatCommandsTests: XCTestCase {
    private func catalog() -> JSON {
        .object(["pairs": .array([
            .array([.string("/status"), .string("Status")]), .array([.string("/skills"), .string("Review skills")]),
            .array([.string("/custom-skill"), .string("Installed skill")]), .array([.string("/old-command"), .string("Old backend")]),
            .array([.string("/stop"), .string("Stop")])]),
            "canon": .object(["/s": .string("/status")]), "commands": .object([
                "/status": .object(["mobile": .string("server")]),
                "/skills": .object(["mobile": .string("server"), "mobile_subcommands": .array([.string("pending"), .string("approve")])]),
                "/custom-skill": .object(["mobile": .string("dispatch")]),
                "/stop": .object(["mobile": .string("native")])])])
    }
    func testScopedCanonicalCommandsKeepMultilineArgumentsAndRespectMobileGates() async throws {
        var calls: [(String, [String: JSON])] = []
        let client = ChatCommandsClient(profile: "writer", sessionID: "runtime-a") { method, params in
            calls.append((method, params))
            if method == "commands.catalog" { return self.catalog() }
            return .object(["output": .string("Saved"), "warning": .string("Applies next session")])
        }
        let status = try await client.execute("/s")
        XCTAssertEqual(status, .output("Saved\n\nApplies next session"))
        XCTAssertEqual(calls.last?.1["command"], .string("status"))
        _ = try await client.execute("/skills approve\n  line one\n\n  line two")
        XCTAssertEqual(calls.last?.1["command"], .string("skills approve\n  line one\n\n  line two"))
        for input in ["/skills install unknown", "/old-command", "/not-installed", "/stop all"] {
            let before = calls.filter { $0.0 != "commands.catalog" }.count
            do { _ = try await client.execute(input); XCTFail("Unsupported command must not execute") } catch {}
            XCTAssertEqual(calls.filter { $0.0 != "commands.catalog" }.count, before)
        }
        XCTAssertTrue(calls.allSatisfy { $0.1["profile"] == .string("writer") && $0.1["session_id"] == .string("runtime-a") })
        let stop = try await client.execute("/stop")
        XCTAssertEqual(stop, .native("stop"))
    }
    func testDynamicSkillUsesDispatchAndKeepsPrivateScaffoldingOutOfDisplay() async throws {
        var methods: [String] = []
        let client = ChatCommandsClient(profile: "writer", sessionID: "runtime-a") { method, params in
            methods.append(method)
            if method == "commands.catalog" { return self.catalog() }
            XCTAssertEqual(params["name"], .string("custom-skill"))
            return .object(["type": .string("skill"), "name": .string("Custom"), "message": .string("PRIVATE SKILL BODY\nTask"), "display": .string("/custom-skill Task")])
        }
        let outcome = try await client.execute("/custom-skill Task")
        XCTAssertEqual(outcome, .send("PRIVATE SKILL BODY\nTask", display: "/custom-skill Task", notice: nil))
        XCTAssertEqual(methods, ["commands.catalog", "command.dispatch"])
    }
    func testUncertainExecutionDoesNotFallbackOrRetryAndCompletionUsesServerRange() async throws {
        var executions = 0
        let client = ChatCommandsClient(profile: "writer", sessionID: "runtime-a") { method, _ in
            if method == "commands.catalog" { return self.catalog() }
            if method == "complete.slash" { return .object(["replace_from": .number(8), "items": .array([.object(["text": .string("pending "), "display": .string("pending")])])]) }
            executions += 1; throw GatewayError.message("Lost acknowledgement")
        }
        do { _ = try await client.execute("/status"); XCTFail("Uncertain command must fail visibly") } catch {}
        XCTAssertEqual(executions, 1)
        let completions = try await client.complete("/skills pen")
        XCTAssertEqual(completions.first?.applying(to: "/skills pen"), "/skills pending ")
        XCTAssertNil(ChatCommandInvocation("/usr/local/file"))
        XCTAssertEqual(ChatCommandInvocation("/GOAL first\n\n  second")?.argument, "first\n\n  second")
    }
}
