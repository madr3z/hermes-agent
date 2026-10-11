import SwiftUI
import HermesGateway

struct BotToolsView: View {
    let bot: Bot
    let store: PhoneStore
    var runtimeID: String? = nil
    var body: some View {
        List {
            Section {
                BotIdentityLabel(name: bot.name, detail: "Tools for this bot")
            }
            Section {
                NavigationLink { BotRoutinesView(bot: bot, store: store) } label: {
                    Label("Scheduled tasks", systemImage: "calendar.badge.clock")
                }
                NavigationLink { BotSkillsView(bot: bot, store: store) } label: {
                    Label("Installed skills", systemImage: "books.vertical")
                }
                NavigationLink { BotModelView(bot: bot, store: store, runtimeID: runtimeID) } label: {
                    Label("Model and status", systemImage: "cpu")
                }
            } footer: {
                Text("Tasks and skills stay on \(bot.name)’s gateway.")
            }
        }
        .navigationTitle("Bot tools")
        .navigationBarTitleDisplayMode(.inline)
    }
}
