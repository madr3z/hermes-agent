import XCTest
import SwiftUI
import HermesGateway
@testable import HermesPhone

@MainActor final class DispatchTests: XCTestCase {
    func testAttentionOmitsSettledAnswersAndKeepsAccountConfirmation() throws {
        let bot = Bot(endpointID: UUID(), row: .object(["name": .string("Assistant")]))
        let frame: JSON = .object(["id": .string("question"), "method": .string("clarify"), "params": .object([
            "session_id": .string("runtime"), "questions": .array([.object([
                "qid": .string("account"), "question": .string("Which account should I use?")
            ])]), "answers": .object(["account": .string("Personal")])
        ])])
        let settled = try XCTUnwrap(ChatHumanRequest(frame, runtimeID: "runtime"))
        let logins = [
            LoginHandoff(.object(["id": .string("confirm"), "status": .string("authorized")])),
            LoginHandoff(.object(["id": .string("canceled"), "status": .string("canceled")])),
            LoginHandoff(.object(["id": .string("sent"), "status": .string("authorized"), "continuation_status": .string("submitted")])),
            LoginHandoff(.object(["id": .string("uncertain"), "status": .string("authorized"), "continuation_status": .string("unconfirmed")]))
        ]
        let items = DispatchAttention.summaries(bot: bot, requests: [settled], logins: logins)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.bot.id, bot.id)
        XCTAssertEqual(items.first?.action, "Review account")
        XCTAssertEqual(items.first?.title, "Confirm your account.")
        XCTAssertEqual(items.last?.title, "Check your conversation.")
        XCTAssertEqual(items.last?.action, "Open conversation")
    }

    func testHomeDoesNotCreateChatsAndDraftReturnsToItsOwner() {
        let store = isolatedStore()
        let endpoint = UUID()
        let assistant = Bot(endpointID: endpoint, row: .object(["name": .string("Assistant")]))
        let other = Bot(endpointID: endpoint, row: .object(["name": .string("Other")]))
        store.bots = [assistant, other]
        XCTAssertTrue(DispatchAttention.items(in: store).isEmpty)
        XCTAssertTrue(store.activeChats.isEmpty)
        XCTAssertTrue(store.clients.isEmpty)
        let chat = store.chat(for: assistant)
        chat.draft = "Keep this draft"
        XCTAssertTrue(store.chat(for: assistant) === chat)
        XCTAssertEqual(store.chat(for: assistant).draft, "Keep this draft")
        XCTAssertTrue(DispatchAttention.items(in: store).isEmpty, "Disconnected requests cannot appear as current")
        XCTAssertEqual(store.chat(for: other).draft, "")
        XCTAssertEqual(store.activeChats[endpoint]?.bot.id, other.id)
    }

    func testRenderReferenceAndAccessibleStates() async throws {
        let store = isolatedStore()
        let endpoint = UUID()
        let assistant = Bot(endpointID: endpoint, row: .object([
            "name": .string("Assistant"), "canonical_session": .object([
                "preview": .string("Weekly summary"), "last_active": .number(1)
            ])
        ]))
        let scout = Bot(endpointID: UUID(), row: .object([
            "name": .string("Scout"), "canonical_session": .object([
                "preview": .string("Research is ready"), "last_active": .number(2)
            ])
        ]))
        store.bots = [assistant, scout]
        let item = DispatchAttention(id: "fixture", bot: assistant, title: "Which account should I use?",
                                     detail: "Your calendar summary is waiting for an account choice.", action: "Choose account")
        for (name, scheme, size) in [("reference", ColorScheme.light, DynamicTypeSize.large),
                                     ("dark", .dark, .large), ("accessible", .light, .accessibility3)] {
            let content = DispatchTodayView(store: store, attention: [item], openChat: { _ in },
                                            openSettings: {}, connect: {}, showChats: {})
                .safeAreaInset(edge: .bottom, spacing: 0) { DispatchTabBar(selection: .constant(.today)) }
                .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size)
                .frame(width: 390, height: 844)
            let image = try await capture(content, scheme: scheme)
            XCTAssertEqual(image.size, CGSize(width: 390, height: 844))
            let attachment = XCTAttachment(image: image)
            attachment.name = "dispatch-" + name; attachment.lifetime = .keepAlways
            add(attachment)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-\(name).png")
            try XCTUnwrap(image.pngData()).write(to: destination)
            print("DISPATCH_RENDER \(destination.path)")
        }
    }

    private func capture<V: View>(_ content: V, scheme: ColorScheme) async throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: content)
        // Match the artwork viewport. System bars are reviewed separately in the live app.
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let laidOut = expectation(description: "Hosted screen laid out")
        DispatchQueue.main.async { host.view.layoutIfNeeded(); laidOut.fulfill() }
        await fulfillment(of: [laidOut], timeout: 5)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        var drawn = false
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            drawn = host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn, "Capture must include UIKit-backed scroll content")
        return image
    }

    private func isolatedStore() -> PhoneStore {
        let name = "dispatch-tests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: name)!
        preferences.removePersistentDomain(forName: name)
        addTeardownBlock { preferences.removePersistentDomain(forName: name) }
        return PhoneStore(preferences: preferences)
    }
}
