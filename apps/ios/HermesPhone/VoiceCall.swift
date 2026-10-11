import AVFoundation
import Foundation
import HermesGateway
import Observation
import WebRTC

@MainActor @Observable final class VoiceCall: NSObject {
    var active = false
    var connecting = false
    var muted = false
    var error: String?
    var transcript = ""
    private var factory: RTCPeerConnectionFactory?
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var track: RTCAudioTrack?
    private var client: GatewayClient?
    private var profile = ""
    private var runtimeID = ""
    private var callID = ""
    private var utteranceID = ""
    private var lastSpeaker = ""
    private var lastEnd = 0.0
    private var delegation = VoiceDelegationTracker()
    private var fragments: [(speaker: String, text: String)] = []
    private var pending: [JSON] = []
    private var flushing = false
    private var outboxURL: URL?
    private var startup: UUID?

    func start(client: GatewayClient, profile: String, runtimeID: String, history: [ChatMessage]) async {
        guard !active && !connecting && peer == nil else { return }
        connecting = true; error = nil
        let generation = UUID(); startup = generation
        defer { if startup == generation { connecting = false } }
        do {
            // A call must not start when its server cannot retain the spoken transcript.
            _ = try await client.request("voice.live.transcript.list", ["session_id": .string(runtimeID), "profile": .string(profile)])
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard allowed else { throw GatewayError.message("Enable microphone access in Settings to use GPT Live.") }
            guard startup == generation else { return }
            self.client = client; self.profile = profile; self.runtimeID = runtimeID
            callID = UUID().uuidString; utteranceID = ""; lastSpeaker = ""; lastEnd = 0
            fragments = []; transcript = ""; muted = false
            try configureOutbox(client: client, profile: profile, runtimeID: runtimeID)
            try await flush()
            let audioConfiguration = VoiceAudioConfiguration.install()
            let audio = RTCAudioSession.sharedInstance()
            audio.lockForConfiguration()
            do {
                try audio.setConfiguration(audioConfiguration, active: true)
                audio.unlockForConfiguration()
            } catch { audio.unlockForConfiguration(); throw error }
            RTCInitializeSSL()
            let factory = RTCPeerConnectionFactory(); self.factory = factory
            let configuration = RTCConfiguration(); configuration.sdpSemantics = .unifiedPlan
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else { throw GatewayError.message("Could not create the native voice connection.") }
            self.peer = peer
            let track = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "microphone")
            self.track = track; peer.add(track, streamIds: ["hermes-voice"])
            channel = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration())
            channel?.delegate = self
            let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
                peer.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)) { sdp, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let sdp { continuation.resume(returning: sdp) }
                    else { continuation.resume(throwing: GatewayError.message("Missing SDP offer.")) }
                }
            }
            try await setDescription(offer, local: true, peer: peer)
            let deadline = Date().addingTimeInterval(8)
            while peer.iceGatheringState != .complete && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
                guard startup == generation else { return }
            }
            let turns = history.suffix(24).map { message in
                JSON.object(["type": .string("message"), "role": .string(message.role), "content": .array([.object(["type": .string(message.role == "user" ? "input_text" : "output_text"), "text": .string(String(message.text.prefix(1200)))])])])
            }
            let response = try await client.http("api/audio/voice-live/session", profile: profile, body: .object(["sdp": .string(peer.localDescription?.sdp ?? offer.sdp), "history": .array(turns)]))
            guard startup == generation else { return }
            guard let answer = response["transport"]["sdp"].string else { throw GatewayError.message("Gateway did not return a GPT Live SDP answer.") }
            try await setDescription(RTCSessionDescription(type: .answer, sdp: answer), local: false, peer: peer)
            let sessionDeadline = Date().addingTimeInterval(20)
            while !active && Date() < sessionDeadline {
                try await Task.sleep(for: .milliseconds(100))
                guard startup == generation else { return }
            }
            guard active else { throw GatewayError.message("GPT Live did not start within 20 seconds.") }
        } catch { self.error = error.localizedDescription; stop() }
    }
    func recoverTranscripts(client: GatewayClient, profile: String, runtimeID: String) async {
        guard !active, !connecting, !flushing else { return }
        do {
            try configureOutbox(client: client, profile: profile, runtimeID: runtimeID)
            try await flush()
        } catch { self.error = "Transcript waiting to sync: \(error.localizedDescription)" }
    }
    private func configureOutbox(client: GatewayClient, profile: String, runtimeID: String) throws {
        self.client = client; self.profile = profile; self.runtimeID = runtimeID
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let key = Data(profile.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        outboxURL = support.appendingPathComponent("voice-\(client.endpoint.id)-\(key).json")
        if let outboxURL, FileManager.default.fileExists(atPath: outboxURL.path) {
            pending = try JSONDecoder().decode([JSON].self, from: Data(contentsOf: outboxURL))
        }
    }
    private func setDescription(_ sdp: RTCSessionDescription, local: Bool, peer: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion: @Sendable (Error?) -> Void = { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            if local { peer.setLocalDescription(sdp, completionHandler: completion) }
            else { peer.setRemoteDescription(sdp, completionHandler: completion) }
        }
    }
    func stop() {
        let hadAudio = peer != nil
        startup = nil; active = false; connecting = false
        send(["type": .string("session.close")])
        track?.isEnabled = false; channel?.delegate = nil; channel?.close(); peer?.close()
        channel = nil; peer = nil; track = nil; factory = nil; delegation.cancel()
        if hadAudio {
            let audio = RTCAudioSession.sharedInstance()
            audio.lockForConfiguration(); try? audio.setActive(false); audio.unlockForConfiguration()
        }
        Task { do { try await flush() } catch { self.error = "Transcript retained on this phone: \(error.localizedDescription)" } }
    }
    func toggleMute() {
        muted.toggle(); track?.isEnabled = !muted
        send(["type": .string(muted ? "session.input_audio.mute" : "session.input_audio.unmute"), "event_id": .string(UUID().uuidString)])
    }
    func taskFinished(_ payload: JSON) {
        if let result = delegation.complete(payload) { speak(result) }
    }
    private func speak(_ result: VoiceTaskResult) {
        for start in stride(from: 0, to: result.text.count, by: 1400) {
            let chunk = String(result.text.dropFirst(start).prefix(1400))
            send(["type": .string("session.commentary.append"), "delegation_id": .string(result.delegationID), "event_id": .string(UUID().uuidString), "content": .string(chunk)])
        }
    }
    private func send(_ fields: [String: JSON]) {
        guard channel?.readyState == .open, let data = try? JSONEncoder().encode(JSON.object(fields)) else { return }
        _ = channel?.sendData(RTCDataBuffer(data: data, isBinary: false))
    }
    private func handle(_ event: JSON) async {
        switch event["type"].string {
        case "session.started": active = true; connecting = false
        case "session.input_transcript.delta", "session.output_transcript.delta":
            let speaker = event["type"].string == "session.input_transcript.delta" ? "user" : "assistant"
            let text = event["delta"].string ?? ""
            guard !text.isEmpty else { return }
            let start = event["start_ms"].number ?? 0, end = event["end_ms"].number ?? 0
            guard start.isFinite, end.isFinite, start >= 0, end >= start, text.count <= 16_000 else {
                self.error = "GPT Live returned an invalid transcript fragment. The call has stopped to avoid losing further speech."
                stop(); return
            }
            if speaker != lastSpeaker || start - lastEnd > 1500 { utteranceID = UUID().uuidString }
            lastSpeaker = speaker; lastEnd = end
            fragments.append((speaker, text)); fragments = Array(fragments.suffix(100))
            transcript += text
            pending.append(.object(["call_id": .string(callID), "utterance_id": .string(utteranceID), "event_id": event["event_id"].string.map(JSON.string) ?? .string(UUID().uuidString), "speaker": .string(speaker), "text": .string(text), "start_ms": .number(start), "end_ms": .number(end)]))
            do { try persist(); try await flush() }
            catch { self.error = "Transcript waiting to sync: \(error.localizedDescription)" }
        case "session.delegation.created":
            guard let id = event["delegation"]["id"].string, let client else { return }
            let context = fragments.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
            let recent = fragments.reversed().drop(while: { $0.speaker != "user" })
            let prompt = recent.prefix(while: { $0.speaker == "user" }).reversed().map(\.text).joined()
            guard !prompt.isEmpty else { self.error = "No spoken request was available to delegate."; return }
            let supersedesOwnTask = delegation.currentID != nil
            delegation.begin(id)
            let clientTurnID = delegation.clientTurnID!
            do {
                if supersedesOwnTask { _ = try await client.request("session.interrupt", owner()) }
                // The interrupt ACK is cooperative; the old run thread still owns the slot.
                let deadline = Date().addingTimeInterval(60)
                while true {
                    guard delegation.currentID == id, delegation.clientTurnID == clientTurnID else { return }
                    let snapshot = try await client.request("session.activate", owner())
                    if !snapshot["running"].bool { break }
                    guard Date() < deadline else { throw GatewayError.message("The previous task has not settled. Follow its state in Bot Chat.") }
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard delegation.currentID == id, delegation.clientTurnID == clientTurnID else { return }
                let result = try await VoiceSubmission.submit(owner(["text": .string(prompt), "surface": .string("voice-live"), "voice_context": .string(context), "queued": .bool(true), "client_turn_id": .string(clientTurnID)])) { try await client.request($0, $1) }
                if let completed = delegation.accept(result, delegationID: id, clientTurnID: clientTurnID) { speak(completed) }
                else if delegation.currentID == id && delegation.clientTurnID == clientTurnID && !delegation.hasTurnIdentity {
                    error = "This gateway accepted the task without turn correlation. Update the gateway to hear queued task results; follow this result in Bot Chat."
                    delegation.cancel()
                }
            } catch {
                if delegation.currentID == id && delegation.clientTurnID == clientTurnID { self.error = error.localizedDescription; delegation.cancel() }
            }
        case "session.closed": stop()
        case "error": error = event["error"]["message"].string ?? "GPT Live reported an error."
        default: break
        }
    }
    private func owner(_ fields: [String: JSON] = [:]) -> [String: JSON] {
        ["session_id": .string(runtimeID), "profile": .string(profile)].merging(fields) { _, value in value }
    }
    private func persist() throws {
        guard let outboxURL else { return }
        try JSONEncoder().encode(pending).write(to: outboxURL, options: [.atomic, .completeFileProtection])
    }
    private func flush() async throws {
        guard !flushing, let client else { return }
        flushing = true; defer { flushing = false }
        while let entry = pending.first {
            guard case .object(let fields) = entry else { break }
            _ = try await client.request("voice.live.transcript.append", owner(fields))
            pending.removeFirst(); try persist()
        }
    }
}

extension VoiceCall: RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed {
            Task { @MainActor in
                guard self.peer === peerConnection else { return }
                self.error = "Voice connection failed."; self.stop()
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let event = try? JSONDecoder().decode(JSON.self, from: buffer.data) else { return }
        Task { @MainActor in
            guard self.channel === dataChannel else { return }
            await self.handle(event)
        }
    }
}
