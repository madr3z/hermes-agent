import SwiftUI
import HermesGateway

/// The same conversation surface is used for both call directions.
struct CallScreen: View {
    @Bindable var voice: VoiceCall
    let name: String
    var reason: String? = nil
    var ringing = false
    var preparing = false
    var onStart: (() -> Void)? = nil
    var onAnswer: (() -> Void)? = nil
    var onLater: (() -> Void)? = nil
    let onEnd: () -> Void
    let onClose: () -> Void
    @State private var followsTranscript = true
    @State private var readingReason = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var status: String {
        if ringing { return "Incoming call" }
        if preparing { return "Connecting securely…" }
        if voice.muted && voice.active { return "Microphone muted" }
        return voice.activity
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header.padding(.horizontal, 20).padding(.bottom, 20)
                Divider()
                transcript
                controls.padding(.horizontal, 20).padding(.vertical, typeSize.isAccessibilitySize ? 8 : 20)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Voice call").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $readingReason) {
                NavigationStack {
                    ScrollView { Text(reason ?? "").font(.body).textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading) }
                        .navigationTitle("Reason for calling")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { readingReason = false } } }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) { Image(systemName: "chevron.down").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel(ringing ? "Decline and close" : "Back to app")
                        .accessibilityHint(voice.active ? "The call stays connected. Use End call to hang up." : "Close the call screen")
                }
            }
        }
    }
    private var header: some View {
        VStack(spacing: 10) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .medium)).foregroundStyle(.tint)
                    .frame(width: 64, height: 64).background(.tint.opacity(0.1), in: Circle()).accessibilityHidden(true)
            }
            Text(name).font(typeSize.isAccessibilitySize ? .headline : .title2.weight(.semibold))
            HStack(spacing: 7) {
                Circle().fill(ringing ? Color.orange : voice.active ? .green : .secondary).frame(width: 7, height: 7)
                Text(status).font(.subheadline).foregroundStyle(.secondary)
                if let startedAt = voice.startedAt, voice.active { Text(startedAt, style: .timer).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
            }.accessibilityElement(children: .combine)
            if let reason, !reason.isEmpty {
                Text(reason).font(.body).multilineTextAlignment(.center).lineLimit(typeSize.isAccessibilitySize ? 2 : 4)
                    .padding(.top, 2).accessibilityLabel("Reason for calling: " + reason)
                if typeSize.isAccessibilitySize || reason.count > 120 { Button("Read full reason") { readingReason = true }.font(.subheadline) }
            }
        }
    }
    private var transcript: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Live transcript").font(.subheadline.weight(.semibold))
                Spacer()
                if !followsTranscript { Button("Latest") { followsTranscript = true }.font(.subheadline) }
            }.padding(.horizontal, 20).padding(.top, 16)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if voice.turns.isEmpty {
                            VStack(spacing: 10) {
                                if !typeSize.isAccessibilitySize { Image(systemName: ringing ? "phone.arrow.down.left" : "text.bubble").font(.title2) }
                                Text(ringing ? "Answer to hear why \(name) is calling." : "Your conversation will appear here.")
                                if !typeSize.isAccessibilitySize { Text("Speak naturally. You can interrupt at any time.").font(.footnote) }
                            }.foregroundStyle(.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.vertical, 36)
                        }
                        ForEach(voice.turns) { turn in
                            VStack(alignment: turn.speaker == "user" ? .trailing : .leading, spacing: 6) {
                                Text(turn.speaker == "user" ? "You" : name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(turn.text).font(.body).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: turn.speaker == "user" ? .trailing : .leading).padding(16)
                            .background(turn.speaker == "user" ? Color.accentColor.opacity(0.07) : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                            .accessibilityElement(children: .combine)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(.horizontal, 20).padding(.vertical, 16)
                }
                .simultaneousGesture(DragGesture().onChanged { _ in followsTranscript = false })
                .onChange(of: voice.turns) { _, _ in if followsTranscript { reader.scrollTo("latest", anchor: .bottom) } }
                .onChange(of: followsTranscript) { _, follow in if follow { reader.scrollTo("latest", anchor: .bottom) } }
            }
            if let error = voice.error { Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 8) }
            Text(voice.turns.isEmpty ? "Transcripts stay in Bot Chat" : voice.hasPendingTranscript ? "Transcript waiting to sync" : "Transcript saved to Bot Chat")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
        }.frame(maxHeight: .infinity)
    }
    @ViewBuilder private var controls: some View {
        if ringing {
            controlLayout {
                callControl("Decline", icon: "phone.down.fill", colour: .red, action: onEnd)
                if let onLater { callControl("Ring later", icon: "clock", colour: .secondary, action: onLater) }
                if let onAnswer { callControl("Answer", icon: "phone.fill", colour: .green, action: onAnswer) }
            }.frame(maxWidth: .infinity)
        } else if voice.active || voice.connecting || preparing {
            controlLayout {
                callControl(voice.muted ? "Unmute" : "Mute", icon: voice.muted ? "mic.slash.fill" : "mic.fill", colour: voice.muted ? .orange : .secondary) { voice.toggleMute() }.disabled(!voice.active)
                controlContentLayout {
                    Menu {
                        Button("iPhone", systemImage: "iphone") { voice.selectAudioRoute(.receiver) }
                        Button("Speaker", systemImage: "speaker.wave.2.fill") { voice.selectAudioRoute(.speaker) }
                        ForEach(voice.audioAccessories, id: \.id) { route in
                            Button(route.name, systemImage: "headphones") { voice.selectAudioRoute(.accessory(route.id)) }
                        }
                    } label: {
                        Image(systemName: voice.audioOutput == "Speaker" ? "speaker.wave.2.fill" : voice.audioOutput == "iPhone" ? "iphone" : "headphones")
                            .font(.system(size: 22)).foregroundStyle(.primary)
                            .frame(width: 56, height: 56).background(Color(uiColor: .secondarySystemBackground), in: Circle())
                    }.accessibilityLabel("Choose audio output")
                    Text(voice.audioOutput).font(typeSize.isAccessibilitySize ? .body : .caption).lineLimit(1)
                }.frame(maxWidth: .infinity)
                callControl("End call", icon: "phone.down.fill", colour: .red, action: onEnd)
            }
        } else if let onStart {
            Button("Start call", systemImage: "phone.fill", action: onStart).buttonStyle(.borderedProminent).controlSize(.large)
        } else { Button("Close", action: onClose).buttonStyle(.bordered).controlSize(.large) }
    }
    private var controlLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 24))
    }
    private var controlContentLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 8))
    }
    private func callControl(_ title: String, icon: String, colour: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            controlContentLayout {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(colour == .secondary ? Color.primary : .white)
                    .frame(width: 56, height: 56).background(colour == .secondary ? Color(uiColor: .secondarySystemBackground) : colour, in: Circle())
                Text(title).font(typeSize.isAccessibilitySize ? .body : .caption).foregroundStyle(.primary)
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}

struct CallSummary: View {
    let name: String
    let status: String
    let endLabel: String
    let onReturn: () -> Void
    let onEnd: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
            Image(systemName: "phone.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.subheadline.weight(.semibold))
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !typeSize.isAccessibilitySize { actions }
            }
            if typeSize.isAccessibilitySize { actions }
        }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 20).padding(.vertical, 8)
    }
    private var actions: some View {
        HStack(spacing: 16) {
            Button("Return", action: onReturn).buttonStyle(.bordered).frame(minHeight: 44)
            Button(endLabel, role: .destructive, action: onEnd).frame(minHeight: 44)
        }.fixedSize(horizontal: true, vertical: false)
    }

}
