import SwiftUI
import HermesGateway

struct BotRoutinesView: View {
    let bot: Bot
    let store: PhoneStore
    @State private var routines: BotRoutinesStore
    @State private var search = ""
    @State private var creating = false
    @State private var removal: BotRoutine?
    init(bot: Bot, store: PhoneStore) {
        self.bot = bot; self.store = store
        _routines = State(initialValue: BotRoutinesStore(bot: bot))
    }
    private var visible: [BotRoutine] {
        routines.jobs.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.prompt.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            Section {
                BotIdentityLabel(name: bot.name, detail: "Scheduled tasks")
            } footer: { Text("Tasks run on this bot’s gateway. You can close the app.") }
            if routines.loading { ProgressView("Loading scheduled tasks…") }
            if routines.working { ProgressView("Saving on gateway…") }
            if let error = routines.error {
                Section {
                    PhoneNotice(title: "Could not complete the request", message: error)
                    Button("Refresh") { Task { await routines.load(store: store) } }.disabled(routines.loading || routines.working)
                }
            }
            if let notice = routines.notice { PhoneNotice(title: "Task update", message: notice, systemImage: "info.circle") }
            if !routines.loading && routines.error == nil && routines.jobs.isEmpty {
                ContentUnavailableView("No scheduled tasks", systemImage: "calendar.badge.clock", description: Text("Add instructions for this bot to run later."))
            } else if !routines.jobs.isEmpty && visible.isEmpty {
                ContentUnavailableView.search(text: search)
            }
            Section {
                ForEach(visible) { job in
                    NavigationLink {
                        BotRoutineDetail(job: job, routines: routines, store: store)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(job.displayName(profile: bot.profile)).font(.headline)
                            Text(job.schedule).font(.subheadline).foregroundStyle(.secondary)
                            if !job.prompt.isEmpty { Text(job.prompt).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                            Label(job.enabled ? job.state.capitalized : "Paused", systemImage: job.enabled ? "clock" : "pause.circle")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if let next = job.nextRun, job.enabled { Text("Next: \(routineDate(next))").font(.subheadline).foregroundStyle(.secondary) }
                        }.padding(.vertical, 9)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { removal = job }
                        Button(job.enabled ? "Pause" : "Resume") {
                            Task { _ = await routines.mutate(store: store) { try await $0.setEnabled(id: job.id, enabled: !job.enabled) } }
                        }.tint(.orange)
                    }
                }
            }.disabled(routines.loading || routines.working || routines.api == nil)
        }
        .navigationTitle("Scheduled tasks").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find a task")
        .task { await routines.load(store: store) }
        .refreshable { await routines.load(store: store) }
        .toolbar {
            Button("Add task", systemImage: "plus") { creating = true }
                .disabled(routines.api == nil || routines.loading || routines.working)
        }
        .sheet(isPresented: $creating) { NewBotRoutineView(routines: routines, store: store) }
        .confirmationDialog("Delete \(removal?.displayName(profile: bot.profile) ?? "task")?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            if let selected = removal {
                Button("Delete scheduled task", role: .destructive) {
                    removal = nil
                    Task { _ = await routines.mutate(store: store) { try await $0.remove(id: selected.id) } }
                }
            }
        } message: { Text("This removes the schedule from \(bot.name). It does not remove past conversation messages.") }
    }
}

