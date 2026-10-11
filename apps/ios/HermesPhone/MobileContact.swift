import AVFoundation
import CallKit
import Foundation
import HermesGateway
import Observation
import PushKit
import UIKit
import UserNotifications
import WebRTC

struct MobileContactSettings: Codable {
    var endpoint: GatewayEndpoint
    var deviceID: UUID
    var bots: Set<UUID>
    var calls: Bool
    var notifications: Bool
}

@MainActor @Observable final class MobileContact: NSObject {
    static let shared = MobileContact()
    private(set) var settings: [UUID: MobileContactSettings] = [:]
    var error: String?
    var detail: MobileInvitation?
    private(set) var callInvitation: MobilePush?
    private(set) var deferredCalls: [MobileDeferredCall] = []
    var postponing = false
    var chooseCallTime = false
    private var ringingTask: Task<Void, Never>?
    private static let postponeCategory = "hermes-ring-again"
    let voice = VoiceCall()
    private var registry: PKPushRegistry?
    private var voipToken: String?
    private var alertToken: String?
    private let provider: CXProvider
    private let callController = CXCallController()
    private var push: MobilePush?
    private var accepted = false
    private var audioActive = false
    private var guestClient: GatewayClient?
    private var runtimeID: String?
    private var callHistory: [ChatMessage] = []
    private var eventObserver: UUID?
    private var expiryTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var handled: [String: Double] = UserDefaults.standard.dictionary(forKey: "mobile-handled-calls") as? [String: Double] ?? [:]
    private var sessions: [UUID: ControllerSession] = [:]
    static var buildEnabled: Bool { (Bundle.main.object(forInfoDictionaryKey: "HermesPushEnabled") as? String) == "YES" }

