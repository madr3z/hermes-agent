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
                header.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 20)
                DispatchStyle.rule.frame(height: 1).padding(.horizontal, 24)
                transcript
                controls.padding(.horizontal, 24).padding(.vertical, typeSize.isAccessibilitySize ? 8 : 20)
            }
            .foregroundStyle(DispatchStyle.ink)
            .background(DispatchStyle.paper)
            .navigationTitle("Voice call").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DispatchStyle.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $readingReason) {
                NavigationStack {
                    ScrollView { Text(reason ?? "").font(.body).textSelection(.enabled).padding(24).frame(maxWidth: .infinity, alignment: .leading) }
                        .foregroundStyle(DispatchStyle.ink).background(DispatchStyle.paper)
                        .navigationTitle("Reason for calling")
                        .toolbarBackground(DispatchStyle.paper, for: .navigationBar)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { readingReason = false } } }
                }
                .tint(DispatchStyle.forest)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) { Image(systemName: "chevron.down").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityIdentifier("callClose")
                        .accessibilityLabel(ringing ? "Decline and close" : "Back to app")
                        .accessibilityHint(voice.active ? "The call stays connected. Use End call to hang up." : "Close the call screen")
                }
            }
        }
        .tint(DispatchStyle.forest)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    if !typeSize.isAccessibilitySize {
                        Text("HERMES · VOICE").font(.caption2).tracking(2.5).foregroundStyle(DispatchStyle.secondary)
                    }
                    Text(name).font(typeSize.isAccessibilitySize ? .headline : DispatchStyle.serif(38))
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize {
                    Image(systemName: "waveform")
                        .font(.system(size: 26, weight: .light)).foregroundStyle(DispatchStyle.forest)
                        .frame(width: 56, height: 56).background(DispatchStyle.wash, in: Circle()).accessibilityHidden(true)
                }
            }
            HStack(spacing: 7) {
                Circle().fill(ringing ? DispatchStyle.rust : voice.active ? DispatchStyle.forest : DispatchStyle.secondary)
                    .frame(width: 7, height: 7).accessibilityHidden(true)
                Text(status).font(.subheadline).foregroundStyle(DispatchStyle.secondary)
                if let startedAt = voice.startedAt, voice.active { Text(startedAt, style: .timer).font(.subheadline.monospacedDigit()).foregroundStyle(DispatchStyle.secondary) }
            }.accessibilityElement(children: .combine)
            if let reason, !reason.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if !typeSize.isAccessibilitySize {
                        Text("REASON FOR CALLING").font(.caption2).tracking(1.8).foregroundStyle(DispatchStyle.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(reason).font(.body).lineLimit(typeSize.isAccessibilitySize ? 2 : 4)
                        .accessibilityLabel("Reason for calling: " + reason)
                    if typeSize.isAccessibilitySize || reason.count > 120 {
                        Button { readingReason = true } label: {
                            Text("Read full reason").font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(DispatchStyle.wash, in: RoundedRectangle(cornerRadius: 16))
                .padding(.top, 4)
            }
        }
    }
    private var transcript: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Live transcript").font(DispatchStyle.serif(24, relativeTo: .title3)).accessibilityAddTraits(.isHeader)
                Spacer()
                if !followsTranscript {
                    Button { followsTranscript = true } label: {
                        Text("Latest").font(.subheadline).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                }
            }.padding(.horizontal, 24).padding(.top, 16)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if voice.turns.isEmpty {
                            VStack(spacing: 10) {
                                if !typeSize.isAccessibilitySize { Image(systemName: ringing ? "phone.arrow.down.left" : "text.bubble").font(.title2) }
                                Text(ringing ? "Answer to hear why \(name) is calling." : "Your conversation will appear here.")
                                if !typeSize.isAccessibilitySize { Text("Speak naturally. You can interrupt at any time.").font(.footnote) }
                            }.foregroundStyle(DispatchStyle.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.vertical, 36)
                        }
                        ForEach(voice.turns) { turn in
                            VStack(alignment: turn.speaker == "user" ? .trailing : .leading, spacing: 6) {
                                Text(turn.speaker == "user" ? "You" : name).font(.caption.weight(.semibold)).foregroundStyle(DispatchStyle.forest)
                                Text(turn.text).font(.body).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: turn.speaker == "user" ? .trailing : .leading).padding(16)
                            .background(turn.speaker == "user" ? DispatchStyle.paper : DispatchStyle.wash, in: RoundedRectangle(cornerRadius: 16))
                            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(DispatchStyle.rule, lineWidth: turn.speaker == "user" ? 1 : 0) }
                            .accessibilityElement(children: .combine)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(.horizontal, 24).padding(.vertical, 16)
                }
                .simultaneousGesture(DragGesture().onChanged { _ in followsTranscript = false })
                .onChange(of: voice.turns) { _, _ in if followsTranscript { reader.scrollTo("latest", anchor: .bottom) } }
                .onChange(of: followsTranscript) { _, follow in if follow { reader.scrollTo("latest", anchor: .bottom) } }
            }
            if let error = voice.error { Text(error).font(.callout).foregroundStyle(DispatchStyle.rust).padding(.horizontal, 24).padding(.bottom, 8) }
            Text(voice.turns.isEmpty ? "Transcripts stay in Bot Chat" : voice.hasPendingTranscript ? "Transcript waiting to sync" : "Transcript saved to Bot Chat")
                .font(.caption).foregroundStyle(DispatchStyle.secondary).padding(.horizontal, 24).padding(.bottom, 12)
        }.frame(maxHeight: .infinity)
    }
    @ViewBuilder private var controls: some View {
        if ringing {
            controlLayout {
                callControl("Decline", icon: "phone.down.fill", fill: DispatchStyle.rust, foreground: DispatchStyle.paper, action: onEnd)
                if let onLater { callControl("Ring later", icon: "clock", action: onLater) }
                if let onAnswer { callControl("Answer", icon: "phone.fill", fill: DispatchStyle.button, foreground: .white, action: onAnswer) }
            }.frame(maxWidth: .infinity)
        } else if voice.active || voice.connecting || preparing {
            controlLayout {
                callControl(voice.muted ? "Unmute" : "Mute", icon: voice.muted ? "mic.slash.fill" : "mic.fill",
                            fill: voice.muted ? DispatchStyle.forest : DispatchStyle.wash,
                            foreground: voice.muted ? DispatchStyle.paper : DispatchStyle.ink) { voice.toggleMute() }.disabled(!voice.active)
                controlContentLayout {
                    Menu {
                        Button("iPhone", systemImage: "iphone") { voice.selectAudioRoute(.receiver) }
                        Button("Speaker", systemImage: "speaker.wave.2.fill") { voice.selectAudioRoute(.speaker) }
                        ForEach(voice.audioAccessories, id: \.id) { route in
                            Button(route.name, systemImage: "headphones") { voice.selectAudioRoute(.accessory(route.id)) }
                        }
                    } label: {
                        Image(systemName: voice.audioOutput == "Speaker" ? "speaker.wave.2.fill" : voice.audioOutput == "iPhone" ? "iphone" : "headphones")
                            .font(.system(size: 22)).foregroundStyle(DispatchStyle.ink)
                            .frame(width: 56, height: 56).background(DispatchStyle.wash, in: Circle())
                    }.accessibilityLabel("Choose audio output").accessibilityValue(voice.audioOutput)
                        .accessibilityIdentifier("callAudioOutput")
                    Text(voice.audioOutput).font(typeSize.isAccessibilitySize ? .body : .caption).lineLimit(1)
                        .foregroundStyle(DispatchStyle.ink)
                }.frame(maxWidth: .infinity)
                callControl("End call", icon: "phone.down.fill", fill: DispatchStyle.rust, foreground: DispatchStyle.paper, action: onEnd)
            }
        } else if let onStart {
            DispatchAction(title: "Start call", action: onStart).accessibilityIdentifier("callStart")
        } else {
            Button(action: onClose) {
                Text("Close").font(.body).frame(maxWidth: .infinity, minHeight: 48)
                    .background(DispatchStyle.wash, in: RoundedRectangle(cornerRadius: 22))
                    .contentShape(RoundedRectangle(cornerRadius: 22))
            }.buttonStyle(.plain).accessibilityIdentifier("callDismiss")
        }
    }
    private var controlLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 24))
    }
    private var controlContentLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 8))
    }
    private func callControl(_ title: String, icon: String, fill: Color = DispatchStyle.wash,
                             foreground: Color = DispatchStyle.ink, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            controlContentLayout {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(foreground)
                    .frame(width: 56, height: 56).background(fill, in: Circle())
                Text(title).font(typeSize.isAccessibilitySize ? .body : .caption).foregroundStyle(DispatchStyle.ink)
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
            Image(systemName: "phone.fill").foregroundStyle(DispatchStyle.forest)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(DispatchStyle.serif(23, relativeTo: .headline)).foregroundStyle(DispatchStyle.ink)
                Text(status).font(.caption).foregroundStyle(DispatchStyle.secondary)
            }
            Spacer()
            if !typeSize.isAccessibilitySize { actions }
            }
            if typeSize.isAccessibilitySize { actions }
        }.padding(16).background(DispatchStyle.wash, in: RoundedRectangle(cornerRadius: 16))
            .tint(DispatchStyle.forest).padding(.horizontal, 20).padding(.vertical, 8)
    }
    private var actions: some View {
        HStack(spacing: 16) {
            Button("Return", action: onReturn).buttonStyle(.bordered).frame(minHeight: 44)
            Button(endLabel, role: .destructive, action: onEnd).frame(minHeight: 44)
        }.fixedSize(horizontal: true, vertical: false)
    }

}
