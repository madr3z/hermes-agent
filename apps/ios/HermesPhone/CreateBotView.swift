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
    @State private var requestID: String?
    @State private var submittedBody: JSON?
    private let route = "api/plugins/bot-provisioning/v1/"
    private var mainEndpoints: [GatewayEndpoint] { store.endpoints.filter { !$0.baseURL.path.contains("/gateways/") } }
    var body: some View {
        NavigationStack {
            Form {
                Section("Controller") {
                    Picker("Gateway", selection: $gatewayID) {
                        Text("Choose gateway").tag(UUID?.none)
                        ForEach(mainEndpoints) { Text($0.label).tag(Optional($0.id)) }
                    }.disabled(working || requestID != nil)
                }
                if capabilities["available"].bool {
                    Section("Bot") {
                        TextField("Name", text: $name).autocorrectionDisabled()
                        TextField("Personality and purpose (optional)", text: $soul, axis: .vertical).lineLimit(3...6)
                    }.disabled(requestID != nil)
                    Section("Linux VM") {
                        Stepper("CPU: \(cpu) cores", value: $cpu, in: resourceRange("cpu", fallback: 1...4))
                        Stepper("Memory: \(memory) MiB", value: $memory, in: resourceRange("memory_mib", fallback: 2048...8192), step: 512)
                        Stepper("Disk: \(disk) GiB", value: $disk, in: resourceRange("disk_gib", fallback: 20...100), step: 10)
                    }.disabled(requestID != nil)
                    Section {
                        Toggle("Copy provider credentials", isOn: $copyCredentials)
                        Text("Copies the controller's available provider API keys on the server. OAuth grants, messaging tokens and cluster credentials are excluded. Keys never pass through this phone.").font(.footnote).foregroundStyle(.secondary)
                        if copyCredentials { Text(capabilities["credential_keys"].array.compactMap(\.string).joined(separator: ", ")).font(.caption) }
                    }.disabled(requestID != nil)
                    Section {
                        Button(requestID == nil ? "Create Bot" : "Retry Same Request") { Task { await submit() } }
                            .disabled(working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if requestID != nil { Text("This request keeps the same ID when retried, so it cannot create a second VM.").font(.footnote) }
                    }
                } else {
                    Section { Text("Create Bot requires the provisioning service on this gateway. Existing bots remain available from the roster.").foregroundStyle(.secondary) }
                }
                if working { ProgressView() }
                if let error { Section { Text(error).foregroundStyle(.red); Button("Refresh") { Task { await load() } }.disabled(working) } }
                if !requests.isEmpty {
                    Section("Provisioning requests") {
                        ForEach(requests, id: \.self) { request in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(request["name"].string ?? "Bot").font(.headline)
                                Text(request["phase"].string ?? "Unknown").foregroundStyle(.secondary)
                                if let message = request["error"]["message"].string { Text(message).foregroundStyle(.red) }
                                if request["phase"].string == "ready" {
                                    Button("Connect Bot") { Task { await connect(request) } }.disabled(working)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Create Bot").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
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
        if submittedBody == nil, let data = UserDefaults.standard.data(forKey: "provision-request-\(gatewayID)"),
           let saved = try? JSONDecoder().decode(JSON.self, from: data) {
            submittedBody = saved; requestID = saved["request_id"].string
            name = saved["name"].string ?? ""; soul = saved["soul"].string ?? ""
            copyCredentials = saved["credentials"]["copy"].bool
        }
        defer { working = false }
        do {
            let client = try await store.client(for: gatewayID)
            capabilities = try await client.http(route + "capabilities")
            cpu = Int(capabilities["resources"]["cpu"]["default"].number ?? 2)
            memory = Int(capabilities["resources"]["memory_mib"]["default"].number ?? 2048)
            disk = Int(capabilities["resources"]["disk_gib"]["default"].number ?? 20)
            if let saved = submittedBody {
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
        if submittedBody == nil {
            requestID = UUID().uuidString.lowercased()
            submittedBody = .object(["request_id": .string(requestID!), "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "resources": .object(["cpu": .number(Double(cpu)), "memory_mib": .number(Double(memory)), "disk_gib": .number(Double(disk))]), "credentials": .object(["copy": .bool(copyCredentials), "source_profile": .string("default")]), "soul": .string(soul)])
            // Persist an uncertain request before sending; a process exit must not turn retry into another VM.
            if let data = try? JSONEncoder().encode(submittedBody) { UserDefaults.standard.set(data, forKey: "provision-request-\(gatewayID)") }
        }
        do {
            let client = try await store.client(for: gatewayID)
            _ = try await client.http(route + "requests", body: submittedBody)
            await refreshRequests()
            UserDefaults.standard.removeObject(forKey: "provision-request-\(gatewayID)")
            submittedBody = nil; requestID = nil; name = ""; soul = ""; copyCredentials = false
        } catch { self.error = error.localizedDescription }
    }
    private func connect(_ request: JSON) async {
        guard let main = store.endpoints.first(where: { $0.id == gatewayID }) else { return }
        working = true; defer { working = false }
        do { try await store.addProvisioned(request, main: main); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
