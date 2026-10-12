import HermesGateway

/// A navigation summary, never an approval or an account selection.
struct DispatchAttention: Identifiable {
    let id: String
    let bot: Bot
    let title: String
    let detail: String
    let action: String

    @MainActor static func items(in store: PhoneStore) -> [DispatchAttention] {
        store.bots.flatMap { bot -> [DispatchAttention] in
            guard let chat = store.activeChats[bot.endpointID], chat.bot.id == bot.id,
                  chat.connected, !chat.loading, let client = chat.client,
                  client.connected, store.clients[bot.endpointID] === client else { return [] }
            return summaries(bot: bot, requests: chat.requests.items, logins: chat.login.requests)
        }
    }

    static func summaries(bot: Bot, requests: [ChatHumanRequest], logins: [LoginHandoff]) -> [DispatchAttention] {
        let accounts = logins.filter(\.needsAction).map { login in
            let unconfirmed = login.continuationStatus == "unconfirmed"
            return DispatchAttention(id: bot.id + ":login:" + login.id, bot: bot,
                              title: unconfirmed ? "Check your conversation." : login.status == "authorized" ? "Confirm your account." : "Sign in to continue.",
                              detail: login.detail.isEmpty ? login.name : login.detail,
                              action: unconfirmed ? "Open conversation" : "Review account")
        }
        let questions = requests.compactMap { request -> DispatchAttention? in
            switch request.kind {
            case .approval(_, _, let description, _):
                return DispatchAttention(id: bot.id + ":request:" + request.id, bot: bot,
                                         title: "Your permission is needed.", detail: description,
                                         action: "Review request")
            case .clarify(let questions, let answers):
                guard let question = questions.first(where: { answers[$0.id] == nil }) else { return nil }
                return DispatchAttention(id: bot.id + ":request:" + request.id, bot: bot,
                                         title: question.text, detail: "Reply in your conversation with \(bot.name).",
                                         action: "Answer question")
            }
        }
        return accounts + questions
    }
}
