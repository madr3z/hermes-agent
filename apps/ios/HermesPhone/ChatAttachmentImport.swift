import Foundation
import UIKit
import UniformTypeIdentifiers
import HermesGateway

/// Imports only representations explicitly supplied by a system picker or paste action.
enum ChatAttachmentImport {
    static let pasteTypes: [UTType] = [.image, .fileURL, .pdf, .zip, .spreadsheet, .presentation, .audio, .movie]

    static func file(_ url: URL) throws -> ChatUpload {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw GatewayError.message("Choose a local file from Files. Web addresses cannot be attached as files.")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentTypeKey])
        guard values.isRegularFile == true else { throw GatewayError.message("Choose a file, not a folder.") }
        guard values.fileSize ?? 0 <= ChatUpload.maximumBytes else { throw GatewayError.message("Choose a file no larger than 10 MiB.") }
        let data = try Data(contentsOf: url)
        let isImage = values.contentType?.conforms(to: .image) == true
        if isImage, ["heic", "heif"].contains(url.pathExtension.lowercased()) {
            return try photo(data, name: url.deletingPathExtension().lastPathComponent)
        }
        return try ChatUpload(name: url.lastPathComponent, data: data, isImage: isImage)
    }

    static func photo(_ data: Data, name: String = "photo") throws -> ChatUpload {
        guard !data.isEmpty, data.count <= ChatUpload.maximumBytes else { throw GatewayError.message("Choose a photo no larger than 10 MiB.") }
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) else {
            throw GatewayError.message("This image format is unavailable.")
        }
        return try ChatUpload(name: (name as NSString).deletingPathExtension + ".jpg", data: jpeg, isImage: true)
    }

    static func paste(_ provider: NSItemProvider) async throws -> ChatUpload {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? GatewayError.message("This pasted photo could not be read.")) }
                }
            }
            return try photo(data, name: provider.suggestedName ?? "pasted-photo")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    do {
                        let url: URL?
                        if let value = item as? URL { url = value }
                        else if let data = item as? Data, let value = String(data: data, encoding: .utf8) { url = URL(string: value) }
                        else { url = nil }
                        guard let url else { throw error ?? GatewayError.message("This pasted file could not be read.") }
                        continuation.resume(returning: try file(url))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        guard let type = provider.registeredTypeIdentifiers.compactMap(UTType.init).first(where: { type in
            pasteTypes.dropFirst(2).contains { type.conforms(to: $0) }
        }) else { throw GatewayError.message("Paste a photo or copy a file from Files.") }
        // The provider deletes its temporary file as soon as the callback returns.
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                do {
                    guard let url else { throw error ?? GatewayError.message("This pasted file could not be read.") }
                    let loaded = try file(url)
                    let name = provider.suggestedName ?? loaded.name
                    continuation.resume(returning: try ChatUpload(name: name, data: loaded.data, isImage: loaded.isImage))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
