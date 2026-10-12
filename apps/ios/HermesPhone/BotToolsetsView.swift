import SwiftUI
import HermesGateway

struct BotToolsetsView: View {
    let bot: Bot
    let store: PhoneStore
    let runtimeID: String?
    var body: some View { BotToolsetsPage(bot: bot, store: store, runtimeID: runtimeID).id(bot.id) }
}

private struct BotToolsetsPage: View {
    @Environment(\.scenePhase) private var scenePhase
    let bot: Bot
    let store: PhoneStore
    let runtimeID: String?
    @State private var toolsets = BotToolsetsStore()
    @State private var query = ""
    @State private var connectionError: String?

    private var filtered: [BotToolset] {
        (toolsets.snapshot?.toolsets ?? []).filter { row in
            query.isEmpty || [row.label, row.description, row.tools.joined(separator: " ")]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        List {
            Section { BotIdentityLabel(name: bot.name, detail: "Tools for this bot") } footer: {
                Text("Enabled settings apply to new sessions. The current chat can keep its existing tools. Enabling a toolset can start its existing setup on this bot.")
            }
            if toolsets.loading || toolsets.working || toolsets.error != nil || connectionError != nil || toolsets.notice != nil {
                Section {
                    if toolsets.loading { ProgressView("Loading toolsets…") }
                    if toolsets.working { ProgressView("Saving on gateway…") }
                    if let error = connectionError ?? toolsets.error {
                        PhoneNotice(title: "Could not read or save toolsets", message: error)
                    }
                    if let notice = toolsets.notice { PhoneNotice(title: "Toolset settings", message: notice, systemImage: "info.circle") }
                }
            }
            if let error = toolsets.snapshot?.currentError {
                Section("Current chat") { PhoneNotice(title: "Current tools unavailable", message: error) }
            } else if runtimeID == nil {
                Section("Current chat") { Text("Open Bot Chat to check which tools are available to it.").foregroundStyle(.secondary) }
            }
            if toolsets.snapshot?.toolsets.isEmpty == true {
                ContentUnavailableView("No toolsets reported", systemImage: "wrench.and.screwdriver")
            }
            ForEach(filtered) { row in
                BotToolsetRow(row: row, currentTools: toolsets.snapshot?.currentTools, state: toolsets)
            }
        }
        .navigationTitle("Tools and toolsets")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find a tool or toolset")
        .task { await connect() }
        .refreshable { await refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(toolsets.loading || toolsets.working) }
    }

    private func connect() async {
        do {
            let gateway = try await store.client(for: bot.endpointID)
            try Task.checkCancellation()
            toolsets.bind(BotToolsetsClient(profile: bot.profile, runtimeID: runtimeID,
                request: { try await gateway.request($0, $1) },
                http: { try await gateway.http($0, profile: $1, body: $2, method: $3) }))
            connectionError = nil
            await toolsets.refresh()
        } catch is CancellationError { return }
        catch { connectionError = botToolsError(error) }
    }

    private func refresh() async {
        if connectionError != nil { await connect() } else { await toolsets.refresh() }
    }
}

private struct BotToolsetRow: View {
    let row: BotToolset
    let currentTools: Set<String>?
    let state: BotToolsetsStore
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.label).font(.headline)
                    Spacer()
                    Text(row.enabled ? "Enabled" : "Disabled").font(.subheadline).foregroundStyle(.secondary)
                }
                if !row.description.isEmpty { Text(row.description).font(.subheadline).foregroundStyle(.secondary) }
                if row.configured == false { Label("Setup required", systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.secondary) }
                if let currentTools, !row.tools.isEmpty {
                    Text("Current chat: \(currentTools.intersection(row.tools).count) of \(row.tools.count) tools available")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if !row.tools.isEmpty {
                DisclosureGroup("Tools (\(row.tools.count))") {
                    ForEach(row.tools, id: \.self) { Text($0).font(.subheadline.monospaced()).textSelection(.enabled) }
                }
            }
            Button(row.enabled ? "Disable for new sessions" : "Enable for new sessions") {
                Task { await state.setEnabled(name: row.name, enabled: !row.enabled) }
            }
            .disabled(!state.canChange)
            .accessibilityLabel((row.enabled ? "Disable " : "Enable ") + row.label + " for new sessions")
        }
    }
}
