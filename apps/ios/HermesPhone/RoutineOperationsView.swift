import SwiftUI
import HermesGateway

struct RoutineOperationsView: View {
    let bot: Bot
    let jobID: String
    let store: PhoneStore
    @State private var operations = RoutineOperationsStore()
    @State private var editing = false
    @State private var runReview: RoutineDetails?
    @State private var reviewingOutcome = false
    @State private var connectionError: String?
    var body: some View {
        DispatchForm {
            DispatchSection { BotIdentityLabel(name: bot.name, detail: "Task controls and history") }
            if let details = operations.details {
                DispatchSection(details.displayName) {
                    Text(details.schedule).textSelection(.enabled)
                    LabeledContent("State", value: details.enabled ? details.state.capitalized : "Paused")
                    LabeledContent("Execution", value: details.noAgent ? "Script only" : "Agent task")
                    LabeledContent("Results", value: details.delivery == "bot-chat" ? "Bot Chat" : details.delivery)
                    Text(details.prompt.isEmpty ? "No agent instructions. This task may use a script or skill." : details.prompt).textSelection(.enabled)
                }
                DispatchSection {
                    Button("Edit task…", systemImage: "pencil") { editing = true }.disabled(!operations.canChange)
                    Button("Run now…", systemImage: "play") { runReview = details }.disabled(!operations.canRun)
                }
            }
            if operations.loading { ProgressView("Reading task and history…") }
            if operations.working { ProgressView("Waiting for the gateway…") }
            if let error = connectionError ?? operations.error {
                PhoneNotice(title: "Task controls unavailable", message: error)
            }
            if let notice = operations.notice { PhoneNotice(title: "Task status", message: notice, systemImage: "info.circle") }
            if operations.uncertainRun {
                DispatchSection("Unconfirmed run request") {
                    Text("The earlier request may have started. Refresh reads actual history; it does not cancel or retry that request.")
                    Button("I reviewed the recorded outcome…") { reviewingOutcome = true }.disabled(!operations.canReviewOutcome)
                }
            }
            DispatchSection("Recorded runs") {
                Text("Latest \(operations.historyLimit) records. Agent runs have saved transcripts. Script runs provide an output preview or execution metadata.").font(.caption).foregroundStyle(DispatchStyle.secondary)
                ForEach(operations.runs) { run in
                    NavigationLink { RoutineRunView(run: run, operations: operations, bot: bot) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(run.title).lineLimit(3)
                            if let date = run.startedAt { Text(date, style: .date) + Text(" · ") + Text(date, style: .time) }
                            if run.schedulerOwned { Label("Scheduler owns this run", systemImage: "clock").font(.caption) }
                        }
                    }
                }
                if operations.historyRead && operations.runs.isEmpty { Text("No recorded runs in this window.").foregroundStyle(DispatchStyle.secondary) }
                if operations.historyRead && operations.historyLimit == 20 && operations.runs.count >= 20 {
                    Button("Show latest 100 runs") { Task { await operations.refresh(limit: 100) } }.disabled(operations.loading || operations.working)
                }
                Button("Refresh task and history", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(operations.loading || operations.working)
            }
        }
        .dispatchTitle("Task details").navigationBarTitleDisplayMode(.inline)
        .task { await connect() }
        .refreshable { await refresh() }
        .sheet(isPresented: $editing) {
            if let details = operations.details { RoutineEditView(original: details, operations: operations, botName: bot.name) }
        }
        .confirmationDialog("Run \(runReview?.displayName ?? "task") now on \(bot.name)?", isPresented: Binding(get: { runReview != nil }, set: { if !$0 { runReview = nil } }), titleVisibility: .visible) {
            if let reviewed = runReview { Button("Run this task now") { runReview = nil; Task { await operations.runNow(reviewed) } } }
            Button("Cancel", role: .cancel) { runReview = nil }
        } message: {
            Text((runReview?.enabled == false || runReview?.state == "paused" ? "This paused task will resume and run now.\n\n" : "") + "This executes its saved instructions and account actions. The gateway may continue after the app closes or a request times out.")
        }
        .confirmationDialog("Allow another manual run?", isPresented: $reviewingOutcome, titleVisibility: .visible) {
            Button("I reviewed history; allow another run") { operations.acknowledgeReviewedOutcome() }
            Button("Keep blocked", role: .cancel) {}
        } message: { Text("A response was lost. The history may not identify that exact request. Another manual run can repeat work that already started. This action does not run the task.") }
    }
    private func connect() async {
        do {
            let client = try await store.client(for: bot.endpointID)
            operations.bind(RoutineOperationsClient(profile: bot.profile, jobID: jobID) { path, profile, body, method, query in
                try await client.http(path, profile: profile, body: body, method: method, query: query)
            })
            connectionError = nil
            await operations.refresh()
        } catch { connectionError = error.localizedDescription }
    }
    private func refresh() async { if connectionError != nil { await connect() } else { await operations.refresh() } }
}

