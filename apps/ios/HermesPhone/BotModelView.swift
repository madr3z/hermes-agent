import SwiftUI
import HermesGateway

struct BotModelView: View {
    let bot: Bot
    let store: PhoneStore
    var runtimeID: String? = nil
    var body: some View {
        BotModelPage(bot: bot, store: store, runtimeID: runtimeID).id(bot.id + ":" + (runtimeID ?? "profile"))
    }
}

private struct BotModelPage: View {
    let bot: Bot
    let store: PhoneStore
    let runtimeID: String?
    @State private var inventory: BotModelInventory?
    @State private var readiness: JSON?
    @State private var api: BotCapabilitiesClient?
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    @State private var selection: ModelSelection?
    var body: some View {
        List {
            Section { BotIdentityLabel(name: bot.name, detail: "Model and status") }
            if loading { ProgressView("Checking this bot…") }
            if let error {
                Section {
                    PhoneNotice(title: "Could not load status", message: error)
                    Button("Try again") { Task { await load() } }.disabled(loading)
                }
            }
            if let readiness {
                Section("Gateway readiness") {
                    Label(readiness["ok"].bool ? "Model route ready" : "Model route needs attention", systemImage: readiness["ok"].bool ? "checkmark.circle" : "exclamationmark.triangle")
                    if let text = readiness["error"].string { Text(text).font(.subheadline).foregroundStyle(.secondary) }
                    Text("Checks configuration and credentials. It does not send a model request.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let inventory {
                Section("Current model") {
                    LabeledContent("Provider", value: inventory.currentProvider?["name"].string ?? inventory.provider)
                    Label {
                        Text(inventory.model.isEmpty ? "No model selected" : inventory.model).font(.title3.weight(.semibold)).textSelection(.enabled)
                    } icon: { Image(systemName: "cpu").foregroundStyle(.tint) }.padding(.vertical, 6)
                    if let warning = inventory.currentProvider?["warning"].string { Text(warning).font(.subheadline).foregroundStyle(.secondary) }
                }
                if let usage = inventory.currentProvider?["usage"], usage != .null { BotUsageSection(usage: usage) }
                Section {
                    ForEach(inventory.availableModels.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { model in
                        Button {
                            if let api { selection = ModelSelection(model: model, provider: inventory.provider, api: api) }
                        } label: {
                            HStack(alignment: .top) {
                                Text(model).foregroundStyle(.primary)
                                Spacer()
                                if model == inventory.model { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Current model") }
                            }
                        }.disabled(runtimeID == nil || api == nil)
                    }
                } header: { Text("Models on this provider") } footer: {
                    Text(runtimeID == nil ? "Open Bot Chat before changing its model." : "A selection applies to this Bot Chat. The provider stays the same.")
                }
                if inventory.availableModels.isEmpty { Text("No selectable models are available from this provider.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Model and usage").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find a model")
        .task(id: runtimeID) { await load() }
        .refreshable { await load() }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading) }
        .sheet(item: $selection, onDismiss: { Task { await load() } }) { selected in
            BotModelSelectionView(selection: selected, api: selected.api, botName: bot.name)
        }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        let ownerRuntime = runtimeID
        defer { loading = false }
        do {
            let client = try await store.client(for: bot.endpointID)
            let api = BotCapabilitiesClient(profile: bot.profile, runtimeID: ownerRuntime) { try await client.request($0, $1) }
            self.api = api
            let models = try await api.models()
            try Task.checkCancellation()
            guard ownerRuntime == runtimeID else { return }
            inventory = models
            do {
                let result = try await api.readiness()
                try Task.checkCancellation()
                guard ownerRuntime == runtimeID else { return }
                readiness = result
            } catch is CancellationError { return }
            catch { readiness = nil; self.error = botToolsError(error) }
        } catch is CancellationError { return }
        catch { api = nil; self.error = botToolsError(error) }
    }
}

private struct ModelSelection: Identifiable {
    let model: String
    let provider: String
    let api: BotCapabilitiesClient
    var id: String { provider + ":" + model }
}

private struct BotModelSelectionView: View {
    let selection: ModelSelection
    let api: BotCapabilitiesClient
    let botName: String
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var warning: String?
    @State private var error: String?
    @State private var saved: String?
    @State private var uncertain = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Use for \(botName)’s Bot Chat") {
                    Text(selection.model).font(.headline).textSelection(.enabled)
                    LabeledContent("Provider", value: selection.provider)
                    Text("The selected model can have different usage costs. The gateway checks its model selection rules before applying this change.").font(.subheadline).foregroundStyle(.secondary)
                }
                if let warning { PhoneNotice(title: "Confirm model change", message: warning) }
                if let error { PhoneNotice(title: "Could not change model", message: error) }
                if let saved { PhoneNotice(title: "Model selected", message: saved, systemImage: "checkmark.circle") }
                if working { ProgressView("Selecting model…") }
                if saved == nil {
                    Button(warning == nil ? "Use this model" : "Confirm model change") { Task { await select() } }
                        .disabled(working || uncertain)
                }
            }
            .navigationTitle("Select model").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(working) } }
            .interactiveDismissDisabled(working)
        }
    }
    private func select() async {
        guard !working else { return }
        working = true; error = nil
        defer { working = false }
        do {
            let result = try await api.selectModel(selection.model, provider: selection.provider, confirmed: warning != nil)
            if result["confirm_required"].bool {
                warning = result["confirm_message"].string ?? result["warning"].string ?? "This model requires extra confirmation."
                return
            }
            saved = result["deferred"].bool ? "The gateway will apply this selection at the next turn." : "Selected for this Bot Chat."
        } catch {
            self.error = botToolsError(error) + " Close this sheet and refresh before trying again."
            uncertain = true
        }
    }
}

private struct BotUsageSection: View {
    let usage: JSON
    var body: some View {
        Section("Provider usage") {
            if !usage["accounts"].array.isEmpty {
                ForEach(Array(usage["accounts"].array.enumerated()), id: \.offset) { index, account in
                    VStack(alignment: .leading, spacing: 8) {
                        Text((account["label"].string ?? "").isEmpty ? "Account \(index + 1)" : account["label"].string!).font(.headline)
                        Text(account["state"].string ?? "unknown").font(.subheadline).foregroundStyle(.secondary)
                        usageWindows(account["windows"].array)
                    }.padding(.vertical, 4)
                }
            } else if !usage["windows"].array.isEmpty { usageWindows(usage["windows"].array) }
            else { Text("Live usage is not available for this provider.").foregroundStyle(.secondary) }
        }
    }
    @ViewBuilder private func usageWindows(_ windows: [JSON]) -> some View {
        ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
            if let used = window["used_percent"].number {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(window["label"].string ?? "Usage"): \(used, specifier: "%.0f")% used").font(.subheadline)
                    ProgressView(value: min(100, max(0, used)), total: 100).accessibilityHidden(true)
                    if let resets = window["resets_at"].string { Text("Resets: \(resets)").font(.subheadline).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