    private override init() {
        let configuration = CXProviderConfiguration(localizedName: "Hermes")
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallGroups = 1; configuration.maximumCallsPerCallGroup = 1
        configuration.supportsVideo = false; configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        if let data = UserDefaults.standard.data(forKey: "mobile-contact-settings"),
           let records = try? JSONDecoder().decode([MobileContactSettings].self, from: data) {
            settings = Dictionary(uniqueKeysWithValues: records.map { ($0.endpoint.id, $0) })
        }
        provider.setDelegate(self, queue: .main)
        voice.onEnded = { [weak self] in self?.finish(reason: .remoteEnded) }
    }
    func launch() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.postponeCategory, actions: [
            UNNotificationAction(identifier: "ring-15", title: "Ring again in 15 minutes", options: [.authenticationRequired]),
            UNNotificationAction(identifier: "ring-60", title: "Ring again in 1 hour", options: [.authenticationRequired]),
            UNNotificationAction(identifier: "ring-custom", title: "Choose a time in Hermes", options: [.foreground, .authenticationRequired])
        ], intentIdentifiers: [])])
        Task { await refreshDeferredCalls() }
        guard Self.buildEnabled, settings.values.contains(where: { $0.calls || $0.notifications }) else { return }
        registerPushTypes(calls: settings.values.contains(where: \.calls), notifications: settings.values.contains(where: \.notifications))
    }
    func authenticationReplaced(_ endpoint: GatewayEndpoint) throws {
        guard let record = settings[endpoint.id], record.endpoint.baseURL != endpoint.baseURL else { return }
        settings.removeValue(forKey: endpoint.id)
        deferredCalls.removeAll { $0.controllerID == endpoint.id }
        try persist(); try MobileCredentials.remove(endpoint.id)
        if push?.controllerID == endpoint.id { end() }
        sessions.removeValue(forKey: endpoint.id)?.session.invalidateAndCancel()
    }
    func credentialsChanged(_ id: UUID) {
        sessions.removeValue(forKey: id)
    }
    private func persist() throws {
        UserDefaults.standard.set(try JSONEncoder().encode(Array(settings.values)), forKey: "mobile-contact-settings")
    }
    private func registerPushTypes(calls: Bool, notifications: Bool) {
        if calls {
            if registry == nil { registry = PKPushRegistry(queue: .main); registry?.delegate = self }
            registry?.desiredPushTypes = [.voIP]
        } else { registry?.desiredPushTypes = [] }
        if notifications { UIApplication.shared.registerForRemoteNotifications() }
    }
    func enable(endpoint: GatewayEndpoint, bots: Set<UUID>, calls: Bool, notifications: Bool, client: GatewayClient) async throws {
        guard Self.buildEnabled else { throw GatewayError.message("Push is disabled in this build. A push-capable signing profile and server APNs key are required.") }
        guard !bots.isEmpty else { throw GatewayError.message("Choose at least one VM bot.") }
        let status = try await client.http("api/plugins/bot-provisioning/v1/mobile/capabilities")
        guard status["status"].string == "configured" else { throw GatewayError.message("The controller's APNs service is disabled or unconfigured.") }
        if calls {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            guard await AVAudioApplication.requestRecordPermission() else { throw GatewayError.message("Enable microphone access before enabling incoming calls.") }
        }
        if notifications {
            guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else { throw GatewayError.message("Enable notification access in Settings.") }
        }
        registerPushTypes(calls: calls, notifications: notifications)
        let deadline = Date().addingTimeInterval(15)
        while (calls && voipToken == nil || notifications && alertToken == nil) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard (!calls || voipToken != nil), (!notifications || alertToken != nil) else { throw GatewayError.message("Apple did not return a device token. Check this build's signing and push capability.") }
        let record = MobileContactSettings(endpoint: endpoint, deviceID: settings[endpoint.id]?.deviceID ?? UUID(), bots: bots, calls: calls, notifications: notifications)
        if calls { try MobileCredentials.save(GatewayKeychain.readData(endpoint.id), id: endpoint.id) }
        do {
            try await register(record, client: client)
            settings[endpoint.id] = record; try persist()
            if !calls { try MobileCredentials.remove(endpoint.id) }
        } catch {
            if settings[endpoint.id]?.calls != true { try? MobileCredentials.remove(endpoint.id) }
            throw error
        }
    }
    func disable(_ endpoint: GatewayEndpoint, client: GatewayClient?) async throws {
        let record = settings[endpoint.id]
        if var disabled = record { disabled.calls = false; disabled.notifications = false; disabled.bots = []; settings[endpoint.id] = disabled }
        deferredCalls.removeAll { $0.controllerID == endpoint.id }
        try persist(); try MobileCredentials.remove(endpoint.id)
        sessions.removeValue(forKey: endpoint.id)?.session.invalidateAndCancel()
        if push?.controllerID == endpoint.id { end() }
        registerPushTypes(calls: settings.values.contains(where: \.calls), notifications: settings.values.contains(where: \.notifications))
        if let record, let client {
            _ = try await client.http("api/plugins/bot-provisioning/v1/mobile/devices/" + record.deviceID.uuidString.lowercased(), method: "DELETE")
            settings.removeValue(forKey: endpoint.id); try persist()
        }
    }
    private func register(_ record: MobileContactSettings, client: GatewayClient) async throws {
        _ = try await client.http("api/plugins/bot-provisioning/v1/mobile/devices/" + record.deviceID.uuidString.lowercased(), body: .object([
            "controller_id": .string(record.endpoint.id.uuidString.lowercased()), "bots": .array(record.bots.map { .string($0.uuidString.lowercased()) }),
            "calls": .bool(record.calls), "notifications": .bool(record.notifications),
            "voip_token": voipToken.map(JSON.string) ?? .null, "alert_token": alertToken.map(JSON.string) ?? .null]), method: "PUT")
    }
    private func client(_ controllerID: UUID, background: Bool) throws -> GatewayClient {
        guard let record = settings[controllerID], !background || record.calls else { throw GatewayError.message("This controller is not enabled for incoming calls.") }
        let data = try background ? MobileCredentials.read(controllerID) : MobileCredentials.foregroundData(controllerID)
        if sessions[controllerID] == nil { sessions[controllerID] = try ControllerSession.restore(endpoint: record.endpoint, data: data) }
        if let session = sessions[controllerID] {
            return GatewayClient(endpoint: record.endpoint, token: nil, session: session.session, onAuthenticationChange: { [weak self, session] in
                guard let self, self.settings[controllerID] != nil else { return }
                if self.settings[controllerID]?.calls == true { try MobileCredentials.save(session.savedData(), id: controllerID) }
                else { try GatewayKeychain.saveData(session.savedData(), id: controllerID) }
            })
        }
        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else { throw GatewayError.message("Sign in to this controller again.") }
        return GatewayClient(endpoint: record.endpoint, token: token)
    }
    private func resolve(_ push: MobilePush, accepting: Bool = false) async throws -> MobileInvitation {
        guard let record = settings[push.controllerID], accepting ? record.calls : record.calls || record.notifications else { throw GatewayError.message("Controller is no longer enabled.") }
        let client = try client(push.controllerID, background: record.calls)
        let path = "api/plugins/bot-provisioning/v1/mobile/invitations/" + push.invitationID.uuidString.lowercased()
        let value: JSON
        if accepting {
            value = try await client.http(path + "/actions", body: .object(["device_id": .string(record.deviceID.uuidString.lowercased()), "action": .string("accept")]))
        } else {
            value = try await client.http(path + "/devices/" + record.deviceID.uuidString.lowercased())
        }
        return try MobileInvitation(value, push: push, allowedGuests: record.bots, accepting: accepting)
    }
    private func action(_ push: MobilePush, _ action: String) async {
        guard let record = settings[push.controllerID], let client = try? client(push.controllerID, background: record.calls) else { return }
        do {
            _ = try await client.http("api/plugins/bot-provisioning/v1/mobile/invitations/" + push.invitationID.uuidString.lowercased() + "/actions", body: .object(["device_id": .string(record.deviceID.uuidString.lowercased()), "action": .string(action)]))
        } catch { self.error = "The controller could not confirm the call ended. The invitation will not ring again." }
    }
    func receive(_ incoming: MobilePush?, completion: @escaping () -> Void) {
        let id = incoming?.invitationID ?? UUID()
        let update = CXCallUpdate(); update.localizedCallerName = "Hermes"; update.remoteHandle = CXHandle(type: .generic, value: "Hermes")
        update.hasVideo = false; update.supportsHolding = false; update.supportsGrouping = false; update.supportsUngrouping = false; update.supportsDTMF = false
        handled = handled.filter { $0.value > Date().timeIntervalSince1970 - 86400 }
        let eligible = incoming.map { Self.buildEnabled && push == nil && $0.isCurrent() && settings[$0.controllerID]?.calls == true && handled[id.uuidString] == nil } ?? false
        if eligible { push = incoming; callInvitation = incoming; detail = nil; accepted = false }
        // Report before any network request, even if the local ownership check fails.
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] failure in
            completion()
            Task { @MainActor in
                guard let self else { return }
                if failure != nil { if eligible && self.push == incoming { self.push = nil }; return }
                guard eligible, let incoming, self.push == incoming else {
                    self.provider.reportCall(with: id, endedAt: Date(), reason: .failed); return
                }
                self.handled[id.uuidString] = Date().timeIntervalSince1970
                UserDefaults.standard.set(self.handled, forKey: "mobile-handled-calls")
                self.expiryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, incoming.expiresAt.timeIntervalSinceNow)))
                    guard !Task.isCancelled, let self, self.push == incoming, !self.accepted else { return }
                    self.finish(reason: .unanswered)
                }
                do {
                    let invitation = try await self.resolve(incoming)
                    guard self.push == incoming, !self.accepted else { return }
                    let details = CXCallUpdate(); details.localizedCallerName = invitation.name
                    self.provider.reportCall(with: id, updated: details)
                    self.detail = invitation
                    await self.offerPostponement(incoming)
                    self.ringingTask = Task { [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled, let self, self.push == incoming, !self.accepted, !self.postponing else { return }
                            do { _ = try await self.resolve(incoming) }
                            catch {
                                if self.push == incoming, !self.accepted, !self.postponing {
                                    self.finish(reason: .remoteEnded, notifyServer: false)
                                    self.callInvitation = nil; self.detail = nil
                                }
                                return
                            }
                        }
                    }
                } catch { if self.push == incoming && !self.accepted { self.finish(reason: .failed) } }
            }
        }
    }
    private func offerPostponement(_ incoming: MobilePush) async {
        let content = UNMutableNotificationContent()
        content.title = "Hermes incoming call"
        content.body = "Open Hermes or choose when the agent should ring again."
        content.categoryIdentifier = Self.postponeCategory
        content.userInfo = ["controller_id": incoming.controllerID.uuidString.lowercased(), "invitation_id": incoming.invitationID.uuidString.lowercased(), "expires_at": incoming.expiresAt.timeIntervalSince1970]
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: incoming.invitationID.uuidString, content: content, trigger: nil)) }
        catch { self.error = "Open Hermes to choose when this agent should ring again." }
    }
    func postpone(_ incoming: MobilePush, until date: Date) async {
        guard !postponing, !accepted else { return }
        postponing = true; error = nil
        defer { postponing = false }
        do {
            try MobileDeferredCall.validateTime(date)
            let value = try await scheduleAction(incoming.controllerID, invitationID: incoming.invitationID, action: "postpone", date: date)
            let record = try MobileDeferredCall(value, controllerID: incoming.controllerID, allowedGuests: settings[incoming.controllerID]?.bots ?? [])
            deferredCalls.removeAll { $0.id == record.id }; deferredCalls.append(record)
            if push == incoming { finish(reason: .remoteEnded, notifyServer: false) }
            if callInvitation == incoming { callInvitation = nil; detail = nil }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [incoming.invitationID.uuidString])
        } catch { self.error = "Could not schedule another ring: " + error.localizedDescription }
    }
    func changeTime(_ call: MobileDeferredCall, to date: Date) async {
        guard !postponing else { return }
        postponing = true; error = nil
        defer { postponing = false }
        do {
            try MobileDeferredCall.validateTime(date)
            let value = try await scheduleAction(call.controllerID, invitationID: call.id, action: "postpone", date: date)
            let updated = try MobileDeferredCall(value, controllerID: call.controllerID, allowedGuests: settings[call.controllerID]?.bots ?? [])
            deferredCalls.removeAll { $0.id == call.id }; deferredCalls.append(updated)
        } catch { self.error = "Could not change the ring time: " + error.localizedDescription }
    }
    func cancelPostponement(_ call: MobileDeferredCall) async {
        guard !postponing else { return }
        postponing = true; error = nil
        defer { postponing = false }
        do {
            _ = try await scheduleAction(call.controllerID, invitationID: call.id, action: "cancel_postpone")
            deferredCalls.removeAll { $0.id == call.id }
        } catch { self.error = "Could not cancel the scheduled ring: " + error.localizedDescription }
    }
    private func scheduleAction(_ controllerID: UUID, invitationID: UUID, action: String, date: Date? = nil) async throws -> JSON {
        guard let record = settings[controllerID], record.calls else { throw GatewayError.message("Incoming calls are disabled.") }
        var body: [String: JSON] = ["device_id": .string(record.deviceID.uuidString.lowercased()), "action": .string(action)]
        if let date { body["scheduled_at"] = .number(date.timeIntervalSince1970) }
        return try await client(controllerID, background: true).http("api/plugins/bot-provisioning/v1/mobile/invitations/" + invitationID.uuidString.lowercased() + "/actions", body: .object(body))
    }
    func refreshDeferredCalls() async {
        for record in settings.values where record.calls {
            do {
                let value = try await client(record.endpoint.id, background: true).http("api/plugins/bot-provisioning/v1/mobile/devices/" + record.deviceID.uuidString.lowercased() + "/deferred")
                let calls = try value["invitations"].array.map { try MobileDeferredCall($0, controllerID: record.endpoint.id, allowedGuests: record.bots) }
                deferredCalls.removeAll { $0.controllerID == record.endpoint.id }; deferredCalls.append(contentsOf: calls)
            } catch { self.error = "Could not refresh scheduled rings. Sign in and try again." }
        }
    }
    private func prepare(_ incoming: MobilePush) async throws {
        let invitation = try await resolve(incoming, accepting: true)
        guard push == incoming, let record = settings[incoming.controllerID] else { throw CancellationError() }
        accepted = true; expiryTask?.cancel(); ringingTask?.cancel()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [incoming.invitationID.uuidString])
        // Derive the URL from the saved controller and authenticated registry identity.
        let main = try client(incoming.controllerID, background: true)
        let row = try await main.http("api/plugins/bot-provisioning/v1/requests/" + invitation.guestID.uuidString.lowercased())
        guard push == incoming, row["phase"].string == "ready", row["request_id"].string.flatMap(UUID.init(uuidString:)) == invitation.guestID else { throw GatewayError.message("This VM is no longer available.") }
        var endpoint = try record.endpoint.provisionedGateway(row)
        guard endpoint.baseURL == record.endpoint.url(path: "api/plugins/bot-provisioning/v1/gateways/" + invitation.guestID.uuidString.lowercased()) else { throw GatewayError.message("The VM registry returned an invalid route.") }
        endpoint.id = invitation.guestID
        let data = try MobileCredentials.read(incoming.controllerID)
        let session = sessions[incoming.controllerID]
        let token = session == nil ? String(data: data, encoding: .utf8) : nil
        let guest = GatewayClient(endpoint: endpoint, token: token, session: session?.session ?? .shared, authenticationEndpoint: record.endpoint, onAuthenticationChange: { [session] in
            if let session { try MobileCredentials.save(session.savedData(), id: incoming.controllerID) }
        })
        guestClient = guest
        try await guest.connect()
        guard push == incoming else { guest.disconnect(); throw CancellationError() }
        let opened = try await CanonicalChat.open(profile: invitation.profile) { try await guest.request($0, $1) }
        guard push == incoming else { guest.disconnect(); throw CancellationError() }
        guard let runtime = opened["session_id"].string else { throw GatewayError.message("The canonical conversation returned no runtime session.") }
        callHistory = ChatMessage.project(opened["messages"].array).filter { $0.role == "user" || $0.role == "assistant" }
        callHistory.append(ChatMessage(id: "incoming-call-reason-" + incoming.invitationID.uuidString, role: "user", text: "I accepted the incoming Hermes call. The bot requested this call for: " + invitation.reason))
        runtimeID = runtime; detail = invitation; accepted = true; expiryTask?.cancel()
        eventObserver = guest.observe(events: { [weak self] event in
            guard let self else { return }
            guard event["type"].string == "message.complete", event["session_id"].string == self.runtimeID || event["payload"]["session_id"].string == self.runtimeID else { return }
            self.voice.taskFinished(event["payload"])
        }, disconnected: { [weak self] in self?.finish(reason: .failed) })
    }
    private func startAudioIfReady() {
        guard accepted, audioActive, let incoming = push, let guestClient, let runtimeID, !voice.connecting, !voice.active else { return }
        setupTask = Task { [weak self] in
            guard let self, self.push == incoming else { return }
            await self.voice.start(client: guestClient, profile: "default", runtimeID: runtimeID, history: self.callHistory, managedAudio: true)
            if !self.voice.active, self.push == incoming { self.error = self.voice.error; self.finish(reason: .failed) }
        }
    }
    func end() {
        guard let push else { return }
        callController.request(CXTransaction(action: CXEndCallAction(call: push.invitationID))) { [weak self] failure in
            if failure != nil { Task { @MainActor in self?.finish(reason: .failed) } }
        }
    }
    private func finish(reason: CXCallEndedReason, notifyServer: Bool = true) {
        guard let old = push else { return }
        let wasAccepted = accepted
        push = nil; accepted = false; audioActive = false
        setupTask?.cancel(); expiryTask?.cancel(); ringingTask?.cancel(); runtimeID = nil; callHistory = []
        if let eventObserver { guestClient?.removeObserver(eventObserver); self.eventObserver = nil }
        voice.stop(); guestClient?.disconnect(); guestClient = nil
        provider.reportCall(with: old.invitationID, endedAt: Date(), reason: reason)
        if notifyServer { Task { await action(old, wasAccepted ? "end" : "decline") } }
    }
    func receivedAlertToken(_ token: Data) {
        alertToken = token.map { String(format: "%02x", $0) }.joined(); synchronizeRegistrations()
    }
    private func synchronizeRegistrations() {
        Task {
            for record in settings.values {
                guard (!record.calls || voipToken != nil), (!record.notifications || alertToken != nil) else { continue }
                do { try await register(record, client: client(record.endpoint.id, background: record.calls)) }
                catch { self.error = "Could not update push registration. Open mobile settings and sign in again." }
            }
        }
    }
}

