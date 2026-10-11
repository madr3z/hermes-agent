import SwiftUI

struct VoiceView: View {
    @Bindable var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        CallScreen(voice: chat.voice, name: chat.bot.name,
                   onStart: { Task { await chat.startVoice() } },
                   onEnd: { chat.voice.stop() }, onClose: { dismiss() })
    }
}
