import SwiftUI
import HermesGateway

struct CreateBotView: View {
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var gatewayID: UUID?
    @State private var name = ""
    @State private var soul = ""
    @State private var cpu = 2
    @State private var memory = 2048
    @State private var disk = 20
    @State private var copyCredentials = false
    @State private var capabilities: JSON = .null
    @State private var requests: [JSON] = []
    @State private var error: String?
    @State private var working = false
    @State private var deleting: VMDeletionTarget?
    @State private var submission = BotCreationSubmission()
    @State private var password = ""
    @State private var passwordConfirmation = ""
    private var requestID: String? { submission.requestID }
    private var validationError: String? { BotCreationSubmission.validationError(name: name, password: password, confirmation: passwordConfirmation, capabilities: capabilities) }
    private let route = "api/plugins/bot-provisioning/v1/"
    private var mainEndpoints: [GatewayEndpoint] { store.endpoints.filter { !$0.baseURL.path.contains("/gateways/") } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhoneNotice(title: "A bot with its own machine", message: "Give your bot a purpose, then choose its VM resources and login.", systemImage: "sparkles")
                }
                Section("Controller") {
                    Picker("Gateway", selection: $gatewayID) {
                        Text("Choose gateway").tag(UUID?.none)
                        ForEach(mainEndpoints) { Text($0.label).tag(Optional($0.id)) }
                    }.disabled(working || requestID != nil)
                }
                if capabilities["available"].bool {
                    Section("Bot") {
                        TextField("Name", text: $name).autocorrectionDisabled().textInputAutocapitalization(.never)
                        TextField("Personality and purpose (optional)", text: $soul, axis: .vertical).lineLimit(3...6)
                    }.disabled(working || requestID != nil)
                    Section("VM login") {
                        LabeledContent("Username", value: BotCreationSubmission.usernameError(name, capabilities: capabilities) == nil ? name : "Enter a valid bot name")
                        Text("The bot name is also its Linux username. This login is separate from the controller login.").font(.footnote).foregroundStyle(.secondary)
                        SecureField("VM password", text: $password).textContentType(.newPassword).privacySensitive()
                        SecureField("Confirm VM password", text: $passwordConfirmation).textContentType(.newPassword).privacySensitive()
                        if requestID != nil {
                            Text(submission.needsPassword ? "Request not found. Re-enter the original password to retry the same request." : "Check the saved request first. A found receipt recovers without a password.").font(.footnote).foregroundStyle(.secondary)
                        }
                        if let validationError, requestID == nil || submission.needsPassword { Text(validationError).font(.footnote).foregroundStyle(.secondary) }
                    }.disabled(working)
                    Section("VM resources") {
                        Stepper("CPU: \(cpu) cores", value: $cpu, in: resourceRange("cpu", fallback: 1...4))
                        Stepper("Memory: \(memory) MiB", value: $memory, in: resourceRange("memory_mib", fallback: 2048...8192), step: 512)
                        Stepper("Disk: \(disk) GiB", value: $disk, in: resourceRange("disk_gib", fallback: 20...100), step: 10)
                    }.disabled(working || requestID != nil)
                    Section {
                        Toggle("Copy main provider API keys", isOn: $copyCredentials)
                        Text("Copies the main controller’s available provider API keys on the server. Model settings are separate. Codex requires sign-in on each bot. Keys never pass through this phone.").font(.footnote).foregroundStyle(.secondary)
                        if copyCredentials { Text(capabilities["credential_keys"].array.compactMap(\.string).joined(separator: ", ")).font(.caption) }
                    }.disabled(working || requestID != nil)
                    Section {
                        Button(requestID == nil ? "Create Bot" : submission.needsPassword && validationError == nil ? "Retry Same Request" : "Check Request") { Task { await submit() } }
                            .disabled(working || (requestID == nil && validationError != nil))
                        if requestID != nil { Text("This request keeps the same ID when retried, so it cannot create a second VM.").font(.footnote) }
                    }
                } else {
                    Section { PhoneNotice(title: gatewayID == nil ? "Choose a controller" : working ? "Checking availability…" : "Bot creation unavailable", message: "The controller must have the provisioning service enabled.", systemImage: "desktopcomputer") }
                }
                if working { ProgressView("Checking controller…") }
                if let error { Section { PhoneNotice(title: "Could not complete the request", message: error); Button("Refresh") { Task { await load() } }.disabled(working) } }
                if !requests.isEmpty {
                    Section("Provisioning requests") {
                        ForEach(requests, id: \.self) { request in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(request["name"].string ?? "Bot").font(.headline)
                                Text(request["phase"].string ?? "Unknown").foregroundStyle(.secondary)
                                if let message = request["error"]["message"].string { Text(message).foregroundStyle(.red) }
                                if capabilities["vm_delete"].bool, request["phase"].string != "deleted", let gatewayID,
                                   let id = request["request_id"].string, let target = VMDeletionTarget(mainID: gatewayID, requestID: id) {
                                    Button("Delete Bot and VM…", role: .destructive) { deleting = target }.disabled(working)
                                }
                                if request["phase"].string == "ready" {
                                    Button("Connect Bot") { Task { await connect(request) } }.disabled(working)
                                }
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Create Bot").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $deleting, onDismiss: { Task { await refreshRequests() } }) { target in VMDeletionView(target: target, store: store) }
            .onDisappear { password = ""; passwordConfirmation = "" }
            .onChange(of: gatewayID) { _, _ in password = ""; passwordConfirmation = "" }
            .task { if gatewayID == nil { gatewayID = mainEndpoints.first?.id } }
            .task(id: gatewayID) {
                await load()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    if requests.contains(where: { ["queued", "provisioning"].contains($0["phase"].string ?? "") }) { await refreshRequests() }
                }
            }
        }
    }
    private func resourceRange(_ key: String, fallback: ClosedRange<Int>) -> ClosedRange<Int> {
        let resource = capabilities["resources"][key]
        guard let min = resource["min"].number, let max = resource["max"].number, min <= max else { return fallback }
        return Int(min)...Int(max)
    }
    private func load() async {
        guard let gatewayID else { return }
        working = true; error = nil; capabilities = .null
        submission.restore(gatewayID: gatewayID)
        if let saved = submission.pending {
            name = saved["name"].string ?? ""; soul = saved["soul"].string ?? ""
            copyCredentials = saved["credentials"]["copy"].bool
        }
        defer { working = false }
        do {
            let client = try await store.client(for: gatewayID)
            if submission.pending != nil, let _ = try await submission.recover(client: client) { clearForm() }
            capabilities = try await client.http(route + "capabilities")
            cpu = Int(capabilities["resources"]["cpu"]["default"].number ?? 2)
            memory = Int(capabilities["resources"]["memory_mib"]["default"].number ?? 2048)
            disk = Int(capabilities["resources"]["disk_gib"]["default"].number ?? 20)
            if let saved = submission.pending {
                cpu = Int(saved["resources"]["cpu"].number ?? Double(cpu))
                memory = Int(saved["resources"]["memory_mib"].number ?? Double(memory))
                disk = Int(saved["resources"]["disk_gib"].number ?? Double(disk))
            }
            requests = try await client.http(route + "requests")["requests"].array
        } catch { self.error = error.localizedDescription }
    }
    private func refreshRequests() async {
        guard let gatewayID else { return }
        do { requests = try await store.client(for: gatewayID).http(route + "requests")["requests"].array }
        catch { self.error = error.localizedDescription }
    }
    private func submit() async {
        guard let gatewayID, !working else { return }
        working = true; error = nil
        defer { working = false }
        let body = JSON.object(["name": .string(name), "resources": .object(["cpu": .number(Double(cpu)), "memory_mib": .number(Double(memory)), "disk_gib": .number(Double(disk))]), "credentials": .object(["copy": .bool(copyCredentials), "source_profile": .string("default")]), "soul": .string(soul)])
        let submittedPassword = password, submittedConfirmation = passwordConfirmation
        do {
            let client = try await store.client(for: gatewayID)
            _ = try await submission.submit(body: body, password: submittedPassword, confirmation: submittedConfirmation, capabilities: capabilities, client: client)
            clearForm()
            await refreshRequests()
        } catch { self.error = submittedPassword.isEmpty ? error.localizedDescription : error.localizedDescription.replacingOccurrences(of: submittedPassword, with: "[redacted]") }
    }
    private func clearForm() {
        name = ""; soul = ""; copyCredentials = false; password = ""; passwordConfirmation = ""
    }
    private func connect(_ request: JSON) async {
        guard let main = store.endpoints.first(where: { $0.id == gatewayID }) else { return }
        working = true; defer { working = false }
        do {
            try await store.addProvisioned(request, main: main)
            if capabilities["vm_delete"].bool { store.vmDeletionControllers.insert(main.id) }
            dismiss()
        }
        catch { self.error = error.localizedDescription }
    }
}