private struct BotRoutineDetail: View {
    let job: BotRoutine
    let routines: BotRoutinesStore
    let store: PhoneStore
    @State private var confirmingRemoval = false
    @Environment(\.dismiss) private var dismiss
    private var current: BotRoutine? { routines.jobs.first { $0.id == job.id } }
    var body: some View {
        Form {
            if let current {
                Section("Schedule") {
                    Text(current.schedule).textSelection(.enabled)
                    LabeledContent("State", value: current.enabled ? current.state.capitalized : "Paused")
                    if let next = current.nextRun { LabeledContent("Next run", value: routineDate(next)) }
                    LabeledContent("Results", value: current.delivery == "bot-chat" ? "Bot Chat" : current.delivery)
                }
                Section("Instructions preview") { Text(current.prompt.isEmpty ? "No preview available" : current.prompt).textSelection(.enabled) }
                Section("Last run") {
                    if let date = current.lastRun { Text(routineDate(date)) }
                    Text(current.lastStatus ?? "No result recorded")
                    if let error = current.lastError { PhoneNotice(title: "Last run issue", message: error) }
                }
                Section {
                    Button(current.enabled ? "Pause task" : "Resume task") {
                        Task { _ = await routines.mutate(store: store) { try await $0.setEnabled(id: job.id, enabled: !current.enabled) } }
                    }
                    Button("Delete task…", role: .destructive) { confirmingRemoval = true }
                }.disabled(routines.working || routines.loading || routines.api == nil)
            } else { Text("This task is no longer in the schedule.") }
            if routines.working { ProgressView("Saving on gateway…") }
            if let error = routines.error {
                PhoneNotice(title: "Could not complete the request", message: error)
                Button("Refresh") { Task { await routines.load(store: store) } }.disabled(routines.loading || routines.working)
            }
            if let notice = routines.notice { PhoneNotice(title: "Task update", message: notice, systemImage: "info.circle") }
        }
        .navigationTitle(job.displayName(profile: routines.bot.profile)).navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this scheduled task?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Delete scheduled task", role: .destructive) {
                Task { if await routines.mutate(store: store, body: { try await $0.remove(id: job.id) }) { dismiss() } }
            }
        } message: { Text("This removes the schedule from \(routines.bot.name). Past conversation messages stay on the gateway.") }
    }
}

private struct NewBotRoutineView: View {
    let routines: BotRoutinesStore
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = BotRoutineDraft()
    @State private var review: BotRoutineDraft?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section { BotIdentityLabel(name: routines.bot.name, detail: "New scheduled task") }
                Section("Instructions") {
                    TextField("Task name", text: $draft.name)
                    TextField("What should this bot do?", text: $draft.instruction, axis: .vertical).lineLimit(4...10)
                }
                Section("When") {
                    Picker("Repeat", selection: $draft.frequency) {
                        ForEach(RoutineFrequency.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if draft.frequency == .once {
                        DatePicker("Run at", selection: $draft.date, in: Date()...)
                        Text("Time zone: \(TimeZone.current.identifier)").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("The interval starts when the gateway creates the task. Results appear in Bot Chat.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section { Text("This bot will run these instructions automatically. Review any account access or actions in your instructions before adding the task.").font(.subheadline).foregroundStyle(.secondary) }
                if let error { PhoneNotice(title: "Check this task", message: error) }
                if let error = routines.error { PhoneNotice(title: "Could not create task", message: error) }
                if routines.working { ProgressView("Creating task…") }
                Button("Review task") {
                    do { _ = try draft.parameters(profile: routines.bot.profile); error = nil; review = draft }
                    catch { self.error = error.localizedDescription }
                }.disabled(routines.working || routines.api == nil)
            }
            .disabled(routines.working)
            .navigationTitle("New task").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(routines.working) } }
            .confirmationDialog("Add \(review?.name ?? "task") for \(routines.bot.name)?", isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } }), titleVisibility: .visible) {
                if let selected = review {
                    Button("Add scheduled task") {
                        review = nil
                        Task { if await routines.mutate(store: store, body: { try await $0.create(selected) }) { dismiss() } }
                    }
                }
            } message: {
                if let selected = review {
                    Text((selected.frequency == .once ? selected.date.formatted(date: .abbreviated, time: .shortened) : selected.frequency.rawValue) + "\nResults: Bot Chat\n\n" + selected.instruction)
                }
            }
            .interactiveDismissDisabled(routines.working)
        }
    }
}

private func routineDate(_ raw: String) -> String {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: raw) { return date.formatted(date: .abbreviated, time: .shortened) }
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.date(from: raw)?.formatted(date: .abbreviated, time: .shortened) ?? raw
}
