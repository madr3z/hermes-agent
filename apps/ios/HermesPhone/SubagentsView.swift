import SwiftUI
import HermesGateway

struct SubagentsView: View {
    let chat: ChatStore
    private var agents: SubagentsStore { chat.subagents }
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        DispatchList {
            DispatchSection {
                BotIdentityLabel(name: chat.bot.name, detail: "Subagents in this chat")
            } footer: {
                Text("Ask \(chat.bot.name) in Bot Chat to delegate a task. Subagents run on this bot’s gateway and return their results to this chat.")
            }
            SubagentNotices(agents: agents)
            if agents.loading && agents.tasks.isEmpty { ProgressView("Loading subagents…") }
            if agents.tasks.isEmpty && !agents.loading && agents.error == nil && agents.connected {
                DispatchEmptyState("No subagents", systemImage: "person.2", description: Text("This chat has no delegated tasks yet."))
            }
            DispatchSection {
                ForEach(agents.tasks) { task in
                    NavigationLink {
                        SubagentDetail(id: task.id, agents: agents)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(task.goal).font(DispatchStyle.serif(23, relativeTo: .headline)).lineLimit(3)
                            Label(task.statusLabel, systemImage: task.isActive ? "circle.dotted" : "checkmark.circle")
                                .font(.subheadline).foregroundStyle(DispatchStyle.secondary)
                            if let tool = task.lastTool { Text("\(task.toolCount) tools · \(tool)").font(.caption).foregroundStyle(DispatchStyle.secondary) }
                            if let error = task.error { Text(error).font(.subheadline).foregroundStyle(DispatchStyle.rust).lineLimit(2) }
                        }.padding(.vertical, 8)
                    }.accessibilityIdentifier("subagent-\(task.id)")
                }
            }
        }
        .dispatchTitle("Subagents").navigationBarTitleDisplayMode(.inline)
        .refreshable { await agents.refresh() }
        .task(id: agents.bindingID) { await agents.watch(isActive: { scenePhase == .active }) }
    }
}

private struct SubagentNotices: View {
    let agents: SubagentsStore
    var body: some View {
        if !agents.connected {
            PhoneNotice(title: "Disconnected", message: "Return to Bot Chat and reconnect to refresh subagents and their controls.")
        }
        if let error = agents.error {
            PhoneNotice(title: "Subagents need attention", message: error)
            Button("Refresh") { Task { await agents.refresh() } }.disabled(!agents.connected || agents.loading || agents.working)
        }
        if let notice = agents.notice { PhoneNotice(title: "Subagent update", message: notice, systemImage: "info.circle") }
        if agents.working { ProgressView("Sending to gateway…") }
    }
}

private struct SubagentDetail: View {
    let id: String
    let agents: SubagentsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var instructions = ""
    @State private var confirmingStop = false
    private var current: SubagentTask? { agents.tasks.first { $0.id == id } }
    var body: some View {
        DispatchForm {
            SubagentNotices(agents: agents)
            if let task = current {
                DispatchSection("Task") { Text(task.goal).textSelection(.enabled) }
                DispatchSection("Progress") {
                    LabeledContent("Status", value: task.statusLabel)
                    if let model = task.model { LabeledContent("Model", value: model) }
                    LabeledContent("Tools used", value: String(task.toolCount))
                    if let tool = task.lastTool { LabeledContent("Last tool", value: tool) }
                    if let parent = task.parentID, !parent.isEmpty { LabeledContent("Parent subagent", value: parent) }
                }
                if let result = task.summary, !result.isEmpty {
                    DispatchSection("Result") { Text(result).textSelection(.enabled) }
                }
                if let error = task.error, !error.isEmpty { DispatchSection("Issue") { Text(error).textSelection(.enabled) } }
                if task.isActive {
                    if task.canSteer {
                        DispatchSection("Update instructions") {
                            TextField("Instructions for this subagent", text: $instructions, axis: .vertical).lineLimit(3...8)
                            Button("Send instructions") {
                                let text = instructions
                                Task { if await agents.steer(id: id, text: text), instructions == text { instructions = "" } }
                            }.disabled(instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.disabled(!controlsEnabled)
                    }
                    if task.canInterrupt {
                        DispatchSection { Button("Stop subagent…", role: .destructive) { confirmingStop = true } }
                            .disabled(!controlsEnabled)
                    }
                    if !task.canSteer && !task.canInterrupt {
                        Text("This connection can view the task. Controls are available only to its current owner.")
                            .font(.subheadline).foregroundStyle(DispatchStyle.secondary)
                    }
                }
            } else {
                Text("This subagent is no longer in the current chat’s list. Return to the list and refresh.")
            }
        }
        .dispatchTitle("Subagent").navigationBarTitleDisplayMode(.inline)
        .refreshable { await agents.refresh() }
        .task(id: agents.bindingID) { await agents.watch(isActive: { scenePhase == .active }) }
        .confirmationDialog("Stop this subagent?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop subagent", role: .destructive) { Task { await agents.interrupt(id: id) } }
        } message: { Text("This requests an interrupt for this task. The gateway reports its final status when it stops.") }
    }
    private var controlsEnabled: Bool { agents.connected && !agents.loading && !agents.working && agents.error == nil }
}
