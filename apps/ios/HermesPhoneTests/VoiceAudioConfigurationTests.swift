import AVFoundation
import WebRTC
import XCTest
@testable import HermesPhone

final class VoiceAudioConfigurationTests: XCTestCase {
    func testWebRTCAudioStartupRetainsSpeakerAndBluetoothOptions() {
        let original = RTCAudioSessionConfiguration.webRTC()
        defer { RTCAudioSessionConfiguration.setWebRTC(original) }

        let configuration = VoiceAudioConfiguration.install()
        let startup = RTCAudioSessionConfiguration.webRTC()

        XCTAssertTrue(startup === configuration)
        XCTAssertEqual(startup.category, AVAudioSession.Category.playAndRecord.rawValue)
        XCTAssertEqual(startup.mode, AVAudioSession.Mode.voiceChat.rawValue)
        XCTAssertTrue(startup.categoryOptions.contains(.defaultToSpeaker))
        XCTAssertTrue(startup.categoryOptions.contains(.allowBluetoothHFP))
        XCTAssertEqual(startup.sampleRate, original.sampleRate)
        XCTAssertEqual(startup.ioBufferDuration, original.ioBufferDuration)
    }
}
