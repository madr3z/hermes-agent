import SwiftUI
import HermesGateway

struct BotToolsView: View {
    let bot: Bot
    let store: PhoneStore
    var runtimeID: String? = nil
    var body: some View {
        DispatchList {
            DispatchSection { BotIdentityLabel(name: bot.name, detail: "Your bot, set up your way") }
            DispatchSection("Work with your bot") {
                NavigationLink { BotToolsetsView(bot: bot, store: store, runtimeID: runtimeID) } label: {
                    PhoneFeatureRow(title: "Tools and toolsets", detail: "Enabled settings and current chat tools", systemImage: "wrench.and.screwdriver")
                }
                NavigationLink { ConnectorsView(bot: bot, store: store) } label: {
                    PhoneFeatureRow(title: "Connectors", detail: "Accounts, apps and services", systemImage: "puzzlepiece.extension")
                }
                NavigationLink { BotRoutinesView(bot: bot, store: store) } label: {
                    PhoneFeatureRow(title: "Scheduled tasks", detail: "Work that happens while you’re away", systemImage: "calendar.badge.clock")
                }
                NavigationLink { BotSkillsView(bot: bot, store: store) } label: {
                    PhoneFeatureRow(title: "Skills", detail: "What this bot knows how to do", systemImage: "books.vertical")
                }
            }
            DispatchSection {
                NavigationLink { BotModelView(bot: bot, store: store, runtimeID: runtimeID) } label: {
                    PhoneFeatureRow(title: "Model and usage", detail: "Current model, limits and readiness", systemImage: "cpu")
                }
                NavigationLink { VMControlView(bot: bot, store: store) } label: {
                    PhoneFeatureRow(title: "Computer", detail: "Desktop, terminal and power", systemImage: "desktopcomputer")
                }
            } header: { Text("Manage") } footer: {
                Text("Settings and accounts belong to \(bot.name). Your other bots keep their own setup.")
            }
        }
        .dispatchTitle("Bot settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
