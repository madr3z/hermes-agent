import XCTest
import UIKit
import UniformTypeIdentifiers
import SwiftUI
import HermesGateway
@testable import HermesPhone

@MainActor final class ChatComposerTests: XCTestCase {
    private func settle(_ view: UIView) async throws {
        try await Task.sleep(for: .milliseconds(100))
        view.layoutIfNeeded()
    }
    private func composer(in view: UIView) -> ChatComposerInput? {
        if let input = view as? ChatComposerInput { return input }
        return view.subviews.lazy.compactMap { self.composer(in: $0) }.first
    }
    private func withComposer(_ check: (ChatComposerInput, UIView) async throws -> Void) async throws {
        let suite = "composer-focus-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let bot = Bot(endpointID: UUID(), row: .object(["name": .string("synthetic-focus-test")]))
        let host = UIHostingController(rootView: ChatView(bot: bot, store: PhoneStore(preferences: preferences)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            preferences.removePersistentDomain(forName: suite)
        }
        try await settle(host.view)
        let input = try XCTUnwrap(composer(in: host.view))
        XCTAssertTrue(input.becomeFirstResponder())
        try await check(input, host.view)
    }
    func testTypingRetainsFirstResponderAcrossDraftUpdates() async throws {
        try await withComposer { input, root in
            for character in ["a", "b", "c"] {
                input.insertText(character)
                try await settle(root)
                XCTAssertTrue(composer(in: root) === input, "Editing must keep the same native composer")
                XCTAssertTrue(input.isFirstResponder, "A draft update must not dismiss the keyboard")
            }
            XCTAssertEqual(input.text, "abc")
        }
    }
    func testProgrammaticDraftUpdateKeepsFocusAndExplicitDismissalStillWorks() async throws {
        try await withComposer { input, root in
            let coordinator = try XCTUnwrap(input.delegate as? ChatComposer.Coordinator)
            coordinator.parent.text = "synthetic replacement draft"
            try await settle(root)
            XCTAssertEqual(input.text, "synthetic replacement draft")
            XCTAssertTrue(input.isFirstResponder)
            coordinator.parent.focused = false
            try await settle(root)
            XCTAssertFalse(input.isFirstResponder)
        }
    }
    private func photo() -> NSItemProvider {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 3, height: 3)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in completion(data, nil); return nil }
        return provider
    }
    func testNativePasteRoutesPhotoAndFileTogetherAndKeepsTextAtSelection() async throws {
        let view = ChatComposerInput(frame: CGRect(x: 0, y: 0, width: 280, height: 100), textContainer: nil)
        view.text = "before after"; view.selectedRange = NSRange(location: 7, length: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("synthetic file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = NSItemProvider()
        file.registerItem(forTypeIdentifier: UTType.fileURL.identifier, loadHandler: { completion, _, _ in completion?(url as NSURL, nil) })
        let imported = expectation(description: "One attachment batch")
        imported.assertForOverFulfill = true
        var providers: [NSItemProvider] = []
        view.onPaste = { providers = $0; imported.fulfill() }
        view.paste(itemProviders: [NSItemProvider(object: "pasted " as NSString), photo(), file])
        await fulfillment(of: [imported], timeout: 5)
        XCTAssertEqual(providers.count, 2)
        let first = try await ChatAttachmentImport.paste(providers[0])
        let second = try await ChatAttachmentImport.paste(providers[1])
        XCTAssertTrue(first.isImage); XCTAssertFalse(second.isImage)
        XCTAssertNil(first.staged); XCTAssertNil(second.staged)
        XCTAssertEqual(view.text, "before pasted after")
    }
    func testAttachmentOnlyPastePreservesSelectedDraftAndPlainTextUsesNativePaste() async throws {
        let view = ChatComposerInput(frame: CGRect(x: 0, y: 0, width: 280, height: 100), textContainer: nil)
        view.text = "keep selected draft"; view.selectedRange = NSRange(location: 5, length: 8)
        let imported = expectation(description: "Photo supplied")
        view.onPaste = { _ in imported.fulfill() }
        view.paste(itemProviders: [photo()])
        await fulfillment(of: [imported], timeout: 5)
        XCTAssertEqual(view.text, "keep selected draft")
        XCTAssertEqual(view.selectedRange, NSRange(location: 5, length: 8))
        let changed = expectation(description: "Plain text pasted")
        let observer = NotificationCenter.default.addObserver(forName: UITextView.textDidChangeNotification, object: view, queue: .main) { _ in changed.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        view.paste(itemProviders: [NSItemProvider(object: "new" as NSString)])
        await fulfillment(of: [changed], timeout: 5)
        XCTAssertEqual(view.text, "keep new draft")
    }
}
