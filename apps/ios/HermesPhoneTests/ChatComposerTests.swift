import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import HermesPhone

@MainActor final class ChatComposerTests: XCTestCase {
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
