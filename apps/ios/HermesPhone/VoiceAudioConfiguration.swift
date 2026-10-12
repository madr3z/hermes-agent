import AVFoundation
import WebRTC

enum VoiceAudioConfiguration {
    static func install(preferReceiver: Bool = false) -> RTCAudioSessionConfiguration {
        let configuration = RTCAudioSessionConfiguration()
        configuration.categoryOptions.insert(.allowBluetoothHFP)
        if preferReceiver { configuration.categoryOptions.remove(.defaultToSpeaker) }
        else { configuration.categoryOptions.insert(.defaultToSpeaker) }
        // WebRTC reapplies this configuration when its audio unit starts.
        RTCAudioSessionConfiguration.setWebRTC(configuration)
        return configuration
    }

    static func select(_ route: VoiceAudioRoute, session: AVAudioSession = .sharedInstance()) throws {
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        let configuration = install(preferReceiver: route != .speaker)
        try audio.setConfiguration(configuration)
        try session.overrideOutputAudioPort(.none)
        switch route {
        case .receiver:
            try session.setPreferredInput(session.availableInputs?.first { $0.portType == .builtInMic })
        case .speaker:
            try session.setPreferredInput(nil)
            try session.overrideOutputAudioPort(.speaker)
        case .accessory(let uid):
            guard let input = session.availableInputs?.first(where: { $0.uid == uid }) else {
                throw GatewayAudioError.disconnected
            }
            try session.setPreferredInput(input)
        }
    }
}

enum VoiceAudioRoute: Equatable {
    case receiver, speaker, accessory(String)
}

private enum GatewayAudioError: LocalizedError {
    case disconnected
    var errorDescription: String? { "This audio device disconnected. Choose another output." }
}