private struct RoutineEditView: View {
    @State private var original: RoutineDetails
    let operations: RoutineOperationsStore
    let botName: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RoutineEditDraft
    @State private var review = false
    @State private var validationError: String?
    init(original: RoutineDetails, operations: RoutineOperationsStore, botName: String) {
        _original = State(initialValue: original); self.operations = operations; self.botName = botName
        _draft = State(initialValue: RoutineEditDraft(original))
    }
    var body: some View {
        NavigationStack {
            DispatchForm {
                DispatchSection { BotIdentityLabel(name: botName, detail: "Edit \(original.displayName)") }
                DispatchSection("Instructions") {
                    TextField("Task name", text: $draft.name)
                    TextField("Saved agent instructions", text: $draft.instruction, axis: .vertical).lineLimit(4...12)
                    if original.noAgent { Text("This is a script-only task. Its script stays unchanged; agent instructions are not executed in this mode.").font(.caption).foregroundStyle(DispatchStyle.secondary) }
                }
                DispatchSection("Schedule") {
                    Text("Current: \(original.schedule)")
                    Toggle("Replace schedule", isOn: $draft.changeSchedule)
                    if draft.changeSchedule {
                        TextField("For example: every 2h", text: $draft.schedule).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("The gateway validates interval, cron and absolute-date expressions. A new schedule recalculates its next run and can change the repeat count.").font(.caption).foregroundStyle(DispatchStyle.secondary)
                    }
                }
                DispatchSection { Text("Delivery, model, provider, script, skills and other settings are preserved. Only the fields you change are saved.").font(.caption).foregroundStyle(DispatchStyle.secondary) }
                if let error = validationError ?? operations.error { PhoneNotice(title: "Edit not saved", message: error) }
                if operations.working { ProgressView("Saving task…") }
                Button("Review changes") {
                    do {
                        guard !(try draft.updates(original: original)).isEmpty else { validationError = "No task settings changed."; return }
                        validationError = nil; review = true
                    } catch { validationError = error.localizedDescription }
                }.disabled(!operations.canChange)
                if operations.needsRefresh {
                    Button("Refresh task; keep draft") {
                        Task {
                            await operations.refresh()
                            if let current = operations.details, !operations.needsRefresh {
                                draft.rebase(from: original, to: current); original = current
                            }
                        }
                    }.disabled(operations.loading || operations.working)
                }
            }
            .disabled(operations.working)
            .dispatchTitle("Edit task").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(operations.working) } }
            .confirmationDialog("Save these changes on \(botName)?", isPresented: $review, titleVisibility: .visible) {
                Button("Save task changes") { Task { if await operations.update(draft, original: original) { dismiss() } } }
                Button("Keep editing", role: .cancel) {}
            } message: { Text(draft.name + "\n" + (draft.changeSchedule ? draft.schedule : "Keep schedule: \(original.schedule)") + "\n\n" + draft.instruction) }
            .interactiveDismissDisabled(operations.working)
        }
    }
}

private struct RoutineRunView: View {
    let run: RoutineRun
    let operations: RoutineOperationsStore
    let bot: Bot
    @State private var messages: [ChatMessage] = []
    @State private var offset = 0
    @State private var hasEarlier = false
    @State private var loading = false
    @State private var error: String?
    @State private var resolvedID: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                Text(run.title).font(DispatchStyle.serif(23, relativeTo: .headline)).textSelection(.enabled)
                if let date = run.startedAt { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(DispatchStyle.secondary) }
                if run.scriptOutput {
                    Text(run.preview.isEmpty ? "No output preview was retained for this execution." : run.preview).textSelection(.enabled)
                    Text("This is an output preview or execution record. The API does not provide the full script output here.").font(.caption).foregroundStyle(DispatchStyle.secondary)
                } else {
                    if hasEarlier { Button("Load earlier messages") { Task { await load() } }.disabled(loading) }
                    if loading { ProgressView("Loading recorded transcript…") }
                    ForEach(messages) { message in
                        ChatMessageView(message: message, client: nil, profile: bot.profile, storedSessionID: run.id, botName: bot.name)
                    }
                    if !loading && messages.isEmpty && error == nil { Text("No visible transcript messages were retained.").foregroundStyle(DispatchStyle.secondary) }
                }
                if let error { PhoneNotice(title: "Run transcript unavailable", message: error) }
            }.padding(20)
        }.dispatchTitle("Recorded run").navigationBarTitleDisplayMode(.inline)
            .task(id: run.id) { if !run.scriptOutput { await load() } }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let page = try await operations.transcript(run: run, offset: offset)
            try Task.checkCancellation()
            if let resolvedID, resolvedID != page.sessionID { throw GatewayError.message("This run transcript changed. Reopen it before loading earlier messages.") }
            resolvedID = page.sessionID
            messages = page.messages.filter { next in !messages.contains { $0.id == next.id } } + messages
            offset += page.returned; hasEarlier = page.returned == 100
        } catch { self.error = error.localizedDescription }
    }
}
