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
    @Environment(RaiseToCallController.self) private var raiseToCall
    @State private var chatVisible = false
    @State private var composerFocused = false
    @State private var showSavedChats = false
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var importingPhotos = false
    init(bot: Bot, store: PhoneStore, messageID: String? = nil) {
        self.store = store; self.messageID = messageID
        if let retained = store.activeChats[bot.endpointID], retained.bot.id == bot.id {
            _chat = State(initialValue: retained)
        } else {
            _chat = State(initialValue: ChatStore(bot: bot))
        }
    }
    init(chat: ChatStore, store: PhoneStore, messageID: String? = nil) { self.store = store; self.messageID = messageID; _chat = State(initialValue: chat) }
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
                    ChatRequestsView(chat: chat)
                    ChatActivityView(activity: chat.activity, botName: chat.bot.name).id("activity")
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(.horizontal, 20).padding(.vertical, 24)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(DispatchStyle.paper)
            .onChange(of: chat.messages.last(where: { $0.role == "assistant" })?.text) { _, _ in if messageID == nil || locatedNotification { reader.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: chat.messages.count) { _, _ in
                if !locatedNotification, let messageID, chat.messages.contains(where: { $0.id == messageID }) {
                    reader.scrollTo(messageID, anchor: .center); locatedNotification = true
                } else { reader.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.activity.phase) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
            .safeAreaInset(edge: .bottom) { composer }
            .task {
                store.activeChats[chat.bot.endpointID] = chat
                await chat.open(store: store)
                if let messageID, chat.messages.contains(where: { $0.id == messageID }) {
                    await Task.yield()
                    reader.scrollTo(messageID, anchor: .center); locatedNotification = true
                }
            }
        }
        .onAppear { chatVisible = true; updateRaiseTarget() }
        .onDisappear { chatVisible = false; raiseToCall.hideChat(chat) }
        .onChange(of: obscuresChat) { _, _ in updateRaiseTarget() }
        .navigationTitle(chat.bot.name).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DispatchStyle.paper, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(chat.bot.name).font(.headline)
                    Text(store.endpoints.first(where: { $0.id == chat.bot.endpointID })?.label ?? "Bot Chat")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SubagentsView(chat: chat) } label: { Image(systemName: "person.2") }
                    .accessibilityLabel("Subagents for \(chat.bot.name)")
                    .accessibilityIdentifier("openSubagents")
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
        .sheet(isPresented: $showSavedChats) { SavedChatsView(chat: chat) }
        .sheet(item: $chat.commands.output) { ChatCommandOutputView(output: $0) }
        .sheet(item: $chat.commands.route) { route in
            NavigationStack {
                Group {
                    switch route {
                    case .help: ChatCommandsView(chat: chat)
                    case .agents: SubagentsView(chat: chat)
                    case .model: BotModelView(bot: chat.bot, store: store, runtimeID: chat.runtimeID)
                    case .browser: VMControlView(bot: chat.bot, store: store, chat: chat)
                    case .profile: Text("Return to the bot list to choose a bot. Each bot keeps its own conversation and settings.").padding(20)
                    }
                }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { chat.commands.route = nil } } }
            }
        }
        .task(id: chat.draft + ":" + chat.commands.bindingID.uuidString) { await chat.commands.complete(chat.draft) }
        .photosPicker(isPresented: $showPhotos, selection: $photos, maxSelectionCount: 5, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): urls.forEach { chat.importFile($0) }
            case .failure(let error): chat.error = error.localizedDescription
            }
        }
        .task(id: photos) { await importPhotos() }
    }
    private var obscuresChat: Bool {
        showSavedChats || showFiles || showPhotos || chat.commands.output != nil || chat.commands.route != nil
    }
    private func updateRaiseTarget() {
        if chatVisible && !obscuresChat { raiseToCall.showChat(chat) }
        else { raiseToCall.hideChat(chat) }
    }
    private var composer: some View {
        VStack(spacing: 8) {
            if !chat.commands.completions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(chat.commands.completions) { completion in
                            Button {
                                if let completed = chat.commands.apply(completion, to: chat.draft) { chat.draft = completed; composerFocused = true }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(completion.display).font(.subheadline.weight(.medium))
                                    if !completion.detail.isEmpty { Text(completion.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }.padding(10).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            }.tint(.primary).disabled(chat.sending)
                        }
                    }
                }.accessibilityLabel("Command suggestions")
            }
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
            if importingPhotos { ProgressView("Preparing attachment…").font(.subheadline) }
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
                    Button("Photos", systemImage: "photo") { composerFocused = false; showPhotos = true }
                    Button("Files", systemImage: "doc") { composerFocused = false; showFiles = true }
                    Button("Saved chats", systemImage: "clock") { composerFocused = false; showSavedChats = true }
                    Button("Commands", systemImage: "command") { composerFocused = false; chat.commands.route = .help }
                } label: { Image(systemName: "plus").font(.title3).frame(width: 44, height: 44) }
                .accessibilityLabel("Attach photos or files").disabled(chat.sending || importingPhotos)
                ChatComposer(text: $chat.draft, focused: Binding(get: { composerFocused }, set: { composerFocused = $0 }), placeholder: "Message \(chat.bot.name)") { providers in
                    Task { await importPasted(providers) }
                }
                .overlay(alignment: .topLeading) {
                    if chat.draft.isEmpty { Text("Message \(chat.bot.name)").foregroundStyle(.tertiary).allowsHitTesting(false) }
                }
                .padding(.vertical, 12)
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
    private func importPasted(_ providers: [NSItemProvider]) async {
        guard !importingPhotos, !chat.sending else { return }
        importingPhotos = true
        defer { importingPhotos = false }
        for provider in providers.prefix(5) {
            do {
                let upload = try await ChatAttachmentImport.paste(provider)
                try Task.checkCancellation()
                chat.addUpload(name: upload.name, data: upload.data, image: upload.isImage)
            } catch is CancellationError { return }
            catch { chat.error = error.localizedDescription }
        }
        if providers.count > 5 { chat.error = "Attach up to five files with a combined size of 10 MiB." }
    }
    private func importPhotos() async {
        guard !photos.isEmpty else { return }
        importingPhotos = true
        defer { importingPhotos = false }
        for item in photos {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw GatewayError.message("This photo could not be read.") }
                try Task.checkCancellation()
                let upload = try ChatAttachmentImport.photo(data, name: "photo-\(UUID().uuidString.prefix(8))")
                chat.addUpload(name: upload.name, data: upload.data, image: true)
            } catch is CancellationError { return }
            catch { chat.error = error.localizedDescription }
        }
        photos = []
    }

}
