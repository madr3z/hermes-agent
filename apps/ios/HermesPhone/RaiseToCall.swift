import CoreMotion
import Foundation
import HermesGateway
import Observation
import UIKit

struct RaiseCallTarget: Codable, Hashable, Identifiable {
    let endpointID: UUID
    let baseURL: URL
    let profile: String
    let name: String
    var id: String { "\(endpointID):\(baseURL.absoluteString):\(profile)" }
    init(bot: Bot, endpoint: GatewayEndpoint) {
        endpointID = endpoint.id; baseURL = endpoint.baseURL; profile = bot.profile; name = bot.name
    }
    func matches(_ bot: Bot, endpoints: [GatewayEndpoint]) -> Bool {
        bot.endpointID == endpointID && bot.profile == profile && endpoints.contains { $0.id == endpointID && $0.baseURL == baseURL }
    }
}

@MainActor enum RaiseProximityMonitoring {
    private static var gestureNeeded = false
    private static var receiverNeeded = false
    static func setGestureNeeded(_ needed: Bool) { gestureNeeded = needed; update() }
    static func setReceiverNeeded(_ needed: Bool) { receiverNeeded = needed; update() }
    private static func update() { UIDevice.current.isProximityMonitoringEnabled = gestureNeeded || receiverNeeded }
}

/// A covered sensor alone cannot start a call. A fresh raise must follow a lowered, uncovered phone.
struct RaiseToCallGesture {
    private var loweredAt: TimeInterval?
    private var lastLoweredAt: TimeInterval?
    private var movedAt: TimeInterval?
    private var nearAt: TimeInterval?
    mutating func reset() { loweredAt = nil; lastLoweredAt = nil; movedAt = nil; nearAt = nil }
    mutating func update(time: TimeInterval, near: Bool, gravityY: Double, gravityZ: Double,
                         acceleration: Double, rotation: Double, eligible: Bool) -> Bool {
        guard eligible else { reset(); return false }
        if !near {
            nearAt = nil
            if gravityY > -0.75 || abs(gravityZ) > 0.6 {
                if loweredAt == nil { loweredAt = time }
                lastLoweredAt = time
            }
            if let loweredAt, let lastLoweredAt, time - loweredAt >= 0.2, time - lastLoweredAt < 0.75,
               acceleration > 0.12, rotation > 0.6 { movedAt = time }
            return false
        }
        guard loweredAt != nil, let movedAt, time - movedAt <= 1.5,
              gravityY < -0.55, abs(gravityZ) < 0.8 else { reset(); return false }
        if nearAt == nil { nearAt = time }
        guard time - nearAt! >= 0.25 else { return false }
        reset()
        return true
    }
}

