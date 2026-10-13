import SwiftUI
import HermesGateway

struct ChatRequestsView: View {
    let chat: ChatStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(chat.requests.items) { item in
                ChatRequestCard(item: item, store: chat.requests, botName: chat.bot.name)
                    .id(item.id + chat.requests.bindingID.uuidString)
            }
            if let error = chat.requests.error {
                PhoneNotice(title: "Request status", message: error)
            }
        }
    }
}

private struct ChatRequestCard: View {
    let item: ChatHumanRequest
    let store: ChatRequestsStore
    let botName: String
    @State private var confirmChoice: String?
    @State private var confirmCancel = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch item.kind {
            case .approval(_, let command, let description, let choices):
                Label("\(botName) needs approval", systemImage: "hand.raised").font(DispatchStyle.serif(23, relativeTo: .headline))
                if !description.isEmpty { Text(description) }
                if !command.isEmpty { Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                Text("Choose only if you authorize this action on this bot.").font(.caption).foregroundStyle(DispatchStyle.secondary)
                ForEach(choices, id: \.self) { choice in
                    Button(ChatHumanRequest.choiceLabel(choice), role: choice == "deny" ? .destructive : nil) {
                        if choice == "deny" { Task { await store.answer(item, choice: choice) } }
                        else { confirmChoice = choice }
                    }.buttonStyle(DispatchSecondaryButtonStyle()).frame(minHeight: 44)
                }
            case .clarify(let questions, let answers):
                Label("\(botName) has a question", systemImage: "questionmark.bubble").font(DispatchStyle.serif(23, relativeTo: .headline))
                ForEach(questions) { question in
                    ChatClarifyAnswerView(question: question, accepted: answers[question.id]) { answer in
                        Task { await store.lock(item, questionID: question.id, answer: answer) }
                    }
                }
                Button("Cancel remaining questions", role: .destructive) { confirmCancel = true }.frame(minHeight: 44)
            }
            if store.working.contains(item.id) { ProgressView("Submitting your response…") }
            if store.uncertain.contains(item.id) { Text("Response outcome is unconfirmed. Reconnect to restore the current request.").font(.caption).foregroundStyle(DispatchStyle.secondary) }
        }
        .padding(16).background(DispatchStyle.wash, in: RoundedRectangle(cornerRadius: 18))
        .disabled(!store.connected || store.working.contains(item.id) || store.uncertain.contains(item.id))
        .task { await store.shown(item) }
        .confirmationDialog(confirmChoice.map(ChatHumanRequest.choiceLabel) ?? "Approve action", isPresented: Binding(get: { confirmChoice != nil }, set: { if !$0 { confirmChoice = nil } }), titleVisibility: .visible) {
            if let choice = confirmChoice { Button(ChatHumanRequest.choiceLabel(choice)) { Task { await store.answer(item, choice: choice) }; confirmChoice = nil } }
            Button("Cancel", role: .cancel) { confirmChoice = nil }
        } message: {
            Text(confirmChoice == "always" ? "This grants a persistent permission for the displayed command. It can apply to later chats." : confirmChoice == "session" ? "This permission lasts for the current chat." : "This permits the displayed action once.")
        }
        .confirmationDialog("Cancel remaining questions?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel remaining questions", role: .destructive) { Task { await store.answer(item, cancel: true) } }
            Button("Keep answering", role: .cancel) {}
        } message: { Text("Answers already submitted stay recorded. The remaining questions are cancelled.") }
    }
}

private struct ChatClarifyAnswerView: View {
    let question: ChatClarifyQuestion
    let accepted: JSON?
    let submit: (String?) -> Void
    @State private var picks: Set<String> = []
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.text).font(.subheadline.weight(.semibold))
            if let accepted {
                Label(accepted == .null ? "Skipped" : accepted.string.map(question.displayAnswer) ?? "Answered", systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(DispatchStyle.secondary)
            } else {
                ForEach(Array(question.choices.enumerated()), id: \.offset) { _, choice in
                    Button {
                        if question.multiSelect {
                            if picks.contains(choice) { picks.remove(choice) } else { picks.insert(choice) }
                        } else { picks = [choice] }
                    } label: { Label(choice, systemImage: picks.contains(choice) ? "checkmark.circle.fill" : "circle").frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(minHeight: 44).buttonStyle(DispatchSecondaryButtonStyle())
                }
                TextField(question.choices.isEmpty ? "Your answer" : "Or write your answer", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...5)
                HStack {
                    Button("Submit answer") {
                        if let answer = question.answer(picks: picks, text: text) { submit(answer) }
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && picks.isEmpty)
                    Spacer()
                    Button("Skip question") { submit(nil) }
                }.frame(minHeight: 44)
            }
        }
    }
}
