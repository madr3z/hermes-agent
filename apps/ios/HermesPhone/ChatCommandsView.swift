import SwiftUI
import HermesGateway

struct ChatCommandsView: View {
    let chat: ChatStore
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    private var commands: ChatCommandsStore { chat.commands }
    private var visible: [ChatCommand] {
        (commands.catalog?.commands ?? []).filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        DispatchList {
            DispatchSection { BotIdentityLabel(name: chat.bot.name, detail: "Commands for this chat") } footer: {
                Text("Choose a command to fill the composer, add any arguments, then send. Commands run on this bot’s gateway. Availability comes from its current registry.")
            }
            if commands.loading { ProgressView("Loading commands…") }
            if !commands.connected { PhoneNotice(title: "Disconnected", message: "Return to Bot Chat and reconnect to load commands.") }
            if let error = commands.error { PhoneNotice(title: "Commands unavailable", message: error) }
            if let warning = commands.catalog?.warning, !warning.isEmpty { Text(warning).font(.subheadline).foregroundStyle(DispatchStyle.secondary) }
            ForEach(visible) { command in
                Button {
                    chat.draft = command.id + " "
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(command.id).font(.headline.monospaced())
                        Text(command.description).font(.subheadline).foregroundStyle(DispatchStyle.secondary)
                        if command.availability == "unsupported" { Text("Use Mac or terminal").font(.caption).foregroundStyle(DispatchStyle.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }.tint(DispatchStyle.forest).disabled(!commands.connected || chat.sending)
            }
        }
        .dispatchTitle("Commands").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find a command or skill")
        .task(id: commands.bindingID) { await commands.load() }
        .refreshable { await commands.load() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Refresh", systemImage: "arrow.clockwise") { Task { await commands.load() } }.disabled(commands.loading || !commands.connected) } }
    }
}

struct ChatCommandOutputView: View {
    let output: PhoneCommandOutput
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { Text(output.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
                .dispatchTitle(output.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
