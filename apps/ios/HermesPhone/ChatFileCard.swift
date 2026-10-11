import SwiftUI
import QuickLook
import HermesGateway

struct ChatFileCard: View {
    let attachment: ChatAttachment
    let client: GatewayClient?
    let profile: String
    let storedSessionID: String?
    @State private var localURL: URL?
    @State private var previewURL: URL?
    @State private var downloading = false
    @State private var requestID = 0
    @State private var operation: UUID?
    @State private var error: String?
    private var ownerKey: String { "\(client?.endpoint.id.uuidString ?? ""):\(profile):\(storedSessionID ?? ""):\(attachment.path)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if attachment.isImage, let localURL, let image = UIImage(contentsOfFile: localURL.path) {
                Button { previewURL = localURL } label: { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: 8)) }
                    .accessibilityLabel("Preview \(attachment.name)")
            }
            HStack(alignment: .top) {
                Image(systemName: attachment.isImage ? "photo" : "doc")
                Text(attachment.name).font(.subheadline.weight(.medium)).lineLimit(2)
                Spacer(minLength: 0)
                if downloading { ProgressView().controlSize(.small) }
            }
            HStack {
                if let localURL {
                    Button("Preview", systemImage: "eye") { previewURL = localURL }.accessibilityLabel("Preview \(attachment.name)")
                    ShareLink(item: localURL) { Label("Share", systemImage: "square.and.arrow.up") }
                        .accessibilityLabel("Save or share \(attachment.name)")
                } else {
                    Button(error == nil ? "Download" : "Retry download", systemImage: "arrow.down.circle") { requestID += 1 }.disabled(downloading || client == nil || storedSessionID == nil)
                }
            }.font(.subheadline).buttonStyle(.bordered).controlSize(.large)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(12).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .quickLookPreview($previewURL)
            .task(id: ownerKey + ":\(requestID)") {
                removeLocalFile()
                if attachment.isImage || requestID > 0 { await download() }
            }
            .onDisappear { operation = nil; downloading = false; removeLocalFile() }
    }
    private func download() async {
        guard !Task.isCancelled, localURL == nil, let client, let storedSessionID else { return }
        let operation = UUID(); self.operation = operation
        downloading = true; error = nil
        defer { if self.operation == operation { downloading = false } }
        do {
            let result = try await client.downloadFile(attachment, profile: profile, storedSessionID: storedSessionID)
            if Task.isCancelled || self.operation != operation { try? FileManager.default.removeItem(at: result.deletingLastPathComponent()); return }
            localURL = result
        } catch is CancellationError { }
        catch { if self.operation == operation, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func removeLocalFile() {
        if let localURL { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }
        localURL = nil; previewURL = nil
    }
}
