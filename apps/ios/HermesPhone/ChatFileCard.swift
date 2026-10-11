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
    @State private var requested = false
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
                Text(attachment.name).font(.callout).lineLimit(2)
                Spacer(minLength: 0)
                if downloading { ProgressView().controlSize(.small) }
            }
            HStack {
                if let localURL {
                    Button("Preview") { previewURL = localURL }
                    ShareLink(item: localURL) { Label("Save or share", systemImage: "square.and.arrow.up") }
                } else {
                    Button("Download", systemImage: "arrow.down.circle") { requested = true }.disabled(downloading || client == nil || storedSessionID == nil)
                }
            }.font(.caption)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(10).background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .quickLookPreview($previewURL)
            .task(id: ownerKey + (requested ? ":requested" : "")) {
                removeLocalFile()
                if attachment.isImage || requested { await download() }
            }
            .onDisappear { removeLocalFile() }
    }
    private func download() async {
        guard !downloading, localURL == nil, let client, let storedSessionID else { return }
        downloading = true; error = nil
        defer { downloading = false }
        do {
            let result = try await client.downloadFile(attachment, profile: profile, storedSessionID: storedSessionID)
            if Task.isCancelled { try? FileManager.default.removeItem(at: result.deletingLastPathComponent()); return }
            localURL = result
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    private func removeLocalFile() {
        if let localURL { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }
        localURL = nil; previewURL = nil
    }
}
