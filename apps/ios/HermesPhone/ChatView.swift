import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import HermesGateway

struct ChatView: View {
    let store: PhoneStore
    @State private var chat: ChatStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showVoice = false
    @State private var showFiles = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var importingPhotos = false
    init(bot: Bot, store: PhoneStore) { self.store = store; _chat = State(initialValue: ChatStore(bot: bot)) }
    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if chat.loading && chat.messages.isEmpty { ProgressView("Opening Bot Chat…").frame(maxWidth: .infinity) }
                    ForEach(chat.messages) { message in ChatMessageView(message: message, client: chat.client, profile: chat.bot.profile, storedSessionID: chat.storedSessionID).id(message.id) }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messages.last(where: { $0.role == "assistant" })?.text) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
            .safeAreaInset(edge: .bottom) { composer }
        }
        .navigationTitle(chat.bot.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { ConnectorsView(bot: chat.bot, store: store) } label: { Label("Connectors", systemImage: "puzzlepiece.extension") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { VMControlView(bot: chat.bot, store: store) } label: { Label("VM controls", systemImage: "desktopcomputer") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("GPT Live", systemImage: "waveform") { showVoice = true }.disabled(!chat.connected || chat.sending).accessibilityIdentifier("startVoice")
            }
        }
        .task { await chat.open(store: store) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await chat.open(store: store) } }
            else if phase == .background { chat.voice.stop() }
        }
        .onDisappear { chat.voice.stop() }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): urls.forEach { chat.importFile($0) }
            case .failure(let error): chat.error = error.localizedDescription
            }
        }
        .task(id: photos) { await importPhotos() }
        .sheet(isPresented: $showVoice) { VoiceView(chat: chat) }
    }
    private var composer: some View {
        VStack(spacing: 8) {
            if let error = chat.error {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button("Reconnect") { Task { await chat.open(store: store) } }.font(.caption)
                }
            }
            if let error = chat.voice.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Circle().fill(chat.connected ? .green : .orange).frame(width: 6, height: 6)
                Text(chat.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if chat.busy { Button("Stop") { Task { await chat.interrupt() } }.font(.caption) }
            }
            if !chat.uploads.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(chat.uploads) { upload in
                            HStack(spacing: 6) {
                                Image(systemName: upload.isImage ? "photo" : "doc")
                                Text(upload.name).lineLimit(1)
                                Button("Remove", systemImage: "xmark.circle.fill") { chat.removeUpload(upload.id) }.labelStyle(.iconOnly)
                            }.font(.caption).padding(8).background(.quaternary, in: Capsule())
                        }
                    }
                }.disabled(chat.sending)
            }
            HStack(alignment: .bottom) {
                Menu {
                    PhotosPicker(selection: $photos, maxSelectionCount: 5, matching: .images) { Label("Photos", systemImage: "photo") }
                    Button("Files", systemImage: "doc") { showFiles = true }
                } label: { Image(systemName: "plus.circle").font(.title2).padding(.bottom, 8) }
                .accessibilityLabel("Attach photos or files").disabled(chat.sending || importingPhotos)
                TextField("Message \(chat.bot.name)", text: $chat.draft, axis: .vertical).lineLimit(1...6).padding(10).background(.background, in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("chatComposer")
                Button { Task { await chat.send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.largeTitle) }
                    .disabled(!chat.connected || chat.loading || chat.sending || importingPhotos || (chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.uploads.isEmpty))
                    .accessibilityLabel(chat.busy ? "Queue message" : "Send message")
            }
        }.padding(.horizontal).padding(.vertical, 10).background(.bar)
    }
    private func importPhotos() async {
        guard !photos.isEmpty else { return }
        importingPhotos = true
        defer { importingPhotos = false }
        for item in photos {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw GatewayError.message("This photo could not be read.") }
                try Task.checkCancellation()
                guard data.count <= ChatUpload.maximumBytes else { throw GatewayError.message("Choose a photo no larger than 10 MiB.") }
                guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) else { throw GatewayError.message("This photo format is unavailable.") }
                chat.addUpload(name: "photo-\(UUID().uuidString.prefix(8)).jpg", data: jpeg, image: true)
            } catch is CancellationError { return }
            catch { chat.error = error.localizedDescription }
        }
        photos = []
    }

}

private struct VoiceView: View {
    @Bindable var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: chat.voice.active ? "waveform.circle.fill" : "waveform.circle").font(.system(size: 88)).foregroundStyle(.tint)
                Text(chat.voice.active ? "Listening" : chat.voice.connecting ? "Connecting…" : "GPT Live").font(.title2)
                Text("Speak naturally and interrupt by speaking. Requests for work are delegated to \(chat.bot.name).").multilineTextAlignment(.center).foregroundStyle(.secondary)
                ScrollView { Text(chat.voice.transcript).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                if let error = chat.voice.error { Text(error).font(.callout).foregroundStyle(.red) }
                HStack {
                    if chat.voice.active {
                        Button(chat.voice.muted ? "Unmute" : "Mute", systemImage: chat.voice.muted ? "mic.slash" : "mic") { chat.voice.toggleMute() }.buttonStyle(.bordered)
                        Button("End Call", role: .destructive) { chat.voice.stop(); dismiss() }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Start Call") { Task { await chat.startVoice() } }.buttonStyle(.borderedProminent).disabled(chat.voice.connecting)
                    }
                }
                Text("Spoken transcripts are saved with Bot Chat. The microphone stops when this sheet closes or the app enters the background.").font(.footnote).foregroundStyle(.secondary)
            }.padding(24).navigationTitle(chat.bot.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { chat.voice.stop(); dismiss() } } }
        }.onDisappear { chat.voice.stop() }
    }
}