extension MobileContact: PKPushRegistryDelegate, CXProviderDelegate, UNUserNotificationCenterDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        voipToken = pushCredentials.token.map { String(format: "%02x", $0) }.joined(); synchronizeRegistrations()
    }
    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        voipToken = nil
        Task { for record in Array(settings.values) where record.calls { try? await disable(record.endpoint, client: try? client(record.endpoint.id, background: true)) } }
    }
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        let value = (try? JSONSerialization.data(withJSONObject: payload.dictionaryPayload)).flatMap { try? JSONDecoder().decode(JSON.self, from: $0) }
        receive(value.flatMap { try? MobilePush($0) }, completion: completion)
    }
    func providerDidReset(_ provider: CXProvider) { finish(reason: .failed) }
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard !postponing, let incoming = push, incoming.invitationID == action.callUUID else { action.fail(); return }
        setupTask = Task {
            do {
                try await prepare(incoming)
                guard push == incoming else { action.fail(); return }
                // Configure only. CallKit activates the session after the answer is fulfilled.
                VoiceCall.stopCurrent()
                let audio = RTCAudioSession.sharedInstance(); audio.useManualAudio = true; audio.isAudioEnabled = false
                let configuration = VoiceAudioConfiguration.install()
                audio.lockForConfiguration()
                do { try audio.setConfiguration(configuration); audio.unlockForConfiguration() }
                catch { audio.unlockForConfiguration(); throw error }
                action.fulfill(); startAudioIfReady()
            } catch { self.error = error.localizedDescription; action.fail(); finish(reason: .failed) }
        }
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) { finish(reason: .remoteEnded); action.fulfill() }
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if voice.muted != action.isMuted { voice.toggleMute() }; action.fulfill()
    }
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) { action.fail(); finish(reason: .failed) }
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        let audio = RTCAudioSession.sharedInstance(); audio.audioSessionDidActivate(audioSession); audio.isAudioEnabled = true
        audioActive = true; startAudioIfReady()
    }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        let audio = RTCAudioSession.sharedInstance(); audio.isAudioEnabled = false; audio.audioSessionDidDeactivate(audioSession)
        audioActive = false
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let value = (try? JSONSerialization.data(withJSONObject: response.notification.request.content.userInfo)).flatMap { try? JSONDecoder().decode(JSON.self, from: $0) }
        Task { @MainActor in
            defer { completionHandler() }
            guard let value, let incoming = try? MobilePush(value), incoming.isCurrent() else { return }
            if response.notification.request.content.categoryIdentifier == Self.postponeCategory {
                guard settings[incoming.controllerID]?.calls == true else { return }
                switch response.actionIdentifier {
                case "ring-15": await postpone(incoming, until: Date().addingTimeInterval(15 * 60))
                case "ring-60": await postpone(incoming, until: Date().addingTimeInterval(60 * 60))
                default:
                    // The custom picker needs no private details. Submission validates the invitation.
                    callInvitation = incoming; chooseCallTime = true
                }
            } else if settings[incoming.controllerID]?.notifications == true {
                do { detail = try await resolve(incoming) } catch { self.error = "This notification expired or its bot is no longer available." }
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([]) }
}

final class HermesApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool { MobileContact.shared.launch(); return true }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) { MobileContact.shared.receivedAlertToken(deviceToken) }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) { MobileContact.shared.error = "Apple push registration failed. Check signing and notification settings." }
}
