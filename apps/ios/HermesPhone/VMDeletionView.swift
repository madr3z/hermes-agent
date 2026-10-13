import SwiftUI
import HermesGateway

struct VMDeletionView: View {
    let target: VMDeletionTarget
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var deletion = VMDeletionControl()
    @State private var confirming = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            DispatchForm {
                DispatchSection("Managed bot") {
                    BotIdentityLabel(name: deletion.name, detail: deletion.phase.capitalized)
                }
                DispatchSection("Permanent deletion") {
                    PhoneNotice(title: "Delete the bot and its machine", message: "This stops the bot and permanently removes its VM, workspace and files. Existing backups are retained.", systemImage: "trash")
                    if deletion.supported {
                        Button(deletion.receipt["phase"].string == "failed" ? "Try deletion again…" : "Delete Bot and VM…", role: .destructive) { confirming = true }.disabled(!deletion.canConfirm)
                        if deletion.missingReceipt {
                            Button("Retry same deletion") { Task { await deletion.retrySameOperation() } }.disabled(deletion.working)
                        }
                    } else { Text("Deletion requires a managed VM and a controller that supports VM deletion.").foregroundStyle(DispatchStyle.secondary) }
                    Button("Refresh status") { Task { await deletion.refresh() } }.disabled(deletion.working)
                    if deletion.deleted { Button("Finish local cleanup") { finish() } }
                    if deletion.working { ProgressView() }
                    if ["queued", "deleting"].contains(deletion.receipt["phase"].string ?? "") { Text("Deletion continues on the controller if you close this screen.").font(.footnote) }
                    if let message = deletion.receipt["error"]["message"].string { Text(message).foregroundStyle(DispatchStyle.rust) }
                    if let message = deletion.error ?? error { PhoneNotice(title: "Deletion needs attention", message: message) }
                }
            }
            .dispatchTitle("Delete managed bot").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .alert("Delete \(deletion.name) and its VM?", isPresented: $confirming) {
                Button("Delete Bot and VM", role: .destructive) { Task { await deletion.confirm() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This stops the bot and permanently removes its VM, workspace and files. This cannot be undone. Existing backups are retained.") }
            .task {
                do {
                    let client = try await store.client(for: target.mainID)
                    await deletion.load(target: target, client: client)
                    if deletion.supported { store.vmDeletionControllers.insert(target.mainID) }
                    else { store.vmDeletionControllers.remove(target.mainID) }
                    try store.recordManagedOwner(deletion.status, mainID: target.mainID)
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        if deletion.pending != nil && !["deleted", "failed"].contains(deletion.phase) { await deletion.refresh() }
                    }
                } catch { self.error = error.localizedDescription }
            }
            .onChange(of: deletion.deleted) { _, deleted in
                if deleted { finish() }
            }
        }
    }
    private func finish() {
        do { try store.removeDeletedVM(mainID: target.mainID, requestID: target.requestID); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