@MainActor @Observable final class RaiseToCallController {
    var enabled: Bool { didSet { preferences.set(enabled, forKey: "raise-to-call-enabled"); updateMonitoring() } }
    var defaultTarget: RaiseCallTarget? {
        didSet {
            preferences.set(try? JSONEncoder().encode(defaultTarget), forKey: "raise-to-call-target")
            gesture.reset(); cancelPreparation()
        }
    }
    private(set) var pending = false
    var error: String?
    private(set) var sensorUnavailable = false
    private(set) var visibleChat: ChatStore?
    private var foreground = false
    private weak var store: PhoneStore?
    private let preferences: UserDefaults
    private let motion = CMMotionManager()
    private var gesture = RaiseToCallGesture()
    private var preparation: Task<Void, Never>?
    private var generation = UUID()

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        enabled = preferences.object(forKey: "raise-to-call-enabled") as? Bool ?? true
        if let data = preferences.data(forKey: "raise-to-call-target") {
            defaultTarget = try? JSONDecoder().decode(RaiseCallTarget.self, from: data)
        }
    }
    func configure(store: PhoneStore, foreground: Bool) {
        self.store = store; self.foreground = foreground; updateMonitoring()
    }
    func showChat(_ chat: ChatStore) {
        guard visibleChat !== chat else { return }
        visibleChat = chat; gesture.reset(); cancelPreparation()
    }
    func hideChat(_ chat: ChatStore) {
        guard visibleChat === chat else { return }
        visibleChat = nil; gesture.reset(); cancelPreparation()
    }
    var callOccupied: Bool {
        let calls = CallPresentation.shared
        let contact = MobileContact.shared
        return VoiceCall.isCallInProgress || calls.isPresented || calls.outgoing?.voice.active == true || calls.outgoing?.voice.connecting == true ||
            contact.callInvitation != nil || contact.voice.active || contact.voice.connecting
    }
    private var eligible: Bool {
        foreground && enabled && !pending && !callOccupied && UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
    }
    private func updateMonitoring() {
        guard foreground && enabled else {
            motion.stopDeviceMotionUpdates(); RaiseProximityMonitoring.setGestureNeeded(false)
            gesture.reset(); cancelPreparation(); return
        }
        guard !motion.isDeviceMotionActive else { return }
        RaiseProximityMonitoring.setGestureNeeded(true)
        sensorUnavailable = !motion.isDeviceMotionAvailable || !UIDevice.current.isProximityMonitoringEnabled
        guard !sensorUnavailable else { RaiseProximityMonitoring.setGestureNeeded(false); return }
        motion.deviceMotionUpdateInterval = 0.05
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
            guard let self, let sample else { return }
            let acceleration = sample.userAcceleration
            let rotation = sample.rotationRate
            let raised = self.gesture.update(time: sample.timestamp, near: UIDevice.current.proximityState,
                gravityY: sample.gravity.y, gravityZ: sample.gravity.z,
                acceleration: sqrt(acceleration.x * acceleration.x + acceleration.y * acceleration.y + acceleration.z * acceleration.z),
                rotation: sqrt(rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z), eligible: self.eligible)
            if raised { self.beginCall() }
        }
    }
    private func cancelPreparation() {
        generation = UUID(); preparation?.cancel(); preparation = nil; pending = false
    }
    func selectedTarget(in store: PhoneStore) -> RaiseCallTarget? {
        if let visibleChat {
            return store.endpoints.first(where: { $0.id == visibleChat.bot.endpointID }).map { RaiseCallTarget(bot: visibleChat.bot, endpoint: $0) }
        }
        return defaultTarget
    }
    func beginCall() {
        guard eligible, let store else { return }
        let visible = visibleChat
        let target = selectedTarget(in: store)
        guard let target else {
            error = visible == nil ? "Choose a default agent in Call settings, or open an agent chat." : "This chat’s gateway is unavailable. Reconnect it before calling."
            return
        }
        guard store.endpoints.contains(where: { $0.id == target.endpointID && $0.baseURL == target.baseURL }) else {
            error = "The selected agent’s gateway changed or was removed. Choose the agent again in Call settings."; return
        }
        pending = true
        let attempt = UUID(); generation = attempt
        preparation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == attempt { self.pending = false; self.preparation = nil } }
            do {
                let chat: ChatStore
                if let visible { chat = visible }
                else {
                    let client = try await store.client(for: target.endpointID)
                    let rows = try await client.request("profiles.list", ["include_sessions": .bool(true)])
                    guard let row = rows["profiles"].array.first(where: { $0["name"].string == target.profile }) else {
                        throw GatewayError.message("The selected agent is no longer available. Choose an agent in Call settings.")
                    }
                    chat = ChatStore(bot: Bot(endpointID: target.endpointID, row: row))
                    await chat.open(store: store)
                }
                try Task.checkCancellation()
                guard self.generation == attempt, self.foreground, self.enabled, !self.callOccupied,
                      UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
                      self.visibleChat === visible, (visible != nil || self.defaultTarget == target),
                      target.matches(chat.bot, endpoints: store.endpoints) else { return }
                guard chat.connected, !chat.loading, !chat.sending else {
                    throw GatewayError.message(chat.error ?? "Wait for the agent chat to connect before calling.")
                }
                // The call now owns startup. Hiding the chat must not cancel its audio setup.
                self.preparation = nil; self.pending = false
                CallPresentation.shared.open(chat)
                await chat.startVoice(preferReceiver: true)
            } catch is CancellationError { return }
            catch { if self.generation == attempt { self.error = error.localizedDescription } }
        }
    }
}
