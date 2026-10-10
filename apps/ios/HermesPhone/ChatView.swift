import SwiftUI
import HermesGateway

struct ChatView: View {
    let store: PhoneStore
    @State private var chat: ChatStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showVoice = false
    init(bot: Bot, store: PhoneStore) { self.store = store; _chat = State(initialValue: ChatStore(bot: bot)) }
    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if chat.loading && chat.messages.isEmpty { ProgressView("Opening Bot Chat…").frame(maxWidth: .infinity) }
                    ForEach(chat.messages) { message in MessageBubble(message: message).id(message.id) }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messages.last?.text) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
            .safeAreaInset(edge: .bottom) { composer }
        }
        .navigationTitle(chat.bot.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("GPT Live", systemImage: "waveform") { showVoice = true }.disabled(!chat.connected).accessibilityIdentifier("startVoice")
            }
        }
        .task { await chat.open(store: store) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await chat.open(store: store) } }
            else if phase == .background { chat.voice.stop() }
        }
        .onDisappear { chat.voice.stop() }
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
            HStack(alignment: .bottom) {
                TextField("Message \(chat.bot.name)", text: $chat.draft, axis: .vertical).lineLimit(1...6).padding(10).background(.background, in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("chatComposer")
                Button { Task { await chat.send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.largeTitle) }
                    .disabled(!chat.connected || chat.sending || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(chat.busy ? "Queue message" : "Send message")
            }
        }.padding(.horizontal).padding(.vertical, 10).background(.bar)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 6) {
                if message.voice { Label("GPT Live", systemImage: "waveform").font(.caption2).foregroundStyle(.secondary) }
                Text(message.text).textSelection(.enabled).font(.body)
            }.padding(12).background(message.role == "user" ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            if message.role != "user" { Spacer(minLength: 20) }
        }
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
