import SwiftUI
import HermesGateway

struct SavedChatsView: View {
    let chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var history = chat.savedChats
        NavigationStack {
            DispatchList {
                DispatchSection {
                    Text("Saved chats on \(chat.bot.name)’s gateway and profile. Viewing history keeps your Bot Chat unchanged.")
                        .font(.caption).foregroundStyle(DispatchStyle.secondary)
                }
                if let error = history.error { PhoneNotice(title: "History unavailable", message: error) }
                ForEach(history.rows) { row in
                    NavigationLink {
                        SavedChatTranscriptView(chat: chat, row: row)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.title).font(DispatchStyle.serif(23, relativeTo: .headline))
                            if !row.preview.isEmpty { Text(row.preview).font(.subheadline).foregroundStyle(DispatchStyle.secondary).lineLimit(2) }
                            HStack {
                                Text(row.source.isEmpty ? "Chat" : row.source)
                                if let date = row.startedAt { Text(date, style: .date) }
                                Text("\(row.messageCount) messages")
                            }.font(.caption).foregroundStyle(DispatchStyle.secondary)
                        }.padding(.vertical, 4)
                    }
                }
                if history.loading { ProgressView("Loading saved chats…") }
                else if history.rows.isEmpty && history.error == nil { Text(history.query.isEmpty ? "No saved chats." : "No matching saved chats.").foregroundStyle(DispatchStyle.secondary) }
                if history.hasMore { Button("Load more chats") { Task { await history.load(more: true) } } }
            }
            .dispatchTitle("Saved chats")
            .searchable(text: $history.query, prompt: "Search saved messages")
            .refreshable { await history.load() }
            .task(id: history.query + history.bindingID.uuidString) {
                if !history.query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                guard !Task.isCancelled else { return }
                await history.load()
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct SavedChatTranscriptView: View {
    let chat: ChatStore
    let row: SavedChat
    var body: some View {
        let history = chat.savedChats
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                Text("Read-only saved chat · \(chat.bot.profile)").font(.caption).foregroundStyle(DispatchStyle.secondary)
                if let error = history.error { PhoneNotice(title: "Transcript unavailable", message: error) }
                if history.hasEarlier {
                    Button("Load earlier messages") { Task { await history.loadMessages() } }
                        .disabled(history.transcriptLoading)
                }
                if history.transcriptLoading { ProgressView("Loading transcript…") }
                ForEach(history.selected?.id == row.id ? history.messages : []) { message in
                    ChatMessageView(message: message, client: chat.client, profile: chat.bot.profile, storedSessionID: row.id, botName: chat.bot.name)
                }
                if !history.transcriptLoading && history.messages.isEmpty && history.error == nil { Text("No visible messages in this saved chat.").foregroundStyle(DispatchStyle.secondary) }
            }.padding(20)
        }
        .dispatchTitle(row.title).navigationBarTitleDisplayMode(.inline)
        .task(id: row.id + history.bindingID.uuidString) { await history.open(row) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if history.selected?.id == row.id, let exported = history.export(profile: chat.bot.profile), !history.messages.isEmpty {
                    ShareLink(item: exported, subject: Text(row.title), preview: SharePreview(row.title)) {
                        Label(history.hasEarlier ? "Share loaded messages" : "Share transcript", systemImage: "square.and.arrow.up")
                    }.disabled(history.transcriptLoading)
                }
            }
        }
    }
}
