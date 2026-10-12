import XCTest
import UIKit
import UniformTypeIdentifiers
import HermesGateway
@testable import HermesPhone

@MainActor final class ChatAttachmentImportTests: XCTestCase {
    func testUIImageObjectAndSelectedPhotoBytesKeepDraftAndStageImageBytes() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        let provider = NSItemProvider(object: image)
        provider.suggestedName = "synthetic-photo"
        let pasted = try await ChatAttachmentImport.paste(provider)
        let selected = try ChatAttachmentImport.photo(XCTUnwrap(image.pngData()), name: "synthetic-selected-photo")
        let chat = ChatStore(bot: Bot(endpointID: UUID(), row: .object(["name": .string("synthetic-media")])))
        chat.draft = "Describe these images together"
        for upload in [pasted, selected] {
            chat.addUpload(name: upload.name, data: upload.data, image: upload.isImage)
        }
        XCTAssertEqual(chat.draft, "Describe these images together")
        XCTAssertEqual(chat.uploads.count, 2)
        XCTAssertTrue(chat.uploads.allSatisfy { $0.isImage && $0.staged == nil })
        for upload in chat.uploads {
            _ = try await upload.stage { method, params in
                XCTAssertEqual(method, "file.attach")
                let encoded = try XCTUnwrap(params["data_url"]?.string?.split(separator: ",", maxSplits: 1).last)
                let bytes = try XCTUnwrap(Data(base64Encoded: String(encoded)))
                XCTAssertNotNil(UIImage(data: bytes))
                return .object(["attached": .bool(true), "path": .string("/synthetic/" + upload.name), "ref_text": .string("@file:/synthetic/" + upload.name)])
            }
        }
        XCTAssertEqual(chat.draft, "Describe these images together")
    }
    func testUserSuppliedImageAndFileProvidersBecomeUnsentAttachments() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3, height: 3)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        }
        let photo = NSItemProvider()
        photo.suggestedName = "Selected photo.png"
        photo.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(image, nil); return nil
        }
        let imported = try await ChatAttachmentImport.paste(photo)
        XCTAssertEqual(imported.name, "Selected photo.jpg")
        XCTAssertTrue(imported.isImage)
        XCTAssertNotNil(UIImage(data: imported.data))
        XCTAssertNil(imported.staged)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        let contents = Data("synthetic selected document".utf8)
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = NSItemProvider()
        document.registerItem(forTypeIdentifier: UTType.fileURL.identifier, loadHandler: { completion, _, _ in completion?(url as NSURL, nil) })
        let pasted = try await ChatAttachmentImport.paste(document)
        XCTAssertEqual(pasted.name, url.lastPathComponent)
        XCTAssertEqual(pasted.data, contents)
        XCTAssertFalse(pasted.isImage)
        XCTAssertNil(pasted.staged)
    }
    func testRemoteURLsFoldersInvalidImagesAndOversizeDataNeverBecomeUploads() async throws {
        XCTAssertThrowsError(try ChatAttachmentImport.file(URL(string: "https://example.invalid/file.pdf")!))
        XCTAssertThrowsError(try ChatAttachmentImport.file(FileManager.default.temporaryDirectory))
        XCTAssertThrowsError(try ChatAttachmentImport.photo(Data("not an image".utf8)))
        XCTAssertThrowsError(try ChatAttachmentImport.photo(Data(count: ChatUpload.maximumBytes + 1)))
        let document = NSItemProvider()
        document.registerItem(forTypeIdentifier: UTType.fileURL.identifier, loadHandler: { completion, _, _ in
            completion?(URL(string: "https://example.invalid/private")! as NSURL, nil)
        })
        do { _ = try await ChatAttachmentImport.paste(document); XCTFail("Remote pasted URL cannot fetch file bytes") } catch {}
        let text = NSItemProvider(object: "ordinary text" as NSString)
        do { _ = try await ChatAttachmentImport.paste(text); XCTFail("Text stays in the normal text composer") } catch {}
    }
}
