import SwiftUI
import HermesGateway

struct DispatchTodayView: View {
    let store: PhoneStore
    let attention: [DispatchAttention]
    let openChat: (Bot) -> Void
    let openSettings: () -> Void
    let connect: () -> Void
    let showChats: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .footnote) private var detailSize = 13

    private var recent: [Bot] {
        store.bots.filter { !$0.conversationPreview.isEmpty }.sorted { $0.lastActive > $1.lastActive }
    }
    private var preferredBot: Bot? {
        store.bots.first { $0.name.lowercased() == "assistant" } ?? store.bots.first
    }
    var body: some View {
        if #available(iOS 26, *) {
            page.scrollEdgeEffectHidden()
        } else {
            page
        }
    }
    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                masthead
                hero
                if let error = store.error {
                    PhoneNotice(title: "Could not refresh", message: error)
                    Button("Try again") { Task { await store.refresh() } }.frame(minHeight: 44)
                }
                if store.loading && store.bots.isEmpty {
                    ProgressView("Refreshing bots…").padding(.vertical, 20)
                } else if let item = attention.first {
                    request(item)
                } else {
                    welcome
                }
                recentConversations
            }
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 22)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(DispatchStyle.paper.ignoresSafeArea())
        .foregroundStyle(DispatchStyle.ink)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let bot = preferredBot {
                Button { openChat(bot) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "paperclip").font(.title2)
                        Text("Message \(bot.name)").font(.body).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                            .foregroundStyle(DispatchStyle.forest)
                    }
                    .foregroundStyle(DispatchStyle.secondary)
                    .padding(.horizontal, 17).padding(.vertical, 13)
                    .frame(minHeight: 54)
                    .overlay { RoundedRectangle(cornerRadius: 24).stroke(DispatchStyle.rule, lineWidth: 1) }
                    .contentShape(RoundedRectangle(cornerRadius: 24))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the chat composer to write a message or attach a file")
                .accessibilityIdentifier("dispatchCompose")
                .padding(.horizontal, 14).padding(.top, 8)
                .background(DispatchStyle.paper)
            }
        }
        .task { await refreshKnownAccounts() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshKnownAccounts() } }
        }
    }
    private var masthead: some View {
        HStack {
            Text("HERMES").font(DispatchStyle.serif(17, relativeTo: .headline)).tracking(4)
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape").font(.system(size: 22, weight: .regular))
                    .frame(width: 44, height: 44)
                    .overlay { Circle().stroke(DispatchStyle.rule, lineWidth: 1) }
            }.buttonStyle(.plain).accessibilityLabel("Settings").accessibilityIdentifier("dispatchSettings")
        }
    }
    private var hero: some View {
        VStack(alignment: .leading, spacing: 13) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                    .font(.caption2).tracking(2.5).foregroundStyle(DispatchStyle.secondary)
            }
            Text("A little help.\nA clearer day.")
                .font(DispatchStyle.serif(typeSize.isAccessibilitySize ? 38 : 46, relativeTo: .largeTitle))
                .tracking(-0.6).lineSpacing(-2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 24) {
                Text("Your agents take care of the details, so you can focus on what matters.")
                    .font(.callout).lineSpacing(3).foregroundStyle(DispatchStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !typeSize.isAccessibilitySize {
                    Text("SMALL\nSTEPS\nFURTHER\n—")
                        .font(DispatchStyle.serif(7, relativeTo: .caption2)).tracking(1.6)
                        .lineSpacing(5).foregroundStyle(DispatchStyle.secondary)
                        .padding(.top, 8).accessibilityHidden(true)
                }
            }
        }
        .padding(.top, 4).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topTrailing) {
            if !typeSize.isAccessibilitySize {
                Image("DispatchBranch").resizable().scaledToFit()
                    .frame(width: 112, height: 172)
                    .offset(x: 24, y: 0).opacity(0.6)
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .clipped()
    }
    private func request(_ item: DispatchAttention) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Circle().fill(DispatchStyle.rust).frame(width: 10, height: 10)
                Text("NEEDS YOU").font(.caption2.weight(.semibold)).tracking(2.3)
                if attention.count > 1 { Text("\(attention.count)").font(.caption.weight(.semibold)) }
            }.foregroundStyle(DispatchStyle.rust)
            HStack(spacing: 14) {
                DispatchAvatar()
                Text(item.bot.name).font(.body)
            }
            Text(item.title).font(DispatchStyle.serif(29)).fixedSize(horizontal: false, vertical: true)
            if !item.detail.isEmpty {
                Text(item.detail).font(.system(size: detailSize)).foregroundStyle(DispatchStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DispatchAction(title: item.action) { openChat(item.bot) }
                .accessibilityIdentifier("dispatchReviewRequest")
            ForEach(attention.dropFirst()) { next in
                Button { openChat(next.bot) } label: {
                    HStack {
                        Text(next.bot.name + " · " + next.title).font(.subheadline).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.padding(.vertical, 10).frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
        }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.endpoints.isEmpty ? "WELCOME HOME" : "A MOMENT FOR YOU")
                .font(.caption.weight(.semibold)).tracking(2.3).foregroundStyle(DispatchStyle.forest)
            Text(store.endpoints.isEmpty ? "A little help starts here." : "What’s on your mind?")
                .font(DispatchStyle.serif(28)).fixedSize(horizontal: false, vertical: true)
            Text(store.endpoints.isEmpty
                 ? "Connect your Hermes controller to bring your bots, conversations and calls together."
                 : "Pick up a conversation, or give your bot something new to work on.")
                .font(.subheadline).foregroundStyle(DispatchStyle.secondary).lineSpacing(3)
            if store.endpoints.isEmpty {
                DispatchAction(title: "Connect to Hermes", action: connect).accessibilityIdentifier("connectGateway")
            } else if let bot = preferredBot {
                DispatchAction(title: "Talk to \(bot.name)") { openChat(bot) }
            } else {
                DispatchAction(title: "Manage connections", action: openSettings)
            }
        }
    }
    private var recentConversations: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(DispatchStyle.rule).frame(height: 1)
            Button(action: showChats) {
                HStack {
                    Text("RECENT CONVERSATIONS").font(.caption2).tracking(2)
                    Spacer()
                    Image(systemName: "chevron.right").font(.body.weight(.light))
                }.foregroundStyle(DispatchStyle.secondary).padding(.vertical, 18).frame(minHeight: 44)
            }.buttonStyle(.plain)
            if recent.isEmpty {
                Text("Your conversations will appear here.")
                    .font(.subheadline).foregroundStyle(DispatchStyle.secondary).padding(.bottom, 12)
            }
            ForEach(Array(recent.prefix(2))) { bot in
                DispatchConversationRow(bot: bot, detail: store.endpoints.first { $0.id == bot.endpointID }?.label,
                                        open: { openChat(bot) })
                if bot.id != recent.prefix(2).last?.id {
                    Rectangle().fill(DispatchStyle.rule).frame(height: 1).padding(.vertical, 2)
                }
            }
        }
    }
    private func refreshKnownAccounts() async {
        // Only inspect chats already opened by the user. Home must not resume other profiles.
        for chat in Array(store.activeChats.values) where chat.connected {
            await chat.login.refresh(chat: chat)
        }
    }
}
