import SwiftUI
import HermesGateway

struct CallPreferencesView: View {
    @Bindable var controller: RaiseToCallController
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    private var targets: [RaiseCallTarget] {
        store.bots.compactMap { bot in
            store.endpoints.first(where: { $0.id == bot.endpointID }).map { RaiseCallTarget(bot: bot, endpoint: $0) }
        }
    }
    var body: some View {
        NavigationStack {
            DispatchForm {
                DispatchSection {
                    Toggle("Raise to call", isOn: $controller.enabled).accessibilityIdentifier("raiseToCallEnabled")
                } footer: {
                    Text("With Hermes open, lower your iPhone, then raise it to your ear to call. The visible agent chat takes priority. Other pages use your default agent.")
                }
                DispatchSection("Default agent") {
                    Picker("Agent", selection: $controller.defaultTarget) {
                        Text("None").tag(nil as RaiseCallTarget?)
                        ForEach(targets) { target in
                            let gateway = store.endpoints.first { $0.id == target.endpointID }?.label ?? "Gateway"
                            Text("\(target.name) · \(gateway) · \(target.profile)").tag(Optional(target))
                        }
                        if let selected = controller.defaultTarget, !targets.contains(selected) {
                            Text("\(selected.name) · Unavailable").tag(Optional(selected))
                        }
                    }.accessibilityIdentifier("defaultCallAgent")
                }
                if controller.sensorUnavailable {
                    DispatchSection { Text("Raise to call is unavailable on this device. You can still use the Call button in an agent chat.").foregroundStyle(DispatchStyle.secondary) }
                }
            }
            .dispatchTitle("Call settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
