import Foundation
import UIKit
import UniformTypeIdentifiers
import HermesGateway

extension ChatStore {
    func addUpload(name: String, data: Data, image: Bool) {
        do {
            guard uploads.count < 5, uploads.reduce(0, { $0 + $1.data.count }) + data.count <= ChatUpload.maximumBytes else {
                throw GatewayError.message("Attach up to five files with a combined size of 10 MiB.")
            }
            uploads.append(try ChatUpload(name: name, data: data, isImage: image)); error = nil
        } catch { self.error = error.localizedDescription }
    }
    func importFile(_ url: URL) {
        do {
            let upload = try ChatAttachmentImport.file(url)
            addUpload(name: upload.name, data: upload.data, image: upload.isImage)
        } catch { self.error = error.localizedDescription }
    }
    func removeUpload(_ id: UUID) { guard !sending else { return }; uploads.removeAll { $0.id == id } }
    func quotedReference(_ value: String) -> String {
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil { return value }
        for quote in ["`", "\"", "'"] where !value.contains(quote) { return quote + value + quote }
        return value
    }
    func prepareUploads(client: GatewayClient, runtime: String, ids: [UUID]) async throws -> [(path: String, reference: String, image: Bool)] {
        var result: [(path: String, reference: String, image: Bool)] = []
        for id in ids {
            try Task.checkCancellation()
            guard let index = uploads.firstIndex(where: { $0.id == id }), runtimeID == runtime else { throw GatewayError.message("Attachment selection changed. Try again.") }
            status = "Uploading \(uploads[index].name)…"
            let staged = try await uploads[index].stage { method, payload in
                try await client.request(method, ["session_id": .string(runtime), "profile": .string(self.bot.profile)].merging(payload) { _, new in new })
            }
            guard runtimeID == runtime, let current = uploads.firstIndex(where: { $0.id == id }) else { throw GatewayError.message("Bot Chat changed during upload. Reconnect before sending.") }
            uploads[current].staged = staged
            result.append((staged.path, staged.reference, uploads[current].isImage))
        }
        for upload in result where upload.image {
            // Stage bytes first. The known path lets us undo even an uncertain image.attach reply.
            pendingImageCleanup.append((runtime, upload.path))
            let response = try await client.request("image.attach", ["session_id": .string(runtime), "profile": .string(bot.profile), "path": .string(upload.path)])
            guard response["attached"].bool else { throw GatewayError.message("The gateway could not attach this photo.") }
        }
        return result
    }
    func cleanupImages(client: GatewayClient) async throws {
        while let image = pendingImageCleanup.first {
            do { _ = try await client.request("image.detach", ["session_id": .string(image.runtime), "profile": .string(bot.profile), "path": .string(image.path)]) }
            catch GatewayError.rpc(let code, _) where code == 4001 { /* A reclaimed runtime cannot retain a pending image. */ }
            pendingImageCleanup.removeFirst()
        }
    }
}
