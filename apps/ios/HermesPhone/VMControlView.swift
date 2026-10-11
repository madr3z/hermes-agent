import SwiftUI
import HermesGateway

struct VMControlView: View {
    let store: PhoneStore
    @State private var control: RemoteControl
    @State private var power = VMPowerControl()
    @State private var confirming: VMPowerAction?
    @State private var showPaste = false
    @State private var showHelp = false
    @State private var pasted = ""
    @Environment(\.scenePhase) private var scenePhase
    init(bot: Bot, store: PhoneStore) { self.store = store; _control = State(initialValue: RemoteControl(bot: bot)) }
    var body: some View {
        VStack(spacing: 0) {
            DisclosureGroup {
                powerPanel
            } label: {
                Label("\(control.bot.name) · \(power.phase.capitalized)", systemImage: "desktopcomputer")
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44)
            }.padding(.horizontal).background(Color(uiColor: .secondarySystemBackground))
            Picker("Remote view", selection: $control.mode) {
                ForEach(RemoteControl.Mode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            remoteStatus
            RemoteSurface(control: control)
                .overlay {
                    if !control.connected {
                        VStack(spacing: 14) {
                            Image(systemName: control.mode == .display ? "desktopcomputer" : "terminal")
                                .font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                            Text(control.working ? "Connecting to your computer…" : "Your bot’s computer")
                                .font(.headline)
                            Text(control.working ? "Opening a secure remote view." : control.mode == .display && control.status["installed"].bool && !control.desktopRunning ? "Choose Start desktop to open the screen. Your bot keeps working when you leave." : "Reconnect to view the screen. Your bot keeps working when you leave.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if control.working { ProgressView() }
                        }
                        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = control.error { PhoneNotice(title: "Remote connection", message: error).padding(12) }
            if control.mode == .display {
                Button("Screen gestures and keyboard", systemImage: "hand.pinch") { showHelp = true }.font(.subheadline).frame(minHeight: 44)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Computer").navigationBarTitleDisplayMode(.inline)
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
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                List {
                    Section("View the screen") {
                        Label("Pinch to zoom. Choose Fit to see the whole screen, or 1:1 for detail.", systemImage: "hand.pinch")
                        Label("Turn on Pan to move around a zoomed screen. You can also rotate your iPhone.", systemImage: "hand.draw")
                    }
                    Section("Control the desktop") {
                        Label("Choose Take control before using the desktop. Hand back returns control to the bot.", systemImage: "cursorarrow")
                        Text("Tap to click. Drag to move. Tap with two fingers for right click; drag with two fingers to scroll.")
                        Text("Use Keyboard for text, Ctrl and navigation keys for shortcuts, or Paste to send text you review first.")
                    }
                    Section { Text("Closing this screen disconnects the viewer. The bot and its machine keep running.").foregroundStyle(.secondary) }
                }
                .navigationTitle("Screen controls").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showHelp = false } } }
            }
        }
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
                ViewThatFits(in: .horizontal) {
                    HStack { powerActions }
                    VStack(alignment: .leading) { powerActions }
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
                    Text("\(Int(cpu)) CPU · \(Int(memory)) MiB · \(Int(disk)) GiB disk").font(.caption).foregroundStyle(.secondary)
                }
            } else { Text("VM power controls require a provisioned VM and a controller that supports them.").font(.caption).foregroundStyle(.secondary) }
            if let error = power.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.vertical, 8)
    }
    @ViewBuilder private var powerActions: some View {
        ForEach(VMPowerAction.allCases) { action in
            Button(action.rawValue.capitalized, role: action == .start ? nil : .destructive) { confirming = action }
                .buttonStyle(.bordered).controlSize(.large).disabled(!power.allowed(action))
        }
        if power.working { ProgressView() }
    }
    private var remoteStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(control.connection, systemImage: control.connected ? "checkmark.circle" : "network")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Reconnect", systemImage: "arrow.clockwise") { Task { await control.reconnect(store: store) } }
                    .font(.subheadline).frame(minHeight: 44).disabled(control.working)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { remoteActions }
                VStack(alignment: .leading, spacing: 8) { remoteActions }
            }.font(.subheadline).buttonStyle(.bordered).controlSize(.large)
        }.padding(.horizontal).padding(.bottom, 8)
    }
    @ViewBuilder private var remoteActions: some View {
        if control.mode == .display {
            if !control.desktopRunning {
                Button("Start desktop", systemImage: "desktopcomputer") { Task { await control.startDesktop() } }
                    .disabled(control.working || !control.status["installed"].bool)
            } else if control.controlling {
                Button("Hand back", systemImage: "arrow.uturn.backward") { Task { await control.releaseControl() } }
            } else {
                Button("Take control", systemImage: "cursorarrow") { Task { await control.takeControl() } }.disabled(!control.connected)
            }
        }
        Button("Paste", systemImage: "doc.on.clipboard") { showPaste = true }
            .disabled(!control.connected || (control.mode == .display && !control.controlling))
    }
}
