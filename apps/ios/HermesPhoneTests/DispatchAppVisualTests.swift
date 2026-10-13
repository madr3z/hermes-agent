import XCTest
import SwiftUI
import HermesGateway
@testable import HermesPhone

@MainActor final class DispatchAppVisualTests: XCTestCase {
    func testFormsAndSettingsUseDispatch() async throws {
        let (store, preferences) = isolatedStore()
        let calls = RaiseToCallController(preferences: preferences)
        try await capture(GatewayForm(store: store), name: "gateway")
        try await capture(GatewayForm(store: store), name: "gateway-dark", scheme: .dark)
        try await capture(GatewayForm(store: store), name: "gateway-accessible", size: .accessibility3)
        try await capture(DispatchSettingsView(store: store, edit: { _ in }, mobile: { _ in },
                                              add: {}, create: {}, callSettings: {}), name: "settings")
        try await capture(CallPreferencesView(controller: calls, store: store), name: "call-settings")
        try await capture(CreateBotView(store: store), name: "create-bot")
        let bot = fixtureBot()
        try await capture(AddMCPView(connectors: ConnectorsStore(bot: bot), store: store), name: "add-account")
    }

    func testManagementAndChatUseDispatch() async throws {
        let (store, preferences) = isolatedStore()
        let calls = RaiseToCallController(preferences: preferences)
        let bot = fixtureBot()
        try await capture(NavigationStack { BotToolsView(bot: bot, store: store) }, name: "bot-settings")
        try await capture(NavigationStack { BotToolsView(bot: bot, store: store) }, name: "bot-settings-dark", scheme: .dark)
        try await capture(NavigationStack { ConnectorsView(bot: bot, store: store) }, name: "accounts")
        try await capture(NavigationStack { BotRoutinesView(bot: bot, store: store) }, name: "scheduled-tasks")
        let chat = store.chat(for: bot)
        chat.messages = [ChatMessage(id: "a", role: "assistant", text: "## A clearer afternoon\nYour appointment is now on Thursday.\n- There is time to prepare.\n- Your notes are ready.")]
        chat.draft = "And remind me the day before."
        try await capture(NavigationStack { ChatView(bot: bot, store: store).environment(calls) }, name: "chat") {
            // Deliver the final synthetic turn after layout, as a real chat snapshot does.
            chat.error = nil; chat.connected = true; chat.status = "Connected"
            chat.messages.append(ChatMessage(id: "u", role: "user", text: "Thank you. Keep the afternoon free."))
        }
        try await capture(SavedChatsView(chat: chat), name: "saved-chats")
    }

    private func fixtureBot() -> Bot {
        Bot(endpointID: UUID(), row: .object(["name": .string("Assistant")]))
    }

    private func isolatedStore() -> (PhoneStore, UserDefaults) {
        let name = "dispatch-app-visual-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: name)!
        preferences.removePersistentDomain(forName: name)
        preferences.set(false, forKey: "raise-to-call-enabled")
        addTeardownBlock { preferences.removePersistentDomain(forName: name) }
        // No endpoints means client lookup stops before credentials or network access.
        return (PhoneStore(preferences: preferences), preferences)
    }

    private func capture<V: View>(_ content: V, name: String, scheme: ColorScheme = .light,
                                  size: DynamicTypeSize = .large, settled: (() -> Void)? = nil) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: content.environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(300))
        if let settled { settled(); try await Task.sleep(for: .milliseconds(300)) }
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        var drawn = false
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            drawn = host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn)
        XCTAssertEqual(image.size, CGSize(width: 390, height: 844))
        let attachment = XCTAttachment(image: image)
        attachment.name = "dispatch-app-" + name; attachment.lifetime = .keepAlways
        add(attachment)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-app-\(name).png")
        try XCTUnwrap(image.pngData()).write(to: destination)
        print("DISPATCH_APP_RENDER \(destination.path)")
    }
}
