import SwiftUI
import HermesGateway

struct VMControlView: View {
    let store: PhoneStore
    @State private var control: RemoteControl
    @State private var power = VMPowerControl()
    @State private var confirming: VMPowerAction?
    @State private var showPaste = false
    @State private var pasted = ""
    @Environment(\.scenePhase) private var scenePhase
    init(bot: Bot, store: PhoneStore) { self.store = store; _control = State(initialValue: RemoteControl(bot: bot)) }
    var body: some View {
        VStack(spacing: 0) {
            powerPanel
            Picker("Remote view", selection: $control.mode) {
                ForEach(RemoteControl.Mode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            remoteStatus
            RemoteSurface(control: control).frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = control.error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
            if control.mode == .display {
                Text("Tap to click; drag to move. Two fingers tap for right click and drag to scroll. Use 1:1 and Pan for detail, or rotate the phone.").font(.caption2).foregroundStyle(.secondary).padding(8)
            }
        }
        .navigationTitle("\(control.bot.name) VM").navigationBarTitleDisplayMode(.inline)
        .task {
            async let vmStatus: () = power.load(bot: control.bot, store: store)
            async let remote: () = control.open(store: store)
            _ = await (vmStatus, remote)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if scenePhase == .active { await power.refresh() }
            }
        }
        .onChange(of: control.mode) { _, _ in Task { await control.changeMode() } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { control.close() }
            else { Task { await power.refresh() } }
        }
        .onDisappear { control.close() }
        .confirmationDialog(confirming.map { "\($0.rawValue.capitalized) this VM?" } ?? "VM power", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let action = confirming {
                Button("\(action.rawValue.capitalized) VM", role: action == .start ? nil : .destructive) {
                    confirming = nil
                    if action != .start { control.close() }
                    Task { await power.perform(action) }
                }
            }
        } message: { Text("Stop and restart interrupt work in the guest. The same VM and disk are retained.") }
        .sheet(isPresented: $showPaste) {
            NavigationStack {
                Form { TextField("Paste text", text: $pasted, axis: .vertical).lineLimit(4...12) }
                .navigationTitle("Paste to \(control.mode.rawValue)")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showPaste = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("Paste") { let text = pasted; pasted = ""; showPaste = false; Task { await control.paste(text) } }.disabled(pasted.isEmpty) }
                }
            }
        }
    }
    private var powerPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("VM: \(power.phase.capitalized)", systemImage: power.vm["ready"].bool ? "desktopcomputer" : "power")
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await power.refresh() } }.labelStyle(.iconOnly).disabled(power.working)
            }
            if power.supported {
                HStack {
                    ForEach(VMPowerAction.allCases) { action in
                        Button(action.rawValue.capitalized) { confirming = action }.buttonStyle(.bordered).disabled(!power.allowed(action))
                    }
                    Spacer()
                    if power.working { ProgressView() }
                }
                if let pending = power.pending {
                    HStack {
                        Text("\(pending.action.rawValue.capitalized): \(power.operationPhase)").font(.caption)
                        if power.operationPhase == "unconfirmed" { Button("Retry same action") { Task { await power.retry() } }.font(.caption).disabled(power.working) }
                        if power.mayBeginNewAction { Button("New action") { power.beginNewAction() }.font(.caption) }
                    }
                    if let message = power.receipt["error"]["message"].string { Text(message).font(.caption).foregroundStyle(.red) }
                }
                let resources = power.vm["resources"]
                if let cpu = resources["cpu"].number, let memory = resources["memory_mib"].number, let disk = resources["disk_gib"].number {
                    Text("\(Int(cpu)) CPU · \(Int(memory)) MiB · \(Int(disk)) GiB").font(.caption2).foregroundStyle(.secondary)
                }
            } else { Text("VM power controls require a provisioned VM and a controller that supports them.").font(.caption).foregroundStyle(.secondary) }
            if let error = power.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.horizontal).padding(.vertical, 8).background(.bar)
    }
    private var remoteStatus: some View {
        HStack {
            Text(control.connection).font(.caption)
            Spacer()
            if control.mode == .display {
                if !control.desktopRunning { Button("Start desktop") { Task { await control.startDesktop() } }.disabled(control.working || !control.status["installed"].bool) }
                else if control.controlling { Button("Hand back") { Task { await control.releaseControl() } } }
                else { Button("Take control") { Task { await control.takeControl() } }.disabled(!control.connected) }
            }
            Button("Paste") { showPaste = true }.disabled(!control.connected || (control.mode == .display && !control.controlling))
            Button("Reconnect") { Task { await control.reconnect(store: store) } }.disabled(control.working)
        }.font(.caption).padding(.horizontal).padding(.bottom, 8)
    }
}
