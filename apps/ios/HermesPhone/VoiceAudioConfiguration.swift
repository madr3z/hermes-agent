import AVFoundation
import WebRTC

enum VoiceAudioConfiguration {
    static func install() -> RTCAudioSessionConfiguration {
        let configuration = RTCAudioSessionConfiguration()
        configuration.categoryOptions.formUnion([.defaultToSpeaker, .allowBluetoothHFP])
        // WebRTC reapplies this configuration when its audio unit starts.
        RTCAudioSessionConfiguration.setWebRTC(configuration)
        return configuration
    }
}
