import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import HermesGateway

struct ChatView: View {
    let store: PhoneStore
    let messageID: String?
    @State private var locatedNotification = false
    @State private var chat: ChatStore
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var composerFocused: Bool
    @State private var showFiles = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var importingPhotos = false
    init(bot: Bot, store: PhoneStore, messageID: String? = nil) { self.store = store; self.messageID = messageID; _chat = State(initialValue: ChatStore(bot: bot)) }
    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if chat.loading && chat.messages.isEmpty {
                        ProgressView("Opening conversation…").frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if chat.messages.isEmpty {
                        ContentUnavailableView("Talk to \(chat.bot.name)", systemImage: "bubble.left.and.bubble.right", description: Text("Send a message, attach a file or start a voice call. Your conversation stays on this bot’s gateway."))
                    }
                    ForEach(chat.messages) { message in ChatMessageView(message: message, client: chat.client, profile: chat.bot.profile, storedSessionID: chat.storedSessionID, botName: chat.bot.name).id(message.id) }
                    LoginHandoffCards(chat: chat)
                    ChatActivityView(activity: chat.activity, botName: chat.bot.name).id("activity")
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(.horizontal, 20).padding(.vertical, 24)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemBackground))
            .onChange(of: chat.messages.last(where: { $0.role == "assistant" })?.text) { _, _ in if messageID == nil || locatedNotification { reader.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: chat.messages.count) { _, _ in
                if !locatedNotification, let messageID, chat.messages.contains(where: { $0.id == messageID }) {
                    reader.scrollTo(messageID, anchor: .center); locatedNotification = true
                } else { reader.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.activity.phase) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
            .safeAreaInset(edge: .bottom) { composer }
            .task {
                await chat.open(store: store)
                if let messageID, chat.messages.contains(where: { $0.id == messageID }) {
                    await Task.yield()
                    reader.scrollTo(messageID, anchor: .center); locatedNotification = true
                }
            }
        }
        .navigationTitle(chat.bot.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(chat.bot.name).font(.headline)
                    Text(store.endpoints.first(where: { $0.id == chat.bot.endpointID })?.label ?? "Bot Chat")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { VMControlView(bot: chat.bot, store: store, chat: chat) } label: { Image(systemName: "desktopcomputer") }
                    .accessibilityLabel("Computer for \(chat.bot.name)")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(chat.voice.active || chat.voice.connecting ? "Return to call" : "Call", systemImage: chat.voice.active ? "phone.fill" : "phone") { composerFocused = false; CallPresentation.shared.open(chat) }
                    .disabled(!chat.connected || chat.sending).accessibilityIdentifier("startVoice")
                    .accessibilityLabel("Voice call with \(chat.bot.name)")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    BotToolsView(bot: chat.bot, store: store, runtimeID: chat.runtimeID)
                } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityLabel("Settings for \(chat.bot.name)")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await chat.open(store: store) } }

        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): urls.forEach { chat.importFile($0) }
            case .failure(let error): chat.error = error.localizedDescription
            }
        }
        .task(id: photos) { await importPhotos() }
    }
    private var composer: some View {
        VStack(spacing: 8) {
            if let error = chat.error {
                VStack(alignment: .leading, spacing: 6) {
                    PhoneNotice(title: "Connection needs attention", message: error)
                    Button("Reconnect", systemImage: "arrow.clockwise") { Task { await chat.open(store: store) } }
                        .font(.subheadline).frame(minHeight: 44)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = chat.voice.error { PhoneNotice(title: "Voice call", message: error, systemImage: "phone.badge.exclamationmark") }
            if !chat.connected || chat.busy {
                HStack {
                    Label(chat.status, systemImage: chat.connected ? "checkmark.circle" : "network")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .accessibilityLabel("Connection status: \(chat.status)")
                    Spacer()
                    if chat.busy {
                        Button("Stop", systemImage: "stop.circle") { Task { await chat.interrupt() } }
                            .font(.subheadline).frame(minHeight: 44)
                    }
                }
            }
            if importingPhotos { ProgressView("Preparing photos…").font(.subheadline) }
            if !chat.uploads.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(chat.uploads) { upload in
                            HStack(spacing: 6) {
                                Image(systemName: upload.isImage ? "photo" : "doc")
                                Text(upload.name).lineLimit(1)
                                Button { chat.removeUpload(upload.id) } label: {
                                    Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44)
                                }.accessibilityLabel("Remove \(upload.name)")
                            }.font(.subheadline).padding(.leading, 12)
                                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }.disabled(chat.sending)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    PhotosPicker(selection: $photos, maxSelectionCount: 5, matching: .images) { Label("Photos", systemImage: "photo") }
                    Button("Files", systemImage: "doc") { showFiles = true }
                } label: { Image(systemName: "plus").font(.title3).frame(width: 44, height: 44) }
                .accessibilityLabel("Attach photos or files").disabled(chat.sending || importingPhotos)
                TextField("Message \(chat.bot.name)", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...6).padding(.vertical, 12)
                    .accessibilityLabel("Message \(chat.bot.name)")
                    .focused($composerFocused).accessibilityIdentifier("chatComposer")
                Button { Task { await chat.send() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).frame(width: 44, height: 44)
                }
                .disabled(!chat.connected || chat.loading || chat.sending || importingPhotos || (chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.uploads.isEmpty))
                .accessibilityLabel(chat.busy ? "Queue message" : "Send message")
            }
            .padding(.horizontal, 6)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 28))
            .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(Color.primary.opacity(0.07)) }
        }.padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
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
