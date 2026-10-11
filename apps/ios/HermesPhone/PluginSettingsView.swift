import SwiftUI
import HermesGateway

struct PluginSettingsView: View {
    let plugin: InstalledPlugin
    let connectors: ConnectorsStore
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var secrets: [String: String] = [:]
    @State private var error: String?
    init(plugin: InstalledPlugin, connectors: ConnectorsStore, store: PhoneStore) {
        self.plugin = plugin; self.connectors = connectors; self.store = store
        var initial: [String: String] = [:]
        for field in plugin.settings where field["type"].string != "secret" {
            let key = field["key"].string ?? ""
            let value = field["value"] == .null ? field["default"] : field["value"]
            if let string = value.string { initial[key] = string }
            else if value != .null, let data = try? JSONEncoder().encode(value) { initial[key] = String(data: data, encoding: .utf8) }
        }
        _values = State(initialValue: initial)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("Settings are saved on \(connectors.bot.name). Secret values are never read back to this phone.").font(.footnote) }
                ForEach(plugin.settings, id: \.self) { field in
                    Section(field["label"].string ?? field["key"].string ?? "Setting") {
                        editor(field)
                        if let description = field["description"].string, !description.isEmpty { Text(description).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                if let error = connectors.error { Text(error).foregroundStyle(.red) }
                Button("Save settings", action: save).disabled(connectors.working)
            }
            .navigationTitle(plugin.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(connectors.working) } }
        }.interactiveDismissDisabled(connectors.working).onDisappear { secrets.removeAll() }
    }
    @ViewBuilder private func editor(_ field: JSON) -> some View {
        let key = field["key"].string ?? ""
        let type = field["type"].string ?? "string"
        if type == "secret" {
            if field["env"].string != nil {
                SecureField(field["has_value"].bool ? "New credential (leave blank to keep)" : "Credential", text: binding(key, secret: true))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
            } else { Text("Configure this credential from your Mac.").font(.footnote) }
        } else if type == "boolean" {
            Toggle("Enabled", isOn: Binding(get: { values[key] == "true" }, set: { values[key] = $0 ? "true" : "false" }))
        } else if type == "enum" {
            Picker("Value", selection: binding(key)) {
                ForEach(field["choices"].array.compactMap(\.string), id: \.self) { Text($0).tag($0) }
            }
        } else {
            TextField(type == "json" ? "JSON value" : "Value", text: binding(key), axis: .vertical)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }
    private func binding(_ key: String, secret: Bool = false) -> Binding<String> {
        Binding(get: { secret ? secrets[key] ?? "" : values[key] ?? "" }, set: { if secret { secrets[key] = $0 } else { values[key] = $0 } })
    }
    private func settings() throws -> [String: JSON] {
        var result: [String: JSON] = [:]
        for field in plugin.settings where field["type"].string != "secret" {
            guard let key = field["key"].string else { continue }
            guard let value = values[key] else { continue }
            switch field["type"].string {
            case "boolean": result[key] = .bool(value == "true")
            case "number":
                guard let number = Double(value), number.isFinite else { throw GatewayError.message("Enter a number for \(field["label"].string ?? key).") }
                result[key] = .number(number)
            case "json":
                guard let data = value.data(using: .utf8), let json = try? JSONDecoder().decode(JSON.self, from: data) else { throw GatewayError.message("Enter valid JSON for \(field["label"].string ?? key).") }
                result[key] = json
            default: result[key] = .string(value)
            }
        }
        return result
    }
    private func save() {
        do {
            let settings = try settings()
            let submitted = secrets; secrets.removeAll(); error = nil
            let fields = plugin.settings
            Task {
                let saved = await connectors.mutate(store: store) { api in
                    do {
                        var result: JSON = .object(["ok": .bool(true)])
                        if !settings.isEmpty { result = try await api.call("plugins.manage", ["action": .string("settings"), "key": .string(plugin.id), "values": .object(settings)]) }
                        for field in fields where field["type"].string == "secret" {
                            guard let key = field["key"].string, let env = field["env"].string, let value = submitted[key], !value.isEmpty else { continue }
                            guard let gateway = connectors.gateway else { throw GatewayError.message("Reconnect to the gateway before saving credentials.") }
                            _ = try await gateway.http("api/env", profile: connectors.bot.profile, body: .object(["key": .string(env), "value": .string(value), "profile": .string(connectors.bot.profile)]), method: "PUT")
                        }
                        return result
                    } catch {
                        let message = submitted.values.filter { !$0.isEmpty }.reduce(error.localizedDescription) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
                        throw GatewayError.message(message)
                    }
                }
                if saved { dismiss() }
            }
        } catch { self.error = error.localizedDescription }
    }
}
