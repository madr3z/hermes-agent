import XCTest
@testable import HermesGateway

@MainActor final class BotToolsetsTests: XCTestCase {
    private func row(enabled: Bool = true, name: String = "terminal") -> JSON {
        .object(["name": .string(name), "label": .string("Terminal"), "enabled": .bool(enabled),
                 "configured": .bool(true), "tools": .array([.string("terminal")])])
    }

    func testWritesOnlyTheOwningProfileAndKeepsCurrentChatReadSeparate() async throws {
        var enabled = true
        var methods: [String] = []
        var writes: [JSON] = []
        let api = BotToolsetsClient(profile: "writer", runtimeID: "runtime-writer", request: { method, params in
            methods.append(method)
            XCTAssertEqual(method, "tools.show")
            XCTAssertEqual(params, ["profile": .string("writer"), "session_id": .string("runtime-writer")])
            return .object(["sections": .array([.object(["tools": .array([.object(["name": .string("terminal")])])])])])
        }, http: { path, profile, body, method in
            XCTAssertEqual(profile, "writer")
            if method == "GET" {
                XCTAssertEqual(path, "api/tools/toolsets"); XCTAssertNil(body)
                return .array([self.row(enabled: enabled)])
            }
            XCTAssertEqual(method, "PUT"); XCTAssertEqual(path, "api/tools/toolsets/terminal")
            XCTAssertEqual(body, .object(["enabled": .bool(false)]))
            writes.append(body!); enabled = false
            return .object(["ok": .bool(true), "name": .string("terminal"), "enabled": .bool(false)])
        })
        _ = try await api.setEnabled(name: "terminal", enabled: false)
        let snapshot = try await api.snapshot()
        XCTAssertEqual(snapshot.toolsets.first?.enabled, false)
        XCTAssertEqual(snapshot.currentTools, Set(["terminal"]))
        XCTAssertNil(snapshot.currentError)
        XCTAssertEqual(methods, ["tools.show"])
        XCTAssertEqual(writes.count, 1)
    }

    func testUnavailableCurrentReadDoesNotPretendToolsWereUnloaded() async throws {
        let api = BotToolsetsClient(profile: "writer", runtimeID: "runtime", request: { _, _ in
            throw GatewayError.rpc(code: 4001, message: "Runtime is no longer active")
        }, http: { _, profile, _, method in
            XCTAssertEqual(profile, "writer"); XCTAssertEqual(method, "GET")
            return .array([self.row(enabled: false)])
        })
        let snapshot = try await api.snapshot()
        XCTAssertEqual(snapshot.toolsets.first?.enabled, false)
        XCTAssertNil(snapshot.currentTools)
        XCTAssertNotNil(snapshot.currentError)
    }

    func testMissingProxyRouteReportsUnavailableWithoutTryingAnotherOwnerOrAPI() async {
        var calls = 0
        let api = BotToolsetsClient(profile: "writer", runtimeID: nil, request: { _, _ in
            XCTFail("A missing REST route must not fall back to session RPC writes")
            return .null
        }, http: { path, profile, _, method in
            calls += 1
            XCTAssertEqual(path, "api/tools/toolsets"); XCTAssertEqual(profile, "writer"); XCTAssertEqual(method, "GET")
            throw GatewayError.http(status: 404, message: "Not found")
        })
        do { _ = try await api.snapshot(); XCTFail("Missing routes cannot become empty toolset lists") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not available through this gateway")) }
        XCTAssertEqual(calls, 1)
    }

    func testRemovedToolsetAndUnconfirmedWriteCannotReportSuccess() async throws {
        var removed = true
        var writes = 0
        let api = BotToolsetsClient(profile: "writer", runtimeID: nil, request: { _, _ in
            XCTFail("A settings-only read must not touch a chat runtime")
            return .null
        }, http: { _, _, _, method in
            if method == "GET" { return .array(removed ? [] : [self.row()]) }
            writes += 1
            return .object(["ok": .bool(true), "name": .string("other"), "enabled": .bool(false)])
        })
        do { _ = try await api.setEnabled(name: "terminal", enabled: false); XCTFail("Removed toolsets must not be written") }
        catch { XCTAssertEqual(writes, 0) }
        removed = false
        do { _ = try await api.setEnabled(name: "terminal", enabled: false); XCTFail("Mismatched receipts must not report success") }
        catch { XCTAssertEqual(writes, 1) }
    }
}
