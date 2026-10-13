import HermesGateway
import SwiftUI

struct MobileContactView: View {
    let endpoint: GatewayEndpoint
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var calls = false
    @State private var notifications = false
    @State private var bots: Set<UUID> = []
    @State private var rows: [JSON] = []
    @State private var status = "Checking controller…"
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            DispatchForm {
                DispatchSection {
                    Text(status).foregroundStyle(DispatchStyle.secondary)
                    Toggle("Incoming calls", isOn: $calls)
                    Toggle("Bot notifications", isOn: $notifications)
                }.disabled(!MobileContact.buildEnabled || saving)
                DispatchSection("Bots allowed to contact this phone") {
                    ForEach(rows, id: \.self) { row in
                        if let id = row["request_id"].string.flatMap(UUID.init(uuidString:)) {
                            Toggle(row["name"].string ?? "Bot", isOn: Binding(get: { bots.contains(id) }, set: { if $0 { bots.insert(id) } else { bots.remove(id) } }))
                        }
                    }
                    if rows.isEmpty { Text("No ready VM bots on this controller.").foregroundStyle(DispatchStyle.secondary) }
                }.disabled(saving)
                DispatchSection {
                    Text("Calls ring through CallKit, including when this phone is locked. Enabling calls saves a separate controller credential on this device. iOS can read it after the first unlock until the phone restarts. Turning calls off removes this copy. Your microphone and GPT Live session start only after you answer.").font(.footnote)
                    Text("Push messages contain IDs and generic Hermes text. Private bot details load from your authenticated controller. Delivery requires network access to your private gateway and Apple push service.").font(.footnote)
                }
                if let error { DispatchSection { Text(error).foregroundStyle(DispatchStyle.rust) } }
                Button(saving ? "Saving…" : "Save") { save() }.disabled(saving || !MobileContact.buildEnabled)
                if MobileContact.shared.settings[endpoint.id] != nil {
                    Button("Disable calls and notifications", role: .destructive) { disable() }.disabled(saving)
                }
            }
            .dispatchTitle("Calls and notifications")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                if let saved = MobileContact.shared.settings[endpoint.id] { calls = saved.calls; notifications = saved.notifications; bots = saved.bots }
                do {
                    let client = try await store.client(for: endpoint.id)
                    rows = try await client.http("api/plugins/bot-provisioning/v1/requests")["requests"].array.filter { $0["phase"].string == "ready" }
                    let result = try await client.http("api/plugins/bot-provisioning/v1/mobile/capabilities")
                    status = MobileContact.buildEnabled ? "Controller push: \(result["status"].string ?? "unconfigured")" : "Push is disabled in this build. Apple signing and the server APNs key must be configured first."
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    private func save() {
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                let client = try await store.client(for: endpoint.id)
                if !calls && !notifications { try await MobileContact.shared.disable(endpoint, client: client) }
                else { try await MobileContact.shared.enable(endpoint: endpoint, bots: bots, calls: calls, notifications: notifications, client: client) }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func disable() {
        saving = true; error = nil
        Task {
            defer { saving = false }
            do { try await MobileContact.shared.disable(endpoint, client: try? await store.client(for: endpoint.id)); dismiss() }
            catch { self.error = "Disabled on this phone. The controller could not confirm removal. Sign in and disable again." }
        }
    }
}

struct MobileCallBanner: View {
    @Bindable var contact = MobileContact.shared
    @State private var selectedTime = Date().addingTimeInterval(15 * 60)
    @State private var editingCall: MobileDeferredCall?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if contact.callInvitation != nil {
                CallSummary(name: contact.detail?.name ?? "Hermes",
                            status: contact.callIsAccepted ? contact.voice.activity : "Incoming call",
                            endLabel: contact.callIsAccepted ? "End" : "Decline",
                            onReturn: { contact.callPresentation.isPresented = true }, onEnd: { contact.end() })
            }
            ForEach(contact.deferredCalls) { call in
                HStack {
                    VStack(alignment: .leading) {
                        Text(call.name + " will ring again").font(DispatchStyle.serif(23, relativeTo: .headline))
                        Text(call.scheduledAt, format: .dateTime.month().day().hour().minute()).font(.caption)
                    }
                    Spacer()
                    Button("Change time") { editingCall = call; selectedTime = call.scheduledAt; contact.chooseCallTime = true }
                    Button("Cancel", role: .destructive) { Task { await contact.cancelPostponement(call) } }
                }.disabled(contact.postponing)
            }
            if let error = contact.error {
                HStack { Text(error).font(.caption).foregroundStyle(DispatchStyle.rust); Spacer(); Button("Dismiss") { contact.error = nil } }
            }
        }
        .padding(contact.callInvitation != nil || !contact.deferredCalls.isEmpty || contact.error != nil ? 12 : 0)
        .background(DispatchStyle.wash)
        .task { await contact.refreshDeferredCalls() }
        .sheet(isPresented: $contact.chooseCallTime) {
            NavigationStack {
                DispatchForm {
                    DatePicker("Ring again at", selection: $selectedTime, in: Date().addingTimeInterval(90)...Date().addingTimeInterval(7 * 86400))
                    Text("The agent will call this phone once at this time. The call will ring for up to one minute. It requires network access and an available bot.").font(.footnote)
                    Button("Ask agent to ring again") {
                        Task {
                            if let editingCall { await contact.changeTime(editingCall, to: selectedTime) }
                            else if let incoming = contact.postponeTarget ?? contact.callInvitation { await contact.postpone(incoming, until: selectedTime) }
                            if contact.error == nil { contact.chooseCallTime = false }
                        }
                    }.disabled(contact.postponing)
                    if let error = contact.error { Text(error).foregroundStyle(DispatchStyle.rust) }
                }
                .dispatchTitle("Ring again")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { contact.chooseCallTime = false; contact.postponeTarget = nil } } }
            }
        }
    }
}
